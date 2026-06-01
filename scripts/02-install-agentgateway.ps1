param(
    [string]$ConfigPath
)

. (Join-Path $PSScriptRoot '_Common.ps1')
$config = Get-LabConfig -ConfigPath $ConfigPath

Assert-Tools -Tools @('kubectl', 'helm')

$gatewayApiVersion = $config.Versions.GatewayApi
$agentgatewayVersion = $config.Versions.AgentGateway
$ns = $config.Namespaces.AgentGateway
$gatewayName = $config.Routing.AgentGatewayGatewayName
$repoRoot = Get-RepoRoot

Write-Step "Installing Gateway API CRDs ($gatewayApiVersion)"
Invoke-Cli -Command "kubectl apply --server-side --force-conflicts -f https://github.com/kubernetes-sigs/gateway-api/releases/download/$gatewayApiVersion/standard-install.yaml"

Write-Step "Installing AgentGateway CRDs and controller ($agentgatewayVersion)"
Invoke-Cli -Command "helm upgrade -i agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds --create-namespace --namespace $ns --version $agentgatewayVersion --set controller.image.pullPolicy=Always"
Invoke-Cli -Command "helm upgrade -i agentgateway oci://cr.agentgateway.dev/charts/agentgateway --namespace $ns --version $agentgatewayVersion --set controller.image.pullPolicy=Always --set controller.extraEnv.KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES=true --wait"

Write-Step 'Applying AgentGateway proxy manifest'
$template = Join-Path $repoRoot 'manifests\agentgateway\gateway.yaml'
Apply-TemplateManifest -TemplatePath $template -Tokens @{
    '__AGENTGATEWAY_GATEWAY_NAME__' = $gatewayName
    '__AGENTGATEWAY_NAMESPACE__' = $ns
}

Write-Step 'Waiting for proxy availability'
Wait-DeploymentAvailable -Namespace $ns -Name $gatewayName -TimeoutSeconds 300
Invoke-Cli -Command "kubectl get pods -n $ns"
