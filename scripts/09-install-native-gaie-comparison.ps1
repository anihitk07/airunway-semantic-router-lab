param(
    [string]$ConfigPath
)

. (Join-Path $PSScriptRoot '_Common.ps1')
$config = Get-LabConfig -ConfigPath $ConfigPath
$repoRoot = Get-RepoRoot

Assert-Tools -Tools @('kubectl', 'helm', 'istioctl')

$gatewayApiVersion = $config.Versions.GatewayApi
$gaieVersion = $config.Versions.Gaie
$comparisonNs = $config.Namespaces.GatewayComparison
$gatewayName = $config.Routing.ComparisonGatewayName
$gatewayClass = $config.Routing.ComparisonGatewayClass

Write-Step "Installing Gateway API CRDs ($gatewayApiVersion)"
Invoke-Cli -Command "kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/$gatewayApiVersion/standard-install.yaml"

Write-Step "Installing GAIE CRDs ($gaieVersion)"
Invoke-Cli -Command "kubectl apply -f https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/$gaieVersion/manifests.yaml"

Write-Step 'Installing Istio with inference extension support'
$istioCmd = 'istioctl install --set values.pilot.env.ENABLE_GATEWAY_API_INFERENCE_EXTENSION=true -y'
if ($config.Versions.IstioRevision) {
    $istioCmd += " --revision $($config.Versions.IstioRevision)"
}
Invoke-Cli -Command $istioCmd

Write-Step "Ensuring gateway namespace $comparisonNs exists"
Invoke-Cli -Command "kubectl create namespace $comparisonNs --dry-run=client -o yaml | kubectl apply -f -"

Write-Step 'Applying comparison gateway manifest'
$gatewayTemplate = Join-Path $repoRoot 'manifests\comparison-istio-gaie\gateway.yaml'
Apply-TemplateManifest -TemplatePath $gatewayTemplate -Tokens @{
    '__COMPARISON_GATEWAY_NAME__' = $gatewayName
    '__COMPARISON_GATEWAY_NAMESPACE__' = $comparisonNs
    '__COMPARISON_GATEWAY_CLASS__' = $gatewayClass
}

Write-Step 'Installing body-based router chart'
Invoke-Cli -Command "helm upgrade -i body-based-router -n $comparisonNs --create-namespace --set provider.name=istio --version $gaieVersion oci://registry.k8s.io/gateway-api-inference-extension/charts/body-based-routing"

Write-Step 'Comparison path installation complete'
Invoke-Cli -Command "kubectl get gateway -n $comparisonNs $gatewayName"
