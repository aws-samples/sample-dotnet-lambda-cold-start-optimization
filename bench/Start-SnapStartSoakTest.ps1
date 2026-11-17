#!/usr/bin/env pwsh
# Copyright © 2026 Amazon.com and Affiliates. Licensed under MIT-0.

<#
.SYNOPSIS
    Soaks 02-snapstart-primed over N hours and charts how its SnapStart restore
    (cold start) times evolve, to test whether they fall the longer the version
    stays deployed.

.DESCRIPTION
    The hypothesis: once a SnapStart version is published, AWS-side caches warm
    with the function's snapshot over time, so restore (cold start) latency
    should trend down the longer the version has been live.

    To establish a known starting point, the script resets the execution
    environment EXACTLY ONCE, before round 1, via
    internal/Reset-ExecutionEnvironment.ps1. For a SnapStart variant that bumps
    COLD_START_SEED, publishes a fresh version and moves the alias onto it, so
    round 1 (elapsed ~0h) is the first restore of a brand-new snapshot. Every
    round after that changes NOTHING about the deployment: no reset, no publish,
    no alias move. That is deliberate - a mid-run reset would mint a new snapshot
    and reset the very clock we are watching. Between rounds we simply let idle
    execution environments be reaped naturally by the Lambda service (its idle
    window is minutes, well under our spacing), so each burst tends to land on
    freshly restored environments against the SAME published version for the
    rest of the soak.

    Each round:
      1. Pick a random concurrency between -MinConcurrency and -MaxConcurrency
         (1..30 by default) and fire that many requests in one wave through
         internal/Invoke-OrdersApi.ps1, so they are genuinely in flight together
         and each forces its own restore (a Lambda environment serves one
         request at a time).
      2. Wait for CloudWatch log ingestion, scrape the REPORT lines, and keep
         the ones that carry a Restore Duration. Those are the cold starts.
      3. Append every cold sample - stamped with the UTC time of the round - to
         a CSV, and rewrite the HTML report. Both are updated every round, so a
         crash or Ctrl-C after hour six still leaves six hours of data and a
         readable chart.
      4. Sleep a random 17..30 minutes (-MinIntervalMin..-MaxIntervalMin) before
         the next round. The spacing comfortably exceeds Lambda's idle reap
         window, so most environments are gone by the next burst.

    Because we never force a cold state, a burst whose concurrency is below the
    number of still-warm environments from the previous burst will see some warm
    responses. That is expected and realistic; the report records the cold/total
    ratio per round so the analysis is explicit about it, and the time-series
    uses cold (restore) samples only.

    The chart buckets cold samples into one-hour windows measured from the first
    round, plotting p50 and p99 restore time per window so the trend (if any) is
    visible. The HTML is self-contained apart from a Chart.js CDN reference.

    Credentials come from the standard AWS chain. Set AWS_PROFILE, or pass
    -ProfileName to override.

.PARAMETER Hours
    How long to keep soaking, in hours. The loop stops once this much wall-clock
    time has elapsed since the first round. Default 8.

.PARAMETER MinConcurrency
    Smallest random burst size. Default 1.

.PARAMETER MaxConcurrency
    Largest random burst size. Default 30.

.PARAMETER MinIntervalMin
    Shortest random wait between rounds, in minutes. Default 17.

.PARAMETER MaxIntervalMin
    Longest random wait between rounds, in minutes. Default 30.

.PARAMETER Variant
    Which variant to soak. Defaults to 02-snapstart-primed - the whole point of
    this experiment - but left as a parameter so the same script can watch any
    SnapStart variant.

.PARAMETER IngestionWaitSec
    How long to wait for CloudWatch log ingestion before scraping REPORT lines.
    Default 12.

.PARAMETER TimeoutSec
    Per-request HTTP timeout. Default 90.

.PARAMETER Region
    Overrides the region from the variant's samconfig.toml.

.PARAMETER ProfileName
    AWS profile to use instead of the default credential chain.

.EXAMPLE
    ./bench/Start-SnapStartSoakTest.ps1 -Hours 8
    An eight-hour soak of 02-snapstart-primed with the default 1..30 burst size
    and 17..30 minute spacing. Open the printed HTML path to watch the chart
    fill in.

