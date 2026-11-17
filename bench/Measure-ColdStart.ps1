#!/usr/bin/env pwsh
# Copyright © 2026 Amazon.com and Affiliates. Licensed under MIT-0.

<#
.SYNOPSIS
    Collects N cold-start samples per variant and writes one CSV per variant.

.DESCRIPTION
    Per variant: force one cold state, fire all samples concurrently, scrape the
    REPORT lines, write the CSV.

    Omit -Variant to measure every variant worth measuring, or name the ones you
    want. Measuring several in one call rather than looping by hand is what makes
    the numbers comparable: -Samples, -Concurrency and -Region are single-valued,
    so they apply to every variant by construction. A hand-rolled loop lets you
    re-run one variant at a different sample count and silently mix a 50-sample
    p99 into a table of 30-sample ones. A loop also dies on the first failure and
    loses the variants after it, which is expensive - each one is a reset plus a
    log-ingestion wait.

    Concurrency is what produces cold starts, not repetition. A Lambda execution
    environment serves one request at a time, so N overlapping requests require
    N environments and yield up to N cold starts from a single reset. Invoking
    sequentially would reuse the same warm environment and produce one sample no
    matter how many requests you sent.

    That is also why the reset runs once per variant rather than once per sample.
    For a SnapStart variant the reset publishes a version and moves the alias,
    and one publish creates a billed snapshot in each of several Availability
    Zones - doing that 30 times would be slow and wasteful. One publish serves
    all N restores.

    Writes results/<variant>.cold.<yyyyMMddTHHmmssZ>.n<Samples>.csv, e.g.
    results/01-managed.cold.20261001T143200Z.n30.csv, with one row per REPORT
    line:
        init_duration_ms,restore_duration_ms,duration_ms,max_memory_mb
    The stamp is the UTC start of the invocation, shared by every variant in
    it. Earlier runs are never overwritten; Show-BenchmarkComparison.ps1 reads
    the latest per variant.

    Managed cold starts report Init Duration; SnapStart restores report Restore
    Duration instead, and never both. Show-BenchmarkComparison.ps1 treats either
    as the cold number.

    Credentials come from the standard AWS chain. Set AWS_PROFILE, or pass
    -ProfileName to override.

.EXAMPLE
    ./bench/Measure-ColdStart.ps1 -Samples 30
    ./bench/Show-BenchmarkComparison.ps1
    The whole comparison, all at the same sample count: managed, SnapStart
    unprimed (02-snapstart as committed) and primed, and Native AOT ready.
    03-native-aot is left out - as committed it deploys and then fails at
    runtime on purpose, so it has no cold-start number to contribute.

.EXAMPLE
    ./bench/Measure-ColdStart.ps1 01-managed
    Thirty samples for one variant. -Variant is positional and tab-completable.

.EXAMPLE
    ./bench/Measure-ColdStart.ps1 02-snapstart-primed -Samples 50
    Fifty concurrent restores from a single published snapshot.

.EXAMPLE
    ./bench/Measure-ColdStart.ps1 01-managed,03-native-aot-ready -Samples 50
    Just the two head-to-head numbers, both at 50 samples.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('01-managed', '02-snapstart', '02-snapstart-primed',
        '03-native-aot', '03-native-aot-ready', '03-native-aot-single-purpose')]
    [string[]] $Variant,
    [int]    $Samples = 30,
    # Requests dispatched simultaneously. Defaults to -Samples, which is what
    # you want: lowering it sends later requests into environments the earlier
    # ones already warmed, so you get fewer cold samples than invocations.
    [int]    $Concurrency = 0,
    [int]    $IngestionWaitSec = 10,
    [int]    $TimeoutSec = 90,
    [string] $Region,
    [string] $ProfileName
)

$ErrorActionPreference = 'Stop'

# Omitting -Variant means every variant, as it does in Deploy-OrdersApi.ps1 and
# the rest. Note 03-native-aot is absent: as committed it deploys and then
# fails at runtime on purpose, so it has no cold-start number to contribute.
# Name it explicitly if you want to watch it fail.
if (-not $Variant) {
    $Variant = @('01-managed', '02-snapstart', '02-snapstart-primed',
        '03-native-aot-ready', '03-native-aot-single-purpose')
}

if ($Concurrency -le 0) { $Concurrency = $Samples }

# One stamp per invocation, so every variant measured together shares it.
$measuredAt = [DateTime]::UtcNow

$resultsDir = Join-Path $PSScriptRoot 'results'
New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null

