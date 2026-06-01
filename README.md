# AI Runway + vLLM Semantic Router on AKS — End-to-End Lab

A runnable PowerShell lab bundle that brings together three independently
maintained projects on a single Azure Kubernetes Service (AKS) cluster and
demonstrates how to combine them for LLM serving, routing and observability:

1. **AI Runway** (`kaito-project/airunway`) — declarative `ModelDeployment`
   API on top of KAITO that provisions vLLM-backed model servers and the
   Gateway API + Inference Extension (GAIE) plumbing around them.
2. **vLLM Semantic Router + AgentGateway**
   (`vllm-project/semantic-router`, `agentgateway.dev`) — a Gateway API
   data plane plus an ExtProc-based classifier that performs domain-aware
   routing across multiple model backends.
3. **Native Istio + Gateway API Inference Extension (GAIE) + Body-Based
   Router (BBR)** — the upstream multi-model comparison path that AI
   Runway natively integrates with.

The lab provisions an AKS cluster from scratch, validates the
AgentGateway + Semantic Router path against a simulator, installs AI
Runway and KAITO, attaches a Spot GPU node pool, deploys a real vLLM
model, swaps the Semantic Router backend onto that model, installs the
native Istio + GAIE comparison stack, and runs a compatibility spike that
captures whether AgentGateway external configuration alone can perform
cross-model semantic routing across AI Runway model deployments.

> Status: validated end-to-end on AKS in `southcentralus` on a single
> `Standard_NC4as_T4_v3` Spot GPU node with `Qwen/Qwen3-0.6B` as the
> primary model.

---

## Table of contents

