#!/usr/bin/env pwsh
# Copyright © 2026 Amazon.com and Affiliates. Licensed under MIT-0.

<#
.SYNOPSIS
    Convenience wrapper: measures cold starts, then shows the HTML comparison.

.DESCRIPTION
    Chains the two scripts you'd otherwise run by hand: Measure-ColdStart.ps1
    for one or more variants, then Show-BenchmarkComparison.ps1 -Html to build
    the cold-start report and open it in the default browser.

    Both scripts assume results live under bench/results - Measure-ColdStart.ps1
    hardcodes that location, and this wrapper's -ResultsPath defaults to the
    same place so the two agree by convention. There is no way to point
    Measure-ColdStart.ps1 at a different directory.

    -Variant, if given, is forwarded to Measure-ColdStart.ps1 unchanged. Omit it
    to measure every variant, which is Measure-ColdStart.ps1's default. -Region
    and -ProfileName also go only to Measure-ColdStart.ps1 -
    Show-BenchmarkComparison.ps1 only reads local CSVs and has no use for AWS
    credentials.

    If one variant fails to measure, Measure-ColdStart.ps1 reports it and
    continues with the rest - this wrapper does not treat that as fatal and
    still runs the comparison. A partial table, with a stale or missing column
    for the failed variant, is still useful; see that script's own output for
    which variants succeeded.

.PARAMETER Variant
    Variants to measure and compare. Omit for Measure-ColdStart.ps1's own
    default set.

.PARAMETER Samples
    Forwarded to Measure-ColdStart.ps1 -Samples.

.PARAMETER Concurrency
    Forwarded to Measure-ColdStart.ps1 -Concurrency. 0 (the default) means
    "use -Samples" inside that script.

.PARAMETER IngestionWaitSec
    Forwarded to Measure-ColdStart.ps1 -IngestionWaitSec.

.PARAMETER TimeoutSec
    Forwarded to Measure-ColdStart.ps1 -TimeoutSec.

.PARAMETER Region
    Forwarded to Measure-ColdStart.ps1 -Region only. Show-BenchmarkComparison.ps1
    reads local CSVs and takes no region.

.PARAMETER ProfileName
    Forwarded to Measure-ColdStart.ps1 -ProfileName only, for the same reason.

.PARAMETER ResultsPath
    Forwarded to Show-BenchmarkComparison.ps1 -ResultsPath. Defaults to
    bench/results, matching the directory Measure-ColdStart.ps1 always writes
    to - that script has no results-path parameter of its own.

.PARAMETER MinimumSamples
    Forwarded to Show-BenchmarkComparison.ps1 -MinimumSamples.

.EXAMPLE
    ./bench/Start-BenchmarkRun.ps1
    Measures every default variant at 30 samples, then opens the HTML report.

.EXAMPLE
    ./bench/Start-BenchmarkRun.ps1 01-managed
    One variant.

.EXAMPLE
    ./bench/Start-BenchmarkRun.ps1 01-managed, 03-native-aot-ready
    A subset. -Variant is positional and tab-completable.

.EXAMPLE
    ./bench/Start-BenchmarkRun.ps1 -Samples 50
    Every default variant, fifty samples each.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('01-managed', '02-snapstart', '02-snapstart-primed',
        '03-native-aot', '03-native-aot-ready', '03-native-aot-single-purpose')]
    [string[]] $Variant,
    [int]      $Samples = 30,
    [int]      $Concurrency = 0,
    [int]      $IngestionWaitSec = 10,
    [int]      $TimeoutSec = 90,
    [string]   $Region,
    [string]   $ProfileName,
    [string]   $ResultsPath = (Join-Path $PSScriptRoot 'results'),
    [int]      $MinimumSamples = 30
)

$ErrorActionPreference = 'Stop'

$measureArgs = @{
    Samples          = $Samples
    Concurrency      = $Concurrency
    IngestionWaitSec = $IngestionWaitSec
    TimeoutSec       = $TimeoutSec
}
if ($Variant) { $measureArgs.Variant = $Variant }
if ($Region) { $measureArgs.Region = $Region }
if ($ProfileName) { $measureArgs.ProfileName = $ProfileName }

Write-Host '=================================================================='
Write-Host '  Measuring cold starts...'
Write-Host '=================================================================='

& "$PSScriptRoot/Measure-ColdStart.ps1" @measureArgs

$compareArgs = @{
    ResultsPath    = $ResultsPath
    MinimumSamples = $MinimumSamples
    Html           = $true
}
if ($Variant) { $compareArgs.Variant = $Variant }

Write-Host ''
Write-Host '=================================================================='
Write-Host '  Generating comparison report...'
Write-Host '=================================================================='

& "$PSScriptRoot/Show-BenchmarkComparison.ps1" @compareArgs
