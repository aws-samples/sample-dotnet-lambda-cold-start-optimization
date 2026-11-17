#!/usr/bin/env pwsh
# Copyright © 2026 Amazon.com and Affiliates. Licensed under MIT-0.

<#
.SYNOPSIS
    Fires many rapid invocations per variant, then reports the cold vs warm
    ratio.

.DESCRIPTION
    This does NOT force cold starts. It hammers each function at a natural
    concurrency to see how Lambda reuses execution environments under load.
    Use Measure-ColdStart.ps1 when you want cold samples on purpose.

    Omit -Variant to measure every variant worth measuring, or name the ones you
    want. -Invocations, -Concurrency and -Region are single-valued, so one call
    applies the same load to every variant and the ratios are comparable. One
    variant failing is reported and does not stop the rest.

    Prints the results and writes
    results/<variant>.coldwarm.<yyyyMMddTHHmmssZ>.n<Invocations>.csv, e.g.
    results/01-managed.coldwarm.20261001T143200Z.n500.csv, one row per REPORT
    line, in the same columns as Measure-ColdStart.ps1:
        init_duration_ms,restore_duration_ms,duration_ms,max_memory_mb
    The stamp is the UTC start of the invocation, shared by every variant in
    it. Earlier runs are never overwritten; Show-BenchmarkComparison.ps1 reads
    the latest per variant.

    "Cold" means the REPORT line carries an Init Duration (managed) or a Restore
    Duration (SnapStart). Counting only Init Duration would classify every
    SnapStart restore as warm and report 0% cold.

    Credentials come from the standard AWS chain. Set AWS_PROFILE, or pass
    -ProfileName to override.

.EXAMPLE
    ./bench/Measure-ColdWarmRatio.ps1
    Every variant except 03-native-aot, five hundred requests each at a
    concurrency of ten, with a summary table at the end.

.EXAMPLE
    ./bench/Measure-ColdWarmRatio.ps1 02-snapstart-primed
    Just one variant. -Variant is positional and tab-completable.

.EXAMPLE
    ./bench/Measure-ColdWarmRatio.ps1 01-managed -Invocations 200 -Concurrency 5
    Lower load, so a larger share of requests land on warm environments.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('01-managed', '02-snapstart', '02-snapstart-primed',
        '03-native-aot', '03-native-aot-ready', '03-native-aot-single-purpose')]
    [string[]] $Variant,
    [int]    $Invocations = 500,
    [int]    $Concurrency = 10,
    [int]    $IngestionWaitSec = 20,
    [int]    $TimeoutSec = 90,
    [string] $Region,
    [string] $ProfileName
)

$ErrorActionPreference = 'Stop'

# Omitting -Variant means every variant, as it does in Measure-ColdStart.ps1.
# 03-native-aot is absent for the same reason: as committed it fails at
# runtime on purpose, so it has no ratio worth reporting. Name it explicitly
# if you want to watch it fail.
if (-not $Variant) {
    $Variant = @('01-managed', '02-snapstart', '02-snapstart-primed',
        '03-native-aot-ready', '03-native-aot-single-purpose')
}

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

    # --region is passed explicitly. Without it the CLI falls back to its own
    # configured default, which may not be the region the stack is in.
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

$summary = [System.Collections.Generic.List[object]]::new()
$failedVariants = [System.Collections.Generic.List[string]]::new()

