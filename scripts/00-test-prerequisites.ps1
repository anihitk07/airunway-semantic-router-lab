param(
    [string]$ConfigPath
)

. (Join-Path $PSScriptRoot '_Common.ps1')

Write-Step 'Loading lab configuration'
$config = Get-LabConfig -ConfigPath $ConfigPath

Write-Step 'Checking required CLI tools'
Assert-Tools -Tools @('az', 'kubectl', 'helm', 'curl')
Write-Host 'All required tools are available.'

Write-Step 'Checking Azure authentication context'
Ensure-AzureContext -Config $config
$account = Invoke-AzJson -Arguments 'account show'
Write-Host ("Active subscription: {0}" -f $account.name)

Write-Step 'Checking Kubernetes client availability'
Invoke-Cli -Command 'kubectl version --client=true'

Write-Step 'Prerequisites complete'
