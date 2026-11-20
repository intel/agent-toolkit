# Perplexity SPACE: Integration Gaps

Status of [perplexityai/SPACE](https://github.com/perplexityai/SPACE) as a
sandbox backend for the Intel® AI Solutions stack, alongside the existing
[Agent Sandbox](agent-sandbox.md).

Assessed: 2026-11-17, upstream commit `70f35fd`. Rechecked 2026-11-20 at `a08174b`
(the pinned commit): there are still no releases, tags or published images.

---

## Summary

SPACE runs agent code in Firecracker microVMs. It offers VM isolation by
default, suspend/resume across nodes, egress allowlists by domain, and an
E2B-compatible API. Agent Sandbox lacks these features.

SPACE cannot be integrated as a supported component yet:

- **There are no official releases.** The repo has no GitHub releases or tags,
  and the project is pre-1.0.
- **There are no published images.** Every service image must be built from
  source and hosted by us.
- **Upstream calls its cluster install evaluation only.** It is not supported
  for production.
- **Two features have no on-premises implementation:** key management and
  credential injection.

Until these close, SPACE can only be offered as an opt-in evaluation backend,
disabled by default.

---

## Release and packaging gaps

| # | Gap | Evidence | Impact |
|---|---|---|---|
| R1 | **No official releases** | GitHub shows 0 releases and 0 tags. `Cargo.toml` has `version = "0.8.2"`, which exists only in source. | Nothing stable to pin in `configs/repos/repos.agent-toolkit.yaml`. We must pin a commit SHA. |
| R2 | **No published container images** | `ghcr.io/perplexityai/{space-api,space-data-plane,space-cluster-controller,space-worker}` returns `403` to anonymous pulls. The upstream values example uses `registry.example.com`. The only images CI pushes are build caches. | We must build every image from the Rust source and host it in our own registry. |
| R3 | **No published shim binary** | `containerd-shim-space-v2` is built from `shim/`. `install-shim.sh` expects us to supply the binary. | The shim needs a build pipeline and a way to distribute it to nodes. |
| R4 | **API not stable yet** | `docs/versioning.md`: 0.8.0 is the "public baseline", 0.9.0 is the "final planned breaking-change release", and 1.0.0 brings stable contracts. | Expect at least one more breaking upgrade before 1.0. |
| R5 | **No published Helm chart** | `space-cluster` (0.1.0) exists only in the repo, and its subcharts are symlinks into the Kind tree. | We install from a repo checkout. There is no chart repository or OCI chart to reference. |

---

## Deployment gaps

| # | Gap | Evidence | Impact |
|---|---|---|---|
| D1 | **Cluster install is evaluation only** | `infra/space/cluster/README.md`: *"This is a development and evaluation path. It is not a production deployment."* | We cannot claim production support on top of it. |
| D2 | **The install provisions none of the infrastructure it depends on** | The same README says Postgres, the object store, Redis, the key broker, the UI and metrics-server are "not installed". | Our roles must supply all of them (see [What the stack must add](#what-the-stack-must-add)). |
| D3 | **containerd is configured by hand** | `install-shim.sh` "never edits the containerd configuration or restarts containerd". | We must add the `space` runtime handler and re-apply it after kubespray runs, as we already do for Kata devmapper. |
| D4 | **Nodes need a btrfs `/space` layout** | Every worker and builder needs it. | This is a new node-prep step, backed by a spare disk or a file-backed loop device. |
| D5 | **Strict host requirements** | x86_64 with KVM, `/dev/net/tun`, loop devices, btrfs, and privileged node services. | Restricts which nodes can run SPACE. VMs need nested virtualization. |
| D6 | **No web console** | The UI chart is excluded from the cluster install. | Only the API is available. |
| D7 | **Overlap with Kata** | Both modify the containerd config and both target KVM nodes. | Decided: both may run on one node. Each adds its own managed block to `config.toml`. |

---

## Feature gaps on-premises

| # | Gap | Evidence | Impact |
|---|---|---|---|
| F1 | **No production key broker** | The chart requires an HTTPS intermediate-key broker. The only implementation in the repo is the Kind fixture, which upstream says "protect[s] nothing". | We must either build a broker, for example in front of OpenBao/Vault Transit, or run the fixture and accept that data at rest has no real encryption. |
| F2 | **Credential injection works only on AWS** | Credentials are resolved through AWS Secrets Manager and IAM (`SPACE_CREDMGR_SECRETS_MANAGER_ROLE_ARN`). Storage credentials are issued through AWS STS (`SPACE_CREDMGR_S3_VEND_ROLE_ARN`). | On-premises, secrets cannot be kept out of the guest unless we write a different backend. |
| F3 | **No native SDK** | The upstream example uses only the Python standard library. Clients use the REST API or the E2B SDK. | Agents written for `k8s-agent-sandbox` need code changes. |
| F4 | **E2B compatibility is partial** | Not supported: the `mcp`, `volumeMounts` and `iam` create options. Only the Python SDK is tested, not the JavaScript one (`docs/ecw.md`). | Some E2B-based agents will not work unchanged. |
| F5 | **No GPU support** | `docs/execution-environments.md`: "GPU assignment is not implemented." | Sandboxes are CPU-only. |
| F6 | **No ARM64** | No ARM64 environment is admitted until it passes qualification. | x86_64 only. |
| F7 | **No Intel-specific support** | The docs make no mention of TDX, SGX or Xeon tuning. | Confidential computing is not available. Xeon is expected to work, but only as generic x86_64 with KVM. |
| F8 | **Its own auth model** | SPACE issues its own user, service and per-command-session tokens. | Integration with our Keycloak is undefined. |
| F9 | **Redis needs a publicly trusted TLS certificate** | SPACE's Redis client accepts only TLS certificates from public CAs. | Our in-cluster Redis cannot be used. Without Redis, SPACE's rate limits are not enforced. |

---

## What the stack must add

| Area | Existing stack component | Work required |
|---|---|---|
| Images and shim | none | A CI build at a pinned commit and a hosting registry. Mirror for air-gapped installs. |
| Node prep | `roles/kata_containers` (KVM preflight) | A new `space_node` role in enterprise-ai-solutions: btrfs `/space`, the shim, the containerd handler, `/dev/net/tun` and loop devices, and node labels (`space.pplx.net/infra`, `space.pplx.net/node-pool`). |
| Cluster objects | none | The `space` RuntimeClass, the PriorityClasses, and the `space` and `sandboxes` namespaces. |
| Database | `roles/postgresql` (CNPG) | A `space` database and the role-password Secret. |
| Object store | `roles/object_store` (SeaweedFS) | The snapshot and template buckets, plus credentials. |
| Internal TLS | `roles/cert_manager` | An issuer and certificates for internal-api, node-api and build-manager. |
| Key broker | none | See F1. |
| Network policy | Calico | Set `internetExcept` to cover the pod, Service and node network ranges. |
| Service mesh | Istio | `space` joins the ambient mesh, with a namespace-wide PERMISSIVE policy for its host-network node services, plus a port-level PERMISSIVE exception on the object store. `sandboxes` stays outside the mesh. (Correction: `agent-sandbox-system` is in the ambient mesh too; only its sandbox pods opt out.) |
| Telemetry | OTel Collector to Tempo | Configure `otlp` mode and node-local receiver ports. |
| Install | none | A new `roles/space` role in this repo: render the values file, run the database migration Job, and install the `space` and `space-builder` releases. Then seed a template and warm pool and smoke-test through the E2B API. |
| Config | `config.agent-toolkit.yaml` | `space_enabled: false` (the default), `space_rev`, `space_src_dir`. Images are built during install, so there is no registry setting. |

---

## Integration status

An opt-in evaluation integration is in place on branches `feat/space-sandbox`
(this repo) and `feat/space-node` (enterprise-ai-solutions). See [SPACE](space.md).

| Gap | How the integration handles it |
|---|---|
| R1, R4 | Pinned to `space_rev` (a commit). |
| R2, R3, R5 | Built from source on the installer host during install, imported into containerd on the nodes, and charts installed from the checkout. |
| D1, D2 | The upstream cluster install, with every prerequisite supplied by our roles. |
| D3, D4, D5 | `space_node` (infrastructure layer) prepares the hosts and re-applies the containerd block on every install. |
| F1 | Fixture broker behind a TLS front: **evaluation only**. |
| F2, F4, F8 | Not addressed: no credential injection, no E2B API, SPACE's own API keys. |

## Upstream changes that would unblock integration

1. Tagged releases with published images, the shim binary and a packaged Helm chart (closes R1–R3 and R5).
2. A 1.0 release with stable API contracts (closes R4).
3. A production-supported Kubernetes install path (closes D1).
4. A pluggable or self-hostable key broker and credential backend, such as Vault or OpenBao (closes F1 and F2).

We should track these upstream and reassess at each release.

---

## References

- Repo: https://github.com/perplexityai/SPACE
- Docs: https://space.docs.perplexity.ai/guide/index.html
- Cluster install: `infra/space/cluster/README.md`
- Versioning: `docs/versioning.md`
- E2B compatibility: `docs/ecw.md`
- Blog: [Making SPACE](https://www.perplexity.ai/hub/blog/making-space-secure-and-efficient-runtimes-for-long-running-agents),
  [Escaping SPACE I](https://www.perplexity.ai/hub/blog/escaping-space-part-i),
  [Escaping SPACE II](https://www.perplexity.ai/hub/blog/escaping-space-part-ii)
