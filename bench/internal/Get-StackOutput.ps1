#!/usr/bin/env pwsh
# Copyright © 2026 Amazon.com and Affiliates. Licensed under MIT-0.

<#
.SYNOPSIS
    Resolves the stack name, function name and API URL for a variant.

.DESCRIPTION
    Every bench script takes a variant name, not a stack name. This resolves
    that name to the deployed resources so the other scripts don't each repeat
    the CloudFormation lookup.

    Returns an object rather than setting variables, because PowerShell has no
    equivalent of bash's `source`. Assign the result and read its properties.

    One describe-stacks call fetches all outputs at once.

    The stack name and region come from the variant's samconfig.toml via
    Get-VariantConfig.ps1, so they are never hardcoded here. An explicit
    -Region overrides the one in that file.

    Credentials come from the standard AWS chain. Set AWS_PROFILE, or pass
    -ProfileName to override.

.EXAMPLE
    $stack = ./bench/internal/Get-StackOutput.ps1 01-managed
    $stack.FunctionName
    Resolve one variant. -Variant is positional and tab-completable.

.EXAMPLE
    ./bench/internal/Get-StackOutput.ps1 03-native-aot-ready -Region eu-west-1
    Same, against a different region.
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

# Stack name and region come from the variant's committed samconfig.toml, so
# editing that file is enough to retarget every script.
$config = & "$PSScriptRoot/Get-VariantConfig.ps1" -Variant $Variant -Region $Region
$StackName = $config.StackName
$Region = $config.Region

# --profile is passed only when supplied. Otherwise the standard AWS
# credential chain applies: AWS_PROFILE, the default profile, or an
# active SSO session.
$awsProfileArgs = if ($ProfileName) { @('--profile', $ProfileName) } else { @() }

$stackJson = (& aws cloudformation describe-stacks `
        --stack-name $StackName --region $Region @awsProfileArgs `
        --query 'Stacks[0].Outputs' --output json | Out-String)

# The CLI's own error text has already gone to stderr. Don't restate it as a
# deployment problem - an expired SSO token fails here too, and guessing sends
# people off to check the wrong thing.
if ($LASTEXITCODE -ne 0) {
    throw "aws describe-stacks failed for '$StackName' in $Region (exit $LASTEXITCODE). See the error above; if it mentions an expired token, run: aws sso login"
}

if (-not $stackJson.Trim()) {
    throw "Stack '$StackName' exists in $Region but returned no outputs."
}

$outputs = @{}
foreach ($entry in ($stackJson | ConvertFrom-Json)) {
    $outputs[$entry.OutputKey] = $entry.OutputValue
}

foreach ($required in 'FunctionName', 'ApiUrl') {
    if (-not $outputs.ContainsKey($required) -or -not $outputs[$required]) {
        throw "Stack '$StackName' has no $required output."
    }
}

[pscustomobject]@{
    Variant      = $Variant
    Region       = $Region
    StackName    = $StackName
    FunctionName = $outputs['FunctionName']
    ApiUrl       = $outputs['ApiUrl'].TrimEnd('/')
    LogGroup     = "/aws/lambda/$($outputs['FunctionName'])"
    ProfileArgs  = $awsProfileArgs
}
