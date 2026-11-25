#!/usr/bin/env pwsh
# Copyright © 2026 Amazon.com and Affiliates. Licensed under MIT-0.

<#
.SYNOPSIS
    Builds and deploys the Orders API variants, each to its own stack.

.DESCRIPTION
    Variants, in talk order. The chapters sit at the repo root; each
    chapter's finished state sits under reference/ with the same number:
      01-managed             managed runtime, the baseline
      02-snapstart           copy of 01-managed; add SnapStart, then priming
      02-snapstart-primed    reference/ - SnapStart plus priming hooks
      03-native-aot          copy of 01-managed; add PublishAot, then the fixes
      03-native-aot-ready    reference/ - PublishAot with the fixes, warning-free
      03-native-aot-single-purpose
                             reference/ - no ASP.NET Core, no Powertools

    Stack names come from each variant's committed samconfig.toml. That file is
    the single source of truth: change a stack name there and this script, the
    cleanup script, the bench harness and a bare `sam deploy` all follow.

    Plain `sam build` for every variant, including the two AOT ones. Do not add
    --use-container: it mounts only the CodeUri directory, so the ProjectReference
    up to 00-shared escapes the mount and the build fails on CS0246 for the
    OrdersApi namespace. Building on the host keeps the whole repo visible, and
    Amazon.Lambda.Tools arranges a Linux AOT build itself when the host needs one.

    Every requested variant is validated before anything is built, so a typo
    cannot leave the set half-deployed.

    POST /orders accepts requests only from -AllowedCidr; GET /health stays
    open. Omit it and the script uses your current public IPv4 address as a
    /32, looked up from https://checkip.amazonaws.com. The CIDR is resolved
    once, before the first build, and passed to every stack. If the lookup
    fails the script stops - it never falls back to an open range. Redeploy
    whenever your public IP changes (a new network, a VPN); the new range
    takes about a minute to take effect.

    No `aws lambda publish-version` here. A SnapStart variant sets
    AutoPublishAlias, so SAM publishes a version and moves the alias on every
    deploy. Publishing again by hand would create an orphan version the alias
    does not point at, and trigger another round of billed snapshot creation -
    one per AZ, not one total. To force a fresh restore for benchmarking, use
    bench/internal/Reset-ExecutionEnvironment.ps1.

.EXAMPLE
    ./Deploy-OrdersApi.ps1
    Every variant: the chapters and the reference variants.

.EXAMPLE
    ./Deploy-OrdersApi.ps1 01-managed, 02-snapstart-primed
    A subset. -Variant is positional and tab-completable.

.EXAMPLE
    ./Deploy-OrdersApi.ps1 03-native-aot-ready
    One AOT variant. Same plain `sam build` as the rest.

.EXAMPLE
    ./Deploy-OrdersApi.ps1 01-managed -AllowedCidr 1.2.3.4/32
    Allow a specific address or range to POST /orders instead of just your own.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('01-managed', '02-snapstart', '02-snapstart-primed',
        '03-native-aot', '03-native-aot-ready', '03-native-aot-single-purpose')]
    [string[]] $Variant,
    [string]   $Region,
    [ValidatePattern('^(\d{1,3}\.){3}\d{1,3}/\d{1,2}$')]
    [string]   $AllowedCidr
)

$ErrorActionPreference = 'Stop'

if (-not $Variant) {
    $Variant = @('01-managed', '02-snapstart', '02-snapstart-primed',
        '03-native-aot', '03-native-aot-ready', '03-native-aot-single-purpose')
}

# Resolve and validate everything up front. A missing template or samconfig
# should stop the run before the first build, not midway through the set.
$targets = foreach ($name in $Variant) {
    $config = & "$PSScriptRoot/bench/internal/Get-VariantConfig.ps1" -Variant $name -Region $Region

    $template = Join-Path $config.Directory 'template.yaml'
    if (-not (Test-Path -LiteralPath $template)) {
        throw "No template.yaml under '$($config.Directory)'."
    }

    $config
}

