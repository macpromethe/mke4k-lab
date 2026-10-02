# Add-ons: NFS, MSR4, k0rdent UI

[← Back to README](../README.md)

## NFS StorageClass (optional)

| Command | Description |
|---|---|
| `t deploy nfs` | Setup NFS server + install CSI driver (cluster must exist) |
| `t connect nfs` | SSH to NFS server (direct or via bastion in airgap) |

Set `nfs_enabled=true` in `config` to automatically provision NFS during `t deploy lab` or `t deploy lab airgap`. Or use `t deploy nfs` to add NFS to an already-running cluster.

Creates a dedicated NFS server EC2 instance, installs `nfs-common` on all cluster nodes, and deploys the [`nfs-subdir-external-provisioner`](https://github.com/kubernetes-sigs/nfs-subdir-external-provisioner) Helm chart with a default `nfs-client` StorageClass.

**Airgap support:** `.deb` packages are downloaded on the bastion and transferred via SCP. The provisioner image (`registry.k8s.io/sig-storage/nfs-subdir-external-provisioner:v4.0.2`) is uploaded to a Harbor `nfs` project and the Helm chart is pulled on the bastion for offline install.

## MSR4 (Harbor) on cluster

| Command | Description |
|---|---|
| `t deploy msr4` | Deploy MSR4 (Harbor) on existing MKE4k cluster (online) |
| `t deploy msr4 airgap` | Deploy MSR4 via bastion Harbor registry (airgap) |

Set `msr4_enabled=true` in `config` to enable. Requires `nfs_enabled=true` for the PVC StorageClass; for HA (`msr4_replicas>=2`) you also need `worker_count >= msr4_replicas` — MKE4k taints controllers, so postgres/redis/harbor replicas only schedule on workers. `t deploy msr4` enforces this with a preflight die.

- **Simple mode** (`msr4_replicas=1`): single Harbor pod with built-in PostgreSQL + Redis.
- **HA mode** (`msr4_replicas>=2`): Zalando postgres-operator + OT-Container-Kit redis-operator installed as k0rdent `ServiceTemplate`s (Flux `HelmRepository` + k0rdent `ServiceTemplate`, namespace `k0rdent`). Harbor wired to external DB + Redis.

Exposed as `NodePort 33443` (HTTPS) on every cluster node. Two-tier TLS PKI; server cert SANs include `msr.<cluster>.local`, all node IPs, and all node EC2 DNS names, so `https://<any-node>:33443` validates without `-k`.

**Airgap support:** on `t deploy msr4 airgap`, the bastion pulls upstream images (skopeo) and charts (`helm pull`), then pushes them to Harbor under projects `postgres`, `redis`, `harbor`. The registry CA is added to the bastion's system trust so `helm push` over self-signed TLS works.

**Access:**
- Online: `https://msr.<cluster>.local:33443` (add `/etc/hosts: <node-public-ip> msr.<cluster>.local`) or `https://<node-public-dns>:33443`
- Airgap: `t tunnel msr4` -> `https://localhost:8444` (requires `/etc/hosts: 127.0.0.1 msr.<cluster>.local` if you want to use the FQDN URL)
- Admin credentials: generated on first deploy, saved to `terraform/msr4_credentials.txt`

### Examples

#### Deploy MSR4 (Harbor) on a running MKE4k cluster

MSR4 needs a StorageClass, so deploy with NFS first, then add MSR4.

```bash
# config
nfs_enabled=true          # provides the nfs-client StorageClass MSR4 needs
msr4_enabled=true
msr4_replicas=1           # simple mode: built-in DB + Redis
```

```bash
t deploy lab              # cluster + NFS StorageClass
t deploy msr4             # then MSR4 on top
```

Access: `https://msr.<cluster>.local:33443` (add the node public IP to `/etc/hosts`) or `https://<node-public-dns>:33443`. Admin password is written to `terraform/msr4_credentials.txt`.

#### Deploy HA MSR4 (postgres-operator + redis-operator)

HA schedules replicas only on workers (controllers are tainted), so you need `worker_count >= msr4_replicas`.

```bash
# config
worker_count=2            # must be >= msr4_replicas
nfs_enabled=true
msr4_enabled=true
msr4_replicas=2           # HA mode: external postgres + redis operators
```

```bash
t deploy lab
t deploy msr4
```

#### Deploy MSR4 on an airgap MKE4k cluster

```bash
# config
nfs_enabled=true
msr4_enabled=true
```

```bash
t deploy lab airgap
t deploy msr4 airgap      # images/charts mirrored to the bastion Harbor
t tunnel msr4             # then browse https://localhost:8444  (needs -p 8444:8444)
```

## k0rdent UI

| Command | Description |
|---|---|
| `t deploy k0rdent-ui` | Rotate the k0rdent UI password and publish it over HTTPS (Envoy gateway + NLB listener) |
| `t destroy k0rdent-ui` | Remove the k0rdent UI gateway resources |

Set `k0rdent_ui_enabled=true` in `config` to do this during `t deploy lab`. Online: `https://<nlb-dns>:8445`. Airgap: `t tunnel k0rdent-ui` → `https://localhost:8445`. The password is saved to `terraform/k0rdent_ui_credentials.txt`.