function Get-ReportMessage {
    param(
        [Parameter(Mandatory)] $Stack,
        [Parameter(Mandatory)] [long] $StartTime,
        [string[]] $ProfileArgument
    )

    # --region is passed explicitly rather than relying on the CLI default,
    # which may not be the region the stack lives in.
    $json = (& aws logs filter-log-events `
            --region $Stack.Region `
            --log-group-name $Stack.LogGroup `
            --filter-pattern 'REPORT' `
            --start-time $StartTime `
            --output json @ProfileArgument | Out-String)

    if ($LASTEXITCODE -ne 0) {
        throw "aws logs filter-log-events failed (exit $LASTEXITCODE). See the error above."
    }
    if (-not $json.Trim()) { return @() }
    @(($json | ConvertFrom-Json).events.message)
}

$measured = [System.Collections.Generic.List[string]]::new()
$failed = [System.Collections.Generic.List[string]]::new()

foreach ($name in $Variant) {
    Write-Host ''
    Write-Host "########## $name ##########" -ForegroundColor Magenta

    try {
        $stack = & "$PSScriptRoot/internal/Get-StackOutput.ps1" `
            -Variant $name -Region $Region -ProfileName $ProfileName

        $resultsFile = & "$PSScriptRoot/internal/Get-BenchmarkResultPath.ps1" `
            -Variant $name -Kind cold -MeasuredAt $measuredAt `
            -RequestedSamples $Samples -ResultsPath $resultsDir

        Write-Host "Stack:       $($stack.StackName)"
        Write-Host "Function:    $($stack.FunctionName)"
        Write-Host "API:         $($stack.ApiUrl)"
        Write-Host "Samples:     $Samples (concurrency $Concurrency)"
        Write-Host ''

        Write-Host '=== Phase 1: forcing a cold state ===' -ForegroundColor Cyan
        $reset = & "$PSScriptRoot/internal/Reset-ExecutionEnvironment.ps1" `
            -Variant $name -Region $Region -ProfileName $ProfileName
        Write-Host ''

        # Start the clock only after the reset, so snapshot-creation INIT_REPORT
        # lines from the publish are not picked up as samples.
        $suiteStart = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

        Write-Host "=== Phase 2: firing $Samples requests ===" -ForegroundColor Cyan

        $results = & "$PSScriptRoot/internal/Invoke-OrdersApi.ps1" `
            -ApiUrl $stack.ApiUrl -Count $Samples -Concurrency $Concurrency `
            -TimeoutSec $TimeoutSec

        $results | Group-Object { if ($_.Ok) { $_.Status } else { $_.Status ?? 'faulted' } } |
            Sort-Object Name | ForEach-Object { Write-Host "  $($_.Count) x $($_.Name)" }
        Write-Host ''

        Write-Host '=== Phase 3: waiting for CloudWatch log ingestion ===' -ForegroundColor Cyan

        $profileArgs = @($stack.ProfileArgs)

        Start-Sleep -Seconds $IngestionWaitSec
        $messages = Get-ReportMessage -Stack $stack -StartTime $suiteStart `
            -ProfileArgument $profileArgs
        if ($messages.Count -eq 0) {
            Write-Host '(logs not ready, retrying in 15s...)'
            Start-Sleep -Seconds 15
            $messages = Get-ReportMessage -Stack $stack -StartTime $suiteStart `
                -ProfileArgument $profileArgs
        }

        $reports = @(& "$PSScriptRoot/internal/ConvertFrom-LambdaReport.ps1" $messages)

        $rows = [System.Collections.Generic.List[string]]::new()
        $rows.Add('init_duration_ms,restore_duration_ms,duration_ms,max_memory_mb')

        # Formatted with the invariant culture, NOT string interpolation. Half of
        # Europe uses a comma as the decimal separator, so '{0},{1}' -f 857.79, 138
        # writes "857,79,138" - four CSV fields from two values, silently corrupt.
        $invariant = [cultureinfo]::InvariantCulture
        foreach ($report in $reports) {
            $rows.Add([string]::Join(',', @(
                        $report.InitMs.ToString($invariant)
                        $report.RestoreMs.ToString($invariant)
                        $report.DurationMs.ToString($invariant)
                        $report.MaxMemoryMb.ToString($invariant)
                    )))
        }

        Set-Content -Path $resultsFile -Value $rows -Encoding utf8

        $coldCount = @($reports | Where-Object IsCold).Count
        $sampleCount = $reports.Count
        Write-Host ''
        Write-Host "Captured $sampleCount REPORT lines ($coldCount cold) from $Samples invocations."
        Write-Host "Expected cold mechanism: $($reset.Mode)"
        Write-Host "Results: $resultsFile"

        if ($coldCount -lt $Samples) {
            Write-Host ''
            Write-Host 'NOTE: fewer cold samples than invocations. Either some requests reused' -ForegroundColor Yellow
            Write-Host 'an environment (raise -Concurrency), or logs are still ingesting.' -ForegroundColor Yellow
            Write-Host 'Re-check with:' -ForegroundColor Yellow
            Write-Host "  ./bench/Get-OrdersApiLog.ps1 $name -Pattern REPORT" -ForegroundColor Yellow
        }

        $measured.Add($name)
    }
    catch {
        # One variant failing must not cost the ones after it. Each is a reset
        # plus 30 concurrent invocations plus an ingestion wait, so aborting the
        # run throws away minutes of work that already succeeded.
        $failed.Add($name)
        Write-Host ''
        Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host ''
Write-Host "Measured: $($measured -join ', ')"

if ($failed.Count -gt 0) {
    Write-Host "Failed:   $($failed -join ', ')" -ForegroundColor Red
    Write-Host ''
    Write-Host 'Re-run the failed variants before comparing. The table picks each' -ForegroundColor Yellow
    Write-Host "variant's latest file, so for these it would show an earlier run" -ForegroundColor Yellow
    Write-Host '(its "Measured at" row will say so).' -ForegroundColor Yellow
}

Write-Host ''
Write-Host 'Comparison table:  ./bench/Show-BenchmarkComparison.ps1'
