# mke4k-lab

A standalone AWS lab provisioning tool for [Mirantis Kubernetes Engine 4k](https://www.mirantis.com/software/mke-4/) and MKE3.

Terraform provisions a dedicated VPC, EC2 instances, NLB, and IAM role; `mkectl apply` / `launchpad apply` installs the product. Supports four deployment modes: **MKE4k** (default), **MKE3** (for upgrade testing), **MKE4k Airgap** (true network isolation with a private registry), and **MKE3 Airgap** (MKE3 in network isolation with proxy-based MCR installation).

## Quick Start

### Option A — Docker (recommended)

```bash
# Build the image (terraform providers pre-initialised during build)
docker build -t mke4k-lab .

# First run — name the container so you can re-attach later
docker run -it --name mke4k-lab \
  -e AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
  -e AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
  mke4k-lab

# For airgap deployments, add port mappings for UI tunnels
#   3000 = MKE4k/MKE3 Dashboard, 8443 = Harbor registry UI, 8444 = MSR4 (Harbor) UI
docker run -it --name mke4k-lab \
  -e AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
  -e AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
  -p 3000:3000 -p 8443:8443 -p 8444:8444 \
  mke4k-lab
```

Once inside the container:
```bash
vi /mke4k-lab/config      # edit cluster settings
t deploy lab              # MKE4k: provision EC2 + NLB, then install
t deploy lab mke3         # MKE3:  provision + launchpad apply
t deploy lab airgap       # Airgap: bastion + registry + MKE4k (no internet on nodes)
t deploy lab mke3-airgap  # MKE3 Airgap: bastion + registry + proxy + MKE3
t show nodes              # print IPs
t destroy lab             # teardown
```

**Re-attaching after exit** — `terraform.tfstate`, `mke4.yaml`, and `aws_private.pem` live inside the container, so keep it around:
```bash
docker start -ai mke4k-lab
```

To copy the SSH key or state out to your host:
```bash
docker cp mke4k-lab:/mke4k-lab/terraform/aws_private.pem .
docker cp mke4k-lab:/mke4k-lab/terraform/terraform.tfstate .
```

### Option B — Local (requires tools installed)

#### Prerequisites

- AWS credentials (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`)
- `terraform` >= 0.14.3
- `mkectl`
- `kubectl`
- `jq`, `yq`

### 1. Edit config

```bash
vi config
```

```bash
cluster_name="mke4k-lab"       # auto-suffixed with random 4-char ID (e.g. mke4k-lab-a3f2)
controller_count=1
worker_count=1
cluster_flavor="m5.xlarge"
region="eu-central-1"
mke4k_version="v4.1.2"
os_distro="ubuntu-22.04"       # ubuntu-22.04 or ubuntu-24.04
```

### 2. Export AWS credentials

```bash
export AWS_ACCESS_KEY_ID="..."
export AWS_SECRET_ACCESS_KEY="..."
```

### 3. Deploy

```bash
./bin/t deploy lab
```

This will:
1. Run `terraform init` + `terraform apply` (provisions dedicated VPC + EC2 + NLB + IAM)
2. Generate `terraform/mke4.yaml` from the provisioned infrastructure
3. Run `mkectl apply -f terraform/mke4.yaml`

## CLI Commands

### MKE4k (default)

| Command | Description |
|---|---|
| `t deploy lab` | Full deployment: Terraform + mkectl apply |
| `t deploy instances` | Terraform only (provision infrastructure) |
| `t deploy cluster` | mkectl only (install MKE4k on existing instances) |
| `t destroy cluster` | Uninstall MKE4k (mkectl reset --force) |
| `t destroy lab` | Teardown all AWS infrastructure (terraform destroy) |

### MKE3

| Command | Description |
|---|---|
| `t deploy lab mke3` | Full: Terraform (both NLBs) + launchpad apply |
| `t deploy instances mke3` | Terraform with MKE3 NLB enabled |
| `t deploy cluster mke3` | launchpad apply on existing instances |
| `t destroy cluster mke3` | Uninstall MKE3 (launchpad reset --force) |

### Airgap (MKE4k)

| Command | Description |
|---|---|
| `t deploy lab airgap` | Full: Terraform + registry setup + bundle upload + mkectl (from bastion) |
| `t deploy instances airgap` | Terraform only (bastion + private-subnet nodes) |
| `t deploy registry` | Setup MSR4 on bastion + download & upload MKE4k bundle |
| `t deploy cluster airgap` | mkectl apply from bastion (registry must exist) |
| `t destroy cluster airgap` | Uninstall MKE4k from bastion (mkectl reset) |

### Airgap (MKE3)

| Command | Description |
|---|---|
| `t deploy lab mke3-airgap` | Full: Terraform + registry + proxy + MKE3 images + launchpad (from bastion) |
| `t deploy instances mke3-airgap` | Terraform only (bastion + private-subnet nodes + both NLBs) |
| `t deploy registry mke3` | Setup MSR4 on bastion + download & upload MKE3 images |
| `t deploy cluster mke3-airgap` | DNS + proxy + launchpad apply from bastion |
| `t destroy cluster mke3-airgap` | Uninstall MKE3 from bastion (launchpad reset) |

### NFS StorageClass (optional)

| Command | Description |
|---|---|
| `t deploy nfs` | Setup NFS server + install CSI driver (cluster must exist) |
| `t connect nfs` | SSH to NFS server (direct or via bastion in airgap) |

Set `nfs_enabled=true` in `config` to automatically provision NFS during `t deploy lab` or `t deploy lab airgap`. Or use `t deploy nfs` to add NFS to an already-running cluster.

Creates a dedicated NFS server EC2 instance, installs `nfs-common` on all cluster nodes, and deploys the [`nfs-subdir-external-provisioner`](https://github.com/kubernetes-sigs/nfs-subdir-external-provisioner) Helm chart with a default `nfs-client` StorageClass.

**Airgap support:** `.deb` packages are downloaded on the bastion and transferred via SCP. The provisioner image (`registry.k8s.io/sig-storage/nfs-subdir-external-provisioner:v4.0.2`) is uploaded to a Harbor `nfs` project and the Helm chart is pulled on the bastion for offline install.

### MSR4 (Harbor) on cluster

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

### KOF (observability & FinOps) on cluster

| Command | Description |
|---|---|
| `t deploy kof` | Deploy KOF self-monitoring stack on existing MKE4k cluster (online) |
| `t destroy kof` | Uninstall KOF (helm uninstall + delete namespace) |

KOF (k0rdent Observability & FinOps) is deployed in **online self-monitoring (M2M) mode**: the MKE4k cluster stores its own metrics, logs, and traces locally — no regional cluster, no child `ClusterDeployment`, no external DNS, no Istio. Targets KOF 1.8.x as shipped with k0rdent Enterprise 1.3.2 (MKE 4.2.0).

Set `kof_enabled=true` in `config` to auto-deploy KOF at the end of `t deploy lab`, or run `t deploy kof` against an already-running cluster. It **requires a StorageClass** — set `nfs_enabled=true` (or run `t deploy nfs`) first; the deploy resolves the cluster default StorageClass, falling back to `nfs-client`, and dies with an actionable message if neither exists.

KOF installs as a **FluxCD-sequenced OCI umbrella Helm chart** (`oci://registry.mirantis.com/k0rdent-enterprise/charts/kof`) via **helm v3** (helm v4 has a webhook bug). The committed, version-pinned asset `kof/global-values.yaml` repoints every subchart image to `registry.mirantis.com/k0rdent-enterprise`; `kof_registry` is an override seam for a future airgap pass. The deploy is idempotent (`helm upgrade -i`).

The umbrella and mothership charts default every k0rdent (KCM) namespace to `kcm-system`, but MKE4k's k0rdent Enterprise build runs k0rdent in the `k0rdent` namespace. `kof_kcm_namespace` (default `k0rdent`) repoints all of them — the umbrella Flux `HelmRepository`/`HelmChart` objects, the KCM integration, and the per-`ServiceTemplate` Flux repos created by mothership's pre-install hooks — and the preflight dies if that namespace is missing. Because this is self-monitoring only, the `kof-regional` and `kof-child` charts (regional/child cluster templates) are disabled.

Before installing, `t deploy kof` exempts the `kof` namespace and the `opentelemetry-operator` service account from MKE4k's built-in `ucpauthz` admission policy (via `mkectl config get` → patch `spec.apiServer.ucpauthz` → `mkectl apply`). Without this, the OpenTelemetry operator is blocked from creating its collector DaemonSets, so node/host-log collection silently never starts. The step is idempotent — it merges into any existing exemptions and skips the (heavyweight) `mkectl apply` when `kof` is already exempt.

**Grafana (opt-in):** Mirantis no longer ships Grafana with KOF. Set `kof_grafana_enabled=true` to have `t deploy kof` enable the `grafana-operator` + the mothership's datasources/dashboards/admin-secret, then apply a pinned Grafana instance CR (`kof/grafana.yaml`). The image is pinned to `<kof_registry>/grafana/grafana:<kof_grafana_image_tag>` (default tag `11.0.0` — the doc's `10.4.18-security-01` is not in the k0rdent-enterprise registry; use whatever tag your registry actually has). Access by port-forward: `kubectl -n kof port-forward svc/grafana-vm-service 3000:3000`; admin creds in secret `grafana-admin-credentials`.

**Grafana over HTTPS (opt-in, touches terraform):** Set `kof_grafana_gateway_enabled=true` (requires `kof_grafana_enabled=true`) to expose Grafana via a dedicated Envoy **Gateway API** gateway instead of port-forward. `t deploy kof` then also runs `terraform apply` to add an NLB listener (`kof_grafana_lb_port`, default `8443`) + a security-group rule for a pinned Envoy NodePort (`kof_grafana_nodeport`, default `33002`), and applies `kof/grafana-gateway.yaml` (a self-contained `Issuer`/`Certificate`/`EnvoyProxy`/`Gateway`/`HTTPRoute` in the `kof` namespace, on the `mke-gateway-ingress` GatewayClass). TLS is self-signed (cert SANs = NLB DNS + node public IPs), terminated at the gateway; the NLB listener is plain TCP pass-through. Access: `https://<nlb-dns>:8443` (or `https://<node-public-ip>:33002`) — no `/etc/hosts` needed (dedicated listener, no host routing). dex/OIDC is not wired (Grafana's admin login is used).

**Access (built-in VMUI, always available):**
- Logs: `kubectl -n kof port-forward svc/kof-storage-victoria-logs-cluster-vlselect 9471:9471` → `http://localhost:9471/select/vmui/`
- Metrics: `kubectl -n kof port-forward svc/vmselect-cluster 8481:8481` → `http://localhost:8481/select/0/vmui/`
- Unified auth proxy: `svc/vmauth:8427` (basic-auth; the Grafana datasources point here)

### Tunnels (airgap)

| Command | Description |
|---|---|
| `t tunnel` | Show available SSH tunnels with manual commands |
| `t tunnel dashboard` | MKE4k Dashboard tunnel -> https://localhost:3000 |
| `t tunnel mke3` | MKE3 Dashboard tunnel -> https://localhost:3000 |
| `t tunnel registry` | Harbor Registry tunnel -> https://localhost:8443 |
| `t tunnel msr4` | MSR4 Harbor UI tunnel -> https://localhost:8444 |

### General

| Command | Description |
|---|---|
| `t status` | Show cluster node status (`kubectl get nodes`) |
| `t show nodes` | Print IPs and NLB DNS name |
| `t connect bastion` | SSH to bastion/registry host (airgap only) |
| `t connect nfs` | SSH to NFS server (when `nfs_enabled=true`) |
| `t connect m1` | SSH to controller-1 (via ProxyCommand when airgap) |
| `t connect w1` | SSH to worker-1 |
| `t connect <node> "cmd"` | Run a single command on a node |

## Project Structure

```
mke4k-lab/
├── config                        # User-edited config (edit this)
├── bin/
│   ├── t                         # Thin launcher
│   ├── t-commandline.bash        # CLI implementation
│   └── cleanup-aws.sh            # Emergency AWS cleanup (when state is lost)
└── terraform/
    ├── vpc.tf                    # Dedicated VPC, IGW, public subnet, route table
    ├── main.tf                   # Provider, SG, keypair, AMI lookup
    ├── variables.tf              # Variable declarations
    ├── controller.tf             # Controller EC2 instances
    ├── worker.tf                 # Worker EC2 instances
    ├── loadbalancer.tf           # MKE4k NLB + IP-type target groups + listeners
    ├── mke3_loadbalancer.tf      # MKE3 NLB (conditional on mke3_enabled)
    ├── airgap.tf                 # Bastion + private subnet (conditional on airgap_enabled)
    ├── nfs.tf                    # NFS server EC2 (conditional on nfs_enabled)
    ├── iam.tf                    # IAM role + CCM policy + instance profile
    └── outputs.tf                # lb_dns_name, IPs, ssh key path, bastion IPs, NFS IPs
```

## What Terraform Creates

### Always created

| Resource | Details |
|---|---|
| `aws_vpc` + `aws_internet_gateway` | Dedicated VPC (`172.31.0.0/16`) with IGW — full isolation per lab |
| `aws_subnet` (public) | `172.31.0.0/24` with `map_public_ip_on_launch` |
| `tls_private_key` + `aws_key_pair` | RSA-4096 key pair, PEM saved to `terraform/aws_private.pem` |
| `aws_security_group` | Ports 22, 443, 6443, 9443, 33001, 30080 + intra-cluster |
| `aws_instance` (controllers) | Ubuntu, `m5.xlarge` (configurable), 50GB gp3 |
| `aws_instance` (workers) | Same as controllers |
| `aws_lb` (NLB) | Public NLB in public subnet (internal in airgap) |
| `aws_lb_target_group` x3 | kube-api (6443), controller-join (9443), ingress (33001) — all **IP-type** |
| `aws_iam_role` + `aws_iam_policy` | AWS CCM minimum permissions (when `ccm_enabled`, auto-disabled in airgap) |
| `aws_iam_instance_profile` | Attached to all EC2 instances (when `ccm_enabled`) |

### MKE3 mode (`mke3_enabled`)

| Resource | Details |
|---|---|
| `aws_lb` (MKE3 NLB) | Second NLB for MKE3 UI (443) + API (6443) — IP-type targets. Internal when `airgap_enabled` |

### Airgap mode (`airgap_enabled`)

| Resource | Details |
|---|---|
| `aws_subnet` (private) | `172.31.1.0/24`, no IGW route — true network isolation |
| `aws_route_table` | Only local VPC routing (no internet) |
| `aws_instance` (bastion) | Public subnet, configurable size, runs MSR4 (Harbor) |
| `aws_lb` (NLB) | Switched to **internal**, placed in private subnet |
| Controllers + workers | Placed in the private subnet (no public IPs), CCM auto-disabled |

### NFS mode (`nfs_enabled`)

| Resource | Details |
|---|---|
| `aws_instance` (NFS server) | Public subnet (online) or private subnet (airgap). Runs `nfs-kernel-server` |

## After Deployment

```bash
# Check node status
t status

# SSH to a controller
t connect m1

# Use kubectl directly
kubectl --kubeconfig ~/.mke/mke.kubeconf get nodes

# Airgap: access MKE4k Dashboard (requires -p 3000:3000 on docker run)
t tunnel dashboard
# then browse https://localhost:3000

# Airgap: access MKE3 Dashboard (requires -p 3000:3000 on docker run)
t tunnel mke3
# then browse https://localhost:3000

# Airgap: access Harbor UI (requires -p 8443:8443 on docker run)
t tunnel registry
# then browse https://localhost:8443

# Airgap: access MSR4 (Harbor) UI (requires -p 8444:8444 on docker run)
t tunnel msr4
# then browse https://localhost:8444

# Teardown
t destroy lab
```

## Configuration Reference

### Shared infrastructure

| Variable | Default | Description |
|---|---|---|
| `cluster_name` | `mke4k-lab` | Name prefix for all resources. Left as default, a random 4-char suffix is auto-appended (e.g. `mke4k-lab-a3f2`) to avoid collisions between users. Persisted in `.cluster-id` |
| `controller_count` | `1` | Number of controller nodes (use 3 for HA) |
| `worker_count` | `1` | Number of worker nodes |
| `cluster_flavor` | `m5.xlarge` | EC2 instance type |
| `region` | `eu-central-1` | AWS region |
| `os_distro` | `ubuntu-22.04` | OS: `ubuntu-22.04` or `ubuntu-24.04` |
| `ccm_enabled` | `true` | Creates IAM role; required for LoadBalancer services. Auto-disabled in airgap |
| `debug` | `false` | `true` adds `-l debug` to mkectl (all modes including airgap) |

### MKE4k settings

| Variable | Default | Description |
|---|---|---|
| `mke4k_version` | `v4.1.2` | MKE4k / mkectl version |

### MKE3 settings

| Variable | Default | Description |
|---|---|---|
| `launchpad_version` | `1.5.15` | Launchpad binary version (no `v` prefix) |
| `mke3_version` | `3.8.2` | MKE3 version |
| `mcr_version` | `25.0.14` | MCR (Docker engine) version |
| `mcr_channel` | `stable-25.0.14` | Must match `mcr_version` exactly |
| `mke3_admin_username` | `admin` | MKE3 UI admin user |

### Airgap settings

| Variable | Default | Description |
|---|---|---|
| `airgap_registry_flavor` | `t3.xlarge` | EC2 instance type for the bastion/registry host |
| `airgap_registry_disk_gb` | `100` | Root volume size (GB) for bastion (Harbor data + bundle) |
| `airgap_msr_version` | `v4.13.3` | MSR4 (Harbor) offline installer version |
| `mke4k_bundle_url` | *(auto)* | Override the MKE4k bundle download URL |
| `mke3_bundle_url` | *(auto)* | Override the MKE3 image bundle download URL |

### NFS settings

| Variable | Default | Description |
|---|---|---|
| `nfs_enabled` | `false` | Provisions NFS server EC2, installs nfs-common on nodes, deploys nfs-subdir-external-provisioner |
| `nfs_flavor` | `t3.small` | EC2 instance type for the NFS server |
| `nfs_disk_gb` | `50` | Root volume size (GB) for the NFS server |
| `nfs_export_path` | `/srv/nfs/data` | NFS export path on the server |

### MSR4 settings

| Variable | Default | Description |
|---|---|---|
| `msr4_enabled` | `false` | Enables `t deploy msr4` / `t deploy msr4 airgap` (standalone; not auto-run during `t deploy lab`) |
| `msr4_version` | `4.13.3` | Harbor chart version deployed on the cluster (separate from `airgap_msr_version` which controls the bastion registry) |
| `msr4_replicas` | `1` | `1` = simple (built-in DB+Redis); `>=2` = HA (postgres-operator + redis-operator). HA requires `worker_count >= msr4_replicas` |
| `msr4_postgres_version` | `1.15.1` | Zalando postgres-operator chart version (HA only) |
| `msr4_redis_operator_version` | `0.24.0` | OT-Container-Kit redis-operator chart version (HA only) |
| `msr4_redis_replication_version` | `0.16.13` | OT-Container-Kit redis-replication chart version (HA only) |
| `msr4_storage_size` | `10Gi` | PVC size for the MSR4 registry volume (requires `nfs_enabled=true`) |

### KOF settings

| Variable | Default | Description |
|---|---|---|
| `kof_enabled` | `false` | Auto-deploy KOF (self-monitoring/M2M) at the end of `t deploy lab`. `t deploy kof` works standalone regardless. Requires a StorageClass |
| `kof_version` | `1.8.1` | KOF Helm umbrella-chart version (matches k0rdent Enterprise 1.3.2 / MKE 4.2.0) |
| `kof_storage_size` | `10Gi` | PVC size for the VictoriaMetrics / VictoriaLogs / VictoriaTraces volumes (doc default is 100Gi) |
| `kof_registry` | `registry.mirantis.com/k0rdent-enterprise` | Image/chart registry. Override seam for future airgap; leave default for online |
| `kof_kcm_namespace` | `k0rdent` | Namespace where k0rdent (KCM) runs. KOF's upstream default is `kcm-system`, but MKE4k's k0rdent Enterprise uses `k0rdent`; the KOF Flux objects + KCM integration are created here |
| `kof_grafana_enabled` | `false` | Deploy Grafana (grafana-operator + datasources/dashboards + the `kof/grafana.yaml` instance CR). Grafana is no longer shipped with KOF by default |
| `kof_grafana_image_tag` | `11.0.0` | Grafana image tag in `<kof_registry>/grafana/grafana` (the registry ships `11.0.0`, not the doc's `10.4.18-security-01`) |
| `kof_grafana_gateway_enabled` | `false` | Expose Grafana over HTTPS via a dedicated Envoy Gateway + NLB listener (requires `kof_grafana_enabled`). **Touches terraform** — `t deploy kof` runs `terraform apply` |
| `kof_grafana_nodeport` | `33002` | NodePort the Grafana Envoy gateway is pinned to (opened in the cluster SG; NLB target group forwards here). Range 32768-35535 |
| `kof_grafana_lb_port` | `8443` | NLB listener port for Grafana (TCP pass-through; the gateway terminates TLS) |

## Airgap Architecture

The airgap deployment creates true network isolation: cluster nodes in a private subnet with no internet access, and a bastion/registry host in a public subnet running MSR4 (Harbor).

```
                    Internet
                       |
              +--------+--------+
              |  Dedicated VPC  |
              |   172.31.0.0/16   |
              |                 |
    +---------+---------+       |
    |   Public Subnet   |       |
    |   172.31.0.0/24     |       |
    |   (has IGW)       |       |
    |                   |       |
    |  +-----------+    |       |
    |  |  Bastion  |    |       |
    |  |  (MSR4)   |<---+------+-- SSH from user
    |  |  Pub IP   |    |       |
    |  +-----------+    |       |
    +---------+---------+       |
              | (VPC routing)   |
    +---------+---------+       |
    |  Private Subnet   |       |
    |  172.31.1.0/24    |       |
    |  (no IGW route)   |       |
    |                   |       |
    |  +-----------+    |       |
    |  | Int. NLB  |<---+------+-- kubectl / MKE UI (via tunnel)
    |  +-----------+    |       |
    |  +------------+   |       |
    |  | Controller |   |       |
    |  | (priv IP)  |   |       |
    |  +------------+   |       |
    |  +------------+   |       |
    |  |   Worker   |   |       |
    |  | (priv IP)  |   |       |
    |  +------------+   |       |
    +-------------------+       |
              +-----------------+
```

**Traffic flows (MKE4k airgap):**
- User -> Bastion: SSH (port 22) via public IP
- User -> NLB: via SSH tunnel through bastion (NLB is internal, not internet-facing)
- NLB -> Cluster nodes: ports 6443, 9443, 33001 via private IPs (IP-type targets, supports hairpin)
- Cluster nodes -> Bastion: Harbor registry (443) via bastion private IP (VPC routing)
- Bastion -> Cluster nodes: SSH (22) for mkectl (VPC routing)
- Cluster nodes -> Internet: **blocked** (no IGW route in private subnet)

**Additional traffic flows (MKE3 airgap):**
- Cluster nodes -> Bastion: Squid proxy (3128) for MCR APT package installation
- Squid proxy -> Internet: HTTPS CONNECT to `*.mirantis.com`, `*.docker.com`, `*.ubuntu.com` (whitelisted domains only)
- Cluster nodes -> Bastion: Docker image pulls from Harbor `mke3` project (443)
- MKE3 NLB (internal): ports 443 (MKE3 UI) + 6443 (kube-api) — same private subnet as MKE4k NLB

## Emergency Cleanup

If you lose Terraform state (e.g. removed the Docker container), use the cleanup script to find and delete resources by cluster tag:

```bash
./bin/cleanup-aws.sh <cluster-name> [region]
# e.g.
./bin/cleanup-aws.sh mke4k-lab-a3f2 eu-central-1
```

The script shows all discovered resources first, then asks for confirmation before each deletion step.
