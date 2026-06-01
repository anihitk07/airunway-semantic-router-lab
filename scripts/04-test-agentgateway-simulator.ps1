param(
    [string]$ConfigPath
)

. (Join-Path $PSScriptRoot '_Common.ps1')
$config = Get-LabConfig -ConfigPath $ConfigPath
$prompts = Get-Prompts
$ns = $config.Namespaces.AgentGateway
$port = [int]$config.Test.PortForwardPort
$temperature = [double]$config.Test.Temperature
$maxTokens = [int]$config.Test.MaxTokens
$gatewayName = $config.Routing.AgentGatewayGatewayName

Write-Step "Starting port-forward for $ns/$gatewayName on localhost:$port"
$pf = Start-Process -FilePath 'kubectl' -ArgumentList "port-forward -n $ns svc/$gatewayName $port`:80" -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 5

try {
    foreach ($test in $prompts.Simulator) {
        Write-Step "Running simulator smoke prompt: $($test.Name)"
        $body = @{
            model = $test.Model
            messages = @(
                @{
                    role = 'user'
                    content = $test.Prompt
                }
            )
            max_tokens = $maxTokens
            temperature = $temperature
        } | ConvertTo-Json -Depth 8

        $response = Invoke-RestMethod -Method Post -Uri "http://localhost:$port/v1/chat/completions" -ContentType 'application/json' -Body $body
        if (-not $response.choices -or $response.choices.Count -lt 1) {
            throw "No choices returned for test '$($test.Name)'."
        }

        $content = $response.choices[0].message.content
        if ([string]::IsNullOrWhiteSpace($content)) {
            throw "Empty completion text for test '$($test.Name)'."
        }

        Write-Host ("[{0}] model={1}" -f $test.Name, $response.model)
    }

    Write-Step 'Simulator smoke tests completed'
}
finally {
    if ($pf -and -not $pf.HasExited) {
        Stop-Process -Id $pf.Id -Force
    }
}
