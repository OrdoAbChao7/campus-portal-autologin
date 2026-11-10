#!/bin/sh
# portal_autologin.sh - keep a captive-portal session alive with your own account.
#
# Works on OpenWrt / Linux (busybox ash or dash). The portal is plain HTTP;
# requests are made with nc, so no curl or jq is needed. HTTPS portals need a
# curl-based variant (see docs/COMPATIBILITY.md).
#
# Safety contract:
#   * credentials live in a root/user-only file, never in this script;
#   * it only acts when /api/account/status shows no live session;
#   * it never posts a login while a session is live (that kills the session);
#   * it never solves captchas: a "code 2" answer stops it with a long backoff;
#   * it never calls logout and never touches an existing session;
#   * it writes only to /tmp; the credential file is the only persistent write.
#
# Usage: portal_autologin.sh [run|status|test-login]
#   run         cron entry point; acts only when the session is gone
#   status      print the current session and local state, no side effects
#   test-login  one login attempt even if the status check passes (diagnostics)
#
# Configuration (env):
#   PORTAL_HOST        portal IP or hostname (required), e.g. 172.30.21.100
#   PORTAL_PORT        portal HTTP port (default 80)
#   PORTAL_CONF        credential file (default /etc/portal/login.conf)
#   PORTAL_NAS_CONF    NAS id file (default /etc/portal/nas.conf)
#   PORTAL_WAN_DEV     WAN interface on a gateway router (default empty)
#   PORTAL_RECONNECT   1 = ifdown/ifup PORTAL_WAN_DEV on "device IP offline"
#   PORTAL_STATE/LOG/BOUNCE/LOCK   /tmp paths

set -u

HOST="${PORTAL_HOST:-}"
PORT="${PORTAL_PORT:-80}"
CONF="${PORTAL_CONF:-/etc/portal/login.conf}"
NAS_CONF="${PORTAL_NAS_CONF:-/etc/portal/nas.conf}"
STATE="${PORTAL_STATE:-/tmp/portal_autologin.state}"
BOUNCE="${PORTAL_BOUNCE:-/tmp/portal_autologin.bounce}"
LOG="${PORTAL_LOG:-/tmp/portal_autologin.log}"
LOCK="${PORTAL_LOCK:-/tmp/portal_autologin.lock}"
WAN_DEV="${PORTAL_WAN_DEV:-}"
RECONNECT="${PORTAL_RECONNECT:-0}"

say() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG"
    logger -t portal-autologin "$*" 2>/dev/null || true
}

wan_ip() {
    [ -n "$WAN_DEV" ] || return 0
    ip -4 addr show dev "$WAN_DEV" 2>/dev/null |
        sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | head -n1
}

wan_mac() {
    [ -n "$WAN_DEV" ] || return 0
    ip link show dev "$WAN_DEV" 2>/dev/null |
        sed -n 's/.*link\/ether \([0-9a-fA-F:]*\).*/\1/p' | head -n1
}

http_exchange() {
    { printf '%s' "$1"; sleep 3; } | nc "$HOST" "$PORT"
}

http_get() {
    { printf 'GET %s HTTP/1.0\r\nHost: %s\r\nConnection: close\r\n\r\n' "$1" "$HOST"; sleep 3; } |
        nc "$HOST" "$PORT"
}

urlencode() {
    printf '%s' "$1" | awk '
        BEGIN { for (i = 32; i <= 126; i++) ord[sprintf("%c", i)] = i }
        {
            n = length($0)
            for (i = 1; i <= n; i++) {
                c = substr($0, i, 1)
                if (c ~ /[A-Za-z0-9._~-]/) printf "%s", c
                else printf "%%%02X", ord[c]
            }
        }'
}

json_code() {
    printf '%s' "$1" | tr -d '\r' |
        sed -n 's/.*"code"[[:space:]]*:[[:space:]]*\([-0-9][0-9]*\).*/\1/p' | head -n1
}

json_field() {
    printf '%s' "$1" | tr -d '\r' |
        sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n1
}

is_online() {
    resp=$(http_get /api/account/status)
    [ "$(json_code "$resp")" = 0 ] || return 1
    printf '%s' "$resp" | tr -d '\r' | grep -q '"Username"[[:space:]]*:[[:space:]]*"[^"]'
}

