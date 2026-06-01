param(
    [string]$ConfigPath
)

. (Join-Path $PSScriptRoot '_Common.ps1')
$config = Get-LabConfig -ConfigPath $ConfigPath
$repoRoot = Get-RepoRoot

Assert-Tools -Tools @('kubectl')

$primary = $config.Models.Primary
$hasSecondary = $config.Models.ContainsKey('Secondary') -and
    $null -ne $config.Models.Secondary -and
    $config.Models.Secondary.ContainsKey('Name') -and
    -not [string]::IsNullOrWhiteSpace($config.Models.Secondary.Name)
$secondary = if ($hasSecondary) { $config.Models.Secondary } else { $null }
$gpu = $config.Aks.GpuPool
$gatewayNs = $config.Namespaces.GatewayComparison
$gatewayName = $config.Routing.ComparisonGatewayName
$port = [int]$config.Test.PortForwardPort
$agentGatewayNs = $config.Namespaces.AgentGateway
$agentGatewayName = $config.Routing.AgentGatewayGatewayName
$pf = $null

function Get-AvailableInferenceGpuCount {
    param([string]$LabelKey, [string]$LabelValue)

    $nodesJson = kubectl get nodes -l "$LabelKey=$LabelValue" -o json 2>$null
    if (-not $nodesJson) { return 0 }

    $nodes = $nodesJson | ConvertFrom-Json
    $total = 0
    foreach ($node in $nodes.items) {
        $gpu = $node.status.allocatable.'nvidia.com/gpu'
        if ($gpu -and [int]$gpu -gt 0) {
            $total += [int]$gpu
        }
    }
    return $total
}

$secondaryGpuCount = 0
if ($hasSecondary) {
   $secondaryGpuCount = [int]$secondary.GpuCount
}
$requiredGpu = [int]$primary.GpuCount + $secondaryGpuCount
$availableGpu = Get-AvailableInferenceGpuCount -LabelKey $gpu.LabelKey -LabelValue $gpu.LabelValue
$capacityLimited = $hasSecondary -and ($availableGpu -lt $requiredGpu)

if (-not $hasSecondary) {
   Write-Host 'Info: Secondary model is not configured; running qwen-only native gateway test.' -ForegroundColor Yellow
}
elseif ($capacityLimited) {
   Write-Host "Warning: Native GAIE dual-model test requires $requiredGpu GPU(s), but only $availableGpu allocatable GPU(s) are available in inference node pool. Running single-model comparison only." -ForegroundColor Yellow
}

if ($hasSecondary) {
   Write-Step "Ensuring secondary model namespace '$($secondary.Namespace)' exists"
   Invoke-Cli -Command "kubectl create namespace $($secondary.Namespace) --dry-run=client -o yaml | kubectl apply -f -"
}

if ($hasSecondary -and -not $capacityLimited) {
   Write-Step "Applying secondary ModelDeployment $($secondary.Name)"
   $secondaryTemplate = Join-Path $repoRoot 'manifests\airunway\modeldeployment-secondary.yaml'
   Apply-TemplateManifest -TemplatePath $secondaryTemplate -Tokens @{
        '__MODEL_NAME__' = $secondary.Name
        '__MODEL_NAMESPACE__' = $secondary.Namespace
        '__MODEL_ID__' = $secondary.Id
        '__PROVIDER_NAME__' = $secondary.Provider
        '__ENGINE_TYPE__' = $secondary.Engine
        '__GPU_COUNT__' = [string]$secondary.GpuCount
        '__GPU_LABEL_KEY__' = $gpu.LabelKey
        '__GPU_LABEL_VALUE__' = $gpu.LabelValue
    }
}

Write-Step 'Waiting for required model deployments to be Running'
Wait-ModelDeploymentRunning -Namespace $primary.Namespace -Name $primary.Name -TimeoutSeconds 2400
if ($hasSecondary -and -not $capacityLimited) {
    Wait-ModelDeploymentRunning -Namespace $secondary.Namespace -Name $secondary.Name -TimeoutSeconds 2400
}

