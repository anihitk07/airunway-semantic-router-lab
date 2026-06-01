param(
    [string]$ConfigPath
)

. (Join-Path $PSScriptRoot '_Common.ps1')
$config = Get-LabConfig -ConfigPath $ConfigPath

Assert-Tools -Tools @('az', 'kubectl')
Ensure-AzureContext -Config $config

$gpu = $config.Aks.GpuPool
if (-not $gpu.Enable) {
    throw 'GPU pool provisioning is disabled in config (Aks.GpuPool.Enable = $false).'
}

Confirm-CostApproval -RequireApproval ([bool]$gpu.RequireApproval)

$rg = $config.Azure.ResourceGroup
$cluster = $config.Aks.ClusterName
$poolName = $gpu.Name

function Get-GpuLabelDefaults {
    param([string]$VmSize)

    $normalized = $VmSize.ToUpperInvariant()
    switch -Regex ($normalized) {
        'T4' {
            return @{
                Product = 'tesla-t4'
                MemoryMiB = '16384'
                CudaMajor = '7'
                CudaMinor = '5'
            }
        }
        'A100' {
            return @{
                Product = 'nvidia-a100'
                MemoryMiB = '81920'
                CudaMajor = '8'
                CudaMinor = '0'
            }
        }
        default {
            return @{
                Product = 'nvidia-gpu'
                MemoryMiB = '16384'
                CudaMajor = ''
                CudaMinor = ''
            }
        }
    }
}

function Get-NodeLabelValue {
    param(
        [object]$Node,
        [string]$Key
    )

    if (-not $Node -or -not $Node.metadata -or -not $Node.metadata.labels) {
        return ''
    }

    $prop = $Node.metadata.labels.PSObject.Properties[$Key]
    if ($null -eq $prop) {
        return ''
    }
    return [string]$prop.Value
}

Write-Step "Checking existing GPU node pool '$poolName'"
$existing = Invoke-AzJson -Arguments "aks nodepool show --resource-group `"$rg`" --cluster-name `"$cluster`" --name `"$poolName`"" -AllowFailure

if ($existing -and $existing.provisioningState -eq 'Failed') {
    Write-Step "Existing GPU node pool '$poolName' is in Failed state; deleting before recreate"
    Invoke-Cli -Command "az aks nodepool delete --resource-group `"$rg`" --cluster-name `"$cluster`" --name `"$poolName`" --only-show-errors"
    $existing = $null
}

