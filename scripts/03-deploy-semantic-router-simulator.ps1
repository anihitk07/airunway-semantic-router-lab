param(
    [string]$ConfigPath
)

. (Join-Path $PSScriptRoot '_Common.ps1')
$config = Get-LabConfig -ConfigPath $ConfigPath

Assert-Tools -Tools @('kubectl', 'helm')

$repoRoot = Get-RepoRoot
$ns = $config.Namespaces.AgentGateway
$gatewayName = $config.Routing.AgentGatewayGatewayName
$backendName = $config.Routing.AgentGatewayBackendName
$chartVersion = $config.Versions.SemanticRouterChart
$storageClass = Get-DefaultStorageClassName

$existingPvcStorageClass = kubectl get pvc semantic-router-models -n $ns -o jsonpath='{.spec.storageClassName}' 2>$null
if (-not [string]::IsNullOrWhiteSpace($existingPvcStorageClass) -and $existingPvcStorageClass -ne $storageClass) {
    Write-Step "Semantic Router PVC uses storageClass '$existingPvcStorageClass' but cluster default is '$storageClass'; recreating release resources"
    Invoke-Cli -Command "helm uninstall semantic-router -n $ns" -AllowFailure
    Invoke-Cli -Command "kubectl delete pvc semantic-router-models -n $ns --ignore-not-found=true"
}

Write-Step 'Deploying simulator backend'
Invoke-Cli -Command "kubectl apply -f `"$((Join-Path $repoRoot 'manifests\agentgateway\demo-llm.yaml'))`""
Wait-DeploymentAvailable -Namespace 'default' -Name 'vllm-llama3-8b-instruct' -TimeoutSeconds 300

Write-Step 'Rendering Semantic Router values for simulator backend'
$valuesTemplatePath = Join-Path $repoRoot 'values\semantic-router-simulator.yaml'
$values = Convert-Template -TemplatePath $valuesTemplatePath -Tokens @{
    '__BACKEND_HOST__' = 'vllm-llama3-8b-instruct.default.svc.cluster.local'
    '__BACKEND_PORT__' = '8000'
}
$valuesFile = Join-Path ([System.IO.Path]::GetTempPath()) ("semantic-router-sim-{0}.yaml" -f ([guid]::NewGuid()))
Set-Content -Path $valuesFile -Value $values -NoNewline

try {
    Write-Step 'Installing Semantic Router chart'
    Invoke-Cli -Command "helm upgrade -i semantic-router oci://ghcr.io/vllm-project/charts/semantic-router --version $chartVersion --namespace $ns --create-namespace --set persistence.storageClassName=$storageClass -f `"$valuesFile`""
}
finally {
    Remove-Item -Path $valuesFile -Force -ErrorAction SilentlyContinue
}

Wait-DeploymentAvailable -Namespace $ns -Name 'semantic-router' -TimeoutSeconds 600

Write-Step 'Applying AgentGateway routing and ExtProc policy'
$routingTemplate = Join-Path $repoRoot 'manifests\agentgateway\routing-resources.yaml'
Apply-TemplateManifest -TemplatePath $routingTemplate -Tokens @{
    '__AGENTGATEWAY_BACKEND_NAME__' = $backendName
    '__BACKEND_NAMESPACE__' = 'default'
    '__ROUTE_NAMESPACE__' = 'default'
    '__GATEWAY_NAMESPACE__' = $ns
    '__AGENTGATEWAY_GATEWAY_NAME__' = $gatewayName
    '__BACKEND_HOST__' = 'vllm-llama3-8b-instruct.default.svc.cluster.local'
    '__BACKEND_PORT__' = '8000'
}

$policyTemplate = Join-Path $repoRoot 'manifests\agentgateway\extproc-policy.yaml'
Apply-TemplateManifest -TemplatePath $policyTemplate -Tokens @{
    '__AGENTGATEWAY_NAMESPACE__' = $ns
    '__AGENTGATEWAY_GATEWAY_NAME__' = $gatewayName
}

Write-Step 'Semantic router simulator setup complete'
Invoke-Cli -Command "kubectl get pods -n $ns"
