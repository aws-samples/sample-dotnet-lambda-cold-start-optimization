#!/usr/bin/env pwsh
# Copyright © 2026 Amazon.com and Affiliates. Licensed under MIT-0.

<#
.SYNOPSIS
    Starts AWS Lambda Power Tuning executions for the Orders API variants.

.DESCRIPTION
    Finds the best price/performance memory setting for each variant by running
    the Lambda Power Tuning state machine against it.

    Resolves the state machine ARN from the StateMachineARN output of the
    -PowerTuningStack stack, and each variant's Lambda ARN from the
    OrdersFunctionArn output of its own stack. Variants whose stack is not
    deployed are skipped with a warning, so you can run whichever exist today.

    Stack names come from each variant's committed samconfig.toml, the same
    source Deploy-OrdersApi.ps1 uses. The state machine is looked up in the same
    region as the variant it is being run against.

    Starts executions and returns immediately - it does not wait. Each returned
    object carries the ExecutionArn.

    Credentials come from the standard AWS chain. Set AWS_PROFILE, or pass
    -ProfileName to override.

.EXAMPLE
    ./bench/Start-PowerTuning.ps1
    Every deployed variant.

.EXAMPLE
    ./bench/Start-PowerTuning.ps1 01-managed, 03-native-aot-ready
    A subset. -Variant is positional and tab-completable.

.EXAMPLE
    ./bench/Start-PowerTuning.ps1 03-native-aot-ready -PowerValues 512, 1024, 2048 -Num 20
    A narrower memory sweep with more invocations per value.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('01-managed', '02-snapstart', '02-snapstart-primed',
        '03-native-aot', '03-native-aot-ready', '03-native-aot-single-purpose')]
    [string[]] $Variant,
    [string]   $PowerTuningStack = 'lambda-power-tuning',
    [int[]]    $PowerValues = @(128, 256, 512, 1024, 2048, 3008, 4096, 6000, 8182),
    [int]      $Num = 10,
    [ValidateSet('cost', 'speed', 'balanced')]
    [string]   $Strategy = 'speed',
    [switch]   $OnlyColdStarts,
    [string]   $Region,
    [string]   $ProfileName
)

$ErrorActionPreference = 'Stop'

# A missing variant stack is a normal outcome here, handled by inspecting
# $LASTEXITCODE rather than by catching. Pinned because if this preference is
# on, a non-zero aws exit throws instead, turning "not deployed" into a crash.
$PSNativeCommandUseErrorActionPreference = $false

if (-not $Variant) {
    $Variant = @('01-managed', '02-snapstart', '02-snapstart-primed',
        '03-native-aot', '03-native-aot-ready', '03-native-aot-single-purpose')
}

# Default matches the bash script this replaces: cold starts are what the talk
# is about, so tune for them unless told otherwise.
if (-not $PSBoundParameters.ContainsKey('OnlyColdStarts')) { $OnlyColdStarts = $true }

$profileArgs = if ($ProfileName) { @('--profile', $ProfileName) } else { @() }

function Get-StackOutputValue {
    param([string] $Stack, [string] $Key, [string] $InRegion)

    # A missing stack is an expected outcome here - return empty and let the
    # caller skip. Anything else must surface: exit code alone cannot tell
    # "stack does not exist" from "your token expired", and silently treating
    # the second as the first would report every variant as not deployed.
    $output = (& aws cloudformation describe-stacks `
            --region $InRegion --stack-name $Stack `
            --query "Stacks[0].Outputs[?OutputKey=='$Key'].OutputValue" `
            --output text @profileArgs 2>&1 | Out-String)

    if ($LASTEXITCODE -ne 0) {
        if ($output -match 'does not exist') { return '' }
        throw @"
aws describe-stacks failed for '$Stack' in $InRegion (exit $LASTEXITCODE).
If the message below mentions an expired token, run: aws sso login

$($output.Trim())
"@
    }

    $value = $output.Trim()
    if ($value -eq 'None') { return '' }
    $value
}

# One lookup per region, not per variant.
$stateMachineByRegion = @{}
function Get-StateMachineArn {
    param([string] $InRegion)

    if (-not $stateMachineByRegion.ContainsKey($InRegion)) {
        $arn = Get-StackOutputValue -Stack $PowerTuningStack `
            -Key 'StateMachineARN' -InRegion $InRegion
        if (-not $arn) {
            throw @"
Could not resolve StateMachineARN from stack '$PowerTuningStack' in $InRegion.
Is the Lambda Power Tuning application deployed there? See
https://github.com/alexcasalboni/aws-lambda-power-tuning
"@
        }
        $stateMachineByRegion[$InRegion] = $arn
        Write-Host "Power Tuning state machine ($InRegion): $arn"
        Write-Host ''
    }
    $stateMachineByRegion[$InRegion]
}

