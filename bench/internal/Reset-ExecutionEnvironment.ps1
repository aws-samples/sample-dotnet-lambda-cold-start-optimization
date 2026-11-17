#!/usr/bin/env pwsh
# Copyright © 2026 Amazon.com and Affiliates. Licensed under MIT-0.

<#
.SYNOPSIS
    Forces the next invocation of a variant to be a genuine cold start.

.DESCRIPTION
    Two different mechanisms, chosen from the function's actual SnapStart
    configuration rather than guessed from the variant name.

    SnapStart off - bump a benign environment variable on $LATEST. Any
    configuration change discards existing execution environments, so the next
    invoke has to initialise.

    SnapStart on - bumping $LATEST forces nothing, because the API Gateway
    integration targets the alias, which serves an immutable published version.
    Instead: update $LATEST, publish a new version (which creates a fresh
    snapshot), then move the alias onto it. The next invoke is then a RESTORE.

    The seed variable is merged into the existing environment map, never
    substituted for it. Passing --environment replaces the whole map, so a naive
    bump silently drops ORDERS_TABLE_NAME and every POWERTOOLS_* variable, and
    the function starts failing in a way that looks like a cold-start problem.

    Credentials come from the standard AWS chain. Set AWS_PROFILE, or pass
    -ProfileName to override.

.EXAMPLE
    ./bench/internal/Reset-ExecutionEnvironment.ps1 01-managed
    Next invoke reports Init Duration. -Variant is positional and tab-completable.

.EXAMPLE
    ./bench/internal/Reset-ExecutionEnvironment.ps1 02-snapstart-primed
    Publishes a version and moves the alias. Next invoke reports Restore
    Duration. Note that one publish creates a billed snapshot in each of several
    Availability Zones, and runs any before-snapshot hook once in each.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('01-managed', '02-snapstart', '02-snapstart-primed',
        '03-native-aot', '03-native-aot-ready', '03-native-aot-single-purpose')]
    [string] $Variant,
    [string] $Region,
    [string] $ProfileName
)

$ErrorActionPreference = 'Stop'

$stack = & "$PSScriptRoot/Get-StackOutput.ps1" `
    -Variant $Variant -Region $Region -ProfileName $ProfileName

$awsCommon = @('--region', $stack.Region,
    '--function-name', $stack.FunctionName) + $stack.ProfileArgs

# --- Merge COLD_START_SEED into the existing environment --------------------

$envJson = (& aws lambda get-function-configuration @awsCommon `
        --query 'Environment.Variables' --output json | Out-String)

$variables = @{}
$existing = if ($envJson.Trim()) { $envJson | ConvertFrom-Json } else { $null }
if ($existing) {
    foreach ($property in $existing.PSObject.Properties) {
        $variables[$property.Name] = $property.Value
    }
}

$preserved = $variables.Count
$variables['COLD_START_SEED'] = [string][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

Write-Host "Bumping COLD_START_SEED=$($variables['COLD_START_SEED']) on $($stack.FunctionName)"
Write-Host "  ($preserved existing variables preserved)"

# Written to a file rather than passed inline: --environment takes a JSON
# structure, and round-tripping embedded quotes through a native command is
# fragile across PowerShell versions.
$payloadFile = New-TemporaryFile
try {
    @{ Variables = $variables } | ConvertTo-Json -Depth 5 -Compress |
        Set-Content -Path $payloadFile -Encoding utf8

    & aws lambda update-function-configuration @awsCommon `
        --environment "file://$($payloadFile.FullName)" `
        --query 'LastUpdateStatus' --output text | Out-String | ForEach-Object { $_.Trim() }

    Write-Host 'Waiting for the configuration update to settle...'
    & aws lambda wait function-updated @awsCommon
}
finally {
    Remove-Item $payloadFile -Force -ErrorAction SilentlyContinue
}

# --- SnapStart: publish a new version and move the alias -------------------

$applyOn = (& aws lambda get-function-configuration @awsCommon `
        --query 'SnapStart.ApplyOn' --output text | Out-String).Trim()

if ($applyOn -ne 'PublishedVersions') {
    Write-Host 'Done. Next invocation will be a cold start (expect Init Duration).'
    return [pscustomobject]@{
        Variant = $Variant; Mode = 'Init'; Version = $null; Alias = $null
    }
}

$alias = (& aws lambda list-aliases @awsCommon `
        --query 'Aliases[0].Name' --output text | Out-String).Trim()

if (-not $alias -or $alias -eq 'None') {
    throw @"
SnapStart is on but the function has no alias. The API would be invoking
`$LATEST, which never gets SnapStart. Check that the template sets
AutoPublishAlias.
"@
}

Write-Host 'SnapStart is on. Publishing a new version (one snapshot per AZ)...'
$version = (& aws lambda publish-version @awsCommon `
        --query 'Version' --output text | Out-String).Trim()

Write-Host "Waiting for version $version to become Active (snapshot creation)..."
& aws lambda wait published-version-active @awsCommon --qualifier $version

Write-Host "Pointing alias '$alias' at version $version..."
& aws lambda update-alias @awsCommon `
    --name $alias --function-version $version `
    --query 'FunctionVersion' --output text | Out-String | ForEach-Object { $_.Trim() }

Write-Host 'Done. Next invocation will be a SnapStart RESTORE (expect Restore'
Write-Host "Duration on the REPORT line, and no Init Duration)."

[pscustomobject]@{
    Variant = $Variant; Mode = 'Restore'; Version = $version; Alias = $alias
}
