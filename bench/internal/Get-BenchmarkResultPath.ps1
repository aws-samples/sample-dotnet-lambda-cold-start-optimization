#!/usr/bin/env pwsh
# Copyright © 2026 Amazon.com and Affiliates. Licensed under MIT-0.

<#
.SYNOPSIS
    Builds the path of a timestamped benchmark result file.

.DESCRIPTION
    The only place that writes the result filename format:

        <variant>.<kind>.<yyyyMMddTHHmmssZ>.n<RequestedSamples>.csv
        e.g. 01-managed.cold.20261001T143200Z.n30.csv

    kind is 'cold' (Measure-ColdStart.ps1) or 'coldwarm'
    (Measure-ColdWarmRatio.ps1). The stamp is UTC and the count is the sample
    count the script was asked for, both formatted with the invariant culture.
    The stamp comes before the count so names sort chronologically, but
    readers must not rely on that: Find-BenchmarkResult.ps1 parses the same
    format and is the place to change if this one changes.

    Returns a path only. Creates neither the directory nor the file.

.PARAMETER Variant
    The variant the run measured.

.PARAMETER Kind
    'cold' for a forced cold-start run, 'coldwarm' for a run under load.

.PARAMETER MeasuredAt
    When the run started. Converted to UTC before formatting.

.PARAMETER RequestedSamples
    The sample count the measuring script was asked for (-Samples or
    -Invocations), not the number of rows it collected.

.PARAMETER ResultsPath
    Directory the file goes in. Defaults to bench/results.

.EXAMPLE
    ./bench/internal/Get-BenchmarkResultPath.ps1 01-managed -Kind cold `
        -MeasuredAt ([datetime]::UtcNow) -RequestedSamples 30
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('01-managed', '02-snapstart', '02-snapstart-primed',
        '03-native-aot', '03-native-aot-ready', '03-native-aot-single-purpose')]
    [string] $Variant,
    [Parameter(Mandatory)]
    [ValidateSet('cold', 'coldwarm')]
    [string] $Kind,
    [Parameter(Mandatory)]
    [datetime] $MeasuredAt,
    [Parameter(Mandatory)]
    [ValidateRange(1, [int]::MaxValue)]
    [int] $RequestedSamples,
    [string] $ResultsPath = (Join-Path $PSScriptRoot '../results')
)

$ErrorActionPreference = 'Stop'

$invariant = [cultureinfo]::InvariantCulture
$stamp = $MeasuredAt.ToUniversalTime().ToString("yyyyMMdd'T'HHmmss'Z'", $invariant)
$count = $RequestedSamples.ToString($invariant)

Join-Path $ResultsPath "$Variant.$Kind.$stamp.n$count.csv"
