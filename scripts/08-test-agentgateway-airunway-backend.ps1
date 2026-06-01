param(
    [string]$ConfigPath
)

. (Join-Path $PSScriptRoot '_Common.ps1')
$config = Get-LabConfig -ConfigPath $ConfigPath
$prompts = Get-Prompts
$repoRoot = Get-RepoRoot

Assert-Tools -Tools @('kubectl', 'helm')

$agentNs = $config.Namespaces.AgentGateway
$gatewayName = $config.Routing.AgentGatewayGatewayName
$backendName = $config.Routing.AgentGatewayBackendName
$model = $config.Models.Primary
$chartVersion = $config.Versions.SemanticRouterChart
$storageClass = Get-DefaultStorageClassName

Write-Step 'Resolving AI Runway model endpoint'
$endpoint = Get-ModelEndpoint -Namespace $model.Namespace -Name $model.Name

Write-Step 'Discovering served backend model ID'
$backendPort = 18081
$backendPf = Start-Process -FilePath 'kubectl' -ArgumentList "port-forward -n $($model.Namespace) svc/$($endpoint.Service) $backendPort`:$($endpoint.Port)" -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 5
try {
    $modelsResponse = Invoke-RestMethod -Method Get -Uri "http://localhost:$backendPort/v1/models"
}
finally {
    if ($backendPf -and -not $backendPf.HasExited) {
        Stop-Process -Id $backendPf.Id -Force
    }
}

if (-not $modelsResponse.data -or $modelsResponse.data.Count -lt 1 -or -not $modelsResponse.data[0].id) {
    throw 'Failed to discover served model ID from backend /v1/models response.'
}
$servedModelId = [string]$modelsResponse.data[0].id
Write-Host ("Discovered backend model id: {0}" -f $servedModelId)

Write-Step 'Upgrading Semantic Router to point at AI Runway backend'
$valuesTemplate = Join-Path $repoRoot 'values\semantic-router-airunway.yaml'
$renderedValues = Convert-Template -TemplatePath $valuesTemplate -Tokens @{
    '__AIRUNWAY_MODEL_ID__' = $servedModelId
    '__BACKEND_HOST__' = $endpoint.Host
    '__BACKEND_PORT__' = [string]$endpoint.Port
}
$valuesFile = Join-Path ([System.IO.Path]::GetTempPath()) ("semantic-router-airunway-{0}.yaml" -f ([guid]::NewGuid()))
Set-Content -Path $valuesFile -Value $renderedValues -NoNewline
try {
    Invoke-Cli -Command "helm upgrade -i semantic-router oci://ghcr.io/vllm-project/charts/semantic-router --version $chartVersion --namespace $agentNs --set persistence.storageClassName=$storageClass -f `"$valuesFile`""
}
finally {
    Remove-Item -Path $valuesFile -Force -ErrorAction SilentlyContinue
}
Wait-DeploymentAvailable -Namespace $agentNs -Name 'semantic-router' -TimeoutSeconds 600

Write-Step 'Updating AgentGateway backend target'
$routingTemplate = Join-Path $repoRoot 'manifests\agentgateway\routing-resources.yaml'
Apply-TemplateManifest -TemplatePath $routingTemplate -Tokens @{
    '__AGENTGATEWAY_BACKEND_NAME__' = $backendName
    '__BACKEND_NAMESPACE__' = $model.Namespace
    '__ROUTE_NAMESPACE__' = $model.Namespace
    '__GATEWAY_NAMESPACE__' = $agentNs
    '__AGENTGATEWAY_GATEWAY_NAME__' = $gatewayName
    '__BACKEND_HOST__' = $endpoint.Host
    '__BACKEND_PORT__' = [string]$endpoint.Port
}

$port = [int]$config.Test.PortForwardPort
Write-Step "Starting AgentGateway port-forward on localhost:$port"
$pf = Start-Process -FilePath 'kubectl' -ArgumentList "port-forward -n $agentNs svc/$gatewayName $port`:80" -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 5

try {
    foreach ($test in $prompts.Airunway) {
        $payload = @{
            model = $servedModelId
            messages = @(
                @{
                    role = 'user'
                    content = $test.Prompt
                }
            )
            temperature = [double]$config.Test.Temperature
            max_tokens = [int]$config.Test.MaxTokens
        } | ConvertTo-Json -Depth 8

        Write-Step "Running AgentGateway -> AI Runway test: $($test.Name)"
        $resp = Invoke-RestMethod -Method Post -Uri "http://localhost:$port/v1/chat/completions" -ContentType 'application/json' -Body $payload
        if (-not $resp.choices -or $resp.choices.Count -lt 1) {
            throw "No completion choices returned for '$($test.Name)'."
        }
        Write-Host ("response model: {0}" -f $resp.model)
    }
}
finally {
    if ($pf -and -not $pf.HasExited) {
        Stop-Process -Id $pf.Id -Force
    }
}

Write-Step 'AgentGateway backend replacement test complete'
