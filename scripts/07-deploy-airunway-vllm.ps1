param(
    [string]$ConfigPath
)

. (Join-Path $PSScriptRoot '_Common.ps1')
$config = Get-LabConfig -ConfigPath $ConfigPath

Assert-Tools -Tools @('kubectl')

$repoRoot = Get-RepoRoot
$model = $config.Models.Primary
$gpu = $config.Aks.GpuPool

function Apply-QwenT4AttentionFix {
    param(
        [string]$Namespace,
        [string]$StatefulSetName
    )

    $cmd = kubectl get sts $StatefulSetName -n $Namespace -o jsonpath='{.spec.template.spec.containers[0].command[2]}' 2>$null
    if ([string]::IsNullOrWhiteSpace($cmd)) {
        return $false
    }

    if ($cmd -match '--attention-backend\s+TRITON_ATTN') {
        return $true
    }

    if ($cmd -match '--attention-backend\s+\S+') {
        $new = [regex]::Replace($cmd, '--attention-backend\s+\S+', '--attention-backend TRITON_ATTN')
    }
    else {
        $new = "$cmd --attention-backend TRITON_ATTN"
    }

    $escaped = $new.Replace('\', '\\').Replace('"', '\"')
    Invoke-Cli -Command "kubectl patch sts $StatefulSetName -n $Namespace --type json -p '[{`"op`":`"replace`",`"path`":`"/spec/template/spec/containers/0/command/2`",`"value`":`"$escaped`"}]'"
    Invoke-Cli -Command "kubectl delete pod ${StatefulSetName}-0 -n $Namespace --wait=true" -AllowFailure
    return $true
}

Write-Step "Ensuring namespace '$($model.Namespace)' exists"
Invoke-Cli -Command "kubectl create namespace $($model.Namespace) --dry-run=client -o yaml | kubectl apply -f -"

Write-Step "Applying ModelDeployment $($model.Name)"
$template = Join-Path $repoRoot 'manifests\airunway\modeldeployment-primary.yaml'
Apply-TemplateManifest -TemplatePath $template -Tokens @{
    '__MODEL_NAME__' = $model.Name
    '__MODEL_NAMESPACE__' = $model.Namespace
    '__MODEL_ID__' = $model.Id
    '__PROVIDER_NAME__' = $model.Provider
    '__ENGINE_TYPE__' = $model.Engine
    '__GPU_COUNT__' = [string]$model.GpuCount
    '__GPU_LABEL_KEY__' = $gpu.LabelKey
    '__GPU_LABEL_VALUE__' = $gpu.LabelValue
}

Write-Step 'Waiting for model deployment to become Running'
try {
    Wait-ModelDeploymentRunning -Namespace $model.Namespace -Name $model.Name -TimeoutSeconds 900
}
catch {
    $isQwenOnT4 = $model.Id.ToLowerInvariant().Contains('qwen3') -and $gpu.VmSize.ToUpperInvariant().Contains('T4')
    if (-not $isQwenOnT4) {
        throw
    }

    Write-Step 'Applying qwen-on-T4 compatibility fix (TRITON_ATTN backend)'
    $fixed = Apply-QwenT4AttentionFix -Namespace $model.Namespace -StatefulSetName $model.Name
    if (-not $fixed) {
        throw "Unable to apply qwen compatibility fix because StatefulSet '$($model.Name)' was not found."
    }

    Wait-ModelDeploymentRunning -Namespace $model.Namespace -Name $model.Name -TimeoutSeconds 1800
}

$endpoint = Get-ModelEndpoint -Namespace $model.Namespace -Name $model.Name
Write-Step 'Model endpoint discovered'
Write-Host ("Service: {0}" -f $endpoint.Service)
Write-Host ("Host:    {0}" -f $endpoint.Host)
Write-Host ("Port:    {0}" -f $endpoint.Port)