# The event the harness sends on each invocation, as a JSON *string* in the
# API Gateway proxy shape. ConvertTo-Json escapes it into the input below,
# which is what the bash version needed jq for.
$eventPayload = @{
    httpMethod      = 'POST'
    path            = '/orders'
    headers         = @{ 'Content-Type' = 'application/json' }
    body            = (@{
            customerId = 'c-123'
            productId  = 'p-456'
            quantity   = 2
        } | ConvertTo-Json -Compress)
    isBase64Encoded = $false
} | ConvertTo-Json -Compress -Depth 5

$started = 0
foreach ($name in $Variant) {
    $config = & "$PSScriptRoot/internal/Get-VariantConfig.ps1" -Variant $name -Region $Region

    $lambdaArn = Get-StackOutputValue -Stack $config.StackName `
        -Key 'OrdersFunctionArn' -InRegion $config.Region

    Write-Host "=== $name ==="
    if (-not $lambdaArn) {
        Write-Host "  SKIP: stack '$($config.StackName)' not deployed (no OrdersFunctionArn output)."
        Write-Host "        Deploy it with ./Deploy-OrdersApi.ps1 $name"
        Write-Host ''
        continue
    }

    $stateMachineArn = Get-StateMachineArn -InRegion $config.Region

    Write-Host "  Stack:  $($config.StackName)"
    Write-Host "  Lambda: $lambdaArn"

    # Not named $input: that is a PowerShell automatic variable holding the
    # pipeline enumerator, and assigning to it is a silent footgun.
    $executionInput = @{
        lambdaARN          = $lambdaArn
        powerValues        = $PowerValues
        num                = $Num
        onlyColdStarts     = [bool]$OnlyColdStarts
        payload            = $eventPayload
        parallelInvocation = $true
        strategy           = $Strategy
    } | ConvertTo-Json -Compress -Depth 5

    $executionName = "power-tuning-$name-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

    $payloadFile = New-TemporaryFile
    try {
        Set-Content -Path $payloadFile -Value $executionInput -Encoding utf8

        $executionArn = (& aws stepfunctions start-execution `
                --region $config.Region `
                --state-machine-arn $stateMachineArn `
                --name $executionName `
                --input "file://$($payloadFile.FullName)" `
                --query 'executionArn' --output text @profileArgs | Out-String).Trim()

        if ($LASTEXITCODE -ne 0 -or -not $executionArn) {
            throw "start-execution failed for $name (exit $LASTEXITCODE). See the error above."
        }
    }
    finally {
        Remove-Item $payloadFile -Force -ErrorAction SilentlyContinue
    }

    Write-Host "  Started: $executionArn"
    Write-Host ''
    $started++

    [pscustomobject]@{
        Variant      = $name
        StackName    = $config.StackName
        Region       = $config.Region
        LambdaArn    = $lambdaArn
        ExecutionArn = $executionArn
    }
}

if ($started -eq 0) {
    throw 'No executions started - none of the requested variants were deployed.'
}

$anyRegion = $stateMachineByRegion.Keys | Select-Object -First 1
Write-Host "$started execution(s) started. Watch progress in the Step Functions console:"
Write-Host "  https://$anyRegion.console.aws.amazon.com/states/home?region=$anyRegion#/statemachines"
Write-Host ''
Write-Host 'Fetch a result once complete with:'
Write-Host "  aws stepfunctions describe-execution --region $anyRegion --execution-arn <arn> --query output --output text"
