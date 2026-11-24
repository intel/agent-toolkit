# SPACE (Firecracker microVM sandboxes)

> **Evaluation only.** SPACE has no upstream releases or published images, and
> this integration uses the upstream *fixture* key broker, whose keys protect
> nothing: sandbox data at rest is not really encrypted. Do not put sensitive
> data in SPACE sandboxes.

[perplexityai/SPACE](https://github.com/perplexityai/SPACE) runs agent code in
Firecracker microVMs. Each sandbox has its own guest kernel and can be
suspended to object storage and woken on any node. It is installed **next to**
[Agent Sandbox](agent-sandbox.md). The two are independent: each has its own
switch, namespaces, runtime and API, and either can run without the other.

| | Agent Sandbox | SPACE |
|---|---|---|
| Switch (`config.agent-toolkit.yaml`) | `agent_sandbox_enabled` | `space_enabled` (default off) |
| Namespaces | `agent-sandbox-system` | `space` (control plane), `sandboxes` (sandbox pods), `space-observability` |
| Isolation | Pod (runc), or Kata microVM | Firecracker microVM, always |
| Runtime | `kata-fc`/`kata-qemu` RuntimeClass (optional) | `space` RuntimeClass, `containerd-shim-space-v2` |
| Node label | `ei-kata-eligible` | `node.kubernetes.io/space-enabled` |
| Clients | `k8s-agent-sandbox` SDK through the router | **E2B SDK** (E2B-compatible API), or SPACE's REST API |

SPACE and Kata can share KVM workers: each adds its own block to
`/etc/containerd/config.toml`.

---

## Enable it

```yaml
# env/<name>/config.agent-toolkit.yaml
space_enabled: true
```

```bash
./toolkit_manager.sh install agent-toolkit --env <name>
```

| Setting | Default | Description |
|---|---|---|
| `space_enabled` | `false` | Install SPACE (`space`) and prepare its hosts (`space_node`) |
| `space_rev` | `a08174b…` | Pinned upstream commit (upstream has no tags yet) |
| `space_e2b_enabled` | `true` | E2B-compatible API on `api.e2b.<base>` and `*.e2b.<base>` |
| `space_public_enabled` | `true` | SPACE's native API on `space.<base>` and `space-dp.<base>` |
| `space_cache_size_gb` | `100` | Virtual size of each worker's sparse btrfs `/space/cache` |

`config.agent-toolkit.yaml` also sets `gateway_extra_wildcard_domains` to
`e2b.<base_domain_name>` while SPACE and E2B are on, so the platform gateway
serves the E2B wildcard (see [Gateway](#gateway)).

### Requirements

| Where | Requirement |
|---|---|
| Workers | x86_64 with `/dev/kvm` (Intel VT-x enabled in the BIOS on bare metal, or nested virtualisation on a VM) and `/dev/vhost-vsock`. The installer loads `kvm_intel` and `vhost_vsock` itself; it cannot turn on VT-x (`kvm_intel: VMX not enabled (by BIOS)`). |
| Workers | Disk for a sparse btrfs cache image (`space_cache_size_gb`). |
| First SPACE worker (the build host) | About 40 GB free under `space_src_dir` and `/var/lib`. The first build compiles the Rust workspace and can take an hour or more; later runs reuse BuildKit's cache. No Docker: cluster nodes must not run Docker, because kubespray would remove it. BuildKit is installed when missing (`space_buildkit_version`). |
| Platform | PostgreSQL, SeaweedFS (object store), cert-manager and the gateway, all on by default. |
| Cluster | Provisioned by this installer. SPACE is not supported on a BYO cluster (`existing_kubernetes`) or on OpenShift, because host preparation runs over SSH. |

---

## What the install does

**Infrastructure layer, `space_node` (enterprise-ai-solutions).** On every worker:
1. Checks KVM and vsock (the check is shared with Kata).
2. Installs `btrfs-progs`.
3. Runs the upstream node layer (`infra/space/kind/node`) as systemd units before kubelet: SPACE accounts, the `/space` layout, the cgroup subtree, loop devices, and a btrfs `/space/cache`.
4. Stages Firecracker 1.15.1 and its guest kernel.
5. Registers the `space` runtime handler in containerd, in the `config.toml` format it finds (version 2 or 3). Re-applied on every install, because kubespray rewrites the file.

It then labels the ready workers and applies the `space` RuntimeClass and the SPACE PriorityClasses.

**Agent-toolkit layer, `space`:**
1. **Build** SPACE at `space_rev` on the first SPACE worker: the service images, the containerd shim and the seed template. Only missing artifacts are built.
   - BuildKit (unit `space-buildkitd`) runs as a containerd worker in the cluster's `k8s.io` namespace, so the images are usable there without an import. Its state lives under `/var/lib/containerd/io.space.buildkit`, so a cluster reset clears it together with the layers it points at.
   - Upstream's build scripts call `docker`; a shim turns `docker build` into `buildctl` and every other command into `nerdctl`, passes the proxy settings into builds, and lets later builds use the images built before them.
   - Other workers import an image archive. Every worker gets the containerd shim.
2. **Secrets and TLS.** The Secrets the upstream install needs, and the internal TLS identities through cert-manager. Generated Secrets are created once and never rotated by a re-run.
3. **Platform services.** A PostgreSQL database (`space`) and object-store buckets (`space-snapshots`, `space-templates`).
4. **Key broker.** The fixture key broker behind an Envoy TLS front.
5. **Install.** Upstream `infra/space/cluster/install.sh`: the migration Job, then the `space` and `space-builder` releases.
6. **Seed and API keys.** Publishes the seed template and mints the agents' API keys.
7. **Gateway.** Publishes the native and E2B hosts.

The control plane runs on the SPACE workers: on a cluster with separate
workers, kubespray taints the control-plane nodes.

### Database: no superuser

SPACE shares the platform's PostgreSQL. Its `space` login has CREATEROLE and
CREATEDB, and may set `log_statement`, and nothing more:

- SPACE's migrator creates its own logins (`space_user`, `space_ro`, …) and gives its break-glass role CREATEDB CREATEROLE. PostgreSQL 16+ lets a non-superuser grant CREATEDB only if it has it.
- It turns statement logging off before it sets those logins' passwords, so they never reach the server log (`GRANT SET ON PARAMETER log_statement`).
- Upstream's comment asks for a superuser, but the migrator works without one: `space_superadmin` is then limited to CREATEDB CREATEROLE.

PostgreSQL 16+ limits CREATEROLE to the roles the login created, so SPACE
cannot alter Keycloak's, LiteLLM's or Langfuse's logins, databases or data.

### Object store

The node services use static keys for the SPACE buckets (`storageCredentials:
static`, upstream's local mode) instead of an AWS-style token exchange.

### Network

- **Mesh.** `space` joins the ambient mesh, so it reaches PostgreSQL and the object store over mTLS. A namespace-wide `PERMISSIVE` PeerAuthentication admits the host-network node services and the sandboxes. `sandboxes` stays outside the mesh, so the upstream sandbox NetworkPolicy applies. A port-level `PERMISSIVE` exception (`space-node-s3`) in the object-store namespace admits the node services on the S3 port.
- **Sandbox → node-api.** Traffic to a sandbox pod's IP on 9800 is forwarded to `node-api` on the pod's own node. Upstream relies on pod-to-own-node traffic bypassing NetworkPolicy; Calico applies the sandbox egress policy to it, and that policy denies the private ranges the node address is in. `space-sandbox-to-node-api` allows sandbox pods TCP 9800 to the SPACE nodes' addresses only.
- **LiteLLM.** With SPACE on, LiteLLM admits the pod network (`litellm_allow_pod_network`), as it does for OpenShell.

### Gateway

Both APIs are published through the core `gateway` role, as other components
publish, and exempt from the gateway's Keycloak JWT: SPACE authenticates every
request with its own API key.

| Surface | Hosts | Listener |
|---|---|---|
| E2B | `api.e2b.<base>` → API, `*.e2b.<base>` → data plane (`<port>-<sandbox-id>.e2b.<base>`) | `https-e2b-<base>` on `*.e2b.<base>`, with its own certificate |
| Native | `space.<base>` → API, `space-dp.<base>` → data plane | the platform's `*.<base>` listener |

The platform certificate covers one label under the base domain, so the E2B
wildcard has its own listener and certificate (`gateway_extra_wildcard_domains`,
see `docs/customize/configuration.md` in enterprise-ai-solutions). The E2B SDK
sends headers with underscores (`lang_version`, `sdk_runtime`), which Envoy
Gateway rejects by default; the ClientTrafficPolicy `space-e2b-listener`
allows them on the E2B listener only.

---

## Use it

The agents' keys and endpoints are in the Secret `space-api-key` in `space`:

| Key | For |
|---|---|
| `E2B_API_KEY`, `E2B_DOMAIN` | E2B SDK clients |
| `SPACE_API_TOKEN` | SPACE's native API |
| `SPACE_API_URL`, `SPACE_DATA_PLANE_URL` | Native API in the cluster (`space-api-entry.space:8080`, `space-data-plane-entry.space:8090`) |
| `SPACE_API_PUBLIC_URL`, `SPACE_DATA_PLANE_PUBLIC_URL` | Native API on the gateway |

Each key serves one surface.

### E2B SDK

SPACE has no SDK of its own; its E2B-compatible API lets agents use the E2B
SDK unchanged:

```python
import os
from e2b import Sandbox

sandbox = Sandbox.create(
    api_key=os.environ["E2B_API_KEY"],
    domain=os.environ["E2B_DOMAIN"],      # e2b.<base_domain_name>
    template="seed",
)
try:
    print(sandbox.commands.run("printf 'Hello from SPACE\\n'").stdout)
finally:
    sandbox.kill()
```

```bash
export E2B_API_KEY=$(kubectl -n space get secret space-api-key -o jsonpath='{.data.E2B_API_KEY}' | base64 -d)
export E2B_DOMAIN=$(kubectl -n space get secret space-api-key -o jsonpath='{.data.E2B_DOMAIN}' | base64 -d)
```

The client needs `api.e2b.<base>` and `*.e2b.<base>` to resolve to the gateway,
and, with the default self-signed gateway, to trust
`env/<name>/logs/ai-solutions-ca.crt` (for example `SSL_CERT_FILE`).

Upstream tests ECW with the Python SDK `e2b==2.21.1` and `e2b-code-interpreter==2.6.2`.
The JavaScript SDK is untested, and the create options `mcp`, `volumeMounts`
and `iam` are not supported (`docs/ecw.md` in the SPACE repository).

### Native API

For SPACE-only features (suspend and wake to object storage, file APIs with
change tracking, command sessions) use the REST API
(<https://space.docs.perplexity.ai/api/index.html>). Upstream's
standard-library walkthrough creates a sandbox from `seed`, runs a command and
offers to delete it:

```bash
export SPACE_API_URL=https://space.<base> SPACE_DATA_PLANE_URL=https://space-dp.<base>
export SPACE_API_TOKEN=$(kubectl -n space get secret space-api-key -o jsonpath='{.data.SPACE_API_TOKEN}' | base64 -d)
python3 ~/.cache/ai-solutions/space/src/examples/first_sandbox.py
```

With the native routes published, the API hands clients the public data-plane
URL, and the walkthrough refuses any other origin: point it at the public
hosts, not at a port-forward. With `space_public_enabled: false`, port-forward
`svc/space-api-entry 8080` and `svc/space-data-plane-entry 8090` instead.

---

## Verify

```bash
./toolkit_manager.sh validate space --env <name> --only
```

`validate` checks that every SPACE Deployment is available and every scheduled
DaemonSet is ready, then creates a sandbox, runs a command and deletes it:

- through the native API (the public hosts when published, else port-forwards);
- through the E2B SDK (`e2b==2.21.1`, in a venv next to `space_src_dir`), when E2B is on.

It resolves the SPACE hosts to the gateway itself (`files/run_via_gateway.py`),
so the installer host needs no DNS for the domain.

```bash
kubectl get runtimeclass space
kubectl get nodes -l node.kubernetes.io/space-enabled=true
kubectl get pods -n space
kubectl get pods -n sandboxes
```

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `space` install stops: "nodes are not prepared" | `space_node` did not run, or no worker passed its checks. Re-run `install`, and read the `space_node` per-node results. |
| A worker is missing from `space_node`'s ready list | Check `/dev/kvm` (`grep -c vmx /proc/cpuinfo`; 0 means VT-x is off in the BIOS) and `/dev/vhost-vsock`, then `systemctl status space-layout space-cache` and `findmnt /space/cache`. |
| Build fails: `content digest … not found` | BuildKit's cache points at layers a cluster reset deleted (state kept outside containerd's root by an older version of this role). `systemctl stop space-buildkitd; rm -rf /var/lib/space-buildkit`, then re-run `install space`. |
| Build `RUN apt-get` cannot reach its mirrors | The build host's proxy is not set: the shim passes `HTTP(S)_PROXY`/`NO_PROXY` from `http_proxy`, `https_proxy`, `no_proxy` in `global_config.yaml`. |
| Sandbox create fails: `storage credential exchange is not configured` | A node service still uses the token exchange; `storageCredentials: static` must be set for it in the install values. |
| Sandbox commands time out: `phase: proxy_unreachable` | Sandbox pods cannot reach `node-api` on their node: check the NetworkPolicy `space-sandbox-to-node-api` in `sandboxes` lists the node addresses. |
| `401: Jwt is not in the form of Header.Payload.Signature` | The route lacks the gateway auth exemption; re-run `install space`. |
| E2B SDK: `StreamReset … error_code:2` (or `400` over HTTP/1.1) | The E2B listener rejects underscore headers: check the ClientTrafficPolicy `space-e2b-listener` in the gateway namespace. |
| Sandbox pod `FailedCreatePodSandBox` | The shim or the containerd handler is missing on that node: `ls /usr/local/bin/containerd-shim-space-v2`, `crictl info \| jq '.config.containerd.runtimes \| keys'`. |
| `install.sh: missing prerequisites` | A Secret or namespace is missing. Re-run install; the role creates them all. |
| Mesh calls to PostgreSQL or the object store refused after a node reboot | Pods that started before ztunnel get no mesh listener: `kubectl -n istio-system logs ds/ztunnel \| grep "pod keep received"` names them; restart those pods. |

---

## Teardown

```bash
./toolkit_manager.sh teardown space --only        # releases, namespaces, routes, mesh exception, E2B policy
./toolkit_manager.sh teardown space_node --only   # RuntimeClass, PriorityClasses, node labels
```

`teardown agent-toolkit` includes `space`. `space_node` is in the
infrastructure layer, so it is removed with that layer or by name.

These stay:
- the `space` database and buckets, as for other platform consumers;
- the build cache and E2B venv (`~/.cache/ai-solutions/space`) and the `space-buildkitd` unit on the build host;
- the host setup on the nodes. To remove it from a node:

```bash
sudo systemctl disable --now space-cache space-layout space-cgroup space-loop-nodes space-runtime-supervisor space-buildkitd
sudo rm -f /etc/systemd/system/space-{cache,layout,cgroup,loop-nodes,buildkitd}.service
sudo umount /space/cache; sudo rm -rf /space /opt/space-kind /usr/local/lib/space /var/lib/space-cache.img /etc/space
sudo rm -rf /var/lib/containerd/io.space.buildkit
sudo rm -f /usr/local/bin/containerd-shim-space-v2*
# remove the "space runtime (managed)" block from /etc/containerd/config.toml, then:
sudo systemctl restart containerd
```

---

## Limits

- **Fixture key broker:** sandbox data at rest is not really encrypted.
- **No credential injection:** SPACE resolves credential references through AWS Secrets Manager only.
- **No custom template builds:** no node is labelled for the builder pool, so the `space-builder` release schedules no pods. Sandboxes use the published `seed` template.
- **No web console:** the upstream UI is not installed.
- **Gateway certificates:** removing a domain from `gateway_extra_wildcard_domains` removes its listener, but its certificate stays until deleted by hand.
