#!/usr/bin/env pwsh
# Copyright © 2026 Amazon.com and Affiliates. Licensed under MIT-0.

<#
.SYNOPSIS
    Reads the benchmark CSVs and prints the head-to-head comparison tables.

.DESCRIPTION
    Reads timestamped result files, all with the same columns:
        init_duration_ms,restore_duration_ms,duration_ms,max_memory_mb

      results/<variant>.cold.<yyyyMMddTHHmmssZ>.n<Samples>.csv
          Measure-ColdStart.ps1 - forced cold starts
      results/<variant>.coldwarm.<yyyyMMddTHHmmssZ>.n<Invocations>.csv
          Measure-ColdWarmRatio.ps1 - natural load

    For each variant and kind the latest file is used - or, with -AsOf, the
    latest stamped at or before that instant. The stamp is parsed from the
    name. A variant with no file of either kind is omitted.

    Always prints two tables, one per kind. They answer different questions,
    so they are never pooled:

      Cold start - p50/p99 come ONLY from the forced-cold file. Cold starts
      seen under load are real, but they were not collected under controlled
      conditions and would blur the head-to-head number. "Cold total (Lambda)"
      is computed per sample - init or restore plus that invocation's duration
      - and the percentile is taken over those sums. Adding a cold p99 to a
      duration p99 would describe a request that never happened. "Cold total
      min" is the fastest of those same sums, so it too is one real request.
      "Duration (cold)" is the REPORT line's Duration on those same cold
      requests - the invocation that landed on a fresh environment - so every
      row in the table describes the same set of requests. Warm rows in the
      file are excluded.

      Cold/warm - cold share and warm duration come ONLY from the cold/warm
      file. A variant without one shows dashes rather than borrowing warm rows
      from the forced-cold run.

    The two tables for one variant may come from different runs - a redeploy
    in between, for example. The "Measured at" row in each table shows which
    run it read. Re-run both before a number goes on a slide.

    "Cold samples" and "Load samples" show collected/requested, e.g. 29/30:
    collected is counted from the file, requested is the n<count> in its name.
    "Warm samples" is a plain count - it is a subset of the load run that
    nothing asked for, so a denominator would mean nothing.

    Cold start is Init Duration for managed variants and Restore Duration for
    SnapStart ones - a REPORT line carries one or the other, never both. Both
    fold into a single "cold" series, and the table reports which one it saw.

    Percentiles are nearest-rank: the value returned actually occurred in the
    sample. Interpolating between samples invents numbers that never happened,
    which is the wrong trade when the output goes on a slide.

    All parsing and formatting uses the invariant culture. On a machine whose
    locale uses a comma as the decimal separator, culture-sensitive formatting
    would print "857,8ms" and, worse, corrupt a CSV.

.PARAMETER Variant
    Variants to show. Omit for every variant that has a result file. Named
    explicitly, a variant with no file still gets a column of dashes.

.PARAMETER MinimumSamples
    Warn when a forced-cold run has fewer cold samples than this.

.PARAMETER AsOf
    Use the latest files stamped at or before this instant instead of the
    latest overall. Compared in UTC: a value with a zone or Z
    (2026-10-01T14:32:00Z) means that instant; a value without one
    (2026-10-01 14:32, or a bare date, which means local midnight) is read as
    local machine time. Append Z to mean UTC. A variant with no file that old
    shows dashes.

.PARAMETER ResultsPath
    Directory holding the result files. Defaults to bench/results. Point it
    at a copied set to compare that instead.

.PARAMETER PassThru
    Also emit the computed statistics as objects.

.PARAMETER Html
    Also write a standalone, self-contained HTML report of the cold-start
    table (no cold/warm table) and open it in the default browser.

.EXAMPLE
    ./bench/Measure-ColdStart.ps1 -Samples 30
    ./bench/Measure-ColdWarmRatio.ps1
    ./bench/Show-BenchmarkComparison.ps1
    Both tables, from the latest run of each.

.EXAMPLE
    ./bench/Show-BenchmarkComparison.ps1 -AsOf 2026-10-01T14:32:00Z
    The latest runs at or before that instant. Paste a "Measured at" value
    to reproduce an earlier table.

.EXAMPLE
    ./bench/Show-BenchmarkComparison.ps1 01-managed, 03-native-aot-ready
    Only these two. Named explicitly, a variant with no CSV still gets a column
    of dashes rather than being skipped.

.EXAMPLE
    ./bench/Show-BenchmarkComparison.ps1 -PassThru | Export-Csv summary.csv
    Also emit the computed statistics as objects.