if (-not $existing) {
    Write-Step 'Creating GPU node pool'
    $cmd = @(
        'az aks nodepool add'
        "--resource-group `"$rg`""
        "--cluster-name `"$cluster`""
        "--name `"$poolName`""
        "--node-vm-size `"$($gpu.VmSize)`""
        "--node-count $($gpu.NodeCount)"
        "--min-count $($gpu.MinCount)"
        "--max-count $($gpu.MaxCount)"
        '--enable-cluster-autoscaler'
        "--labels $($gpu.LabelKey)=$($gpu.LabelValue)"
        "--node-taints `"$($gpu.Taint)`""
        '--only-show-errors'
    ) -join ' '

    if ($gpu.Zones -and $gpu.Zones.Count -gt 0) {
        $cmd += " --zones $($gpu.Zones -join ' ')"
    }
    if ($gpu.Priority -and $gpu.Priority -eq 'Spot') {
        $cmd += ' --priority Spot'
        if ($gpu.EvictionPolicy) {
            $cmd += " --eviction-policy $($gpu.EvictionPolicy)"
        }
        if ($null -ne $gpu.SpotMaxPrice) {
            $cmd += " --spot-max-price $($gpu.SpotMaxPrice)"
        }
    }

    Invoke-Cli -Command $cmd
}
else {
    Write-Host 'GPU node pool already exists. Skipping creation.'
}

Write-Step 'Refreshing kubeconfig and validating GPU inventory'
Invoke-Cli -Command "az aks get-credentials --resource-group `"$rg`" --name `"$cluster`" --overwrite-existing --only-show-errors"

if ($gpu.Priority -and $gpu.Priority -eq 'Spot') {
    Write-Step 'Ensuring NVIDIA device plugin tolerates Spot taint'
    $daemonsetJson = kubectl get daemonset nvidia-device-plugin-daemonset -n kaito-workspace -o json 2>$null
    if ($daemonsetJson) {
        $daemonset = $daemonsetJson | ConvertFrom-Json
        $hasSpotToleration = $false
        foreach ($toleration in $daemonset.spec.template.spec.tolerations) {
            if ($toleration.key -eq 'kubernetes.azure.com/scalesetpriority' -and $toleration.value -eq 'spot' -and $toleration.effect -eq 'NoSchedule') {
                $hasSpotToleration = $true
                break
            }
        }

        if (-not $hasSpotToleration) {
            Invoke-Cli -Command "kubectl patch daemonset nvidia-device-plugin-daemonset -n kaito-workspace --type='json' -p='[{`"op`":`"add`",`"path`":`"/spec/template/spec/tolerations/-`",`"value`":{`"key`":`"kubernetes.azure.com/scalesetpriority`",`"operator`":`"Equal`",`"value`":`"spot`",`"effect`":`"NoSchedule`"}}]'"
            Invoke-Cli -Command 'kubectl rollout status daemonset/nvidia-device-plugin-daemonset -n kaito-workspace --timeout=300s'
        }
    }
}

Invoke-Cli -Command "kubectl get nodes -L $($gpu.LabelKey),nvidia.com/gpu.product"
Invoke-Cli -Command 'kubectl get nodes -o custom-columns=NAME:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu,PRODUCT:.metadata.labels.nvidia\.com/gpu\.product'
$defaults = Get-GpuLabelDefaults -VmSize $gpu.VmSize
$gpuNodesJson = kubectl get nodes -l "$($gpu.LabelKey)=$($gpu.LabelValue)" -o json 2>$null
if ($gpuNodesJson) {
    $gpuNodes = $gpuNodesJson | ConvertFrom-Json
    foreach ($node in $gpuNodes.items) {
        $nodeName = $node.metadata.name
        $allocatableGpu = $node.status.allocatable.'nvidia.com/gpu'
        if ([string]::IsNullOrWhiteSpace($allocatableGpu)) {
            continue
        }

        $labels = @(
            'nvidia.com/gpu.present=true'
            "nvidia.com/gpu.count=$allocatableGpu"
        )

        if ([string]::IsNullOrWhiteSpace((Get-NodeLabelValue -Node $node -Key 'nvidia.com/gpu.product'))) {
            $labels += "nvidia.com/gpu.product=$($defaults.Product)"
        }
        if ([string]::IsNullOrWhiteSpace((Get-NodeLabelValue -Node $node -Key 'nvidia.com/gpu.memory'))) {
            $labels += "nvidia.com/gpu.memory=$($defaults.MemoryMiB)"
        }
        if ($defaults.CudaMajor -and [string]::IsNullOrWhiteSpace((Get-NodeLabelValue -Node $node -Key 'nvidia.com/cuda.compute.major'))) {
            $labels += "nvidia.com/cuda.compute.major=$($defaults.CudaMajor)"
        }
        if ($defaults.CudaMinor -and [string]::IsNullOrWhiteSpace((Get-NodeLabelValue -Node $node -Key 'nvidia.com/cuda.compute.minor'))) {
            $labels += "nvidia.com/cuda.compute.minor=$($defaults.CudaMinor)"
        }

        Invoke-Cli -Command ("kubectl label node {0} {1} --overwrite" -f $nodeName, ($labels -join ' '))
    }
}

$deadline = (Get-Date).AddMinutes(5)
do {
    $nodesJson = kubectl get nodes -l "$($gpu.LabelKey)=$($gpu.LabelValue)" -o json 2>$null
    if ($nodesJson) {
        $nodes = $nodesJson | ConvertFrom-Json
        foreach ($node in $nodes.items) {
            $allocatableGpu = $node.status.allocatable.'nvidia.com/gpu'
            if ($allocatableGpu -and [int]$allocatableGpu -ge 1) {
                return
            }
        }
    }
    Start-Sleep -Seconds 10
} while ((Get-Date) -lt $deadline)

throw "GPU allocatable capacity is not ready on nodes with label $($gpu.LabelKey)=$($gpu.LabelValue). Check NVIDIA device plugin and node taints."
