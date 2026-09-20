<#
.SYNOPSIS
    Claude Code hook: push the hook event to Pushover.

.DESCRIPTION
    Reads the hook payload (JSON) from stdin and sends a Pushover notification.
    Credentials are resolved in this order:
      1. $env:PUSHOVER_TOKEN / $env:PUSHOVER_USER
      2. $env:PUSHOVER_CONFIG (default: ~/.claude/pushover.json), shaped like
         { "token": "...", "user": "...", "priority": 0, "sound": "pushover", "device": "",
           "cooldown": 60 }

    Throttling: after a push is sent, further pushes from the same Claude Code session are
    suppressed for `cooldown` seconds (default 60, 0 disables). $env:PUSHOVER_COOLDOWN takes
    precedence over the config file. State lives in ~/.claude/hooks/pushover-state
    (override with $env:PUSHOVER_STATE_DIR), one small file per session.

    Always exits 0 - a failed notification must never block the session.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-HookError([string]$Message) {
    [Console]::Error.WriteLine("pushover-notify: $Message")
}

try {
    $raw = [Console]::In.ReadToEnd()
    $payload = if ([string]::IsNullOrWhiteSpace($raw)) { $null } else { $raw | ConvertFrom-Json }
} catch {
    $payload = $null
}

$token = $env:PUSHOVER_TOKEN
$user = $env:PUSHOVER_USER
$priority = $null
$sound = $null
$device = $null
$cooldown = $env:PUSHOVER_COOLDOWN

$configPath = if ($env:PUSHOVER_CONFIG) { $env:PUSHOVER_CONFIG } else { Join-Path $HOME '.claude\pushover.json' }
if (Test-Path -LiteralPath $configPath) {
    try {
        $config = Get-Content -LiteralPath $configPath -Raw -Encoding utf8 | ConvertFrom-Json
        foreach ($field in 'token', 'user', 'priority', 'sound', 'device', 'cooldown') {
            if (-not ($config.PSObject.Properties.Name -contains $field)) { continue }
            $value = $config.$field
            if ($null -eq $value -or "$value" -eq '') { continue }
            switch ($field) {
                'token'    { if (-not $token) { $token = "$value" } }
                'user'     { if (-not $user) { $user = "$value" } }
                'priority' { $priority = "$value" }
                'sound'    { $sound = "$value" }
                'device'   { $device = "$value" }
                'cooldown' { if ($null -eq $cooldown -or "$cooldown" -eq '') { $cooldown = "$value" } }
            }
        }
    } catch {
        Write-HookError "could not parse $configPath : $($_.Exception.Message)"
    }
}

if (-not $token -or -not $user) {
    Write-HookError "no credentials (set PUSHOVER_TOKEN/PUSHOVER_USER or write $configPath)"
    exit 0
}

function Get-Field($obj, [string]$name) {
    if ($obj -and $obj.PSObject.Properties.Name -contains $name) { return "$($obj.$name)" }
    return ''
}

$event = Get-Field $payload 'hook_event_name'
if (-not $event) { $event = 'Notification' }

$message = Get-Field $payload 'message'
if (-not $message) { $message = $event }

$cwd = Get-Field $payload 'cwd'
if (-not $cwd) { $cwd = (Get-Location).Path }
$project = Split-Path -Leaf $cwd

