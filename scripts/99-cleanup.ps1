param(
    [string]$ConfigPath,
    [switch]$DeleteCluster,
    [switch]$DeleteResourceGroup
)

. (Join-Path $PSScriptRoot '_Common.ps1')
$config = Get-LabConfig -ConfigPath $ConfigPath

Assert-Tools -Tools @('az', 'kubectl', 'helm')
Ensure-AzureContext -Config $config

$airunwayRef = $config.Versions.AirunwayRef
$agentNs = $config.Namespaces.AgentGateway
$airunwayNs = $config.Namespaces.Airunway
$kaitoNs = $config.Namespaces.KaitoWorkspace
$comparisonNs = $config.Namespaces.GatewayComparison
$rg = $config.Azure.ResourceGroup
$cluster = $config.Aks.ClusterName
$gpuPool = $config.Aks.GpuPool.Name
$hasSecondary = $config.Models.ContainsKey('Secondary') -and
    $null -ne $config.Models.Secondary -and
    $config.Models.Secondary.ContainsKey('Name') -and
    -not [string]::IsNullOrWhiteSpace($config.Models.Secondary.Name)

Write-Step 'Removing compatibility spike artifacts'
Invoke-Cli -Command "kubectl delete -f `"$((Join-Path (Get-RepoRoot) 'manifests\spike\modeldeployment-http-route-ref.yaml'))`" --ignore-not-found=true" -AllowFailure

Write-Step 'Removing comparison path resources'
Invoke-Cli -Command "helm uninstall body-based-router -n $comparisonNs" -AllowFailure
Invoke-Cli -Command "kubectl delete gateway $($config.Routing.ComparisonGatewayName) -n $comparisonNs --ignore-not-found=true" -AllowFailure

Write-Step 'Removing AgentGateway/Semantic Router resources'
Invoke-Cli -Command "kubectl delete agentgatewaypolicy semantic-router-extproc -n $agentNs --ignore-not-found=true" -AllowFailure
Invoke-Cli -Command "kubectl delete httproute $($config.Routing.AgentGatewayBackendName) -n $agentNs --ignore-not-found=true" -AllowFailure
Invoke-Cli -Command "kubectl delete agentgatewaybackend $($config.Routing.AgentGatewayBackendName) -n $agentNs --ignore-not-found=true" -AllowFailure
Invoke-Cli -Command "helm uninstall semantic-router -n $agentNs" -AllowFailure
Invoke-Cli -Command "helm uninstall agentgateway -n $agentNs" -AllowFailure
Invoke-Cli -Command "helm uninstall agentgateway-crds -n $agentNs" -AllowFailure

Write-Step 'Removing simulator deployment'
Invoke-Cli -Command "kubectl delete -f `"$((Join-Path (Get-RepoRoot) 'manifests\agentgateway\demo-llm.yaml'))`" --ignore-not-found=true" -AllowFailure

Write-Step 'Removing AI Runway and KAITO resources'
Invoke-Cli -Command "kubectl delete modeldeployment $($config.Models.Primary.Name) -n $($config.Models.Primary.Namespace) --ignore-not-found=true" -AllowFailure
if ($hasSecondary) {
    Invoke-Cli -Command "kubectl delete modeldeployment $($config.Models.Secondary.Name) -n $($config.Models.Secondary.Namespace) --ignore-not-found=true" -AllowFailure
}
Invoke-Cli -Command "kubectl delete -f https://raw.githubusercontent.com/kaito-project/airunway/$airunwayRef/providers/kaito/deploy/kaito.yaml --ignore-not-found=true" -AllowFailure
Invoke-Cli -Command "kubectl delete -f https://raw.githubusercontent.com/kaito-project/airunway/$airunwayRef/deploy/dashboard.yaml --ignore-not-found=true" -AllowFailure
Invoke-Cli -Command "kubectl delete -f https://raw.githubusercontent.com/kaito-project/airunway/$airunwayRef/deploy/controller.yaml --ignore-not-found=true" -AllowFailure
Invoke-Cli -Command "helm uninstall kaito-workspace -n $kaitoNs" -AllowFailure

Write-Step 'Deleting GPU node pool (optional but recommended for cost control)'
Invoke-Cli -Command "az aks nodepool delete --resource-group `"$rg`" --cluster-name `"$cluster`" --name `"$gpuPool`" --only-show-errors --yes" -AllowFailure

if ($DeleteCluster) {
    Write-Step "Deleting AKS cluster $cluster"
    Invoke-Cli -Command "az aks delete --resource-group `"$rg`" --name `"$cluster`" --yes --no-wait --only-show-errors"
}

if ($DeleteResourceGroup) {
    Write-Step "Deleting resource group $rg"
    Invoke-Cli -Command "az group delete --name `"$rg`" --yes --no-wait"
}

Write-Step 'Cleanup completed'
