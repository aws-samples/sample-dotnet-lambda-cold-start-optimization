#!/usr/bin/env pwsh
# Copyright © 2026 Amazon.com and Affiliates. Licensed under MIT-0.

<#
.SYNOPSIS
    Deletes the CloudFormation stacks created by Deploy-OrdersApi.ps1.

.DESCRIPTION
    DESTRUCTIVE. Deletes each variant's stack and everything in it - the Lambda
    function, API Gateway, and the DynamoDB Orders table including any data.
    This cannot be undone.

    Because it is destructive it prompts before acting. Use -WhatIf to see
    exactly which stacks would go without touching anything, and -Confirm:$false
    to skip the prompt in a script.

    Stack names are read from each variant's committed samconfig.toml - the same
    source Deploy-OrdersApi.ps1 uses - so this only ever targets stacks that
    script created. Variants whose stack does not exist are skipped.

.EXAMPLE
    ./Remove-OrdersApi.ps1 -WhatIf
    Show what would be deleted. Safe, makes no changes.

.EXAMPLE
    ./Remove-OrdersApi.ps1
    All six - three chapters and three reference variants - with a
    confirmation prompt per stack.

.EXAMPLE
    ./Remove-OrdersApi.ps1 01-managed -Confirm:$false
    One stack, no prompt.

.EXAMPLE
    ./Remove-OrdersApi.ps1 -NoWait
    Issue the deletes and return without waiting for DELETE_COMPLETE.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Position = 0)]
    [ValidateSet('01-managed', '02-snapstart', '02-snapstart-primed',
        '03-native-aot', '03-native-aot-ready', '03-native-aot-single-purpose')]
    [string[]] $Variant,
    [switch]   $NoWait,
    [string]   $Region,
    [string]   $ProfileName
)

$ErrorActionPreference = 'Stop'

# A stack that does not exist is a normal outcome here, detected from the exit
# code. Pinned so a non-zero aws exit cannot turn "already gone" into a crash.
$PSNativeCommandUseErrorActionPreference = $false

if (-not $Variant) {
    $Variant = @('01-managed', '02-snapstart', '02-snapstart-primed',
        '03-native-aot', '03-native-aot-ready', '03-native-aot-single-purpose')
}

$profileArgs = if ($ProfileName) { @('--profile', $ProfileName) } else { @() }

# Validate every name and keep only the stacks that actually exist.
$targets = foreach ($name in $Variant) {
    $config = & "$PSScriptRoot/bench/internal/Get-VariantConfig.ps1" -Variant $name -Region $Region

    # 2>&1 so the CLI's message can be inspected. Exit code alone cannot tell
    # "stack does not exist" from "your token expired" - both are 254 - and
    # treating the second as the first would report a live stack as already
    # gone, which reads as "cleanup already happened".
    $probe = (& aws cloudformation describe-stacks `
            --region $config.Region --stack-name $config.StackName `
            --output json @profileArgs 2>&1 | Out-String)

    if ($LASTEXITCODE -ne 0) {
        if ($probe -match 'does not exist') {
            Write-Host "SKIP: $name - stack '$($config.StackName)' not found in $($config.Region)."
            continue
        }
        throw @"
Could not check stack '$($config.StackName)' in $($config.Region) (exit $LASTEXITCODE).
Refusing to continue, because a failure here is indistinguishable from the stack
being absent. If the message below mentions an expired token, run: aws sso login

$($probe.Trim())
"@
    }
    $config
}

$targets = @($targets)
if ($targets.Count -eq 0) {
    Write-Host 'No matching stacks to delete.'
    return
}

Write-Host ''
Write-Host 'The following stacks will be DELETED, including their DynamoDB tables'
Write-Host 'and any data in them:'
foreach ($target in $targets) {
    Write-Host "  - $($target.StackName)   ($($target.Variant), $($target.Region))"
}
Write-Host ''

$deleted = foreach ($target in $targets) {
    $description = "$($target.StackName) in $($target.Region)"
    if (-not $PSCmdlet.ShouldProcess($description, 'Delete CloudFormation stack')) {
        continue
    }

    Write-Host ">> deleting $($target.StackName)..."
    & aws cloudformation delete-stack `
        --region $target.Region --stack-name $target.StackName @profileArgs
    if ($LASTEXITCODE -ne 0) {
        throw "delete-stack failed for $($target.StackName) (exit $LASTEXITCODE)."
    }
    $target
}

$deleted = @($deleted)
if ($deleted.Count -eq 0) {
    Write-Host 'Nothing was deleted.'
    return
}

if ($NoWait) {
    Write-Host ''
    Write-Host "$($deleted.Count) delete(s) issued. Not waiting for completion."
    return
}

Write-Host ''
Write-Host 'Waiting for deletions to complete...'
foreach ($target in $deleted) {
    Write-Host ">> waiting on $($target.StackName)..."
    & aws cloudformation wait stack-delete-complete `
        --region $target.Region --stack-name $target.StackName @profileArgs

    if ($LASTEXITCODE -eq 0) {
        Write-Host "   $($target.StackName) deleted."
    }
    else {
        Write-Warning "$($target.StackName) did not reach DELETE_COMPLETE - check the CloudFormation console."
    }
}

Write-Host ''
Write-Host 'Cleanup finished.'