foreach ($name in $Variant) {
    Write-Host ''
    Write-Host "########## $name ##########" -ForegroundColor Magenta

    try {
        $stack = & "$PSScriptRoot/internal/Get-StackOutput.ps1" `
            -Variant $name -Region $Region -ProfileName $ProfileName
        $profileArgs = @($stack.ProfileArgs)

        Write-Host "Stack:        $($stack.StackName)"
        Write-Host "Function:     $($stack.FunctionName)"
        Write-Host "API:          $($stack.ApiUrl)"
        Write-Host "Invocations:  $Invocations"
        Write-Host "Concurrency:  $Concurrency"
        Write-Host ''

        $startTime = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

        Write-Host "=== Phase 1: firing $Invocations requests (concurrency $Concurrency) ===" `
            -ForegroundColor Cyan

        $results = & "$PSScriptRoot/internal/Invoke-OrdersApi.ps1" `
            -ApiUrl $stack.ApiUrl -Count $Invocations -Concurrency $Concurrency `
            -TimeoutSec $TimeoutSec -ShowProgress

        $failedRequests = @($results | Where-Object { -not $_.Ok })
        Write-Host ''
        if ($failedRequests.Count -gt 0) {
            Write-Host "$($failedRequests.Count) of $Invocations requests failed." `
                -ForegroundColor Yellow
            foreach ($failure in ($failedRequests | Select-Object -First 3)) {
                Write-Host "  $($failure.Status) $($failure.Error)" -ForegroundColor Yellow
            }
            Write-Host ''
        }

        Write-Host '=== Phase 2: waiting for log ingestion ===' -ForegroundColor Cyan

        Start-Sleep -Seconds $IngestionWaitSec
        $messages = Get-ReportMessage -Stack $stack -StartTime $startTime `
            -ProfileArgument $profileArgs
        if ($messages.Count -eq 0) {
            Write-Host '(logs still ingesting, retrying in 15s...)'
            Start-Sleep -Seconds 15
            $messages = Get-ReportMessage -Stack $stack -StartTime $startTime `
                -ProfileArgument $profileArgs
        }

        $reports = @(& "$PSScriptRoot/internal/ConvertFrom-LambdaReport.ps1" $messages)

        # Same columns as Measure-ColdStart.ps1; the kind and stamp in the file
        # name keep the runs apart. Invariant culture for the same reason: on
        # a comma-decimal locale, interpolation writes 857.79 as "857,79".
        $rows = [System.Collections.Generic.List[string]]::new()
        $rows.Add('init_duration_ms,restore_duration_ms,duration_ms,max_memory_mb')
        $invariant = [cultureinfo]::InvariantCulture
        foreach ($report in $reports) {
            $rows.Add([string]::Join(',', @(
                        $report.InitMs.ToString($invariant)
                        $report.RestoreMs.ToString($invariant)
                        $report.DurationMs.ToString($invariant)
                        $report.MaxMemoryMb.ToString($invariant)
                    )))
        }
        $resultsFile = & "$PSScriptRoot/internal/Get-BenchmarkResultPath.ps1" `
            -Variant $name -Kind coldwarm -MeasuredAt $measuredAt `
            -RequestedSamples $Invocations -ResultsPath $resultsDir
        Set-Content -Path $resultsFile -Value $rows -Encoding utf8

        $cold = @($reports | Where-Object IsCold)
        $warm = @($reports | Where-Object { -not $_.IsCold })
        $total = $reports.Count

        $coldPercent = $null
        $avgCold = $null
        $avgWarm = $null
        $kind = ''

        Write-Host ''
        Write-Host '  Results'
        Write-Host '  -------'
        Write-Host "  Total REPORT lines:    $total"
        Write-Host "  Cold starts:           $($cold.Count)"
        Write-Host "  Warm starts:           $($warm.Count)"
        Write-Host ''

        if ($total -gt 0) {
            $coldPercent = 100 * $cold.Count / $total
            Write-Host ("  Cold start %:          {0:N1}%" -f $coldPercent)
            Write-Host ("  Warm start %:          {0:N1}%" -f (100 - $coldPercent))
            Write-Host ''

            if ($cold.Count -gt 0) {
                $avgCold = ($cold | Measure-Object ColdMs -Average).Average
                $kind = if (@($cold | Where-Object { $_.RestoreMs -gt 0 }).Count -gt 0) {
                    'restore'
                }
                else { 'init' }
                Write-Host ("  Avg cold ({0,-7}):     {1:N1}ms" -f $kind, $avgCold)
            }

            if ($warm.Count -gt 0) {
                $avgWarm = ($warm | Measure-Object DurationMs -Average).Average
                Write-Host ("  Avg warm duration:     {0:N1}ms" -f $avgWarm)
            }
        }

        Write-Host ''
        Write-Host "  Results: $resultsFile"

        if ($total -lt $Invocations) {
            Write-Host ''
            Write-Host "NOTE: only $total of $Invocations REPORT lines found. Some may still be" `
                -ForegroundColor Yellow
            Write-Host 'ingesting. Re-check with:' -ForegroundColor Yellow
            Write-Host "  ./bench/Get-OrdersApiLog.ps1 $name -Pattern REPORT" -ForegroundColor Yellow
        }

        $summary.Add([pscustomobject]@{
                Variant  = $name
                Reports  = $total
                Cold     = $cold.Count
                'Cold %' = if ($null -ne $coldPercent) { '{0:N1}' -f $coldPercent } else { '-' }
                Kind     = $kind
                'Avg cold ms' = if ($null -ne $avgCold) { '{0:N1}' -f $avgCold } else { '-' }
                'Avg warm ms' = if ($null -ne $avgWarm) { '{0:N1}' -f $avgWarm } else { '-' }
            })
    }
    catch {
        # One variant failing must not cost the ones after it: each is hundreds
        # of invocations plus an ingestion wait that already succeeded.
        $failedVariants.Add($name)
        Write-Host ''
        Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host ''
Write-Host '============================================'
Write-Host '  Cold vs Warm Summary'
Write-Host '============================================'
if ($summary.Count -gt 0) {
    $summary | Format-Table -AutoSize | Out-String | Write-Host
}

if ($failedVariants.Count -gt 0) {
    Write-Host "Failed:   $($failedVariants -join ', ')" -ForegroundColor Red
    Write-Host "The comparison table picks each variant's latest file, so for these" `
        -ForegroundColor Yellow
    Write-Host 'it would show an earlier run (its "Measured at" row will say so).' `
        -ForegroundColor Yellow
}

Write-Host ''
Write-Host 'Comparison table:  ./bench/Show-BenchmarkComparison.ps1'