$cooldownSeconds = 60
if ("$cooldown" -ne '') {
    $parsed = 0.0
    if ([double]::TryParse("$cooldown", [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed) -and $parsed -ge 0) {
        $cooldownSeconds = $parsed
    } else {
        Write-HookError "ignoring invalid cooldown '$cooldown' (using $cooldownSeconds)"
    }
}

# Throttle key: one cooldown window per session, falling back to the project directory.
$throttleKey = Get-Field $payload 'session_id'
if (-not $throttleKey) { $throttleKey = $cwd }

$stateDir = if ($env:PUSHOVER_STATE_DIR) { $env:PUSHOVER_STATE_DIR } else { Join-Path $HOME '.claude\hooks\pushover-state' }
$stateFile = $null
$previousStamp = $null   # last-write time before we claimed the slot; $null = file did not exist

# Returns $true when this notification may be sent. On $true the slot is already claimed
# (state file touched), so concurrent hook processes cannot both pass. Any failure here
# fails open: a broken throttle must not swallow notifications.
function Request-SendSlot {
    if ($cooldownSeconds -le 0) { return $true }
    $mutex = $null
    $locked = $false
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        $hash = ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($throttleKey)) | ForEach-Object { $_.ToString('x2') }) -join ''
        $hash = $hash.Substring(0, 16)
        New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
        $script:stateFile = Join-Path $stateDir "$hash.stamp"

        $mutex = New-Object Threading.Mutex($false, "Local\pushover-notify-$hash")
        try { $locked = $mutex.WaitOne(5000) } catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { return $true }

        $now = [DateTime]::UtcNow
        if (Test-Path -LiteralPath $script:stateFile) {
            $script:previousStamp = (Get-Item -LiteralPath $script:stateFile).LastWriteTimeUtc
            $age = ($now - $script:previousStamp).TotalSeconds
            if ($age -ge 0 -and $age -lt $cooldownSeconds) {
                Write-HookError ("suppressed (last push {0:N0}s ago, cooldown {1}s)" -f $age, $cooldownSeconds)
                return $false
            }
        } else {
            New-Item -ItemType File -Path $script:stateFile -Force | Out-Null
        }
        (Get-Item -LiteralPath $script:stateFile).LastWriteTimeUtc = $now

        # Opportunistic cleanup of stamps from long-gone sessions.
        Get-ChildItem -LiteralPath $stateDir -Filter '*.stamp' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTimeUtc -lt $now.AddDays(-7) } |
            Remove-Item -Force -ErrorAction SilentlyContinue
        return $true
    } catch {
        Write-HookError "throttle disabled for this push: $($_.Exception.Message)"
        return $true
    } finally {
        if ($mutex) {
            if ($locked) { try { $mutex.ReleaseMutex() } catch { } }
            $mutex.Dispose()
        }
    }
}

# Undo the claim after a failed push so the next notification is not throttled by it.
function Restore-SendSlot {
    if (-not $stateFile) { return }
    try {
        if ($null -eq $previousStamp) {
            Remove-Item -LiteralPath $stateFile -Force -ErrorAction SilentlyContinue
        } else {
            (Get-Item -LiteralPath $stateFile).LastWriteTimeUtc = $previousStamp
        }
    } catch { }
}

if (-not (Request-SendSlot)) { exit 0 }

$body = @{
    token   = $token
    user    = $user
    title   = "Claude Code: $project"
    message = $message
}
if ($priority) { $body['priority'] = $priority }
if ($sound)    { $body['sound'] = $sound }
if ($device)   { $body['device'] = $device }

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $response = Invoke-RestMethod -Method Post -Uri 'https://api.pushover.net/1/messages.json' -Body $body -TimeoutSec 10
    if ($response.status -ne 1) {
        Write-HookError "$event push rejected: $($response | ConvertTo-Json -Compress)"
        Restore-SendSlot
    }
} catch {
    # PS 5.1 throws on any 4xx/5xx, so dig the API's own error text out of the response.
    $detail = $_.Exception.Message
    $errorResponse = $null
    if ($_.Exception.PSObject.Properties.Name -contains 'Response') {
        $errorResponse = $_.Exception.Response
    }
    if ($errorResponse) {
        try {
            $reader = New-Object IO.StreamReader($errorResponse.GetResponseStream())
            $bodyText = $reader.ReadToEnd()
            $reader.Close()
            if ($bodyText) { $detail = "$detail $bodyText" }
        } catch { }
    }
    Write-HookError "$event push failed: $detail"
    Restore-SendSlot
}

exit 0
