param(
    [string]$ConfigPath
)

. (Join-Path $PSScriptRoot '_Common.ps1')
$config = Get-LabConfig -ConfigPath $ConfigPath
$repoRoot = Get-RepoRoot

Assert-Tools -Tools @('kubectl')

$agentNs = $config.Namespaces.AgentGateway
$gatewayName = $config.Routing.AgentGatewayGatewayName
$primary = $config.Models.Primary
$hasSecondary = $config.Models.ContainsKey('Secondary') -and
    $null -ne $config.Models.Secondary -and
    $config.Models.Secondary.ContainsKey('Name') -and
    -not [string]::IsNullOrWhiteSpace($config.Models.Secondary.Name)
$secondary = if ($hasSecondary) { $config.Models.Secondary } else { $null }
$port = [int]$config.Test.PortForwardPort

$results = [ordered]@{
    timestamp = (Get-Date).ToString('o')
    checks = @()
}

Write-Step 'Collecting routing inventory for compatibility spike'
$mdList = kubectl get modeldeployments -A -o json | ConvertFrom-Json
$poolList = kubectl get inferencepools -A -o json | ConvertFrom-Json
$routeList = kubectl get httproutes -A -o json | ConvertFrom-Json

$results.checks += @{
    name = 'inventory'
    modeldeployments = $mdList.items.Count
    inferencepools = $poolList.items.Count
    httproutes = $routeList.items.Count
}

Write-Step "Starting AgentGateway port-forward on localhost:$port"
$pf = Start-Process -FilePath 'kubectl' -ArgumentList "port-forward -n $agentNs svc/$gatewayName $port`:80" -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 5

try {
    $primaryProbeModel = kubectl get modeldeployment $primary.Name -n $primary.Namespace -o jsonpath='{.status.gateway.modelName}'
    if ([string]::IsNullOrWhiteSpace($primaryProbeModel)) {
        $primaryProbeModel = $primary.Id
    }
    $probeModels = @($primaryProbeModel)
    if ($hasSecondary) {
        $secondaryProbeModel = kubectl get modeldeployment $secondary.Name -n $secondary.Namespace -o jsonpath='{.status.gateway.modelName}' 2>$null
        if ([string]::IsNullOrWhiteSpace($secondaryProbeModel)) {
            $secondaryProbeModel = $secondary.Id
        }
        $probeModels += $secondaryProbeModel
    }
    $probeOutcomes = @()
    foreach ($modelId in $probeModels) {
        $payload = @{
            model = $modelId
            messages = @(
                @{
                    role = 'user'
                    content = 'Return a short response.'
                }
            )
            temperature = [double]$config.Test.Temperature
            max_tokens = [int]$config.Test.MaxTokens
        } | ConvertTo-Json -Depth 8

        try {
            $resp = Invoke-RestMethod -Method Post -Uri "http://localhost:$port/v1/chat/completions" -ContentType 'application/json' -Body $payload
            $probeOutcomes += @{
                requestedModel = $modelId
                success = $true
                returnedModel = $resp.model
            }
        }
        catch {
            $probeOutcomes += @{
                requestedModel = $modelId
                success = $false
                error = $_.Exception.Message
            }
        }
    }

    $results.checks += @{
        name = 'agentgateway-cross-model-probe'
        outcomes = $probeOutcomes
    }
}
finally {
    if ($pf -and -not $pf.HasExited) {
        Stop-Process -Id $pf.Id -Force
    }
}

$adapterLikelyNeeded = $true
$externalConfigSufficient = $false
$summaryNote = 'Cross-model compatibility was not evaluated because only one model is configured.'

if ($hasSecondary) {
    $adapterLikelyNeeded = $false
    $externalConfigSufficient = $true
    $summaryNote = 'Observed model-dependent routing behavior across tested models.'
    $probe = $results.checks | Where-Object { $_.name -eq 'agentgateway-cross-model-probe' }
    if ($probe) {
        $distinctReturned = @($probe.outcomes | Where-Object { $_.success } | Select-Object -ExpandProperty returnedModel -Unique)
        if ($distinctReturned.Count -lt 2) {
            $adapterLikelyNeeded = $true
            $externalConfigSufficient = $false
            $summaryNote = 'AgentGateway route currently behaves as single fixed backend for tested models.'
        }
    }
}

$results.summary = @{
    externalConfigSufficient = $externalConfigSufficient
    adapterLikelyNeeded = $adapterLikelyNeeded
    note = $summaryNote
}

$outFile = Join-Path $repoRoot 'tests\compatibility-spike-results.json'
$results | ConvertTo-Json -Depth 12 | Set-Content -Path $outFile
Write-Step "Spike results written to $outFile"

Write-Host ($results.summary | ConvertTo-Json -Depth 5)
