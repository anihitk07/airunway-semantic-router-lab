Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Get-RepoRoot {
    Split-Path -Parent $PSScriptRoot
}

function Resolve-LabConfigPath {
    param([string]$ConfigPath)

    if ($ConfigPath) {
        return (Resolve-Path -Path $ConfigPath).Path
    }

    $default = Join-Path (Get-RepoRoot) 'config\lab.psd1'
    if (Test-Path $default) {
        return (Resolve-Path -Path $default).Path
    }

    throw "Config file not found. Copy config\lab.example.psd1 to config\lab.psd1 or pass -ConfigPath."
}

function Get-LabConfig {
    param([string]$ConfigPath)
    $resolved = Resolve-LabConfigPath -ConfigPath $ConfigPath
    Import-PowerShellDataFile -Path $resolved
}

function Test-HasTool {
    param([Parameter(Mandatory = $true)][string]$Name)
    $null -ne (Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

function Assert-Tools {
    param([string[]]$Tools = @('az', 'kubectl', 'helm', 'curl'))
    $missing = @()
    foreach ($tool in $Tools) {
        if (-not (Test-HasTool -Name $tool)) {
            $missing += $tool
        }
    }
    if ($missing.Count -gt 0) {
        throw "Missing required tools: $($missing -join ', ')"
    }
}

function Invoke-AzJson {
    param(
        [Parameter(Mandatory = $true)][string]$Arguments,
        [switch]$AllowFailure
    )

    $cmd = "az $Arguments --output json"
    Write-Host ">> $cmd" -ForegroundColor DarkGray
    $output = Invoke-Expression $cmd 2>&1
    if ($LASTEXITCODE -ne 0) {
        if ($AllowFailure) {
            return $null
        }
        throw "Azure CLI failed: $cmd`n$output"
    }
    if ([string]::IsNullOrWhiteSpace([string]$output)) { return $null }
    $output | ConvertFrom-Json
}

function Invoke-Cli {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [switch]$AllowFailure
    )

    Write-Host ">> $Command" -ForegroundColor DarkGray
    Invoke-Expression $Command
    if ($LASTEXITCODE -ne 0 -and -not $AllowFailure) {
        throw "Command failed with exit code ${LASTEXITCODE}: $Command"
    }
}

function Confirm-CostApproval {
    param(
        [bool]$RequireApproval = $true,
        [string]$Message = 'GPU node pools incur significant hourly cost. Type YES to continue'
    )

    if (-not $RequireApproval) {
        return
    }
    $answer = Read-Host -Prompt $Message
    if ($answer -cne 'YES') {
        throw 'GPU provisioning cancelled by user.'
    }
}

function Convert-Template {
    param(
        [Parameter(Mandatory = $true)][string]$TemplatePath,
        [Parameter(Mandatory = $true)][hashtable]$Tokens
    )

    $raw = Get-Content -Path $TemplatePath -Raw
    foreach ($key in $Tokens.Keys) {
        $raw = $raw.Replace($key, [string]$Tokens[$key])
    }
    return $raw
}

function Apply-TemplateManifest {
    param(
        [Parameter(Mandatory = $true)][string]$TemplatePath,
        [Parameter(Mandatory = $true)][hashtable]$Tokens
    )

    $yaml = Convert-Template -TemplatePath $TemplatePath -Tokens $Tokens
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("airunway-lab-{0}.yaml" -f ([guid]::NewGuid()))
    Set-Content -Path $tmp -Value $yaml -NoNewline
    try {
        Invoke-Cli -Command "kubectl apply -f `"$tmp`""
    }
    finally {
        Remove-Item -Path $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Wait-DeploymentAvailable {
    param(
        [Parameter(Mandatory = $true)][string]$Namespace,
        [Parameter(Mandatory = $true)][string]$Name,
        [int]$TimeoutSeconds = 600
    )
    Invoke-Cli -Command "kubectl wait --for=condition=Available deployment/$Name -n $Namespace --timeout=${TimeoutSeconds}s"
}

function Wait-ModelDeploymentRunning {
    param(
        [Parameter(Mandatory = $true)][string]$Namespace,
        [Parameter(Mandatory = $true)][string]$Name,
        [int]$TimeoutSeconds = 1800
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $phase = kubectl get modeldeployment $Name -n $Namespace -o jsonpath='{.status.phase}' 2>$null
        if ($phase -eq 'Running') { return }
        if ($phase -eq 'Failed') { throw "ModelDeployment $Namespace/$Name failed." }
        Start-Sleep -Seconds 10
    } while ((Get-Date) -lt $deadline)

    throw "Timed out waiting for ModelDeployment $Namespace/$Name to reach Running."
}

function Get-ModelEndpoint {
    param(
        [Parameter(Mandatory = $true)][string]$Namespace,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $service = kubectl get modeldeployment $Name -n $Namespace -o jsonpath='{.status.endpoint.service}'
    $port = kubectl get modeldeployment $Name -n $Namespace -o jsonpath='{.status.endpoint.port}'
    if ([string]::IsNullOrWhiteSpace($service) -or [string]::IsNullOrWhiteSpace($port)) {
        throw "Missing endpoint status for $Namespace/$Name."
    }
    @{
        Service = $service
        Port = [int]$port
        Host = "$service.$Namespace.svc.cluster.local"
    }
}

function Ensure-AzureContext {
    param([hashtable]$Config)
    $account = Invoke-AzJson -Arguments 'account show' -AllowFailure
    if (-not $account) {
        throw "Azure CLI is not authenticated. Run 'az login' first."
    }
    if ($Config.Azure.Subscription) {
        Invoke-Cli -Command "az account set --subscription `"$($Config.Azure.Subscription)`""
    }
}

function Get-Prompts {
    $path = Join-Path (Get-RepoRoot) 'tests\smoke-prompts.psd1'
    Import-PowerShellDataFile -Path $path
}

function Get-DefaultStorageClassName {
    $name = kubectl get storageclass -o jsonpath="{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=='true')]}{.metadata.name}{end}" 2>$null
    if ([string]::IsNullOrWhiteSpace($name)) {
        return 'default'
    }
    return $name
}
