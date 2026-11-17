#!/usr/bin/env pwsh
# Copyright © 2026 Amazon.com and Affiliates. Licensed under MIT-0.

<#
.SYNOPSIS
    Sends one or more orders to a variant and reports what came back.

.DESCRIPTION
    Resolves the variant to its API URL, posts valid orders through
    internal/Invoke-OrdersApi.ps1, then summarises: wall clock, how many
    succeeded and failed, and the first few failures.

    With -Count greater than 1 every request is dispatched before any is
    awaited, so they are genuinely in flight together. That matters: a Lambda
    execution environment serves one request at a time, so only overlapping
    requests force new environments. Anything dispatching slower than the
    handler completes (~10 ms warm here) sees the same environment reused and
    produces almost no restores.

    Also flags duplicate OrderIds, which is how a frozen random seed shows up
    after a SnapStart restore, and warns that a run containing failures should
    be discarded - failed requests still emit Restore Duration and would skew
    any measurement taken from the same logs.

    Credentials come from the standard AWS chain. Set AWS_PROFILE, or pass
    -ProfileName to override.

.EXAMPLE
    ./bench/Send-OrderRequest.ps1 02-snapstart-primed
    One order. Use immediately after a deploy for the first restore of a fresh
    snapshot. -Variant is positional and tab-completable.

.EXAMPLE
    ./bench/Send-OrderRequest.ps1 02-snapstart-primed -Count 50
    Fifty simultaneous requests, forcing up to fifty restores.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('01-managed', '02-snapstart', '02-snapstart-primed',
        '03-native-aot', '03-native-aot-ready', '03-native-aot-single-purpose')]
    [string] $Variant,
    [int]    $Count      = 1,
    [int]    $TimeoutSec = 60,
    [string] $Region,
    [string] $ProfileName
)

$ErrorActionPreference = 'Stop'

$stack = & "$PSScriptRoot/internal/Get-StackOutput.ps1" `
    -Variant $Variant -Region $Region -ProfileName $ProfileName

Write-Host "POST $($stack.ApiUrl)/orders"
Write-Host "count: $Count (all dispatched before any is awaited)"

$started = Get-Date
$results = @(& "$PSScriptRoot/internal/Invoke-OrdersApi.ps1" `
        -ApiUrl $stack.ApiUrl -Count $Count -TimeoutSec $TimeoutSec)
$elapsed = (Get-Date) - $started

$ok = @($results | Where-Object Ok)
$failed = @($results | Where-Object { -not $_.Ok })

Write-Host ''
Write-Host ("succeeded: {0}   failed: {1}   wall clock: {2:N2}s" -f `
        $ok.Count, $failed.Count, $elapsed.TotalSeconds)

$duplicates = @($ok.OrderId | Group-Object | Where-Object Count -gt 1)
if ($duplicates.Count -gt 0) {
    Write-Host "DUPLICATE OrderIds: $($duplicates.Count)" -ForegroundColor Red
}

foreach ($failure in ($failed | Select-Object -First 5)) {
    Write-Host "  $($failure.Status) $($failure.Error)" -ForegroundColor Red
}

if ($failed.Count -gt 0) {
    Write-Host ''
    Write-Host 'Failed requests still emit Restore Duration. Discard this run.' `
        -ForegroundColor Yellow
}

$results
