#!/usr/bin/env pwsh
# Copyright © 2026 Amazon.com and Affiliates. Licensed under MIT-0.

<#
.SYNOPSIS
    Renders the cold-start comparison table as a self-contained HTML page.

.DESCRIPTION
    Pure rendering only. Takes the already-computed per-variant statistics
    and row definitions that Show-BenchmarkComparison.ps1 builds and writes
    one standalone HTML file - no CSV reads, no stat math, no percentile
    logic. The page embeds its own <style> (no external CSS or font links)
    so it opens correctly offline, styled after the Dracula color theme.

    Every cell value is HTML-encoded via [System.Net.WebUtility]::HtmlEncode
    before being written out.

    The variant with the numerically lowest "Cold total p50 (Lambda)" is the
    winner: its entire column - header and every row - is highlighted,
    matching the green ".reveal table strong" convention in
    slides/custom.css. Values arrive already formatted (e.g. "857.8ms", or
    an em dash when absent), so the winner is found by parsing the leading
    number back out of the ColdTotalP50 row and ignoring cells with no
    parseable value. A tie keeps the first (left-most) variant as the
    winner; if no cell has a value, no column is highlighted.

.PARAMETER Present
    The per-variant statistics array (Show-BenchmarkComparison.ps1's
    $present) - one pscustomobject per variant, each exposing a Label and
    the properties named in ColdMetric.

.PARAMETER ColdMetric
    The cold-table row definitions (Show-BenchmarkComparison.ps1's
    $coldMetrics) - an array of @{ Label; Property } hashtables, in display
    order.

.PARAMETER OutputPath
    Path to write the HTML file to.

.OUTPUTS
    The resolved absolute path of the written HTML file.

.EXAMPLE
    ./bench/internal/ConvertTo-BenchmarkHtml.ps1 $present $coldMetrics `
        -OutputPath (Join-Path $ResultsPath 'cold-start-report.html')
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [object[]] $Present,
    [Parameter(Mandatory, Position = 1)]
    [object[]] $ColdMetric,
    [Parameter(Mandatory)]
    [string] $OutputPath
)

$ErrorActionPreference = 'Stop'

$invariant = [cultureinfo]::InvariantCulture

function Protect-Html {
    param($Value)
    [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

# Formatted durations look like "857.8ms", or an em dash when absent. Parses
# the leading number back out; returns $null for anything that isn't one
# (the dash, blank, or a non-duration value like "init").
function ConvertFrom-FormattedDuration {
    param([string] $Value)
    $match = [regex]::Match($Value, '^-?\d+(\.\d+)?')
    if (-not $match.Success) { return $null }
    $parsed = 0.0
    if ([double]::TryParse($match.Value, [Globalization.NumberStyles]::Float,
            $invariant, [ref] $parsed)) { $parsed } else { $null }
}

# Index of the variant with the lowest value for a property, parsed back from
# its formatted string. Ties keep the first (left-most) variant. Returns -1
# when no variant has a parseable value.
function Get-WinnerIndex {
    param([object[]] $Values, [string] $Property)

    $winner = -1
    $best = $null
    for ($i = 0; $i -lt $Values.Count; $i++) {
        $number = ConvertFrom-FormattedDuration ([string]$Values[$i].($Property))
        if ($null -eq $number) { continue }
        if ($null -eq $best -or $number -lt $best) {
            $best = $number
            $winner = $i
        }
    }
    $winner
}

$winnerIndex = Get-WinnerIndex $Present 'ColdTotalP50'

$generatedAt = [datetime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", $invariant)

$headerCells = (0..($Present.Count - 1) | ForEach-Object {
        $encoded = Protect-Html $Present[$_].Label
        if ($_ -eq $winnerIndex) { "<th class=`"winner`">$encoded</th>" }
        else { "<th>$encoded</th>" }
    }) -join "`n            "

$bodyRows = ($ColdMetric | ForEach-Object {
        $metric = $_
        $cells = (0..($Present.Count - 1) | ForEach-Object {
                $encoded = Protect-Html ([string]$Present[$_].($metric.Property))
                if ($_ -eq $winnerIndex) { "<td class=`"winner`">$encoded</td>" }
                else { "<td>$encoded</td>" }
            }) -join "`n                "
        "<tr>`n                <td>$(Protect-Html $metric.Label)</td>`n                $cells`n            </tr>"
    }) -join "`n            "

$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <title>Cold Start Benchmark Comparison</title>
    <style>
        :root {
            --dracula-bg: #282a36;
            --dracula-current-line: #44475a;
            --dracula-foreground: #f8f8f2;
            --dracula-comment: #6272a4;
            --dracula-purple: #bd93f9;
            --dracula-pink: #ff79c6;
            --dracula-green: #50fa7b;
            --dracula-cyan: #8be9fd;
        }

        body {
            background: var(--dracula-bg);
            color: var(--dracula-foreground);
            font-family: 'SF Mono', Menlo, Consolas, 'Courier New', monospace;
            padding: 2em;
            margin: 0;
            min-height: 100vh;
            display: flex;
            flex-direction: column;
            align-items: center;
            justify-content: center;
        }

        h1 {
            color: var(--dracula-pink);
        }

        p.generated {
            color: var(--dracula-comment);
            font-size: 0.9em;
            font-style: italic;
        }

        table {
            border-collapse: collapse;
            margin: 1.5em 0;
        }

        th,
        td {
            padding: 0.35em 0.7em;
            text-align: left;
        }

        th {
            color: var(--dracula-cyan);
            border-bottom: 2px solid var(--dracula-cyan);
        }

        tbody tr:nth-child(even) {
            background: var(--dracula-current-line);
        }

        td:first-child {
            color: var(--dracula-purple);
        }

        /* The winning variant's whole column - header and every row. */
        th.winner,
        td.winner {
            color: var(--dracula-green);
            font-weight: bold;
        }
    </style>
</head>
<body>
    <h1>Cold Start Benchmark Comparison</h1>
    <p class="generated">Generated $generatedAt</p>
    <table>
        <thead>
            <tr>
                <th>Metric</th>
                $headerCells
            </tr>
        </thead>
        <tbody>
            $bodyRows
        </tbody>
    </table>
</body>
</html>
"@

$outputDir = Split-Path -Parent $OutputPath
if ($outputDir -and -not (Test-Path -LiteralPath $outputDir)) {
    [void](New-Item -ItemType Directory -Path $outputDir -Force)
}

Set-Content -LiteralPath $OutputPath -Value $html -Encoding utf8

(Resolve-Path -LiteralPath $OutputPath).Path
