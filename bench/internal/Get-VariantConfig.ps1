#!/usr/bin/env pwsh
# Copyright © 2026 Amazon.com and Affiliates. Licensed under MIT-0.

<#
.SYNOPSIS
    Reads a variant's stack name and region out of its samconfig.toml.

.DESCRIPTION
    samconfig.toml is committed and is the single source of truth for stack
    names, so every script derives the name from it rather than hardcoding a
    prefix. Edit stack_name there and the deploy, cleanup, power-tuning and
    bench scripts all follow, exactly as a bare `sam deploy` from the variant
    directory does.

    Makes no AWS calls. That matters for Deploy-OrdersApi.ps1 and
    Remove-OrdersApi.ps1, which need the stack name before (or after) the stack
    exists. Use Get-StackOutput.ps1 instead when you need deployed resources.

.EXAMPLE
    $config = ./bench/internal/Get-VariantConfig.ps1 01-managed
    $config.StackName
    -Variant is positional and tab-completable.

.EXAMPLE
    ./bench/internal/Get-VariantConfig.ps1 02-snapstart-primed -Region eu-west-1
    An explicit -Region wins over the one in samconfig.toml.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('01-managed', '02-snapstart', '02-snapstart-primed',
        '03-native-aot', '03-native-aot-ready', '03-native-aot-single-purpose')]
    [string] $Variant,
    [string] $Region
)

$ErrorActionPreference = 'Stop'

# The chapters live at the repo root, two levels up from bench/internal;
# their finished states live under reference/. The variant NAME stays flat
# either way, so -Variant tab-completes without a slash in it and this is the
# one place that knows about the extra directory level.
$repoRoot = (Resolve-Path -LiteralPath "$PSScriptRoot/../..").Path
$variantDir = Join-Path $repoRoot $Variant
if (-not (Test-Path -LiteralPath $variantDir)) {
    $variantDir = Join-Path $repoRoot "reference/$Variant"
}
$configPath = Join-Path $variantDir 'samconfig.toml'

if (-not (Test-Path -LiteralPath $configPath)) {
    throw @"
$configPath is missing. That file is committed to this repo and holds the stack
name - restore it rather than passing --stack-name by hand.
"@
}

# Deliberately a regex rather than a TOML parser: one key, one shape, and a
# dependency-free read keeps these scripts runnable on a clean machine.
function Read-TomlString([string] $Key) {
    $match = Select-String -LiteralPath $configPath `
        -Pattern "^\s*$Key\s*=\s*`"([^`"]+)`"" | Select-Object -First 1
    if ($match) { $match.Matches[0].Groups[1].Value } else { $null }
}

$stackName = Read-TomlString 'stack_name'
if (-not $stackName) {
    throw "Could not read stack_name from $configPath."
}

if (-not $Region) { $Region = Read-TomlString 'region' }
if (-not $Region) { $Region = 'us-east-1' }

[pscustomobject]@{
    Variant    = $Variant
    Directory  = $variantDir
    ConfigPath = $configPath
    StackName  = $stackName
    Region     = $Region
}