state_get() {
    [ -f "$STATE" ] || { echo 0; return 0; }
    value=$(sed -n "s/^$1=//p" "$STATE" | head -n1)
    case "$value" in
        ''|*[!0-9]*) echo 0 ;;
        *) echo "$value" ;;
    esac
}

state_set() {
    printf 'fail=%s\nnext=%s\n' "$1" "$2" >"$STATE"
}

rotate_log() {
    [ -f "$LOG" ] || return 0
    [ "$(wc -c <"$LOG")" -gt 65536 ] && mv "$LOG" "$LOG.1"
}

# Some NAS only re-register a device after the link comes up again; the portal
# answers "device IP offline, reconnect" until then. Off by default outside a
# gateway router; at most once per 15 minutes.
wan_reconnect() {
    [ "$RECONNECT" = 1 ] && [ -n "$WAN_DEV" ] || return 1
    now=$(date +%s)
    last=0
    [ -f "$BOUNCE" ] && last=$(sed -n '1p' "$BOUNCE" 2>/dev/null)
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    if [ $((now - last)) -lt 900 ]; then
        say "WAN reconnect skipped (already tried recently)"
        return 1
    fi
    printf '%s\n' "$now" >"$BOUNCE"
    say "portal reports the device IP is offline; reconnecting $WAN_DEV"
    ifdown "$WAN_DEV" 2>/dev/null
    sleep 3
    ifup "$WAN_DEV" 2>/dev/null
    n=0
    while [ -z "$(wan_ip)" ] && [ "$n" -lt 15 ]; do
        sleep 2
        n=$((n + 1))
    done
    sleep 3
    return 0
}

# After a link cycle the NAS may authenticate the MAC by itself; give it up to
# a minute before spending a credential login.
wait_online() {
    limit=$1
    waited=0
    while [ "$waited" -lt "$limit" ]; do
        is_online && return 0
        sleep 5
        waited=$((waited + 5))
    done
    return 1
}

# While unauthenticated the BRAS answers any port-80 request with a 302 to the
# login page; its query carries the real nasId/acip for this port. Only used
# when no NAS id was configured and the portal is reachable through the BRAS.
discover_portal() {
    DISCOVERED_NAS=""
    resp=$( { printf 'GET / HTTP/1.0\r\nHost: 1.1.1.1\r\nConnection: close\r\n\r\n'; sleep 3; } | nc 1.1.1.1 80 )
    loc=$(printf '%s' "$resp" | tr -d '\r' |
        sed -n 's/^Location:[[:space:]]*\(.*\)$/\1/p' | head -n1)
    printf '%s' "$loc" | grep -q 'nasId=' || return 1
    DISCOVERED_NAS=$(printf '%s' "$loc" | sed -n 's/.*[?&]nasId=\([0-9][0-9]*\).*/\1/p')
    [ -n "$DISCOVERED_NAS" ]
}

# One credential login. Sets LOGIN_CODE and LOGIN_MSG.
post_login() {
    token_resp=$(http_get /api/csrf-token)
    token=$(json_field "$token_resp" csrf_token)
    cookie=$(printf '%s' "$token_resp" | tr -d '\r' |
        sed -n 's/^Set-Cookie:[[:space:]]*\(yudear=[^;]*\).*/\1/p' | head -n1)
    if [ -z "$token" ]; then
        LOGIN_CODE=csrf
        LOGIN_MSG="no csrf token"
        return 0
    fi

    nas=""
    [ -r "$NAS_CONF" ] && nas=$(sed -n 's/^NAS_ID=//p' "$NAS_CONF" | head -n1)
    [ -n "$nas" ] || { discover_portal && nas=$DISCOVERED_NAS; }
    [ -n "$nas" ] || nas=$(json_field "$(http_get /api/config)" default_nas)
    [ -n "$nas" ] || nas=1

    login_ip=$(wan_ip)
    login_mac=$(wan_mac)
    body="username=$(urlencode "$USERNAME")&password=$(urlencode "$PASSWORD")&switchip=&nasId=$nas"
    [ -n "$login_ip" ] && body="$body&userIpv4=$login_ip"
    [ -n "$login_mac" ] && body="$body&userMac=$login_mac"
    body="$body&captcha=&captchaId="
    length=$(printf '%s' "$body" | wc -c)
    request=$(printf 'POST /api/account/login HTTP/1.0\r\nHost: %s\r\nConnection: close\r\nContent-Type: application/x-www-form-urlencoded\r\nX-CSRF-Token: %s\r\nCookie: %s\r\nContent-Length: %s\r\n\r\n%s' \
        "$HOST" "$token" "$cookie" "$length" "$body")
    resp=$(http_exchange "$request")
    LOGIN_CODE=$(json_code "$resp")
    LOGIN_MSG=$(json_field "$resp" msg)
    [ -n "$LOGIN_CODE" ] || {
        LOGIN_CODE=bad
        [ -n "$LOGIN_MSG" ] || LOGIN_MSG=$(printf '%s' "$resp" | head -c 120 | tr -d '\r\n')
    }
}