# Resolved once, so every stack in the run gets the same range. No fallback:
# a failed lookup stops the run rather than deploying an open API.
if ($AllowedCidr) {
    Write-Host ">> POST /orders allowed from $AllowedCidr"
}
else {
    $publicIp = (Invoke-RestMethod -Uri 'https://checkip.amazonaws.com').Trim()
    if ($publicIp -notmatch '^(\d{1,3}\.){3}\d{1,3}$') {
        throw "checkip.amazonaws.com returned '$publicIp'. Pass -AllowedCidr."
    }
    $AllowedCidr = "$publicIp/32"
    Write-Host ">> POST /orders allowed from $AllowedCidr (detected)"
}

# obj/ carries absolute, host-specific NuGet paths. Restoring on Windows writes
# this into obj/<project>.nuget.g.props:
#
#   <NuGetPackageFolders>C:\Users\you\.nuget\packages\;
#     C:\Program Files (x86)\Microsoft Visual Studio\Shared\NuGetPackages</...>
#
# An AOT build runs in a Linux container with the whole repo mounted, so it
# imports that file, builds a FallbackPackagePathResolver from it, and dies on
# "Unable to find fallback package folder" - reported against 00-shared, because
# a host build of a managed variant earlier in the same run left Windows paths
# there.
# Deleting obj/ and bin/ first forces a restore in whichever environment is about
# to build. It costs a full restore per project and buys determinism, which is
# the right trade the day before a talk.
$sharedProject = Join-Path $PSScriptRoot '00-shared/src/OrdersLib'

function Clear-BuildArtifact {
    param([Parameter(Mandatory)] [string] $ProjectDirectory)

    foreach ($dir in 'obj', 'bin') {
        $path = Join-Path $ProjectDirectory $dir
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Recurse -Force
        }
    }
}

foreach ($target in $targets) {
    Write-Host '=================================================================='
    Write-Host "  $($target.Variant)  ->  $($target.StackName)"
    Write-Host '=================================================================='

    Write-Host '>> clearing obj/ and bin/ (host-specific NuGet paths)'
    Clear-BuildArtifact -ProjectDirectory $sharedProject
    Clear-BuildArtifact -ProjectDirectory (Join-Path $target.Directory 'src/OrdersApi')

    # Push-Location rather than a subshell: sam picks up ./template.yaml and
    # ./samconfig.toml from the current directory, and each variant keeps its
    # own .aws-sam build output.
    Push-Location $target.Directory
    try {
        # No --use-container, for any variant. It mounts only CodeUri, which puts
        # the ProjectReference up to 00-shared outside the container and fails
        # the build. Amazon.Lambda.Tools handles a Linux AOT build on its own.
        Write-Host '>> sam build'
        & sam build
        if ($LASTEXITCODE -ne 0) {
            throw "sam build failed for $($target.Variant) (exit $LASTEXITCODE)."
        }

        # stack_name, s3_prefix, region and capabilities all come from
        # samconfig.toml. Only an explicit -Region overrides it.
        Write-Host '>> sam deploy'
        $deployArgs = @('--no-confirm-changeset', '--no-fail-on-empty-changeset',
            '--parameter-overrides', "AllowedCidr=$AllowedCidr")
        if ($Region) { $deployArgs += @('--region', $Region) }

        & sam deploy @deployArgs
        if ($LASTEXITCODE -ne 0) {
            throw "sam deploy failed for $($target.Variant) (exit $LASTEXITCODE)."
        }
    }
    finally {
        Pop-Location
    }

    Write-Host ">> $($target.Variant) done."
    Write-Host ''
}

Write-Host 'All requested variants deployed.'
Write-Host 'Measure them with:      ./bench/Measure-ColdStart.ps1 <variant> -Samples 30'
Write-Host 'Find the best memory:   ./bench/Start-PowerTuning.ps1'
