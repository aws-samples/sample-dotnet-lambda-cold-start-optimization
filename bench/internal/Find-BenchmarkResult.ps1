#!/usr/bin/env pwsh
# Copyright © 2026 Amazon.com and Affiliates. Licensed under MIT-0.

<#
.SYNOPSIS
    Finds the latest benchmark result file for one variant and kind.

.DESCRIPTION
    The only reader of result filenames. Get-BenchmarkResultPath.ps1 writes
    them in this format, and the two must change together:

        <variant>.<kind>.<yyyyMMddTHHmmssZ>.n<RequestedSamples>.csv

    The stamp and count are parsed out of each name, and the file with the
    latest parsed stamp wins. Sort order of the names is never relied on.
    Files that do not match the format exactly - including the old
    untimestamped <variant>.csv and <variant>.load.csv - are ignored.

.PARAMETER Variant
    The variant to look for.

.PARAMETER Kind
    'cold' (Measure-ColdStart.ps1) or 'coldwarm' (Measure-ColdWarmRatio.ps1).

.PARAMETER AsOf
    Only consider files stamped at or before this instant. Compared in UTC:
    a value with a zone or Z (2026-10-01T14:32:00Z) means that instant; a
    value without one (2026-10-01 14:32, or a bare date, which means local
    midnight) is read as local machine time. Append Z to mean UTC.

.PARAMETER ResultsPath
    Directory to search. Defaults to bench/results.

.OUTPUTS
    One object with Variant, Kind, Path, MeasuredAt (UTC DateTime) and
    RequestedSamples (int), or nothing when no file matches.

.EXAMPLE
    ./bench/internal/Find-BenchmarkResult.ps1 01-managed -Kind cold

.EXAMPLE
    ./bench/internal/Find-BenchmarkResult.ps1 01-managed -Kind coldwarm `
        -AsOf 2026-10-01T14:32:00Z
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
    [datetime] $AsOf,
    [string] $ResultsPath = (Join-Path $PSScriptRoot '../results')
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $ResultsPath)) { return }

$invariant = [cultureinfo]::InvariantCulture
$utc = [Globalization.DateTimeStyles]::AssumeUniversal -bor
    [Globalization.DateTimeStyles]::AdjustToUniversal
$pattern = '^(?<variant>.+)\.(?<kind>cold|coldwarm)\.' +
    '(?<stamp>\d{8}T\d{6}Z)\.n(?<requested>\d+)\.csv$'

$files = Get-ChildItem -LiteralPath $ResultsPath -File -Filter "$Variant.$Kind.*.csv"

$candidates = foreach ($file in $files) {
    if ($file.Name -notmatch $pattern) { continue }
    if ($Matches.variant -ne $Variant -or $Matches.kind -ne $Kind) { continue }

    [pscustomobject]@{
        Variant          = $Variant
        Kind             = $Kind
        Path             = $file.FullName
        Name             = $file.Name
        MeasuredAt       = [datetime]::ParseExact($Matches.stamp,
            "yyyyMMdd'T'HHmmss'Z'", $invariant, $utc)
        RequestedSamples = [int]::Parse($Matches.requested, $invariant)
    }
}

if ($PSBoundParameters.ContainsKey('AsOf')) {
    $cutoff = $AsOf.ToUniversalTime()
    $candidates = @($candidates | Where-Object { $_.MeasuredAt -le $cutoff })
}

$candidates |
    Sort-Object MeasuredAt, Name -Descending |
    Select-Object -First 1 |
    Select-Object Variant, Kind, Path, MeasuredAt, RequestedSamples