.EXAMPLE
    ./bench/Start-SnapStartSoakTest.ps1 -Hours 24 -MinIntervalMin 20 -MaxIntervalMin 40
    A longer, more widely spaced run.
#>
[CmdletBinding()]
param(
    [double] $Hours = 8,
    [ValidateRange(1, 1000)]
    [int]    $MinConcurrency = 1,
    [ValidateRange(1, 1000)]
    [int]    $MaxConcurrency = 30,
    [ValidateRange(1, 1440)]
    [int]    $MinIntervalMin = 17,
    [ValidateRange(1, 1440)]
    [int]    $MaxIntervalMin = 30,
    [ValidateSet('01-managed', '02-snapstart', '02-snapstart-primed',
        '03-native-aot', '03-native-aot-ready')]
    [string] $Variant = '02-snapstart-primed',
    [int]    $IngestionWaitSec = 12,
    [int]    $TimeoutSec = 90,
    [string] $Region,
    [string] $ProfileName
)

$ErrorActionPreference = 'Stop'

if ($MinConcurrency -gt $MaxConcurrency) {
    throw "-MinConcurrency ($MinConcurrency) cannot exceed -MaxConcurrency ($MaxConcurrency)."
}
if ($MinIntervalMin -gt $MaxIntervalMin) {
    throw "-MinIntervalMin ($MinIntervalMin) cannot exceed -MaxIntervalMin ($MaxIntervalMin)."
}

$invariant = [cultureinfo]::InvariantCulture
$startedAt = [DateTime]::UtcNow
$stamp = $startedAt.ToString("yyyyMMdd'T'HHmmss'Z'", $invariant)

$resultsDir = Join-Path $PSScriptRoot 'results'
New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null

$csvPath = Join-Path $resultsDir "$Variant.soak.$stamp.csv"
$htmlPath = Join-Path $resultsDir "$Variant.soak.$stamp.html"

# Resolve the stack once. The deployment is fixed for the whole soak - that is
# the experiment - so there is no reason to re-resolve it each round.
$stack = & "$PSScriptRoot/internal/Get-StackOutput.ps1" `
    -Variant $Variant -Region $Region -ProfileName $ProfileName

Write-Host ''
Write-Host '==================================================================' -ForegroundColor Cyan
Write-Host '  SnapStart soak test (no environment reset)' -ForegroundColor Cyan
Write-Host '==================================================================' -ForegroundColor Cyan
Write-Host "Variant:     $Variant"
Write-Host "Stack:       $($stack.StackName)"
Write-Host "Function:    $($stack.FunctionName)"
Write-Host "API:         $($stack.ApiUrl)"
Write-Host "Region:      $($stack.Region)"
Write-Host "Duration:    $Hours h   (started $($startedAt.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", $invariant)))"
Write-Host "Burst:       random $MinConcurrency..$MaxConcurrency concurrent requests"
Write-Host "Interval:    random $MinIntervalMin..$MaxIntervalMin min between rounds"
Write-Host "CSV:         $csvPath"
Write-Host "Report:      $htmlPath"
Write-Host ''
Write-Host 'No reset between rounds: environments are left to idle out naturally.' -ForegroundColor Yellow
Write-Host 'Safe to stop with Ctrl-C - the CSV and HTML are rewritten every round.' -ForegroundColor Yellow
Write-Host ''

$profileArgs = @($stack.ProfileArgs)

# --- One reset before round 1, and only before round 1 ---------------------
# Establish a clean, known starting point: bump COLD_START_SEED and (for a
# SnapStart variant) publish a fresh version and move the alias onto it. That
# makes round 1 the first restore of a brand-new snapshot - elapsed ~0h means
# genuinely just-published - so the hours that follow measure THAT version
# aging. No later round touches the function, so nothing resets the clock we
# are watching.
Write-Host '=== Pre-round reset (once, before round 1) ===' -ForegroundColor Cyan
$reset = & "$PSScriptRoot/internal/Reset-ExecutionEnvironment.ps1" `
    -Variant $Variant -Region $Region -ProfileName $ProfileName
Write-Host "Reset mode: $($reset.Mode)$(if ($reset.Version) { " (published version $($reset.Version) on alias '$($reset.Alias)')" })"
Write-Host ''

