#!/usr/bin/env pwsh
# Copyright © 2026 Amazon.com and Affiliates. Licensed under MIT-0.

<#
.SYNOPSIS
    POSTs the standard order payload N times and returns one result per request.

.DESCRIPTION
    Internal helper. Callers are Send-OrderRequest.ps1, Measure-ColdStart.ps1
    and Measure-ColdWarmRatio.ps1; it takes an -ApiUrl rather than a -Variant
    so it never has to resolve a stack itself.

    Dispatches every request in a wave before awaiting any of it, so they are
    genuinely in flight together. That is the whole point: a Lambda execution
    environment serves one request at a time, so only overlapping requests force
    new environments. Anything that dispatches slower than the handler completes
    (~10 ms warm here) sees the same environment reused and produces almost no
    cold starts.

    -Concurrency 0 means one wave of -Count, which maximises cold starts.
    A lower value sends later waves into environments the earlier ones already
    warmed, which is what you want when measuring natural reuse instead.

    Returns objects with Ok, Status, OrderId and Error. Aggregation is left to
    the caller.

.EXAMPLE
    $results = ./bench/internal/Invoke-OrdersApi.ps1 -ApiUrl $stack.ApiUrl -Count 50
    @($results | Where-Object Ok).Count

.EXAMPLE
    ./bench/internal/Invoke-OrdersApi.ps1 -ApiUrl $stack.ApiUrl -Count 500 -Concurrency 10 -ShowProgress
    Natural-concurrency load rather than a cold-start burst.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $ApiUrl,
    [int] $Count = 1,
    [int] $Concurrency = 0,
    [int] $TimeoutSec = 90,
    [int] $ProgressEvery = 50,
    [switch] $ShowProgress
)

$ErrorActionPreference = 'Stop'

$uri = "$($ApiUrl.TrimEnd('/'))/orders"

# Built as a hashtable so PowerShell never has to escape JSON quotes.
$body = @{
    customerId = 'c-123'
    productId  = 'p-456'
    quantity   = 2
} | ConvertTo-Json -Compress

if ($Concurrency -le 0) { $Concurrency = $Count }

$client = [System.Net.Http.HttpClient]::new()
$client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)

try {
    $completed = 0
    $remaining = $Count

    while ($remaining -gt 0) {
        $wave = [Math]::Min($Concurrency, $remaining)
        $tasks = [System.Collections.Generic.List[object]]::new()

        for ($i = 0; $i -lt $wave; $i++) {
            $content = [System.Net.Http.StringContent]::new(
                $body, [System.Text.Encoding]::UTF8, 'application/json')
            $tasks.Add($client.PostAsync($uri, $content))
        }

        [System.Threading.Tasks.Task]::WaitAll($tasks.ToArray())

        foreach ($task in $tasks) {
            if ($task.IsFaulted) {
                [pscustomobject]@{
                    Ok      = $false
                    Status  = $null
                    OrderId = $null
                    Error   = $task.Exception.GetBaseException().Message
                }
                continue
            }

            $response = $task.Result
            $text = $response.Content.ReadAsStringAsync().Result

            if (-not $response.IsSuccessStatusCode) {
                [pscustomobject]@{
                    Ok      = $false
                    Status  = [int]$response.StatusCode
                    OrderId = $null
                    Error   = $text
                }
                continue
            }

            # A 200 with an unparseable body is still a failure worth seeing.
            $orderId = $null
            $parseError = $null
            try { $orderId = ($text | ConvertFrom-Json).OrderId }
            catch { $parseError = "unparseable body: $text" }

            [pscustomobject]@{
                Ok      = ($null -eq $parseError)
                Status  = [int]$response.StatusCode
                OrderId = $orderId
                Error   = $parseError
            }
        }

        $completed += $wave
        $remaining -= $wave

        if ($ShowProgress -and $ProgressEvery -gt 0 -and
            ($completed % $ProgressEvery -eq 0 -or $remaining -eq 0)) {
            Write-Host "  $completed/$Count complete"
        }
    }
}
finally {
    $client.Dispose()
}
