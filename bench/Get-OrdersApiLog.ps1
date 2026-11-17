#!/usr/bin/env pwsh
# Copyright © 2026 Amazon.com and Affiliates. Licensed under MIT-0.

<#
.SYNOPSIS
    Fetches recent CloudWatch log events for the Orders function.

.DESCRIPTION
    Resolves the log group from the stack's FunctionName output, fetches events
    from the last -Minutes, and sorts them by timestamp client-side.

    The client-side sort matters: filter-log-events matches across every stream
    in the group, and SnapStart spreads snapshot-creation and invoke logs across
    several streams, so the API's return order is not reliably chronological.

    Credentials come from the standard AWS chain. Set AWS_PROFILE, or pass
    -ProfileName to override.

.EXAMPLE
    ./bench/Get-OrdersApiLog.ps1 02-snapstart-primed -Minutes 10
    Everything from the last ten minutes. -Variant is positional and tab-completable.

.EXAMPLE
    ./bench/Get-OrdersApiLog.ps1 02-snapstart-primed -Minutes 5 -Pattern REPORT
    Only REPORT lines. Also matches INIT_REPORT and RESTORE_REPORT.

.EXAMPLE
    ./bench/Get-OrdersApiLog.ps1 02-snapstart-primed -Minutes 5 -Pattern serviceMs
    Only successful order handlers. This line is emitted after CreateOrderAsync
    returns, so its presence proves the happy path ran.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('01-managed', '02-snapstart', '02-snapstart-primed',
        '03-native-aot', '03-native-aot-ready', '03-native-aot-single-purpose')]
    [string] $Variant,
    [int]    $Minutes = 10,
    [string] $Pattern = '',
    [int]    $Tail    = 0,
    [switch] $MessageOnly,
    [string] $Region,
    [string] $ProfileName
)

$ErrorActionPreference = 'Stop'

$stack = & "$PSScriptRoot/internal/Get-StackOutput.ps1" `
    -Variant $Variant -Region $Region -ProfileName $ProfileName

$since = [DateTimeOffset]::UtcNow.AddMinutes(-$Minutes).ToUnixTimeMilliseconds()

$cliArgs = @(
    'logs', 'filter-log-events'
    '--log-group-name', $stack.LogGroup
    '--region', $stack.Region
    '--start-time', $since
    '--output', 'json'
) + $stack.ProfileArgs
if ($Pattern) { $cliArgs += @('--filter-pattern', $Pattern) }

$response = (& aws @cliArgs | Out-String) | ConvertFrom-Json

$events = @($response.events | Sort-Object timestamp)
if ($Tail -gt 0) { $events = @($events | Select-Object -Last $Tail) }

$label = if ($Pattern) { "pattern '$Pattern'" } else { 'no filter' }
Write-Host $stack.LogGroup
Write-Host "last $Minutes min, $label, $($events.Count) events"
Write-Host ''

# Not $event: that is a PowerShell automatic variable (set inside eventing
# action blocks), and shadowing it is the same footgun as assigning to $input.
foreach ($logEvent in $events) {
    $message = $logEvent.message.TrimEnd()

    if ($MessageOnly) {
        $message
        continue
    }

    $stamp = [DateTimeOffset]::FromUnixTimeMilliseconds($logEvent.timestamp).
    ToLocalTime().ToString('HH:mm:ss.fff')
    "$stamp  $message"
}