attempt_login() {
    now=$(date +%s)
    if is_online; then
        state_set 0 0
        return 0
    fi

    post_login
    case "$LOGIN_CODE" in
        0)
            state_set 0 0
            sleep 2
            if is_online; then
                say "login OK and verified online (nas $nas)"
            else
                say "portal accepted the login but the session is not online yet"
            fi
            ;;
        2)
            state_set 0 $((now + 1800))
            say "portal requires a captcha; auto-login paused, manual login needed"
            ;;
        1)
            device_offline=0
            printf '%s' "$LOGIN_MSG" | grep -q '不在线' && device_offline=1
            printf '%s' "$LOGIN_MSG" | grep -qi 'not online' && device_offline=1
            if [ "$device_offline" = 1 ]; then
                if wan_reconnect; then
                    if wait_online 60; then
                        state_set 0 0
                        say "session restored by itself after the WAN reconnect"
                        return 0
                    fi
                    post_login
                    if [ "$LOGIN_CODE" = 0 ]; then
                        state_set 0 0
                        sleep 2
                        if is_online; then
                            say "login OK after WAN reconnect (nas $nas)"
                        else
                            say "login accepted after WAN reconnect but session still offline"
                        fi
                        return 0
                    fi
                fi
            fi
            fail=$((fail + 1))
            delay=$((300 * fail))
            [ "$delay" -gt 1800 ] && delay=1800
            state_set "$fail" $((now + delay))
            say "login rejected (code 1, nas $nas): $LOGIN_MSG; retry in ${delay}s"
            ;;
        *)
            state_set 0 $((now + 300))
            say "unexpected portal answer: $LOGIN_MSG"
            ;;
    esac
}

run_once() {
    exec 9>"$LOCK" || exit 1
    flock -n 9 || exit 0

    [ -n "$HOST" ] || exit 0
    rotate_log
    [ -r "$CONF" ] || exit 0
    . "$CONF"
    [ -n "${USERNAME:-}" ] && [ -n "${PASSWORD:-}" ] || exit 0

    now=$(date +%s)
    [ "$now" -ge "$(state_get next)" ] || exit 0

    if is_online; then
        if [ "$(state_get fail)" != 0 ]; then
            state_set 0 0
            say "session is back, counters reset"
        fi
        exit 0
    fi

    fail=$(state_get fail)
    attempt_login
}

show_status() {
    if [ -z "$HOST" ]; then
        echo "portal:  not configured (set PORTAL_HOST)"
    else
        if is_online; then
            echo "session: online"
        else
            echo "session: offline"
        fi
        echo "portal:  http://$HOST:$PORT"
    fi
    echo "conf:    $CONF $([ -r "$CONF" ] && echo present || echo missing)"
    echo "nas:     $([ -r "$NAS_CONF" ] && sed -n 's/^NAS_ID=//p' "$NAS_CONF" | head -n1 || echo none)"
    echo "state:   fail=$(state_get fail) next=$(state_get next)"
}

case "${1:-run}" in
    run) run_once ;;
    status) show_status ;;
    test-login)
        [ -n "$HOST" ] || { echo "PORTAL_HOST is not set" >&2; exit 2; }
        [ -r "$CONF" ] || { echo "missing $CONF" >&2; exit 1; }
        . "$CONF"
        if is_online && [ "${PORTAL_FORCE_LOGIN:-0}" != 1 ]; then
            echo "session is online; refusing test-login (set PORTAL_FORCE_LOGIN=1 to override)"
            exit 0
        fi
        fail=$(state_get fail)
        attempt_login
        ;;
    *) echo "usage: $0 [run|status|test-login]" >&2; exit 2 ;;
esac
