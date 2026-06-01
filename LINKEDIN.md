# Bringing AI Runway, the vLLM Semantic Router and native Gateway API Inference Extension together on a single AKS cluster

A few weeks ago I started with a fairly direct question. AI Runway from the KAITO project is a clean way to declare LLM model deployments on AKS using vLLM and Gateway API. The vLLM Semantic Router project plus AgentGateway is a clean way to do classifier-driven routing in front of model backends. Could the two be combined on the same cluster, on real GPUs, and could the result be compared against the native Istio plus Gateway API Inference Extension path that AI Runway already integrates with?

The short answer is yes, on one important caveat that I will get to at the end. The longer answer is a runnable lab that I have now open-sourced. This article walks through what it does, the design decisions behind it and the real, non-glamorous environment issues that had to be solved to get an end-to-end run on AKS.

## What the lab is

The lab is a set of PowerShell scripts that drive an end-to-end deployment on AKS. From a fresh subscription it will:

1. Create an AKS cluster with secure Day-0 defaults: Standard SKU control plane, managed identity, OIDC issuer, workload identity, Azure CNI Overlay with Cilium dataplane and a dedicated system node pool with the cluster autoscaler on.
2. Install AgentGateway and the vLLM Semantic Router Helm chart, validate the path with the upstream llm-d inference simulator, and run a deterministic smoke prompt set through the classifier-routed pipeline.
3. Install AI Runway, KAITO and the KAITO provider shim that AI Runway uses.
4. Add a Spot GPU node pool to control cost, patch the NVIDIA device plugin to tolerate the Spot taint, and bootstrap the GPU node labels that KAITO expects.
5. Deploy Qwen3-0.6B as an AI Runway ModelDeployment on that GPU node.
6. Switch the AgentGateway and Semantic Router backend from the simulator to the AI Runway service, and re-run the smoke tests against the real model.
7. Install Istio with the Gateway API Inference Extension enabled, plus the body-based router Helm chart, as the native AI Runway multi-model comparison path.
8. Run a structured compatibility spike that records whether AgentGateway external configuration alone is enough to perform cross-model semantic routing across multiple AI Runway deployments.

There is one cluster, two parallel routing planes, and a structured artifact that captures the outcome of the spike on every run.

## How the components actually connect

The AgentGateway path looks like this. The client sends an OpenAI-compatible chat completion request to a Gateway resource. AgentGateway intercepts it via an ExtProc policy that calls the Semantic Router gRPC service. The Semantic Router classifies the request body, picks a routing decision and returns it to AgentGateway. AgentGateway then forwards the request to the AgentgatewayBackend, which points at either the simulator service or the AI Runway-managed vLLM service.

The native path looks different. AI Runway creates the InferencePool and HTTPRoute itself. Istio with the inference extension enabled serves the Gateway. The body-based router Helm chart picks the InferencePool based on the request body. The request hits the same KAITO-managed vLLM model server underneath.

The same model service can be reached through either plane. That is what makes the spike honest.

## The non-glamorous parts that mattered

This is the part that usually does not make it into a blog post but is exactly where time goes in real environments.

First, tenant policy. Many enterprise Azure tenants deny non-Spot GPU node pools by default. The lab defaults to Spot priority so it works on those tenants out of the box. Spot brings its own consequence. Eviction and replacement of the GPU node drops manually applied labels, so the GPU label bootstrap step has to be idempotent and re-runnable.

Second, NVIDIA device plugin tolerations. The default DaemonSet does not tolerate the Spot taint, so on a Spot GPU pool the device plugin pods sit Pending and the node never reports allocatable GPUs. The lab patches the DaemonSet to add the missing toleration and waits for the rollout.

Third, GPU node labels. KAITO does not just require allocatable nvidia.com/gpu. It also requires presence, count, product, memory and optionally CUDA compute major and minor labels. On a freshly added Spot node these labels are not always populated. The lab bootstraps them with sensible per-SKU defaults for T4 and A100.

Fourth, Gateway API listener namespace policy. AgentGateway enforces that the HTTPRoute attaching to a Gateway listener has to satisfy the listener's allowedRoutes policy. Co-locating the HTTPRoute with the backend service while keeping the Gateway in its own namespace solved a NotAllowedByListeners acceptance failure I hit. The routing templates split backend namespace, route namespace and gateway namespace as three separate tokens for exactly this reason.

Fifth, served model id discovery. The id that vLLM serves is not always identical to the string passed to ModelDeployment.spec.model.id. Case, slashes and prefixes can differ. Calling the model server's /v1/models endpoint and using the returned id is the only reliable way to construct an OpenAI-compatible request that does not 400 with "model not found".

Sixth, and this was the longest yak shave, the vLLM attention backend on a T4 GPU. The default FLASHINFER path tries to JIT-compile and needs nvcc in the container image, which is not present in the bundled image. FLASH_ATTN does not support the T4 compute capability. TORCH_SDPA was not registered as a backend in the build I was running. TRITON_ATTN was. The lab detects qwen-on-T4 and patches the generated StatefulSet container command to append the --attention-backend TRITON_ATTN flag, deletes the pod and re-waits.

These are the kinds of things that an end-to-end lab forces you to confront. None of them are bugs in any of the upstream projects on their own. They are integration realities at a specific point on the version matrix.

## The compatibility spike outcome

This is the question I started with. Can AgentGateway, with only external configuration and the upstream Semantic Router, perform cross-model semantic routing across multiple AI Runway model deployments?

On the versions tested in the lab the answer is no. The AgentGateway route currently behaves as a single fixed backend. To get true cross-model routing, an adapter or additional logic is required between the Semantic Router decision and the backend selection. The spike records this outcome to a JSON artifact every run, so it is straightforward to re-evaluate on a new version of any of the three projects without having to re-derive the conclusion.

Importantly, this is not a negative result about AI Runway, the Semantic Router or AgentGateway individually. Each of them does what they advertise. The result is about the integration surface between them at this specific version combination, and it is the kind of thing the community is actively iterating on.

## What I would use this for

If you operate AKS for a team that wants to serve open-weights LLMs and you are evaluating either AI Runway, the vLLM Semantic Router or both, this lab gives you a known-good end-to-end starting point that runs on a single Spot T4 GPU. You can read each script, understand the integration assumptions, and then either adopt the patterns directly or swap them out for your own infra-as-code.

If you are doing comparison work between AgentGateway-driven semantic routing and the native Istio plus Gateway API Inference Extension path, having both planes on the same cluster against the same model server removes a lot of noise from the comparison.

If you are working upstream on any of the three projects, the spike artifact and the script-level remediations are the kind of concrete signal that is easier to act on than a long bug report.

## Where to find it

The lab is open source at github.com/anihitk07/airunway-semantic-router-lab. The README is a complete operator runbook, including the full execution order, the known issues and their workarounds, and the expected timings on a single Spot T4 node.

If you try it on a different GPU SKU, a different region, or a different combination of versions, I would be very interested in the diff. The spike artifact format is intentionally small and machine-readable so that comparing outcomes across environments is straightforward.

Thanks to the maintainers of AI Runway, KAITO, the vLLM Semantic Router, AgentGateway, the Gateway API Inference Extension, Istio and the KAITO provider shim. The hard work is theirs. This lab is just the integration glue with the lights on.
