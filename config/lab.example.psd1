@{
    Azure = @{
        Subscription = ''
        ResourceGroup = 'airunway-semantic-router-lab-rg'
        Location = 'westeurope'
    }

    Aks = @{
        ClusterName = 'airunway-lab-aks'
        KubernetesVersion = ''
        NodeResourceGroup = ''
        SkuTier = 'Standard'
        NetworkPlugin = 'azure'
        NetworkPluginMode = 'overlay'
        NetworkDataplane = 'cilium'
        PodCidr = '10.240.0.0/16'
        ServiceCidr = '10.2.0.0/24'
        DnsServiceIp = '10.2.0.10'
        SystemPool = @{
            Name = 'system'
            VmSize = 'Standard_D4ds_v5'
            NodeCount = 2
            MinCount = 2
            MaxCount = 3
            Zones = @('1', '2', '3')
        }
        GpuPool = @{
            Name = 'gpu'
            VmSize = 'Standard_NC24ads_A100_v4'
            NodeCount = 1
            MinCount = 0
            MaxCount = 2
            Zones = @('1')
            Taint = 'sku=gpu:NoSchedule'
            LabelKey = 'workload'
            LabelValue = 'inference'
            Enable = $false
            RequireApproval = $true
        }
    }

    Versions = @{
        GatewayApi = 'v1.5.0'
        Gaie = 'v1.5.0'
        AgentGateway = 'v1.3.0-alpha.1'
        SemanticRouterChart = 'v0.0.0-latest'
        AirunwayRef = 'main'
        KaitoChartVersion = ''
        IstioRevision = ''
    }

    Namespaces = @{
        AgentGateway = 'agentgateway-system'
        Airunway = 'airunway-system'
        KaitoWorkspace = 'kaito-workspace'
        GatewayComparison = 'gateway'
    }

    Routing = @{
        AgentGatewayBackendName = 'semantic-router-vllm'
        AgentGatewayGatewayName = 'agentgateway-proxy'
        ComparisonGatewayName = 'inference-gateway'
        ComparisonGatewayClass = 'istio'
    }

    Models = @{
        Primary = @{
            Name = 'qwen3-0-6b'
            Id = 'Qwen/Qwen3-0.6B'
            Provider = 'kaito'
            Engine = 'vllm'
            Namespace = 'default'
            GpuCount = 1
        }
        # Optional for dual-model comparison:
        # Secondary = @{
        #     Name = 'secondary-model'
        #     Id = 'org/model-id'
        #     Provider = 'kaito'
        #     Engine = 'vllm'
        #     Namespace = 'default'
        #     GpuCount = 1
        # }
    }

    Test = @{
        PortForwardPort = 8080
        Temperature = 0
        MaxTokens = 64
    }
}
