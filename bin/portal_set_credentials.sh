#!/bin/sh
# portal_set_credentials.sh - prompt on the console and write the credentials
# to the configured file (default /etc/portal/login.conf, mode 600).
#
# The password is typed by the operator, never echoed, never on a command line
# and never written anywhere except that file.

set -u

CONF="${PORTAL_CONF:-/etc/portal/login.conf}"
NAS_CONF="${PORTAL_NAS_CONF:-/etc/portal/nas.conf}"

mkdir -p "$(dirname "$CONF")" || exit 1
chmod 700 "$(dirname "$CONF")" 2>/dev/null

printf 'Portal username: '
read -r user
printf 'Portal password (input hidden): '
stty -echo 2>/dev/null
read -r pass
stty echo 2>/dev/null
printf '\n'

if [ -z "$user" ] || [ -z "$pass" ]; then
    echo "aborted: empty username or password"
    exit 1
fi

escape() {
    printf '%s' "$1" | sed "s/'/'\\\\''/g"
}

umask 077
{
    printf "USERNAME='%s'\n" "$(escape "$user")"
    printf "PASSWORD='%s'\n" "$(escape "$pass")"
} >"$CONF"
chmod 600 "$CONF"

printf 'Optional NAS id (empty = auto/default): '
read -r nas
if [ -n "$nas" ]; then
    case "$nas" in
        *[!0-9]*) echo "ignored: NAS id must be numeric" ;;
        *)
            printf 'NAS_ID=%s\n' "$nas" >"$NAS_CONF"
            chmod 600 "$NAS_CONF"
            echo "saved $NAS_CONF"
            ;;
    esac
fi

echo "saved $CONF (mode 600, owner $(id -un))"
