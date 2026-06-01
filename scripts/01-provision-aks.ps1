param(
    [string]$ConfigPath
)

. (Join-Path $PSScriptRoot '_Common.ps1')
$config = Get-LabConfig -ConfigPath $ConfigPath

Assert-Tools -Tools @('az', 'kubectl')
Ensure-AzureContext -Config $config

$rg = $config.Azure.ResourceGroup
$location = $config.Azure.Location
$cluster = $config.Aks.ClusterName
$pool = $config.Aks.SystemPool

Write-Step "Ensuring resource group $rg exists"
Invoke-Cli -Command "az group create --name `"$rg`" --location `"$location`" --only-show-errors"

Write-Step "Checking AKS cluster $cluster"
$existing = Invoke-AzJson -Arguments "aks show --resource-group `"$rg`" --name `"$cluster`"" -AllowFailure

if (-not $existing) {
    Write-Step "Creating AKS cluster $cluster"
    $k8sVersionArg = ''
    if ($config.Aks.KubernetesVersion) {
        $k8sVersionArg = "--kubernetes-version `"$($config.Aks.KubernetesVersion)`""
    }

    $cmd = @(
        'az aks create'
        "--resource-group `"$rg`""
        "--name `"$cluster`""
        "--location `"$location`""
        "--tier `"$($config.Aks.SkuTier)`""
        "--nodepool-name `"$($pool.Name)`""
        "--node-vm-size `"$($pool.VmSize)`""
        "--node-count $($pool.NodeCount)"
        "--min-count $($pool.MinCount)"
        "--max-count $($pool.MaxCount)"
        "--enable-cluster-autoscaler"
        '--enable-managed-identity'
        '--enable-oidc-issuer'
        '--enable-workload-identity'
        "--network-plugin `"$($config.Aks.NetworkPlugin)`""
        "--network-plugin-mode `"$($config.Aks.NetworkPluginMode)`""
        "--network-dataplane `"$($config.Aks.NetworkDataplane)`""
        "--pod-cidr `"$($config.Aks.PodCidr)`""
        "--service-cidr `"$($config.Aks.ServiceCidr)`""
        "--dns-service-ip `"$($config.Aks.DnsServiceIp)`""
        '--generate-ssh-keys'
        '--only-show-errors'
        $k8sVersionArg
    ) -join ' '

    if ($pool.Zones -and $pool.Zones.Count -gt 0) {
        $cmd += " --zones $($pool.Zones -join ' ')"
    }

    Invoke-Cli -Command $cmd
}
else {
    Write-Host "AKS cluster already exists. Skipping creation."
}

Write-Step 'Fetching AKS kubeconfig'
Invoke-Cli -Command "az aks get-credentials --resource-group `"$rg`" --name `"$cluster`" --overwrite-existing --only-show-errors"

Write-Step 'Verifying AKS connectivity'
Invoke-Cli -Command 'kubectl config current-context'
Invoke-Cli -Command 'kubectl get nodes -o wide'
