#!/usr/bin/env pwsh
# Copyright © 2026 Amazon.com and Affiliates. Licensed under MIT-0.

<#
.SYNOPSIS
    Parses Lambda REPORT log lines into objects.

.DESCRIPTION
    Returns one object per real REPORT line with InitMs, RestoreMs, DurationMs,
    MaxMemoryMb, ColdMs and IsCold.

    Two things this gets right that a naive parser does not.

    Field names are matched explicitly rather than positionally. REPORT fields
    are not in a fixed order - on a SnapStart line Restore Duration comes before
    plain Duration - and four of them end in "Duration": Duration, Billed
    Duration, Init Duration, Restore Duration, Billed Restore Duration. Taking
    the first "Duration:" match therefore reads the restore time as the
    invocation time. Every variant has to appear in the pattern even though only
    four are returned, or an unmatched one falls through and overwrites the
    plain Duration.

    Only lines beginning with REPORT are parsed. A CloudWatch filter pattern of
    "REPORT" also matches INIT_REPORT and RESTORE_REPORT, which carry different
    fields and would otherwise be counted as invocations.

    Cold is Init Duration for a managed cold start or Restore Duration for a
    SnapStart restore. A line carries one or the other, never both, so ColdMs
    collapses them into a single comparable number.

.EXAMPLE
    $rows = ./bench/internal/ConvertFrom-LambdaReport.ps1 $events.message
    $rows | Where-Object IsCold | Measure-Object ColdMs -Average
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [AllowEmptyCollection()]
    [AllowEmptyString()]
    [string[]] $Message
)

$ErrorActionPreference = 'Stop'

# Longest alternatives first: the engine takes the first that matches at a
# position, so "Duration" must come after every prefixed form.
$fieldPattern = [regex]::new(
    '(Post Runtime Extensions Duration|Billed Restore Duration|Restore Duration' +
    '|Billed Duration|Init Duration|Duration|Max Memory Used|Memory Size)' +
    ':\s*([\d.]+)\s*(?:ms|MB)')

foreach ($line in $Message) {
    if (-not $line) { continue }
    $text = $line.Trim()
    if ($text -notmatch '^REPORT\b') { continue }

    $fields = @{}
    foreach ($match in $fieldPattern.Matches($text)) {
        $fields[$match.Groups[1].Value.Trim()] = $match.Groups[2].Value
    }

    $init = [double]($fields['Init Duration'] ?? 0)
    $restore = [double]($fields['Restore Duration'] ?? 0)

    [pscustomobject]@{
        InitMs      = $init
        RestoreMs   = $restore
        DurationMs  = [double]($fields['Duration'] ?? 0)
        MaxMemoryMb = [double]($fields['Max Memory Used'] ?? 0)
        ColdMs      = $init + $restore
        IsCold      = ($init -gt 0 -or $restore -gt 0)
    }
}