Write-Step 'Inspecting AI Runway generated gateway resources'
Invoke-Cli -Command 'kubectl get inferencepools -A'
Invoke-Cli -Command 'kubectl get httproutes -A'

$gatewayNamespace = kubectl get modeldeployment $primary.Name -n $primary.Namespace -o jsonpath='{.status.gateway.gatewayNamespace}'
if ([string]::IsNullOrWhiteSpace($gatewayNamespace)) {
    $gatewayNamespace = $gatewayNs
}

$primaryModelName = kubectl get modeldeployment $primary.Name -n $primary.Namespace -o jsonpath='{.status.gateway.modelName}'
if ([string]::IsNullOrWhiteSpace($primaryModelName)) {
    $primaryModelName = $primary.Id
}

$secondaryModelName = $null
if ($hasSecondary -and -not $capacityLimited) {
    $secondaryModelName = $secondary.Id
    $resolvedSecondaryModelName = kubectl get modeldeployment $secondary.Name -n $secondary.Namespace -o jsonpath='{.status.gateway.modelName}'
    if (-not [string]::IsNullOrWhiteSpace($resolvedSecondaryModelName)) {
        $secondaryModelName = $resolvedSecondaryModelName
    }
}

if ($gatewayNamespace -eq $agentGatewayNs) {
    Write-Host "Warning: ModelDeployment routes are currently attached to '$agentGatewayNs/$agentGatewayName' instead of '$gatewayNs/$gatewayName'. Validating against the active gateway." -ForegroundColor Yellow
    Write-Step "Starting AgentGateway port-forward on localhost:$port"
    $pf = Start-Process -FilePath 'kubectl' -ArgumentList "port-forward -n $agentGatewayNs svc/$agentGatewayName $port`:80" -PassThru -WindowStyle Hidden
    $baseUri = "http://localhost:$port"
}
else {
    $gatewayAddress = kubectl get gateway $gatewayName -n $gatewayNs -o jsonpath='{.status.addresses[0].value}' 2>$null
    if (-not [string]::IsNullOrWhiteSpace($gatewayAddress)) {
        Write-Step "Using gateway address http://$gatewayAddress"
        $baseUri = "http://$gatewayAddress"
    }
    else {
        Write-Step "Starting Istio ingress port-forward on localhost:$port"
        $ingressService = kubectl get svc -n istio-system -l istio=ingressgateway -o jsonpath='{.items[0].metadata.name}'
        if ([string]::IsNullOrWhiteSpace($ingressService)) {
            throw 'Unable to find istio ingressgateway service in istio-system namespace.'
        }
        $pf = Start-Process -FilePath 'kubectl' -ArgumentList "port-forward -n istio-system svc/$ingressService $port`:80" -PassThru -WindowStyle Hidden
        $baseUri = "http://localhost:$port"
    }
}
Start-Sleep -Seconds 5

try {
    $modelIds = @($primaryModelName)
    if ($hasSecondary -and -not $capacityLimited) {
        $modelIds += $secondaryModelName
    }

    foreach ($modelId in $modelIds) {
        Write-Step "Testing model routing for '$modelId'"
        $payload = @{
            model = $modelId
            messages = @(
                @{
                    role = 'user'
                    content = 'Respond with exactly one sentence.'
                }
            )
            temperature = [double]$config.Test.Temperature
            max_tokens = [int]$config.Test.MaxTokens
        } | ConvertTo-Json -Depth 8

        $resp = Invoke-RestMethod -Method Post -Uri "$baseUri/v1/chat/completions" -ContentType 'application/json' -Body $payload
        if (-not $resp.choices -or $resp.choices.Count -lt 1) {
            throw "No choices returned for routed model '$modelId'."
        }
        Write-Host ("returned model: {0}" -f $resp.model)
    }
}
finally {
    if ($pf -and -not $pf.HasExited) {
        Stop-Process -Id $pf.Id -Force
    }
}

if (-not $hasSecondary) {
    Write-Step 'Native GAIE comparison completed in qwen-only mode'
}
elseif ($capacityLimited) {
    Write-Step 'Native GAIE comparison completed in single-model mode due GPU capacity limits'
}
else {
    Write-Step 'Native GAIE multi-model comparison test complete'
}
