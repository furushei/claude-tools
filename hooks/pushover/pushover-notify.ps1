<#
.SYNOPSIS
    Claude Code hook: push the hook event to Pushover.

.DESCRIPTION
    Reads the hook payload (JSON) from stdin and sends a Pushover notification.
    Credentials are resolved in this order:
      1. $env:PUSHOVER_TOKEN / $env:PUSHOVER_USER
      2. $env:PUSHOVER_CONFIG (default: ~/.claude/pushover.json), shaped like
         { "token": "...", "user": "...", "priority": 0, "sound": "pushover", "device": "" }

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

$configPath = if ($env:PUSHOVER_CONFIG) { $env:PUSHOVER_CONFIG } else { Join-Path $HOME '.claude\pushover.json' }
if (Test-Path -LiteralPath $configPath) {
    try {
        $config = Get-Content -LiteralPath $configPath -Raw -Encoding utf8 | ConvertFrom-Json
        foreach ($field in 'token', 'user', 'priority', 'sound', 'device') {
            if (-not ($config.PSObject.Properties.Name -contains $field)) { continue }
            $value = $config.$field
            if ($null -eq $value -or "$value" -eq '') { continue }
            switch ($field) {
                'token'    { if (-not $token) { $token = "$value" } }
                'user'     { if (-not $user) { $user = "$value" } }
                'priority' { $priority = "$value" }
                'sound'    { $sound = "$value" }
                'device'   { $device = "$value" }
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
}

exit 0