1. [What this lab proves](#what-this-lab-proves)
2. [Architecture and component flow](#architecture-and-component-flow)
3. [Repository layout](#repository-layout)
4. [Prerequisites](#prerequisites)
5. [Configuration](#configuration)
6. [End-to-end execution order](#end-to-end-execution-order)
7. [What each script does](#what-each-script-does)
8. [Verification and expected output](#verification-and-expected-output)
9. [Known issues and workarounds](#known-issues-and-workarounds)
10. [Cleanup](#cleanup)
11. [Security and cost notes](#security-and-cost-notes)
12. [References](#references)

---

## What this lab proves

| Track | Question | Result |
|-------|----------|--------|
| Track A: AgentGateway + Semantic Router (simulator) | Can the upstream Semantic Router chart route via AgentGateway in front of a vLLM-compatible backend on AKS? | Yes — validated against the upstream `llm-d-inference-sim`. |
| Track B: AI Runway + KAITO + vLLM | Can AI Runway provision a real vLLM model on a Spot GPU node pool and expose it via Gateway API? | Yes — `Qwen/Qwen3-0.6B` runs on `NC4as_T4_v3` Spot after applying a Triton attention-backend workaround. |
| Track C: AgentGateway in front of AI Runway backend | Can the Semantic Router stack be re-pointed at the AI Runway-managed model service without re-deploying? | Yes — by discovering the served model id via `/v1/models` and re-rendering the `AgentgatewayBackend` + `HTTPRoute`. |
| Track D: Native Istio + GAIE + BBR | Does AI Runway's native multi-model routing path work on the same cluster? | Yes — `InferencePool` + `HTTPRoute` + body-based router work via the Istio gateway address. |
| Track E: Compatibility spike | Can AgentGateway perform cross-model semantic routing across multiple AI Runway deployments using external config alone? | No — under the tested versions, the AgentGateway route currently behaves as a single fixed backend; an adapter / additional logic is required to perform real cross-model routing. |

The spike outcome is written to `tests/compatibility-spike-results.json`
on every run (regenerated artifact, gitignored).

---

## Architecture and component flow

There are two parallel data planes on the same cluster:

```
                       +--------------------------+
                       |  Operator / Smoke client |
                       +-----------+--------------+
                                   |
                          /v1/chat/completions
                                   |
       Track A/C: AgentGateway     |     Track D: Native Istio + GAIE
       =====================       |     ============================
                                   |
   +-------------------+           |           +-----------------------+
   | Gateway API:      |           |           | Gateway API:          |
   |   Gateway         |           |           |   Gateway             |
   |   HTTPRoute       |           |           |   HTTPRoute (BBR)     |
   |   ExtProc policy  |           |           |   InferencePool       |
   | (AgentGateway)    |           |           | (Istio + GAIE)        |
   +---------+---------+           |           +-----------+-----------+
             |                                            |
             |  ExtProc gRPC                              |  Body-based routing
             v                                            v
   +-------------------+                       +------------------------+
   | Semantic Router   |                       | Body-Based Router      |
   | (vllm-project)    |                       | (GAIE helm chart)      |
   |  - classify       |                       |  - select InferencePool|
   |  - decide route   |                       |    by request body     |
   +---------+---------+                       +-----------+------------+
             |                                             |
             v                                             v
   +-------------------+                       +------------------------+
   | Backend selection |                       | AI Runway              |
   |  - simulator OR   |                       |   ModelDeployment      |
   |  - AI Runway svc  |                       |   (Qwen3-0.6B on KAITO)|
   +---------+---------+                       +-----------+------------+
             |                                             |
             +----------------+   +------------------------+
                              v   v
                     +-----------------------+
                     | vLLM model server     |
                     | (KAITO StatefulSet on |
                     |  Spot GPU node pool)  |
                     +-----------------------+
```

Key design decisions:

- **Single AKS cluster, two routing planes.** AgentGateway lives in
  `agentgateway-system`; the native comparison gateway lives in
  `gateway` and is served by Istio with the GAIE inference extension
  enabled.
- **Gateway-listener namespace policy matters.** AgentGateway's Gateway
  listener is configured with `allowedRoutes.namespaces.from: All`, but
  the project still enforces same-namespace attachment by default in
  some scenarios. The templates therefore separate
  `__BACKEND_NAMESPACE__`, `__ROUTE_NAMESPACE__` and
  `__GATEWAY_NAMESPACE__` so the HTTPRoute can be co-located with the
  backend (the model service) while the Gateway stays in its own
  namespace.
- **Served model id discovery.** The model id served by vLLM is not
  necessarily the same string passed to the `ModelDeployment.spec.model.id`
  (case, slashes, etc. may differ). Script `08` port-forwards the model
  service and calls `/v1/models` to discover the actual id before
  rendering the Semantic Router values and AgentGateway backend.
- **Spot GPU compatibility.** The NVIDIA device plugin DaemonSet is
  patched to tolerate `kubernetes.azure.com/scalesetpriority=spot:NoSchedule`,
  and the GPU node is bootstrapped with the `nvidia.com/gpu.*` labels
  KAITO expects (presence, count, product, memory, optional CUDA major /
  minor) when they are missing.
- **vLLM attention-backend on T4.** On `NC4as_T4_v3`, the default vLLM
  attention path tries `FLASHINFER` (which JIT-compiles and needs `nvcc`
  in the image) or `FLASH_ATTN` (unsupported compute capability). Script
  `07` detects qwen-on-T4 and patches the StatefulSet command to use
  `--attention-backend TRITON_ATTN`, which is supported by the bundled
  vLLM build.

---

## Repository layout

```
.
├── README.md                                # this file
├── LINKEDIN.md                              # narrative write-up for sharing
├── .gitignore
├── config/
│   ├── lab.example.psd1                     # template; copy to lab.psd1 locally
│   └── lab.psd1                             # (gitignored) your environment-specific config
├── manifests/
│   ├── agentgateway/
│   │   ├── demo-llm.yaml                    # vllm-llama3-8b-instruct simulator (llm-d sim)
│   │   ├── gateway.yaml                     # AgentGateway Gateway resource
│   │   ├── routing-resources.yaml           # AgentgatewayBackend + HTTPRoute
│   │   └── extproc-policy.yaml              # AgentgatewayPolicy: ExtProc -> semantic-router
│   ├── airunway/
│   │   ├── modeldeployment-primary.yaml     # qwen3-0-6b ModelDeployment
│   │   └── modeldeployment-secondary.yaml   # template for optional dual-model mode
│   ├── comparison-istio-gaie/
│   │   └── gateway.yaml                     # Istio Gateway for native GAIE
│   └── spike/
│       └── modeldeployment-http-route-ref.yaml  # spike-only manifest
├── values/
│   ├── semantic-router-simulator.yaml       # Helm values for simulator backend
│   └── semantic-router-airunway.yaml        # Helm values for AI Runway backend
├── scripts/
│   ├── _Common.ps1                          # shared helpers
│   ├── 00-test-prerequisites.ps1
│   ├── 01-provision-aks.ps1
│   ├── 02-install-agentgateway.ps1
│   ├── 03-deploy-semantic-router-simulator.ps1
│   ├── 04-test-agentgateway-simulator.ps1
│   ├── 05-install-airunway-kaito.ps1
│   ├── 06-add-gpu-nodepool.ps1
│   ├── 07-deploy-airunway-vllm.ps1
│   ├── 08-test-agentgateway-airunway-backend.ps1
│   ├── 09-install-native-gaie-comparison.ps1
│   ├── 10-test-native-gaie-multimodel.ps1
│   ├── 11-run-compatibility-spike.ps1
│   └── 99-cleanup.ps1
└── tests/
    ├── smoke-prompts.psd1                   # deterministic prompt set
    └── compatibility-spike-results.json     # (gitignored) regenerated artifact
```

---

## Prerequisites

- PowerShell 7+ (`pwsh`)
- Azure CLI (`az`) with an authenticated session (`az login`)
- `kubectl`
- `helm`
- `istioctl` (required by `scripts/09-install-native-gaie-comparison.ps1`)
- `curl` (or rely on `Invoke-RestMethod`)
- An Azure subscription with:
  - permissions to create AKS clusters, node pools and resource groups
  - sufficient regional **GPU vCPU quota** for the chosen SKU (the
    default uses Spot `Standard_NC4as_T4_v3` = 4 vCPUs in
    `southcentralus`)
  - if your tenant policy denies non-Spot GPU SKUs (a common Microsoft
    tenant guardrail), keep `Aks.GpuPool.Priority = 'Spot'`

Run preflight first:

```powershell
pwsh .\scripts\00-test-prerequisites.ps1
```

---

## Configuration

The lab is driven entirely by a single PowerShell data file.

1. Copy the example file:

   ```powershell
   Copy-Item .\config\lab.example.psd1 .\config\lab.psd1
   ```

2. Edit `config\lab.psd1`. The most important values are:

   | Section | Field | Notes |
   |---------|-------|-------|
   | `Azure.Subscription` | string | Subscription name or id. Optional — if empty, the currently active `az account` is used. |
   | `Azure.ResourceGroup` | string | Resource group that will be created if missing. |
   | `Azure.Location` | string | Region. Match this to where you have GPU quota. |
   | `Aks.ClusterName` | string | AKS cluster name. |
   | `Aks.SystemPool.VmSize` | string | CPU node SKU (`Standard_D4ds_v5` by default). |
   | `Aks.GpuPool.VmSize` | string | GPU SKU. Default is `Standard_NC4as_T4_v3` (T4, 16GB VRAM). |
   | `Aks.GpuPool.Priority` | `Spot` or `Regular` | Use `Spot` on tenants where Regular GPU SKUs are policy-denied. |
   | `Aks.GpuPool.RequireApproval` | bool | Set `true` to require interactive `YES` confirmation before provisioning a GPU pool. |
   | `Models.Primary` | hashtable | The model AI Runway will deploy. Defaults to `Qwen/Qwen3-0.6B`. |
   | `Models.Secondary` | hashtable (optional) | Provide only when you have capacity for two GPU-backed models and want to run the dual-model GAIE comparison. |
   | `Versions.*` | strings | Pin Gateway API, GAIE, AgentGateway, Semantic Router chart, AI Runway ref. |
   | `Routing.*` | strings | Names for the AgentGateway Gateway, comparison Istio Gateway, etc. |
   | `Test.PortForwardPort` / `Temperature` / `MaxTokens` | ints | Local port used by `kubectl port-forward` and deterministic test parameters. |

`config/lab.psd1` is **gitignored on purpose** so each operator can keep
their own subscription / cluster names out of source control. Only the
sanitized template `config/lab.example.psd1` is tracked.

---

## End-to-end execution order

```powershell
pwsh .\scripts\00-test-prerequisites.ps1
pwsh .\scripts\01-provision-aks.ps1
pwsh .\scripts\02-install-agentgateway.ps1
pwsh .\scripts\03-deploy-semantic-router-simulator.ps1
pwsh .\scripts\04-test-agentgateway-simulator.ps1
pwsh .\scripts\05-install-airunway-kaito.ps1
pwsh .\scripts\06-add-gpu-nodepool.ps1
pwsh .\scripts\07-deploy-airunway-vllm.ps1
pwsh .\scripts\08-test-agentgateway-airunway-backend.ps1
pwsh .\scripts\09-install-native-gaie-comparison.ps1
pwsh .\scripts\10-test-native-gaie-multimodel.ps1
pwsh .\scripts\11-run-compatibility-spike.ps1
```

You can pass `-ConfigPath` to any script to point at a non-default config
file:

```powershell
pwsh .\scripts\01-provision-aks.ps1 -ConfigPath C:\path\to\my-lab.psd1
```

Cleanup is always last:

```powershell
pwsh .\scripts\99-cleanup.ps1                              # leave cluster running
pwsh .\scripts\99-cleanup.ps1 -DeleteCluster               # also delete the AKS cluster
pwsh .\scripts\99-cleanup.ps1 -DeleteResourceGroup         # also delete the whole RG
```

---

## What each script does

### `00-test-prerequisites.ps1`

Loads the lab configuration, asserts that `az`, `kubectl`, `helm`, `curl`
are on PATH, makes sure `az` is authenticated, sets the configured
subscription as active, and prints the active subscription name and
client-side `kubectl` version.

### `01-provision-aks.ps1`

Creates the resource group (idempotent) and creates the AKS cluster if
it does not already exist, with:

- Standard SKU control plane
- managed identity + OIDC issuer + workload identity
- Azure CNI Overlay + Cilium dataplane
- a dedicated `system` node pool with cluster autoscaler enabled
- the pod CIDR / service CIDR / DNS service IP from config

Finally it fetches kubeconfig (`az aks get-credentials`) and prints
`kubectl get nodes`.

### `02-install-agentgateway.ps1`

Installs:

- Kubernetes Gateway API CRDs (`standard-install.yaml` at the configured
  version)
- AgentGateway CRDs and controller via Helm (OCI chart
  `oci://cr.agentgateway.dev/charts/agentgateway[-crds]`)
- The lab `Gateway` resource named per `Routing.AgentGatewayGatewayName`
  in `Namespaces.AgentGateway`

Then it waits for the proxy Deployment to become Available.

### `03-deploy-semantic-router-simulator.ps1`

- Deploys the upstream simulator
  (`ghcr.io/llm-d/llm-d-inference-sim`) as `vllm-llama3-8b-instruct` in
  `default`.
- If a previous Semantic Router PVC used a different storage class than
  the cluster default, it uninstalls the release and deletes the PVC
  before reinstalling (avoids stuck pods on storage class mismatch).
- Renders `values/semantic-router-simulator.yaml` and installs the
  Semantic Router Helm chart
  (`oci://ghcr.io/vllm-project/charts/semantic-router`).
- Applies the AgentGateway backend, the HTTPRoute and the ExtProc
  `AgentgatewayPolicy` that points the Gateway at the Semantic Router
  service over gRPC port `50051`.

### `04-test-agentgateway-simulator.ps1`

Port-forwards the AgentGateway service to `localhost:<Test.PortForwardPort>`
and runs the `Simulator` prompts from `tests/smoke-prompts.psd1`
(math / science / general) through `/v1/chat/completions`. Asserts that
each call returns a non-empty completion.

### `05-install-airunway-kaito.ps1`

Installs:

- KAITO workspace operator via Helm (with NAP disabled —
  `disableNodeAutoProvisioning=true` so AI Runway controls node pool
  selection)
- AI Runway controller, dashboard and the KAITO provider shim from the
  pinned ref in `Versions.AirunwayRef`

Validates that `modeldeployments.airunway.ai` and
`inferenceproviderconfigs.airunway.ai` CRDs are present and that the AI
Runway / KAITO pods are running.

### `06-add-gpu-nodepool.ps1`

- Guards with `Confirm-CostApproval` when `RequireApproval = $true` in
  config.
- Creates the GPU node pool with the configured SKU, taints
  (`sku=gpu:NoSchedule`), labels (`workload=inference`), autoscaler
  min/max, zones, and Spot/Regular priority.
- If priority is `Spot`, patches the NVIDIA device plugin DaemonSet to
  tolerate `kubernetes.azure.com/scalesetpriority=spot:NoSchedule`.
- Bootstraps the `nvidia.com/gpu.present`, `nvidia.com/gpu.count`,
  `nvidia.com/gpu.product`, `nvidia.com/gpu.memory` and (when known)
  CUDA compute major/minor labels on the new GPU node, using a
  per-SKU defaults table (T4 / A100 / fallback).
- Waits up to 5 minutes for allocatable `nvidia.com/gpu >= 1` on a
  labelled node before returning.

### `07-deploy-airunway-vllm.ps1`

- Renders and applies `manifests/airunway/modeldeployment-primary.yaml`
  with the configured model id, namespace, GPU count and node selector
  / tolerations.
- Waits for the `ModelDeployment` to reach `phase = Running`.
- **Qwen-on-T4 remediation:** if the wait times out and the model is
  `Qwen/Qwen3-0.6B` on a T4 SKU, the script patches the generated
  StatefulSet's container command to append (or replace) the vLLM flag
  `--attention-backend TRITON_ATTN`, deletes the pod to let the
  StatefulSet recreate it, and re-waits.
- Prints the service name, port and in-cluster host of the model
  endpoint.

### `08-test-agentgateway-airunway-backend.ps1`

- Resolves the AI Runway model endpoint.
- Port-forwards the model service and calls `/v1/models` to discover the
  **served** model id (which the OpenAI-compatible request must use as
  its `model` field).
- Re-renders `values/semantic-router-airunway.yaml` with the discovered
  id and the model service host/port, and upgrades the Semantic Router
  Helm release to point at the AI Runway backend.
- Re-applies `manifests/agentgateway/routing-resources.yaml` so the
  AgentGateway backend + HTTPRoute target the AI Runway service. The
  HTTPRoute and AgentgatewayBackend are placed in the same namespace as
  the model service to satisfy the listener's allowed-routes policy.
- Port-forwards the AgentGateway and runs the `Airunway` prompts from
  `tests/smoke-prompts.psd1`. Asserts a non-empty completion comes back
  from the real model.

### `09-install-native-gaie-comparison.ps1`

Installs the second routing plane on the same cluster:

- Gateway API CRDs (idempotent, same version).
- GAIE CRDs at the configured version.
- Istio with `ENABLE_GATEWAY_API_INFERENCE_EXTENSION=true` via
  `istioctl install`.
- The comparison `Gateway` resource (gatewayClass `istio`) in
  `Namespaces.GatewayComparison`.
- The `body-based-routing` Helm chart from
  `oci://registry.k8s.io/gateway-api-inference-extension/charts/body-based-routing`.

### `10-test-native-gaie-multimodel.ps1`

- Detects whether a `Models.Secondary` is configured and how many GPUs
  are allocatable on the inference pool.
- Runs in one of three modes:
  - **Qwen-only** (default with this lab's config): tests only the
    primary model.
  - **Single-model fallback**: secondary is configured but GPU capacity
    is insufficient.
  - **Dual-model**: secondary is configured and capacity is sufficient;
    the secondary `ModelDeployment` is applied and waited on.
- Discovers whether AI Runway attached the route to the AgentGateway or
  to the comparison Istio gateway via
  `kubectl get modeldeployment ... -o jsonpath='{.status.gateway.gatewayNamespace}'`.
- Uses the gateway's public address from `gateway.status.addresses[0].value`
  when available (more reliable than a local port-forward), and falls
  back to port-forwarding the Istio ingress when needed.
- Issues `/v1/chat/completions` calls per model and asserts a model name
  comes back.

### `11-run-compatibility-spike.ps1`

The spike that captures whether AgentGateway external configuration
alone is enough to perform cross-model semantic routing across AI Runway
deployments:

- Snapshots inventory (`modeldeployments`, `inferencepools`,
  `httproutes`).
- Port-forwards AgentGateway and sends a probe per configured model.
- In single-model (qwen-only) mode, records that cross-model
  compatibility was not evaluated.
- In dual-model mode, considers the test passed only if at least two
  distinct `returnedModel` values are observed across the probes; if
  not, marks `adapterLikelyNeeded = true`.
- Writes the structured outcome to
  `tests/compatibility-spike-results.json`.

### `99-cleanup.ps1`

Scoped, idempotent teardown:

- Removes the spike artifacts, the comparison body-based-router release
  and the comparison Gateway.
- Removes the AgentGateway policy, HTTPRoute, backend, the Semantic
  Router and AgentGateway Helm releases.
- Removes the simulator deployment.
- Removes the configured primary `ModelDeployment` and, when configured,
  the secondary as well.
- Uninstalls the AI Runway controller / dashboard / KAITO provider shim
  and the KAITO workspace Helm release.
- Deletes the GPU node pool to stop accruing GPU cost.
- Optional: `-DeleteCluster` deletes the AKS cluster;
  `-DeleteResourceGroup` deletes the whole resource group.

---

## Verification and expected output

Approximate timing on `Standard_NC4as_T4_v3` Spot + 2x `Standard_D4ds_v5`
system nodes:

| Step | Wall-clock |
|------|-----------|
| 01 — `az aks create` | ~8 min |
| 02 — AgentGateway install | ~1 min |
| 03 — simulator + Semantic Router | ~3 min |
| 04 — simulator smoke tests | <30 s |
| 05 — AI Runway + KAITO | ~2 min |
| 06 — GPU node pool + labels | ~6 min |
| 07 — `qwen3-0-6b` ModelDeployment to `Running` (with Triton patch) | ~10 min |
| 08 — AgentGateway switch + smoke | ~2 min |
| 09 — Istio + GAIE + BBR | ~3 min |
| 10 — native qwen-only test | <30 s |
| 11 — compatibility spike | <30 s |

A successful run reports lines like:

```
==> Discovering served backend model ID
Discovered backend model id: qwen3-0.6b
...
==> Running AgentGateway -> AI Runway test: basic-completion
response model: qwen3-0.6b

==> AgentGateway backend replacement test complete

==> Using gateway address http://<gateway-public-ip>
==> Testing model routing for 'qwen3-0.6b'
returned model: qwen3-0.6b
==> Native GAIE comparison completed in qwen-only mode
```

The spike outcome on a qwen-only run looks like:

```json
{
  "summary": {
    "note": "Cross-model compatibility was not evaluated because only one model is configured.",
    "adapterLikelyNeeded": true,
    "externalConfigSufficient": false
  }
}
```

---

## Known issues and workarounds

| Symptom | Root cause | Fix in this repo |
|---------|-----------|------------------|
| `az aks nodepool add` is denied for `Standard_NC*` SKUs in `Regular` priority | Tenant Azure Policy denies non-Spot GPU node pools | Default `Aks.GpuPool.Priority = 'Spot'`. |
| NVIDIA device plugin pods stuck `Pending` on Spot GPU nodes | DaemonSet does not tolerate `kubernetes.azure.com/scalesetpriority=spot:NoSchedule` | Script `06` patches the DaemonSet to add the missing toleration. |
| KAITO refuses to schedule a `ModelDeployment` even though `nvidia.com/gpu` is allocatable | Required `nvidia.com/gpu.present`, `nvidia.com/gpu.count`, `nvidia.com/gpu.product`, `nvidia.com/gpu.memory` labels are missing on the new node | Script `06` bootstraps these labels with per-SKU defaults (T4 / A100) when they are missing. |
| New Spot GPU node replacement loses the manually applied labels | Spot eviction + replacement re-creates the node without re-running the label bootstrap | Re-run `scripts/06-add-gpu-nodepool.ps1` after eviction. |
| HTTPRoute is `Accepted: False` against the AgentGateway listener (`NotAllowedByListeners`) | Gateway listener policy was configured to allow routes only from `default` while the HTTPRoute was created in `agentgateway-system` | Routing templates split `__BACKEND_NAMESPACE__`, `__ROUTE_NAMESPACE__`, `__GATEWAY_NAMESPACE__` and place the route alongside the backend. |
| `400 Bad Request: model 'Qwen/Qwen3-0.6B' not found` from the AgentGateway path | The model id served by vLLM differs from `Models.Primary.Id` | Script `08` calls `/v1/models` on the backend and uses the discovered id. |
| qwen vLLM pod fails to start with `Could not find nvcc` (FLASHINFER), `Compute capability unsupported` (FLASH_ATTN) or `Backend TORCH_SDPA not registered` | The bundled vLLM build does not include nvcc for FlashInfer JIT, T4 compute capability is below FLASH_ATTN's requirement, and `TORCH_SDPA` is not registered in this image's backend list | Script `07` patches the generated StatefulSet command to append `--attention-backend TRITON_ATTN`, which is supported. |
| Native GAIE test fails with `response ended prematurely` over local port-forward | port-forward to the Istio ingress is flaky for first-byte timing | Script `10` prefers the Gateway's `status.addresses[0].value` (the public IP) and only falls back to port-forwarding when the address is empty. |
| Dual-model native GAIE comparison cannot run | Only 1 allocatable GPU available on a single T4 node | Script `10` runs in single-model mode automatically; provision a second GPU node (or larger SKU) for true dual-model. |

---

## Cleanup

```powershell
# Cost-control cleanup: removes the GPU node pool, all lab workloads and Helm releases,
# but leaves the AKS cluster and resource group intact.
pwsh .\scripts\99-cleanup.ps1

# Full teardown:
pwsh .\scripts\99-cleanup.ps1 -DeleteCluster
pwsh .\scripts\99-cleanup.ps1 -DeleteResourceGroup
```

---

## Security and cost notes

- GPU node pools are only created when `Aks.GpuPool.Enable = $true` in
  config; `Aks.GpuPool.RequireApproval = $true` additionally requires
  the operator to type `YES` interactively before provisioning.
- The lab uses internal access only (`kubectl port-forward`) for the
  smoke tests; nothing is exposed publicly by the lab itself. The native
  Istio gateway does get a public IP (which is intended for the
  comparison path) — make sure your environment is OK with that or
  configure a private gateway.
- Secrets must not be committed. Anything sensitive in `config/lab.psd1`
  stays local (the file is gitignored). The `.gitignore` also blocks
  common patterns (`*.env`, `*credentials*`, `*secret*`,
  `*.kubeconfig`, `*.tfstate*`, etc.).
- Cleanup scripts are scoped to the configured cluster, resource group,
  Helm releases and namespaces.

---

## References

- AI Runway repo: https://github.com/kaito-project/airunway
- AI Runway docs: https://github.com/kaito-project/airunway/blob/main/docs/gateway.md
- AI Runway providers: https://github.com/kaito-project/airunway/blob/main/docs/providers.md
- Tobias Fenster — Deploy LLMs on AKS with AI Runway:
  https://tobiasfenster.io/deploy-llms-on-azure-kubernetes-service-with-ai-runway
- Tobias Fenster — Easier network access for AI Runway:
  https://tobiasfenster.io/easier-network-access-for-ai-runway
- vLLM Semantic Router on Kubernetes with AgentGateway:
  https://vllm-semantic-router.com/docs/installation/k8s/agentgateway/
- AgentGateway: https://agentgateway.dev
- KAITO: https://github.com/kaito-project/kaito
- Gateway API Inference Extension (GAIE):
  https://github.com/kubernetes-sigs/gateway-api-inference-extension