# Human-readable one-liner for the report metadata, so the starting condition
# is documented alongside the results.
$resetSummary = if ($reset.Mode -eq 'Restore') {
    "reset once before round 1 &mdash; published version $($reset.Version) onto alias '$($reset.Alias)' (round 1 is the first restore of a fresh snapshot)"
}
else {
    'reset once before round 1 &mdash; bumped COLD_START_SEED on $LATEST (round 1 is the first cold start after the change)'
}

# One row per cold (restore) sample, so the HTML can rebucket however it likes.
#   round, timestamp_utc, elapsed_hours, concurrency, restore_ms, duration_ms, max_memory_mb
$csvHeader = 'round,timestamp_utc,elapsed_hours,concurrency,restore_ms,duration_ms,max_memory_mb'
Set-Content -Path $csvPath -Value $csvHeader -Encoding utf8

# Per-round bookkeeping for the report's run log and summary.
$rounds = [System.Collections.Generic.List[object]]::new()
# Flat list of every cold sample, used to render the chart and the stats.
$coldSamples = [System.Collections.Generic.List[object]]::new()

function Get-ReportMessage {
    param([Parameter(Mandatory)] [long] $StartTime)

    $json = (& aws logs filter-log-events `
            --region $stack.Region `
            --log-group-name $stack.LogGroup `
            --filter-pattern 'REPORT' `
            --start-time $StartTime `
            --output json @profileArgs | Out-String)

    if ($LASTEXITCODE -ne 0) {
        throw "aws logs filter-log-events failed (exit $LASTEXITCODE). See the error above."
    }
    if (-not $json.Trim()) { return @() }
    @(($json | ConvertFrom-Json).events.message)
}

function Get-Percentile {
    param([double[]] $Values, [int] $Percent)
    if (-not $Values -or $Values.Count -eq 0) { return $null }
    $ordered = @($Values | Sort-Object)
    if ($ordered.Count -eq 1) { return $ordered[0] }
    # Nearest rank: the value returned actually occurred in the sample.
    $rank = [int][Math]::Round($Percent / 100 * $ordered.Count)
    $rank = [Math]::Max(1, [Math]::Min($ordered.Count, $rank))
    $ordered[$rank - 1]
}

# ---------------------------------------------------------------------------
# HTML report. Rewritten after every round so it is always current.
# ---------------------------------------------------------------------------
function Write-Report {
    param([bool] $Complete)

    # One point per round on the x-axis. Each round carries its four
    # pre-computed percentiles (restore p50/p99, total cold p50/p99); a round
    # with no cold samples contributes a null, which breaks the Chart.js line
    # into a visible gap rather than inventing a value.
    $labels = [System.Collections.Generic.List[string]]::new()
    $restoreP50Series = [System.Collections.Generic.List[string]]::new()
    $restoreP99Series = [System.Collections.Generic.List[string]]::new()
    $totalP50Series = [System.Collections.Generic.List[string]]::new()
    $totalP99Series = [System.Collections.Generic.List[string]]::new()
    $counts = [System.Collections.Generic.List[string]]::new()
    $roundRows = [System.Collections.Generic.List[string]]::new()

    function Format-Point { param($Value)
        if ($null -eq $Value) { 'null' } else { ([double]$Value).ToString('F1', $invariant) }
    }
    function Format-Cell { param($Value)
        if ($null -eq $Value) { '&mdash;' } else { ([double]$Value).ToString('F1', $invariant) }
    }

    foreach ($r in $rounds) {
        $labels.Add('"' + $r.Round.ToString($invariant) + '"')
        $restoreP50Series.Add((Format-Point $r.RestoreP50))
        $restoreP99Series.Add((Format-Point $r.RestoreP99))
        $totalP50Series.Add((Format-Point $r.TotalP50))
        $totalP99Series.Add((Format-Point $r.TotalP99))
        $counts.Add($r.Cold.ToString($invariant))

        $roundRows.Add(('<tr><td>{0}</td><td>{1}</td><td>{2:F2}</td><td>{3}</td><td>{4}</td><td>{5}/{6}</td><td>{7}</td><td>{8}</td><td>{9}</td><td>{10}</td></tr>' -f `
            $r.Round,
            $r.TimestampUtc,
            $r.ElapsedHours,
            $r.Concurrency,
            $r.Ok,
            $r.Cold, $r.Reports,
            (Format-Cell $r.RestoreP50),
            (Format-Cell $r.RestoreP99),
            (Format-Cell $r.TotalP50),
            (Format-Cell $r.TotalP99)))
    }

    # ---- Analysis prose, computed from the data we actually have ----
    $allRestore = @($coldSamples | ForEach-Object { [double]$_.RestoreMs })
    $allTotal = @($coldSamples | ForEach-Object { [double]$_.TotalMs })
    $totalCold = $allRestore.Count
    $totalRounds = $rounds.Count
    $totalReports = ($rounds | Measure-Object -Property Reports -Sum).Sum
    $elapsedH = ([DateTime]::UtcNow - $startedAt).TotalHours

    # Rounds that actually produced cold samples, in order, for first-vs-last.
    $coldRounds = @($rounds | Where-Object { $_.Cold -gt 0 })

    $analysis = [System.Collections.Generic.List[string]]::new()

    if ($coldRounds.Count -lt 2) {
        $analysis.Add('<p>Not enough data yet to judge the hypothesis. The trend becomes meaningful once at least two rounds have cold (restore) samples in them.</p>')
    }
    else {
        # Compare the first cold round to the last, on both series.
        $first = $coldRounds[0]
        $last = $coldRounds[-1]

        $rDelta = $last.RestoreP50 - $first.RestoreP50
        $rPct = if ($first.RestoreP50 -ne 0) { 100 * $rDelta / $first.RestoreP50 } else { 0 }
        $tDelta = $last.TotalP50 - $first.TotalP50
        $tPct = if ($first.TotalP50 -ne 0) { 100 * $tDelta / $first.TotalP50 } else { 0 }

        $direction = if ($rDelta -lt -1) { 'fallen' } elseif ($rDelta -gt 1) { 'risen' } else { 'held roughly flat' }
        $verdict = if ($rDelta -lt -1) {
            'This is consistent with the hypothesis: restore latency is trending down over the rounds that follow the deploy.'
        }
        elseif ($rDelta -gt 1) {
            'This runs against the hypothesis: restore latency did not improve over the soak. The warming effect, if any, is smaller than the round-to-round noise.'
        }
        else {
            'This neither confirms nor refutes the hypothesis: restore latency is essentially flat across the soak, so no meaningful warming trend is visible at this sample size.'
        }

        $analysis.Add(('<p>From round {0} to round {1} ({2} rounds with cold samples), median restore time has <strong>{3}</strong> from <strong>{4:F1}ms</strong> to <strong>{5:F1}ms</strong> &mdash; a change of <strong>{6:+0.0;-0.0;0.0}ms ({7:+0.0;-0.0;0.0}%)</strong>. Over the same rounds, median total cold start went from <strong>{8:F1}ms</strong> to <strong>{9:F1}ms</strong> (<strong>{10:+0.0;-0.0;0.0}ms, {11:+0.0;-0.0;0.0}%</strong>).</p>' -f `
            $first.Round, $last.Round, $coldRounds.Count,
            $direction, $first.RestoreP50, $last.RestoreP50, $rDelta, $rPct,
            $first.TotalP50, $last.TotalP50, $tDelta, $tPct))
        $analysis.Add("<p>$verdict</p>")

        $overallRP50 = Get-Percentile $allRestore 50
        $overallRP99 = Get-Percentile $allRestore 99
        $overallTP50 = Get-Percentile $allTotal 50
        $overallTP99 = Get-Percentile $allTotal 99
        $analysis.Add(('<p>Across the whole run so far ({0} cold samples): restore p50 <strong>{1:F1}ms</strong> / p99 <strong>{2:F1}ms</strong>; total cold start p50 <strong>{3:F1}ms</strong> / p99 <strong>{4:F1}ms</strong>.</p>' -f `
            $totalCold, $overallRP50, $overallRP99, $overallTP50, $overallTP99))
    }

    $coldShare = if ($totalReports -gt 0) { 100 * $totalCold / $totalReports } else { 0 }
    $analysis.Add(('<p>Cold share: of {0} REPORT lines captured across {1} rounds, {2} ({3:F1}%) were cold restores; the rest hit environments still warm from an earlier burst. The chart uses the cold samples only. Total cold start is each sample''s restore plus its own invocation duration.</p>' -f `
        $totalReports, $totalRounds, $totalCold, $coldShare))

    if (-not $Complete) {
        $analysis.Add('<p><em>Run in progress &mdash; this report refreshes after every round.</em></p>')
    }

    $statusBadge = if ($Complete) { 'complete' } else { 'running' }
    $generatedAt = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", $invariant)
    $startedText = $startedAt.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", $invariant)

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>SnapStart soak &mdash; $Variant</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4"></script>
<style>
  :root { color-scheme: light dark; }
  body { font-family: -apple-system, Segoe UI, Roboto, Helvetica, Arial, sans-serif;
         margin: 0; padding: 2rem; line-height: 1.5; max-width: 1100px; }
  h1 { margin-bottom: 0.25rem; }
  .sub { color: #666; margin-top: 0; }
  .badge { display: inline-block; padding: 0.15rem 0.6rem; border-radius: 1rem;
           font-size: 0.8rem; font-weight: 600; vertical-align: middle; }
  .badge.running { background: #fde68a; color: #92400e; }
  .badge.complete { background: #bbf7d0; color: #166534; }
  .meta { display: grid; grid-template-columns: max-content 1fr; gap: 0.15rem 1rem;
          font-size: 0.9rem; margin: 1rem 0 2rem; }
  .meta dt { font-weight: 600; color: #555; }
  .meta dd { margin: 0; font-variant-numeric: tabular-nums; }
  canvas { max-width: 100%; }
  .card { border: 1px solid #e5e7eb; border-radius: 0.75rem; padding: 1.25rem;
          margin: 1.5rem 0; }
  table { border-collapse: collapse; width: 100%; font-size: 0.88rem;
          font-variant-numeric: tabular-nums; }
  th, td { text-align: right; padding: 0.35rem 0.6rem; border-bottom: 1px solid #eee; }
  th:first-child, td:first-child { text-align: left; }
  thead th { border-bottom: 2px solid #ddd; }
  .analysis p { margin: 0.6rem 0; }
  footer { color: #888; font-size: 0.8rem; margin-top: 2rem; }
</style>
</head>
<body>
  <h1>SnapStart soak test <span class="badge $statusBadge">$statusBadge</span></h1>
  <p class="sub">$Variant &mdash; does SnapStart restore (cold start) latency fall the longer the version stays deployed?</p>

  <dl class="meta">
    <dt>Function</dt><dd>$($stack.FunctionName)</dd>
    <dt>Region</dt><dd>$($stack.Region)</dd>
    <dt>Started (UTC)</dt><dd>$startedText</dd>
    <dt>Elapsed</dt><dd>$($elapsedH.ToString('F2', $invariant)) h of $Hours h</dd>
    <dt>Rounds</dt><dd>$totalRounds</dd>
    <dt>Burst size</dt><dd>random $MinConcurrency&ndash;$MaxConcurrency concurrent</dd>
    <dt>Interval</dt><dd>random $MinIntervalMin&ndash;$MaxIntervalMin min</dd>
    <dt>Start condition</dt><dd>$resetSummary</dd>
    <dt>Reset between rounds</dt><dd>none &mdash; natural idle timeout</dd>
    <dt>Cold samples</dt><dd>$totalCold</dd>
  </dl>

  <div class="card">
    <h2>Cold start time per round</h2>
    <canvas id="chart" height="110"></canvas>
  </div>

  <div class="card analysis">
    <h2>Analysis</h2>
    $([string]::Join("`n    ", $analysis))
  </div>

  <div class="card">
    <h2>Round log</h2>
    <table>
      <thead><tr>
        <th>#</th><th>Timestamp (UTC)</th><th>Elapsed (h)</th><th>Burst</th><th>OK</th><th>Cold/Total</th>
        <th>Restore p50 (ms)</th><th>Restore p99 (ms)</th><th>Total p50 (ms)</th><th>Total p99 (ms)</th>
      </tr></thead>
      <tbody>
        $([string]::Join("`n        ", $roundRows))
      </tbody>
    </table>
  </div>

  <footer>Generated $generatedAt &middot; chart rendered with Chart.js 4 &middot; percentiles are nearest-rank</footer>

<script>
const labels = [$([string]::Join(', ', $labels))];
const restoreP50 = [$([string]::Join(', ', $restoreP50Series))];
const restoreP99 = [$([string]::Join(', ', $restoreP99Series))];
const totalP50 = [$([string]::Join(', ', $totalP50Series))];
const totalP99 = [$([string]::Join(', ', $totalP99Series))];
const counts = [$([string]::Join(', ', $counts))];
new Chart(document.getElementById('chart'), {
  type: 'line',
  data: {
    labels,
    datasets: [
      { label: 'Restore p50 (ms)', data: restoreP50, borderColor: '#2563eb',
        backgroundColor: '#2563eb', tension: 0.25, spanGaps: false },
      { label: 'Restore p99 (ms)', data: restoreP99, borderColor: '#60a5fa',
        backgroundColor: '#60a5fa', tension: 0.25, spanGaps: false, borderDash: [5, 4] },
      { label: 'Total cold start p50 (ms)', data: totalP50, borderColor: '#16a34a',
        backgroundColor: '#16a34a', tension: 0.25, spanGaps: false },
      { label: 'Total cold start p99 (ms)', data: totalP99, borderColor: '#f97316',
        backgroundColor: '#f97316', tension: 0.25, spanGaps: false, borderDash: [5, 4] }
    ]
  },
  options: {
    responsive: true,
    interaction: { mode: 'index', intersect: false },
    scales: {
      y: { title: { display: true, text: 'Duration (ms)' }, beginAtZero: false },
      x: { title: { display: true, text: 'Round' } }
    },
    plugins: {
      legend: { position: 'top' },
      tooltip: { callbacks: {
        afterBody: (items) => 'cold samples in round: ' + counts[items[0].dataIndex]
      } }
    }
  }
});
</script>
</body>
</html>
"@

    Set-Content -Path $htmlPath -Value $html -Encoding utf8
}

# Write an initial (empty) report so the file exists immediately.
Write-Report -Complete:$false

$round = 0
$rng = [Random]::new()

try {
    while (([DateTime]::UtcNow - $startedAt).TotalHours -lt $Hours) {
        $round++
        $concurrency = $rng.Next($MinConcurrency, $MaxConcurrency + 1)
        $roundStartUtc = [DateTime]::UtcNow
        $roundStartMs = [DateTimeOffset]::new($roundStartUtc, [TimeSpan]::Zero).ToUnixTimeMilliseconds()
        $elapsedHours = ($roundStartUtc - $startedAt).TotalHours
        $tsText = $roundStartUtc.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", $invariant)

        Write-Host ''
        Write-Host "----- Round $round @ $tsText (elapsed $($elapsedHours.ToString('F2', $invariant))h) -----" -ForegroundColor Magenta
        Write-Host "Firing $concurrency concurrent request(s)..."

        $results = & "$PSScriptRoot/internal/Invoke-OrdersApi.ps1" `
            -ApiUrl $stack.ApiUrl -Count $concurrency -Concurrency $concurrency `
            -TimeoutSec $TimeoutSec
        $results = @($results)

        $ok = @($results | Where-Object Ok).Count
        $failed = $results.Count - $ok
        if ($failed -gt 0) {
            Write-Host "  $failed request(s) failed; cold rows from this round are still recorded but may be noisy." -ForegroundColor Yellow
        }

        # Give CloudWatch a moment, then scrape REPORT lines for this round only.
        Start-Sleep -Seconds $IngestionWaitSec
        $messages = Get-ReportMessage -StartTime $roundStartMs
        if ($messages.Count -eq 0) {
            Write-Host '  (logs not ready, retrying in 15s...)'
            Start-Sleep -Seconds 15
            $messages = Get-ReportMessage -StartTime $roundStartMs
        }

        $reports = @(& "$PSScriptRoot/internal/ConvertFrom-LambdaReport.ps1" $messages)
        $cold = @($reports | Where-Object { $_.RestoreMs -gt 0 })

        # Append cold samples to the CSV and the in-memory list.
        $csvRows = [System.Collections.Generic.List[string]]::new()
        foreach ($c in $cold) {
            $coldSamples.Add([pscustomobject]@{
                Round        = $round
                ElapsedHours = $elapsedHours
                RestoreMs    = $c.RestoreMs
                DurationMs   = $c.DurationMs
                # Total cold start = this request's restore plus its own
                # invocation duration. Summed per sample so a percentile is
                # taken over real requests, never restore p99 + duration p99
                # (which would describe a request that never happened).
                TotalMs      = $c.RestoreMs + $c.DurationMs
            })
            $csvRows.Add([string]::Join(',', @(
                $round.ToString($invariant)
                $tsText
                $elapsedHours.ToString('F4', $invariant)
                $concurrency.ToString($invariant)
                $c.RestoreMs.ToString($invariant)
                $c.DurationMs.ToString($invariant)
                $c.MaxMemoryMb.ToString($invariant)
            )))
        }
        if ($csvRows.Count -gt 0) {
            Add-Content -Path $csvPath -Value $csvRows -Encoding utf8
        }

        $coldMs = @($cold | ForEach-Object { [double]$_.RestoreMs })
        $totalMs = @($cold | ForEach-Object { [double]$_.RestoreMs + [double]$_.DurationMs })

        # Per-round percentiles, computed once and carried on the round object
        # so Write-Report just reads them. $null when the round had no cold
        # samples, which the chart renders as a line gap.
        $restP50 = if ($coldMs.Count) { Get-Percentile $coldMs 50 } else { $null }
        $restP99 = if ($coldMs.Count) { Get-Percentile $coldMs 99 } else { $null }
        $totP50 = if ($totalMs.Count) { Get-Percentile $totalMs 50 } else { $null }
        $totP99 = if ($totalMs.Count) { Get-Percentile $totalMs 99 } else { $null }

        $rounds.Add([pscustomobject]@{
            Round        = $round
            TimestampUtc = $tsText
            ElapsedHours = $elapsedHours
            Concurrency  = $concurrency
            Ok           = $ok
            Reports      = $reports.Count
            Cold         = $cold.Count
            RestoreP50   = $restP50
            RestoreP99   = $restP99
            TotalP50     = $totP50
            TotalP99     = $totP99
        })

        $coldText = if ($cold.Count) { "restore p50 $($restP50.ToString('F1', $invariant))ms" } else { 'none' }
        Write-Host "  $ok OK, $($reports.Count) REPORT line(s), $($cold.Count) cold restore(s) ($coldText)."

        # Rewrite the report every round so the chart is always current.
        Write-Report -Complete:$false
        Write-Host "  Report updated: $htmlPath"

        # Stop before sleeping if we are already out of time.
        if (([DateTime]::UtcNow - $startedAt).TotalHours -ge $Hours) { break }

        $waitMin = $rng.Next($MinIntervalMin, $MaxIntervalMin + 1)
        # Don't oversleep past the deadline - trim the final wait.
        $remainingMin = ($Hours - ([DateTime]::UtcNow - $startedAt).TotalHours) * 60
        if ($remainingMin -lt $waitMin) { $waitMin = [int][Math]::Ceiling($remainingMin) }
        if ($waitMin -lt 1) { break }

        $nextAt = [DateTime]::UtcNow.AddMinutes($waitMin).ToString("HH:mm:ss'Z'", $invariant)
        Write-Host "  Sleeping $waitMin min (next round ~$nextAt)..."
        Start-Sleep -Seconds ($waitMin * 60)
    }
}
finally {
    # Always finalize the report, even on Ctrl-C, so whatever ran is captured.
    Write-Report -Complete:$true
}

Write-Host ''
Write-Host '==================================================================' -ForegroundColor Cyan
Write-Host "  Soak complete: $round round(s), $($coldSamples.Count) cold sample(s)" -ForegroundColor Cyan
Write-Host '==================================================================' -ForegroundColor Cyan
Write-Host "CSV:    $csvPath"
Write-Host "Report: $htmlPath"
Write-Host ''
Write-Host 'Open the report:'
Write-Host "  open '$htmlPath'"
Write-Host ''