.EXAMPLE
    ./bench/Show-BenchmarkComparison.ps1 -Html
    Also write the cold-start table as a standalone HTML report and open it
    in the default browser.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('01-managed', '02-snapstart', '02-snapstart-primed',
        '03-native-aot', '03-native-aot-ready', '03-native-aot-single-purpose')]
    [string[]] $Variant,
    [int]      $MinimumSamples = 30,
    [datetime] $AsOf,
    [string]   $ResultsPath = (Join-Path $PSScriptRoot 'results'),
    [switch]   $PassThru,
    [switch]   $Html
)

$ErrorActionPreference = 'Stop'

$invariant = [cultureinfo]::InvariantCulture
$dash = [string][char]0x2014   # em dash

# Display order and labels. Effort is the qualitative axis the talk argues for.
$allVariants = @(
    [pscustomobject]@{ Id = '01-managed'; Label = 'Managed'; Effort = 'none' }
    [pscustomobject]@{ Id = '02-snapstart'; Label = 'SnapStart'; Effort = 'low' }
    [pscustomobject]@{ Id = '02-snapstart-primed'; Label = 'SnapStart+prime (ref)'; Effort = 'low' }
    [pscustomobject]@{ Id = '03-native-aot'; Label = 'Native AOT'; Effort = 'high' }
    [pscustomobject]@{ Id = '03-native-aot-ready'; Label = 'Native AOT (ref)'; Effort = 'high' }
    [pscustomobject]@{ Id = '03-native-aot-single-purpose'; Label = 'AOT single-purpose (ref)'; Effort = 'high' }
)

$findArgs = @{ ResultsPath = $ResultsPath }
if ($PSBoundParameters.ContainsKey('AsOf')) { $findArgs.AsOf = $AsOf }

function ConvertTo-Number {
    param($Raw)
    $parsed = 0.0
    [void][double]::TryParse(([string]$Raw).Trim(),
        [Globalization.NumberStyles]::Float, $invariant, [ref] $parsed)
    $parsed
}

