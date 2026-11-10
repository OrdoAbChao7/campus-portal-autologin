#Requires -Version 5.1
<#
.SYNOPSIS
  Keep a campus captive-portal session alive with your own account (Windows).

.DESCRIPTION
  Port of bin/portal_autologin.sh for a Windows machine on the same LAN as the
  portal (or on the portal network itself). The portal keys the session to the
  source IP it sees, so a PC behind the dorm router can keep the router's
  session alive when the portal keys on IP.

  Safety contract:
    * the password is stored DPAPI-encrypted for the current Windows user;
    * it acts only when /api/account/status shows no live session;
    * it never posts a login while a session is live;
    * it never solves captchas (code 2 stops it for 30 minutes);
    * it never calls logout.

  Status: beta. The status path is read-only and safe to run anywhere; the
  login path follows the same protocol as the shell version and has not been
  re-validated on this campus from a PC.

.PARAMETER Command
  run        cron/Task Scheduler entry point
  status     print session and local state, no side effects
  setup      prompt for portal URL, username and password
  test-login one login attempt (refused while online unless -Force)

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File portal_autologin.ps1 status
  powershell -ExecutionPolicy Bypass -File portal_autologin.ps1 setup
#>
[CmdletBinding()]
param(
    [ValidateSet('run', 'status', 'setup', 'test-login')]
    [string]$Command = 'run',
    [string]$PortalUrl = '',
    [int]$NasId = 0,
    [string]$StateDir = (Join-Path $env:APPDATA 'campus-portal-autologin'),
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$ConfigPath = Join-Path $StateDir 'config.json'
$SecretPath = Join-Path $StateDir 'secret.txt'
$StatePath = Join-Path $StateDir 'state.json'
$LogPath = Join-Path $StateDir 'autologin.log'

function Write-Log([string]$Message) {
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
}

function Get-Config {
    if (-not (Test-Path -LiteralPath $ConfigPath)) { return $null }
    Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Save-Config($Config) {
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
    $Config | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
}

function Get-State {
    if (-not (Test-Path -LiteralPath $StatePath)) {
        return [pscustomobject]@{ fail = 0; next = 0 }
    }
    Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Save-State([int]$Fail, [long]$Next) {
    [pscustomobject]@{ fail = $Fail; next = $Next } |
        ConvertTo-Json | Set-Content -LiteralPath $StatePath -Encoding UTF8
}

function Get-Password {
    if (-not (Test-Path -LiteralPath $SecretPath)) { return $null }
    $enc = (Get-Content -LiteralPath $SecretPath -Raw -Encoding UTF8).Trim()
    $ss = ConvertTo-SecureString $enc
    [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss))
}

function Invoke-Portal {
    param(
        [string]$Path,
        [Microsoft.PowerShell.Commands.WebRequestSession]$Session,
        [hashtable]$Headers,
        [hashtable]$Body
    )
    $args = @{
        Uri                = $Config.portalUrl.TrimEnd('/') + $Path
        UseBasicParsing    = $true
        TimeoutSec         = 10
        MaximumRedirection = 0
    }
    if ($Session) { $args.WebSession = $Session }
    if ($Headers) { $args.Headers = $Headers }
    if ($Body) { $args.Method = 'POST'; $args.Body = $Body }
    try {
        $resp = Invoke-WebRequest @args
        return $resp.Content
    } catch {
        if ($_.Exception.Response) {
            $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
            return $reader.ReadToEnd()
        }
        throw
    }
}

function Test-Online($Config) {
    $raw = Invoke-Portal -Path '/api/account/status' -Session $script:Session
    try { $j = $raw | ConvertFrom-Json } catch { return $false }
    return ($j.code -eq 0 -and $j.online -and $j.online.Username)
}

function Get-JsonInt([string]$Raw, [string]$Name) {
    try { return [int]($Raw | ConvertFrom-Json).$Name } catch { return $null }
}

function Post-Login($Config) {
    $tokenRaw = Invoke-Portal -Path '/api/csrf-token' -Session $script:Session
    $token = ($tokenRaw | ConvertFrom-Json).csrf_token
    if (-not $token) { return @{ code = 'csrf'; msg = 'no csrf token' } }

    $nas = $NasId
    if ($nas -le 0 -and $Config.nasId) { $nas = [int]$Config.nasId }
    if ($nas -le 0) {
        $cfg = Invoke-Portal -Path '/api/config' -Session $script:Session
        $nas = Get-JsonInt $cfg 'default_nas'
        if (-not $nas) { $nas = 1 }
    }

    $body = @{
        username  = $Config.username
        password  = $script:Password
        switchip  = ''
        nasId     = $nas
        captcha   = ''
        captchaId = ''
    }
    $raw = Invoke-Portal -Path '/api/account/login' -Session $script:Session `
        -Headers @{ 'X-CSRF-Token' = $token } -Body $body
    try { $j = $raw | ConvertFrom-Json } catch {
        return @{ code = 'bad'; msg = $raw }
    }
    return @{ code = $j.code; msg = $j.msg }
}

try {
    $Config = Get-Config

    switch ($Command) {
        'setup' {
            $url = if ($PortalUrl) { $PortalUrl } elseif ($Config) { $Config.portalUrl } else { 'http://172.30.21.100' }
            $url = Read-Host "Portal URL [$url]"
            if (-not $url) { $url = if ($Config) { $Config.portalUrl } else { 'http://172.30.21.100' } }
            $user = Read-Host 'Portal username'
            $pass = Read-Host 'Portal password' -AsSecureString
            $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                [Runtime.InteropServices.Marshal]::SecureStringToBSTR($pass))
            New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
            ConvertFrom-SecureString -SecureString $pass |
                Set-Content -LiteralPath $SecretPath -Encoding UTF8
            $nasText = Read-Host 'NAS id (empty = auto)'
            $nas = 0
            if ($nasText -match '^\d+$') { $nas = [int]$nasText }
            Save-Config ([pscustomobject]@{
                portalUrl = $url
                username  = $user
                nasId     = $nas
            })
            Write-Host "saved $ConfigPath (password DPAPI-encrypted for $env:USERNAME)"
            break
        }

        'status' {
            if (-not $Config) { Write-Host 'not configured (run setup)'; exit 0 }
            $script:Session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
            $online = Test-Online $Config
            $st = Get-State
            Write-Host ("session: " + $(if ($online) { 'online' } else { 'offline' }))
            Write-Host ("portal:  " + $Config.portalUrl)
            Write-Host ("user:    " + $Config.username)
            Write-Host ("nas:     " + $Config.nasId)
            Write-Host ("state:   fail=$($st.fail) next=$($st.next)")
            break
        }

        default {
            if (-not $Config) { exit 0 }
            $st = Get-State
            $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            if ($now -lt [long]$st.next) { exit 0 }

            $script:Session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
            if (Test-Online $Config) {
                if ($st.fail -ne 0) { Save-State 0 0; Write-Log 'session is back, counters reset' }
                exit 0
            }

            $script:Password = Get-Password
            if (-not $script:Password) { Write-Log 'no stored password'; exit 0 }
            $result = Post-Login $Config
            switch ($result.code) {
                0 {
                    Save-State 0 0
                    Start-Sleep -Seconds 2
                    if (Test-Online $Config) { Write-Log 'login OK and verified online' }
                    else { Write-Log 'portal accepted the login but the session is not online yet' }
                }
                2 {
                    Save-State 0 ($now + 1800)
                    Write-Log 'portal requires a captcha; auto-login paused, manual login needed'
                }
                1 {
                    $fail = [int]$st.fail + 1
                    $delay = [Math]::Min(1800, 300 * $fail)
                    Save-State $fail ($now + $delay)
                    Write-Log "login rejected (code 1): $($result.msg); retry in ${delay}s"
                }
                default {
                    Save-State 0 ($now + 300)
                    Write-Log "unexpected portal answer: $($result.msg)"
                }
            }
        }
    }
} catch {
    if (Test-Path -LiteralPath $StateDir) { Write-Log ('error: ' + $_.Exception.Message) }
    exit 1
}
