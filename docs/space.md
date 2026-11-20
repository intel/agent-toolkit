# SPACE (Firecracker microVM sandboxes)

> **Evaluation only.** SPACE has no upstream releases or published images, and
> this integration uses the upstream *fixture* key broker, whose keys protect
> nothing: sandbox data at rest is not really encrypted. Do not put sensitive
> data in SPACE sandboxes. See [SPACE integration gaps](space-integration-gaps.md).

[perplexityai/SPACE](https://github.com/perplexityai/SPACE) runs agent code in
Firecracker microVMs. Each sandbox has its own guest kernel and can be
suspended to object storage and woken on any node. It is installed **next to**
[Agent Sandbox](agent-sandbox.md). The two are independent: each has its own
switch, namespaces, runtime and API, and either can run without the other.

| | Agent Sandbox | SPACE |
|---|---|---|
| Switch (`config.agent-toolkit.yaml`) | `agent_sandbox_enabled` (default on) | `space_enabled` (default off) |
| Namespaces | `agent-sandbox-system` | `space` (control plane), `sandboxes` (sandbox pods), `space-observability` |
| Isolation | Pod (runc), or Kata microVM | Firecracker microVM, always |
| Runtime | `kata-fc`/`kata-qemu` RuntimeClass (optional) | `space` RuntimeClass, `containerd-shim-space-v2` |
| Node label | `ei-kata-eligible` | `node.kubernetes.io/space-enabled` |
| Client | `k8s-agent-sandbox` SDK through the router | SPACE REST API |

SPACE and Kata can share KVM workers: each adds its own block to
`/etc/containerd/config.toml`.

---

## Enable it

```yaml
# env/<name>/config.agent-toolkit.yaml
space_enabled: true
```

```bash
./es_auto_installer.sh install agent-toolkit
```

The pinned commit is `space_rev` in the same file. Upstream has no tags yet.

### Requirements

| Where | Requirement |
|---|---|
| Workers | x86_64 with `/dev/kvm` (Intel VT-x on bare metal, or nested virtualisation on a VM) and `/dev/vhost-vsock`. The installer loads `kvm_intel` and `vhost_vsock` itself. |
| Workers | Disk for a sparse btrfs cache image (`space_cache_size_gb`, default 100 GB virtual). |
| Installer host | Docker, with privileged builds allowed, and about 40 GB free under `space_src_dir` and Docker's data root. The first build compiles the Rust workspace and can take an hour or more. Later runs reuse it. |
| Platform | PostgreSQL, SeaweedFS (object store) and cert-manager, all on by default. |
| Cluster | Provisioned by this installer. SPACE is not supported on a BYO cluster (`existing_kubernetes`) or on OpenShift, because host preparation runs over SSH. |

---

## What the install does

**Infrastructure layer, `space_node` (enterprise-ai-solutions).** On every worker:
1. Checks KVM and vsock. The check is shared with Kata.
2. Installs `btrfs-progs`.
3. Runs the upstream node layer (`infra/space/kind/node`) as systemd units before kubelet: SPACE accounts, the `/space` layout, the cgroup subtree, loop devices, and a btrfs `/space/cache`.
4. Stages Firecracker 1.15.1 and its guest kernel.
5. Registers the `space` runtime handler in containerd. This is re-applied on every install, because kubespray rewrites `config.toml`.

It then labels the ready workers and applies the `space` RuntimeClass and the SPACE PriorityClasses.

**Agent-toolkit layer, `space`:**
1. **Build.** Builds SPACE at `space_rev` on the installer host: the service images, the containerd shim and the seed template. It imports the images into containerd on each SPACE worker and installs the shim there. Only missing artifacts are built.
2. **Secrets and TLS.** Creates the Secrets the upstream install needs, and the internal TLS identities through cert-manager. Generated Secrets are created once and never rotated by a re-run.
3. **Platform services.** Gets a PostgreSQL database (`space`) and object-store buckets (`space-snapshots`, `space-templates`) from the platform.
4. **Key broker.** Deploys the fixture key broker behind an Envoy TLS front.
5. **Install.** Runs upstream `infra/space/cluster/install.sh`: the migration Job, then the `space` and `space-builder` releases.
6. **Seed and API key.** Publishes the seed template and mints an API key for agents.

The control plane runs on the SPACE workers. On a cluster with separate
workers, kubespray taints the control-plane nodes.

### Istio

- `space` joins the ambient mesh, so it reaches PostgreSQL and the object store over mTLS.
- A namespace-wide `PERMISSIVE` PeerAuthentication admits the SPACE node services, which use the host network, and the sandboxes.
- `sandboxes` stays outside the mesh, so the upstream sandbox NetworkPolicy applies.
- A port-level `PERMISSIVE` exception (`space-node-s3`) in the object-store namespace lets the node services read templates and write snapshots.
- With SPACE on, LiteLLM admits the pod network (`litellm_allow_pod_network`), as it does for OpenShell.

---

## Use it

Agents use the native REST API with the minted key:

```bash
kubectl -n space get secret space-api-key -o jsonpath='{.data.SPACE_API_TOKEN}' | base64 -d
```

The Secret also holds `SPACE_API_URL` and `SPACE_DATA_PLANE_URL`:

| | In-cluster URL |
|---|---|
| API | `http://space-api-entry.space.svc.cluster.local:8080` |
| Data plane | `http://space-data-plane-entry.space.svc.cluster.local:8090` |

From a workstation, port-forward both Services and run upstream's walkthrough.
It creates a sandbox from `seed:latest`, runs a command and offers to delete
the sandbox:

```bash
kubectl -n space port-forward svc/space-api-entry 8080:8080 &
kubectl -n space port-forward svc/space-data-plane-entry 8090:8090 &
export SPACE_API_URL=http://127.0.0.1:8080 SPACE_DATA_PLANE_URL=http://127.0.0.1:8090
export SPACE_API_TOKEN=$(kubectl -n space get secret space-api-key -o jsonpath='{.data.SPACE_API_TOKEN}' | base64 -d)
python3 ~/.cache/ai-solutions/space/src/examples/first_sandbox.py
```

The API reference is at <https://space.docs.perplexity.ai/api/index.html>.
`POST /v1/sandboxes/{id}:suspend` and `:wake` save a sandbox to object storage
and restore it.

Not in this release:
- The E2B-compatible API (ECW). The minted key is for the native API only.
- Custom template builds. No node is labelled for the builder pool, so the `space-builder` release schedules no pods.
- A web console.

---

## Verify

```bash
./es_auto_installer.sh validate agent-toolkit
```

`validate` checks that every SPACE Deployment is available and every scheduled
DaemonSet is ready. It then runs upstream's walkthrough end to end: create a
sandbox, run a command, delete it.

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
| A worker is missing from `space_node`'s ready list | Check `/dev/kvm` and `/dev/vhost-vsock`, then `systemctl status space-layout space-cache` and `findmnt /space/cache`. |
| Sandbox pod `FailedCreatePodSandBox` | The shim or the containerd handler is missing on that node. Check `ls /usr/local/bin/containerd-shim-space-v2` and `containerd config dump \| grep runtimes.space`. |
| `install.sh: missing prerequisites` | A Secret or namespace is missing. Re-run install, because the role creates them all. |
| Image pull errors for `localhost/space/...` | The images were not imported on that node. Check `ctr -n k8s.io images ls \| grep localhost/space`. |

---

## Teardown

```bash
./es_auto_installer.sh teardown space --only        # SPACE releases, namespaces, mesh exception
./es_auto_installer.sh teardown space_node --only   # RuntimeClass, PriorityClasses, node labels
```

`teardown agent-toolkit` includes `space`. `space_node` is in the
infrastructure layer, so it is removed with that layer or by name.

These stay:
- the `space` database and buckets, as for other platform consumers;
- the build cache on the installer host (`~/.cache/ai-solutions/space`).

The host setup stays on the nodes too. To remove it from a node:

```bash
sudo systemctl disable --now space-cache space-layout space-cgroup space-loop-nodes space-runtime-supervisor
sudo rm -f /etc/systemd/system/space-{cache,layout,cgroup,loop-nodes}.service
sudo umount /space/cache; sudo rm -rf /space /opt/space-kind /usr/local/lib/space /var/lib/space-cache.img /etc/space
sudo rm -f /usr/local/bin/containerd-shim-space-v2*
# remove the "space runtime (managed)" block from /etc/containerd/config.toml, then:
sudo systemctl restart containerd
```

---

## Unverified on a real cluster

These steps follow upstream's Kind path and are marked `TODO(spike)` in the code:

1. Whether upstream's Kind node layer runs unchanged on a real host. Related: whether the Firecracker jailer needs `/dev/vhost-vsock` added to its jails. Upstream's Kind-only `vsock-jails` unit does that, and it is not installed here.
2. The release-mode build through `build-rust-artifacts.sh` outside Tilt.
3. The SeaweedFS S3 pod label (`app.kubernetes.io/component: s3`) that the mesh exception selects.
