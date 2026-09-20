<#
.SYNOPSIS
    Install (or remove) the Pushover Notification hook in the global Claude Code settings.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File hooks\pushover\install.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File hooks\pushover\install.ps1 -Uninstall

.DESCRIPTION
    Copies pushover-notify.ps1 to ~/.claude/hooks/ and registers a Notification hook in
    ~/.claude/settings.json. Existing settings and other hooks are preserved; re-running
    replaces only this hook's entry.
#>

[CmdletBinding()]
param(
    [switch]$Uninstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$srcDir       = Split-Path -Parent $MyInvocation.MyCommand.Path
$claudeHome   = Join-Path $HOME '.claude'
$hooksDir     = Join-Path $claudeHome 'hooks'
$settingsPath = Join-Path $claudeHome 'settings.json'
$target       = Join-Path $hooksDir 'pushover-notify.ps1'

$settings = if (Test-Path -LiteralPath $settingsPath) {
    Get-Content -LiteralPath $settingsPath -Raw -Encoding utf8 | ConvertFrom-Json
} else {
    [pscustomobject]@{}
}

function Test-PushoverHook($entry) {
    # The script path can live in `command` (shell form) or in `args` (exec form).
    $parts = @()
    foreach ($field in 'command', 'args') {
        if ($entry.PSObject.Properties.Name -contains $field) { $parts += @($entry.$field) }
    }
    return (($parts -join ' ') -match 'pushover-notify\.ps1')
}

# Existing Notification groups, minus any previously installed copy of this hook.
$existing = @()
if ($settings.PSObject.Properties.Name -contains 'hooks' -and
    $settings.hooks.PSObject.Properties.Name -contains 'Notification') {
    foreach ($group in @($settings.hooks.Notification)) {
        $kept = @($group.hooks | Where-Object { -not (Test-PushoverHook $_) })
        if ($kept.Count -gt 0) {
            $group.hooks = $kept
            $existing += $group
        }
    }
}

function Save-Settings($obj) {
    $json = $obj | ConvertTo-Json -Depth 20
    # Set-Content -Encoding utf8 adds a BOM on Windows PowerShell 5.1.
    [IO.File]::WriteAllText($settingsPath, $json, (New-Object Text.UTF8Encoding($false)))
}

function Set-Notification($obj, $groups) {
    if ($groups.Count -gt 0) {
        $obj.hooks | Add-Member -NotePropertyName Notification -NotePropertyValue @($groups) -Force
        return
    }
    if ($obj.hooks.PSObject.Properties.Name -contains 'Notification') {
        $obj.hooks.PSObject.Properties.Remove('Notification')
    }
}

if (-not ($settings.PSObject.Properties.Name -contains 'hooks')) {
    $settings | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{}) -Force
}

if ($Uninstall) {
    Set-Notification $settings $existing
    Save-Settings $settings
    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force }
    Write-Output "Uninstalled the Pushover Notification hook from $settingsPath"
    return
}

New-Item -ItemType Directory -Force -Path $hooksDir | Out-Null
Copy-Item -LiteralPath (Join-Path $srcDir 'pushover-notify.ps1') -Destination $target -Force

$entry = [pscustomobject]@{
    hooks = @(
        [pscustomobject]@{
            type          = 'command'
            command       = 'powershell.exe'
            args          = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $target)
            async         = $true
            timeout       = 15
            statusMessage = 'Sending Pushover notification'
        }
    )
}

Set-Notification $settings (@($existing) + @($entry))
Save-Settings $settings

Write-Output "Installed $target"
Write-Output "Registered the Notification hook in $settingsPath"

$configPath = Join-Path $claudeHome 'pushover.json'
if (-not (Test-Path -LiteralPath $configPath) -and -not $env:PUSHOVER_TOKEN) {
    Write-Output "Next: create $configPath with your Pushover token and user key."
}
