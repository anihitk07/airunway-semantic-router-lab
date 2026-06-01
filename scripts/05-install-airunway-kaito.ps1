param(
    [string]$ConfigPath
)

. (Join-Path $PSScriptRoot '_Common.ps1')
$config = Get-LabConfig -ConfigPath $ConfigPath

Assert-Tools -Tools @('kubectl', 'helm')

$airunwayRef = $config.Versions.AirunwayRef
$kaitoVersion = $config.Versions.KaitoChartVersion
$airunwayNs = $config.Namespaces.Airunway
$kaitoNs = $config.Namespaces.KaitoWorkspace

Write-Step 'Installing KAITO workspace operator'
Invoke-Cli -Command 'helm repo add kaito https://kaito-project.github.io/kaito/charts/kaito'
Invoke-Cli -Command 'helm repo update'

$chartCmd = "helm upgrade -i kaito-workspace kaito/workspace --namespace $kaitoNs --create-namespace --set featureGates.disableNodeAutoProvisioning=true"
if ($kaitoVersion) {
    $chartCmd += " --version $kaitoVersion"
}
Invoke-Cli -Command $chartCmd

Write-Step 'Installing AI Runway controller, dashboard, and KAITO provider shim'
Invoke-Cli -Command "kubectl apply -f https://raw.githubusercontent.com/kaito-project/airunway/$airunwayRef/deploy/controller.yaml"
Invoke-Cli -Command "kubectl apply -f https://raw.githubusercontent.com/kaito-project/airunway/$airunwayRef/deploy/dashboard.yaml"
Invoke-Cli -Command "kubectl apply -f https://raw.githubusercontent.com/kaito-project/airunway/$airunwayRef/providers/kaito/deploy/kaito.yaml"

Write-Step 'Validating AI Runway and KAITO resources'
Invoke-Cli -Command 'kubectl get crd modeldeployments.airunway.ai'
Invoke-Cli -Command 'kubectl get crd inferenceproviderconfigs.airunway.ai'
Invoke-Cli -Command "kubectl get pods -n $airunwayNs"
Invoke-Cli -Command "kubectl get pods -n $kaitoNs"
Invoke-Cli -Command 'kubectl get inferenceproviderconfigs'

Write-Step 'AI Runway + KAITO installation complete'