# One object per CSV row, with every column parsed. A missing file is no rows.
function Read-Report {
    param([string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) { return }
    foreach ($row in (Import-Csv -LiteralPath $Path)) {
        $init = ConvertTo-Number $row.init_duration_ms
        $restore = ConvertTo-Number $row.restore_duration_ms
        [pscustomobject]@{
            InitMs      = $init
            RestoreMs   = $restore
            ColdMs      = $init + $restore
            DurationMs  = ConvertTo-Number $row.duration_ms
            MaxMemoryMb = ConvertTo-Number $row.max_memory_mb
            IsCold      = ($init -gt 0 -or $restore -gt 0)
        }
    }
}

function Get-Percentile {
    param([double[]] $Values, [int] $Percent)

    if (-not $Values -or $Values.Count -eq 0) { return $null }
    $ordered = @($Values | Sort-Object)
    if ($ordered.Count -eq 1) { return $ordered[0] }

    # Nearest rank. [Math]::Round is banker's rounding by default, matching the
    # Python implementation this replaces, so published numbers don't shift.
    $rank = [int][Math]::Round($Percent / 100 * $ordered.Count)
    $rank = [Math]::Max(1, [Math]::Min($ordered.Count, $rank))
    $ordered[$rank - 1]
}

function Format-Duration {
    param($Value)
    if ($null -eq $Value) { return $dash }
    $Value.ToString('F1', $invariant) + 'ms'
}

function Format-Stamp {
    param($Value)
    if ($null -eq $Value) { return $dash }
    $Value.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", $invariant)
}

# Best-effort: open a file in the OS default browser. Failures are the
# caller's problem to warn about, not this function's to swallow.
function Open-InBrowser {
    param([string] $Path)
    if ($IsWindows) { Start-Process $Path }
    elseif ($IsMacOS) { & open $Path }
    elseif ($IsLinux) { & xdg-open $Path }
    else { Start-Process $Path }
}

# Collected over requested, e.g. 29/30.
function Format-Count {
    param([int] $Collected, [int] $Requested)
    $Collected.ToString($invariant) + '/' + $Requested.ToString($invariant)
}

function Get-ColdKind {
    param($Reports)
    $cold = @($Reports | Where-Object IsCold)
    if (-not $cold.Count) { return $dash }
    if (@($cold | Where-Object { $_.InitMs -gt 0 }).Count) { 'init' } else { 'restore' }
}

$present = foreach ($entry in $allVariants) {
    if ($Variant -and $entry.Id -notin $Variant) { continue }

    $coldFile = & "$PSScriptRoot/internal/Find-BenchmarkResult.ps1" `
        $entry.Id -Kind cold @findArgs
    $coldwarmFile = & "$PSScriptRoot/internal/Find-BenchmarkResult.ps1" `
        $entry.Id -Kind coldwarm @findArgs

    # With no -Variant given, a variant that was never benchmarked is omitted
    # rather than shown as an empty column.
    if (-not $coldFile -and -not $coldwarmFile -and -not $Variant) { continue }

    $stats = [ordered]@{
        Variant    = $entry.Id
        Label      = $entry.Label
        Effort     = $entry.Effort
        HasColdRun = [bool]$coldFile
        HasLoadRun = [bool]$coldwarmFile
    }

    # --- Cold table: the forced-cold file only ---
    $coldRun = if ($coldFile) { @(Read-Report $coldFile.Path) } else { @() }
    $coldRows = @($coldRun | Where-Object IsCold)
    $coldMs = @($coldRows | ForEach-Object ColdMs)

    # Per sample: this request's init/restore plus this request's duration.
    $coldTotals = @($coldRows | ForEach-Object { $_.ColdMs + $_.DurationMs })
    $memories = @($coldRun | ForEach-Object MaxMemoryMb | Where-Object { $_ -gt 0 })

    $stats.ColdP50 = Format-Duration (Get-Percentile $coldMs 50)
    $stats.ColdP99 = Format-Duration (Get-Percentile $coldMs 99)
    $stats.ColdKind = Get-ColdKind $coldRun
    $stats.ColdTotalMin = if ($coldTotals.Count) {
        Format-Duration ($coldTotals | Measure-Object -Minimum).Minimum
    }
    else { $dash }
    $stats.ColdTotalP50 = Format-Duration (Get-Percentile $coldTotals 50)
    $stats.ColdTotalP90 = Format-Duration (Get-Percentile $coldTotals 90)
    $stats.ColdTotalP99 = Format-Duration (Get-Percentile $coldTotals 99)
    # Cold requests only. Warm rows in the same file would drag a p50 down to
    # warm duration, by an amount that depends on each variant's cold share.
    $coldDurationMs = @($coldRows | ForEach-Object DurationMs)
    $stats.ColdDurationP50 = Format-Duration (Get-Percentile $coldDurationMs 50)
    $stats.ColdDurationP99 = Format-Duration (Get-Percentile $coldDurationMs 99)
    $stats.ColdCount = $coldRows.Count
    $stats.ColdSamples = if ($coldFile) {
        Format-Count $coldRows.Count $coldFile.RequestedSamples
    }
    else { $dash }
    $stats.MaxMemory = if ($memories.Count) {
        ($memories | Measure-Object -Maximum).Maximum.ToString('F0', $invariant) + 'MB'
    }
    else { $dash }
    $stats.ColdMeasuredAt = Format-Stamp $coldFile.MeasuredAt
    $stats.ColdFile = $coldFile.Path

    # --- Cold/warm table: the cold/warm file only, no fallback ---
    $loadRun = if ($coldwarmFile) { @(Read-Report $coldwarmFile.Path) } else { @() }
    $loadCold = @($loadRun | Where-Object IsCold)

    # Warm = a row with neither an init nor a restore.
    $warm = @($loadRun | Where-Object { -not $_.IsCold } | ForEach-Object DurationMs)

    $stats.LoadColdPercent = if ($loadRun.Count) {
        (100 * $loadCold.Count / $loadRun.Count).ToString('F1', $invariant) + '%'
    }
    else { $dash }
    $stats.LoadColdAvg = if ($loadCold.Count) {
        Format-Duration (($loadCold | Measure-Object ColdMs -Average).Average)
    }
    else { $dash }
    $stats.LoadSamples = if ($coldwarmFile) {
        Format-Count $loadRun.Count $coldwarmFile.RequestedSamples
    }
    else { $dash }
    $stats.WarmAvg = if ($warm.Count) {
        Format-Duration (($warm | Measure-Object -Average).Average)
    }
    else { $dash }
    $stats.WarmSamples = if ($coldwarmFile) { $warm.Count.ToString($invariant) } else { $dash }
    $stats.ColdwarmMeasuredAt = Format-Stamp $coldwarmFile.MeasuredAt
    $stats.ColdwarmFile = $coldwarmFile.Path

    [pscustomobject]$stats
}

$present = @($present)
$asOfText = if ($PSBoundParameters.ContainsKey('AsOf')) { Format-Stamp $AsOf } else { $null }

if ($present.Count -eq 0) {
    Write-Host ''
    if ($asOfText) {
        Write-Host "No result files found in $ResultsPath as of $asOfText."
    }
    else {
        Write-Host "No result files found in $ResultsPath."
    }
    Write-Host 'Run bench/Measure-ColdStart.ps1 or bench/Measure-ColdWarmRatio.ps1 first.'
    Write-Host ''
    return
}

$coldMetrics = @(
    @{ Label = 'Cold start p50'; Property = 'ColdP50' }
    @{ Label = 'Cold start p99'; Property = 'ColdP99' }
    @{ Label = 'Cold measured as'; Property = 'ColdKind' }
    @{ Label = 'Duration p50 (cold)'; Property = 'ColdDurationP50' }
    @{ Label = 'Duration p99 (cold)'; Property = 'ColdDurationP99' }
    @{ Label = 'Cold total min (Lambda)'; Property = 'ColdTotalMin' }
    @{ Label = 'Cold total p50 (Lambda)'; Property = 'ColdTotalP50' }
    @{ Label = 'Cold total p90 (Lambda)'; Property = 'ColdTotalP90' }
    @{ Label = 'Cold total p99 (Lambda)'; Property = 'ColdTotalP99' }
    @{ Label = 'Cold samples'; Property = 'ColdSamples' }
    @{ Label = 'Max memory used'; Property = 'MaxMemory' }
    @{ Label = 'Measured at'; Property = 'ColdMeasuredAt' }
    @{ Label = 'Engineering effort'; Property = 'Effort' }
)

$coldwarmMetrics = @(
    @{ Label = 'Cold % under load'; Property = 'LoadColdPercent' }
    @{ Label = 'Avg cold under load'; Property = 'LoadColdAvg' }
    @{ Label = 'Load samples'; Property = 'LoadSamples' }
    @{ Label = 'Warm avg duration'; Property = 'WarmAvg' }
    @{ Label = 'Warm samples'; Property = 'WarmSamples' }
    @{ Label = 'Measured at'; Property = 'ColdwarmMeasuredAt' }
)

# One set of widths for both tables, wide enough for every label and cell.
$allMetrics = $coldMetrics + $coldwarmMetrics
$longestCell = ($present | ForEach-Object {
        $column = $_
        $column.Label
        $allMetrics | ForEach-Object { [string]$column.($_.Property) }
    } | Measure-Object -Maximum -Property Length).Maximum
$colWidth = [Math]::Max(14, $longestCell + 1)
$metricWidth = ($allMetrics.Label | Measure-Object -Maximum -Property Length).Maximum + 1

$header = 'Metric'.PadRight($metricWidth) + ' | ' +
    (($present | ForEach-Object { $_.Label.PadRight($colWidth) }) -join ' | ')
$rule = '=' * $header.Length

function Write-MetricTable {
    param([string] $Title, $Metric)

    Write-Host "  $Title"
    Write-Host ''
    Write-Host $header
    Write-Host ('-' * $header.Length)
    foreach ($row in $Metric) {
        $cells = ($present | ForEach-Object {
                ([string]$_.($row.Property)).PadRight($colWidth)
            }) -join ' | '
        Write-Host ($row.Label.PadRight($metricWidth) + ' | ' + $cells)
    }
}

Write-Host ''
Write-Host $rule
Write-Host '  .NET Serverless Benchmark Comparison'
if ($asOfText) { Write-Host "  Latest results as of $asOfText" } else { Write-Host '  Latest results' }
Write-Host $rule
Write-Host ''
Write-MetricTable 'Cold start - forced (Measure-ColdStart.ps1)' $coldMetrics
Write-Host ''
Write-MetricTable 'Cold/warm - under load (Measure-ColdWarmRatio.ps1)' $coldwarmMetrics
Write-Host ''
Write-Host $rule

# Only variants with a forced-cold run can be short of cold samples. A variant
# measured under load alone has no p99 to warn about.
$thin = @($present | Where-Object { $_.HasColdRun -and $_.ColdCount -lt $MinimumSamples })
if ($thin.Count -gt 0) {
    Write-Host ''
    Write-Host ("WARNING: fewer than $MinimumSamples cold samples for: " +
        ($thin.Variant -join ', ')) -ForegroundColor Yellow
    Write-Host 'p99 is not meaningful at this sample size. Do not put these on a slide.' `
        -ForegroundColor Yellow
}
Write-Host ''

if ($Html) {
    try {
        $htmlPath = Join-Path $ResultsPath 'cold-start-report.html'
        $resolved = & "$PSScriptRoot/internal/ConvertTo-BenchmarkHtml.ps1" `
            $present $coldMetrics -OutputPath $htmlPath
        Write-Host "HTML report written to $resolved"
        Open-InBrowser $resolved
    }
    catch {
        Write-Warning "Could not generate or open the HTML report: $($_.Exception.Message)"
    }
}

if ($PassThru) { $present }
