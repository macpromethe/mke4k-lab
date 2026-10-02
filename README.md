# mke4k-lab

A standalone AWS lab provisioning tool for [Mirantis Kubernetes Engine 4k](https://www.mirantis.com/software/mke-4/) and MKE3.

Terraform provisions a dedicated VPC, EC2 instances, NLB, and IAM role; `mkectl apply` / `launchpad apply` installs the product. Supports four deployment modes: **MKE4k** (default), **MKE3** (for upgrade testing), **MKE4k Airgap** (true network isolation with a private registry), and **MKE3 Airgap** (MKE3 in network isolation with proxy-based MCR installation). An online MKE4k lab can also provision an **MKE4k child cluster** on AWS through k0rdent / Cluster API (`t deploy child-cluster`).

## Quick Start

### Option A — Prebuilt Docker image (easiest)

The latest image is always published to `registry.ci.mirantis.com/ajagiello/mke4k-lab:latest`, so you can skip the build entirely:

```bash
# Pull the prebuilt image
docker pull registry.ci.mirantis.com/ajagiello/mke4k-lab:latest

# First run — name the container so you can re-attach later
docker run -it --name mke4k-lab registry.ci.mirantis.com/ajagiello/mke4k-lab:latest

# For airgap deployments, add port mappings for UI tunnels
#   3000 = MKE4k/MKE3 Dashboard, 8443 = Harbor registry / KOF Grafana, 8444 = MSR4 (Harbor) UI
docker run -it --name mke4k-lab \
  -p 3000:3000 -p 8443:8443 -p 8444:8444 \
  registry.ci.mirantis.com/ajagiello/mke4k-lab:latest
```

> **AWS credentials** — you don't have to pass them at `docker run` time. Once inside the container just export them in the shell:
> ```bash
> export AWS_ACCESS_KEY_ID="..."
> export AWS_SECRET_ACCESS_KEY="..."
> ```
> If you'd rather inject them up front, add `-e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY` to the `docker run` command (passes them through from your host env).

> The bastion's Harbor registry UI is reachable directly at `https://<bastion-public-ip>` (the bastion has a public IP and the SG opens 443), so no port mapping or tunnel is needed for it.

### Option B — Build the Docker image yourself

```bash
# Build the image (terraform providers pre-initialised during build)
docker build -t mke4k-lab .

# First run — name the container so you can re-attach later
docker run -it --name mke4k-lab mke4k-lab

# For airgap deployments, add port mappings for UI tunnels
#   3000 = MKE4k/MKE3 Dashboard, 8443 = Harbor registry / KOF Grafana, 8444 = MSR4 (Harbor) UI
docker run -it --name mke4k-lab \
  -p 3000:3000 -p 8443:8443 -p 8444:8444 \
  mke4k-lab
```

As with Option A, export `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` inside the container (or pass `-e` at `docker run` time).

Once inside the container:
```bash
export AWS_ACCESS_KEY_ID="..."        # if not already passed via -e on docker run
export AWS_SECRET_ACCESS_KEY="..."
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

### Option C — Local (requires tools installed)

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
controller_flavor="m5a.xlarge"
worker_flavor="m5a.large"
region="eu-central-1"
mke4k_version="v4.2.0"
os_name="ubuntu"               # cluster node OS: ubuntu or redhat
os_version="22.04"             # ubuntu: 22.04/24.04 | redhat: 9.6/8.10
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

## Recipes

Each recipe is just **(1) a handful of edits in `config`** + **(2) one command**. All of them assume you're already inside the container (`docker start -ai mke4k-lab`) with AWS credentials exported. Only the lines that differ from the shipped `config` are shown.

### Deploy MKE4k v4.2.0 (online)

```bash
# config
ccm_enabled=true          # enable for LoadBalancer services / EBS volumes
```

```bash
t deploy lab
```

### Deploy MKE4k v4.2.0 — HA control plane (3 controllers)

```bash
# config
controller_count=3        # must be odd
worker_count=2
ccm_enabled=true
```

```bash
t deploy lab
```

### Deploy MKE4k v4.2.0 airgap

Cluster nodes sit in a private subnet with no internet; a bastion runs Harbor and the bundle is mirrored locally. CCM is auto-disabled (no AWS API from the private subnet).

```bash
# config
airgap_registry_disk_gb=100      # holds Harbor + the mirrored bundle
```

```bash
t deploy lab airgap
```

> Airgap bundles only exist for GA versions. If your chosen `mke4k_version` has no published bundle, either pick a GA version or set `mke4k_bundle_url=` to a reachable bundle.

### Deploy MSR4 (Harbor) on a running MKE4k cluster

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

### Deploy HA MSR4 (postgres-operator + redis-operator)

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

### Deploy MSR4 on an airgap MKE4k cluster

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

### Deploy KOF observability (with Grafana over HTTPS)

Grafana and its HTTPS gateway are on by default, and `nfs_enabled=true` (the shipped default) provides the StorageClass KOF's PVCs need — so one line is enough:

```bash
# config
kof_enabled=true          # auto-runs at the end of 't deploy lab'
```

```bash
t deploy lab
# Grafana: https://<nlb-dns>:8443  (login printed in the deploy summary)
```

The default scope is `lean` (cluster monitoring only). For the complete observability + FinOps platform set `kof_mode="full"` — or skip `kof_enabled` entirely and deploy later on the running cluster:

```bash
t deploy kof              # lean (default)
t deploy kof full         # full platform
```

### Deploy KOF on an airgap cluster

The MKE 4.2.0 offline bundle ships all KOF charts and images, so the bastion's Harbor already has everything after `t deploy lab airgap`. The Grafana gateway is auto-enabled in airgap (it is the only path to Grafana).

```bash
# config
kof_enabled=true          # auto-runs at the end of 't deploy lab airgap'
```

```bash
t deploy lab airgap
# or on an existing airgap cluster:
t deploy kof airgap       # add full|lean before 'airgap' to override kof_mode

t tunnel grafana          # then browse https://localhost:8443  (needs -p 8443:8443)
```

### Deploy an MKE4k child cluster (k0rdent / CAPI on AWS)
```bash
# config (defaults shown; optional)
child_control_plane_count=1
child_worker_count=1
# child_worker_flavor="m5.large"   # advanced settings: region, instance types, AZs, timeouts
```

```bash
t deploy lab                      # online MKE4k management cluster first
t deploy child-cluster            # ~15 min -> UI URL + admin login + terraform/child.kubeconfig
t status child                    # MkeChildConfig status + child nodes
t destroy child-cluster           # or just 't destroy lab' — it deletes the child first
```

See [MKE4k child cluster](#mke4k-child-cluster-online-mke4k-only) for prerequisites, credentials and teardown.

### Deploy MKE3 v3.8.2, then test the in-place upgrade to MKE4k

```bash
# config
mke3_version="3.8.2"
mke4k_version="v4.2.0"    # the upgrade target (shipped default)
```

```bash
t deploy lab mke3         # provisions both NLBs + launchpad apply
# the deploy summary prints a ready-to-paste mkectl upgrade command
```

## CLI Commands

### MKE4k (default)

| Command | Description |
|---|---|
| `t deploy lab` | Full deployment: Terraform + mkectl apply |
| `t deploy instances` | Terraform only (provision infrastructure) |
| `t deploy cluster` | mkectl only (install MKE4k on existing instances) |
| `t destroy cluster` | Uninstall MKE4k (mkectl reset --force) |
| `t destroy lab` | Teardown all AWS infrastructure (terraform destroy); deletes any child cluster first |

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
| `t deploy kof [full\|lean]` | Deploy KOF self-monitoring stack on existing MKE4k cluster (online). Mode defaults to `kof_mode` (`lean`) |
| `t deploy kof [full\|lean] airgap` | Deploy KOF from the bastion against the internal registry (airgap) |
| `t destroy kof` | Uninstall KOF (helm uninstall + delete namespace; auto-detects airgap) |

KOF (k0rdent Observability & FinOps) is deployed in **self-monitoring (M2M) mode**: the MKE4k cluster stores its own metrics, logs, and traces locally — no regional cluster, no child `ClusterDeployment`, no external DNS, no Istio. Targets KOF 1.8.x as shipped with k0rdent Enterprise 1.3.2 (**requires MKE 4.2.0+**). Two scopes: `full` (complete observability + FinOps platform) and `lean` (cluster monitoring only — drops tracing, FinOps, and dead dashboards). The default is `lean` (`kof_mode` in `config`); override per-run with `t deploy kof full`.

Set `kof_enabled=true` in `config` to auto-deploy KOF at the end of `t deploy lab` / `t deploy lab airgap`, or run `t deploy kof` (online) / `t deploy kof airgap` against an already-running cluster. It **requires a StorageClass** — set `nfs_enabled=true` (or run `t deploy nfs`) first; the deploy resolves the cluster default StorageClass, falling back to `nfs-client`, and dies with an actionable message if neither exists.

KOF installs as a **FluxCD-sequenced OCI umbrella Helm chart** (`oci://registry.mirantis.com/k0rdent-enterprise/charts/kof`) via **helm v3** (helm v4 has a webhook bug). The committed, version-pinned asset `kof/global-values.yaml` repoints every subchart image to `kof_registry`. The deploy is idempotent (`helm upgrade -i`).

**Airgap:** the MKE 4.2.0 offline bundle ships all KOF charts and images, so after `t deploy lab airgap` the bastion's Harbor already holds everything KOF needs. `t deploy kof airgap` runs the whole install from the bastion (helm/kubectl/mkectl there), auto-derives `kof_registry` to `<registry-hostname>/mke`, auto-enables the Grafana gateway (the only path to Grafana in airgap), and prints `t tunnel grafana` access at the end.

**MKE-monitoring reuse (default on):** `kof_reuse_mke_monitoring=true` reuses MKE4's built-in monitoring instead of duplicating it — drops KOF's own node-exporter and kube-proxy/coredns/apiserver scrapes (KOF already scrapes MKE's, same labels), makes KOF's kube-state-metrics custom-resource-only, and adds MKE's Prometheus as a Grafana datasource. The sub-option `kof_reuse_mke_kubelet=true` (also default) additionally drops KOF's duplicate kubelet/cAdvisor scrape so pod CPU/memory aren't double-counted. Set both to `false` to run KOF's full scrape set alongside MKE's.

The umbrella and mothership charts default every k0rdent (KCM) namespace to `kcm-system`, but MKE4k's k0rdent Enterprise build runs k0rdent in the `k0rdent` namespace. `kof_kcm_namespace` (default `k0rdent`) repoints all of them — the umbrella Flux `HelmRepository`/`HelmChart` objects, the KCM integration, and the per-`ServiceTemplate` Flux repos created by mothership's pre-install hooks — and the preflight dies if that namespace is missing. Because this is self-monitoring only, the `kof-regional` and `kof-child` charts (regional/child cluster templates) are disabled.

Before installing, `t deploy kof` exempts the `kof` namespace and the `opentelemetry-operator` service account from MKE4k's built-in `ucpauthz` admission policy (via `mkectl config get` → patch `spec.apiServer.ucpauthz` → `mkectl apply`). Without this, the OpenTelemetry operator is blocked from creating its collector DaemonSets, so node/host-log collection silently never starts. The step is idempotent — it merges into any existing exemptions and skips the (heavyweight) `mkectl apply` when `kof` is already exempt.

**Grafana (default on):** Mirantis no longer ships Grafana with KOF; `kof_grafana_enabled=true` (the default) has `t deploy kof` enable the `grafana-operator` + the mothership's datasources/dashboards/admin-secret, then apply a pinned Grafana instance CR (`kof/grafana.yaml`). The image is pinned to `<kof_registry>/grafana/grafana:<kof_grafana_image_tag>` (default tag `11.0.0` — the doc's `10.4.18-security-01` is not in the k0rdent-enterprise registry; use whatever tag your registry actually has). The admin login (from secret `grafana-admin-credentials`) is resolved and printed in the deploy output (`Grafana login: <user> / <pass>`).

**Grafana over HTTPS (default on, touches terraform when online):** `kof_grafana_gateway_enabled=true` (the default; requires `kof_grafana_enabled=true`) exposes Grafana via a dedicated Envoy **Gateway API** gateway instead of port-forward. Online, `t deploy kof` also runs `terraform apply` to add an NLB listener (`kof_grafana_lb_port`, default `8443`) + a security-group rule for a pinned Envoy NodePort (`kof_grafana_nodeport`, default `33002`), and applies `kof/grafana-gateway.yaml` (a self-contained `Issuer`/`Certificate`/`EnvoyProxy`/`Gateway`/`HTTPRoute` in the `kof` namespace, on the `mke-gateway-ingress` GatewayClass). TLS is self-signed (cert SANs = NLB DNS + node public IPs), terminated at the gateway; the NLB listener is plain TCP pass-through. Access: `https://<nlb-dns>:8443` (or `https://<node-public-ip>:33002`) — no `/etc/hosts` needed (dedicated listener, no host routing). dex/OIDC is not wired (Grafana's admin login is used). In airgap the terraform step is skipped (internal NLB) and access is via `t tunnel grafana` → `https://localhost:8443`. Set the flag to `false` to fall back to port-forward: `kubectl -n kof port-forward svc/grafana-vm-service 3000:3000`.

**Access (built-in VMUI, always available):**
- Logs: `kubectl -n kof port-forward svc/kof-storage-victoria-logs-cluster-vlselect 9471:9471` → `http://localhost:9471/select/vmui/`
- Metrics: `kubectl -n kof port-forward svc/vmselect-cluster 8481:8481` → `http://localhost:8481/select/0/vmui/`
- Unified auth proxy: `svc/vmauth:8427` (basic-auth; the Grafana datasources point here)

**Example — deploy KOF with Grafana over HTTPS on a running lab:**

```bash
# 1. Ensure a StorageClass exists (KOF's PVCs need one). nfs_enabled=true (the
#    shipped default) provisions it during 't deploy lab'; otherwise add it on demand:
t deploy nfs

# 2. Deploy KOF on the existing cluster. Grafana + the HTTPS gateway are on by
#    default, so this also runs 'terraform apply' to add the NLB listener +
#    SG rule (idempotent). Default scope is lean; use 't deploy kof full' for
#    the complete observability + FinOps platform.
t deploy kof

# The deploy output ends with the access block, e.g.:
#   KOF access (self-monitoring / M2M):
#     Grafana (HTTPS): https://<nlb-dns>:8443  (self-signed; accept the cert)
#                      or https://<node-public-ip>:33002
#     Grafana login:  admin / <generated-password>

# 3. Tear down just KOF when done (leaves the cluster intact):
t destroy kof
```

> With `kof_enabled=true` in `config`, step 2 runs automatically at the end of `t deploy lab` — no separate `t deploy kof` needed. The same applies to `t deploy lab airgap` (KOF then installs from the bastion; Grafana via `t tunnel grafana`).

### MKE4k child cluster (online MKE4k only)

| Command | Description |
|---|---|
| `t deploy child-cluster` | Provision `<cluster_name>-child` via k0rdent / Cluster API on AWS from the running lab (~15 min) |
| `t destroy child-cluster` | Delete the child; CAPA removes its AWS resources (~5 min) |
| `t status child` | `MkeChildConfig` status + `kubectl get nodes` on the child |
| `t rotate child-creds` | Push freshly exported AWS credentials into the child's CAPA identity |
| `t connect m1-child` / `w1-child` / `child-bastion` | SSH into a child node via its bastion (`child_ssh_enabled=true`) |

An MKE4k cluster is also a [k0rdent](https://k0rdent.io) management cluster: it can provision further MKE4k **child clusters** on AWS through Cluster API (CAPA + k0smotron). `t deploy child-cluster` automates the [official MKE 4 tutorial](https://docs.mirantis.com/mke4/4.2.0/tutorials/deploy-mke4-child-cluster/aws/) against your lab. The child gets its **own** VPC, NAT gateway, load balancer and EC2 instances, created by CAPA — not by Terraform.

**Prerequisites**
- A running **online** MKE4k lab (`t deploy lab`). Airgap and MKE3 labs are not supported (CAPA needs the AWS API). `ccm_enabled` is not required.
- AWS credentials exported in the container. They are reused for the child (see *Credentials*). The account needs the standard CAPA IAM setup (`clusterawsadm` bootstrap): the preflight warns if the `control-plane.cluster-api-provider-aws.sigs.k8s.io` instance profile is missing — both control-plane and worker machines use it.
- One free Elastic IP per availability zone the child spans (`child_az_limit`, default 1); the preflight warns when the region's quota is exhausted.

**What `t deploy child-cluster` does**
1. Enables the `cluster-api-provider-aws` and `cluster-api-provider-k0sproject-k0smotron` providers on `Management/kcm` (only the missing ones) and waits for them.
2. Creates the AWS identity in the `k0rdent` namespace: `aws-cluster-identity-secret` + `AWSClusterStaticIdentity` + `Credential` `aws-cluster-identity-cred` + the resource-template ConfigMap (`child-cluster/aws-identity.yaml`).
3. Applies an `MkeChildConfig` rendered from `child-cluster/mkechildconfig.yaml` and the `child_*` settings — `spec.version` is always your `mke4k_version` (it must match the management cluster).
4. Waits for `READY=True`, printing each status change, and saves the kubeconfig to `terraform/child.kubeconfig`.
5. Creates a UI login and prints a summary (see *Access*).

Re-running it is safe: every step is idempotent, so it also resumes a deploy that timed out.

**Access**
- `t status child`, or `KUBECONFIG=terraform/child.kubeconfig kubectl get nodes`.
- **UI:** the child's `EXTERNAL ADDRESS` (`https://<elb>:30001`, self-signed). MKE4k creates no Dex admin user on child clusters, so with `child_admin_enabled=true` (default) the deploy creates one the same way `mkectl` does on a standalone cluster: a Dex `Password` object (`admin`, bcrypt hash only) in the child's `mke` namespace, plus a copy of the management cluster's ClusterRoleBindings for its own admin (`mke4k-lab-child-admin-*`; without it the login works but shows nothing). The password is saved to `terraform/child_credentials.txt` (chmod 600).
- `t show summary` includes a *Child cluster* section — live status/version, UI URL, login, kubeconfig — while a child exists.

**SSH (`child_ssh_enabled=true`, default)**
- The child's nodes have no public IPs, and CAPA only lets SSH into them from its own bastion — so SSH means a CAPA **bastion** in the child VPC's public subnet (`t2.micro`), allowed only from your public IP (`/32`, auto-detected via `checkip.amazonaws.com`, or `child_ssh_allowed_cidr`). The nodes keep `publicIP: false`.
- The machines get the lab's own EC2 key pair (`<cluster_name>-key` / `terraform/aws_private.pem`), so the child must be in the lab's region.
- `t connect m1-child` / `w1-child` (control-plane / worker, 1-based by node name) jump through the bastion as `ec2-user` (Amazon Linux 2023); `t connect child-bastion` opens the bastion itself. `t connect m1-child "cmd"` runs one command.
- Set it **before** `t deploy child-cluster` — the SSH key is part of the machine templates and can't be added to a running child (recreate it to change). The bastion and its allowed CIDR can change any time: after your public IP changes, re-run `t deploy child-cluster`.
- Without SSH you can still get a root shell on a child node: `kubectl --kubeconfig terraform/child.kubeconfig debug node/<node> -it --image=busybox -- chroot /host sh`.

**Credentials**
- The identity secret is built in-memory from the container's `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` (`AWS_SESSION_TOKEN` included); override with `CHILD_AWS_ACCESS_KEY_ID` / `CHILD_AWS_SECRET_ACCESS_KEY` / `CHILD_AWS_SESSION_TOKEN`. No IAM user is created.
- CAPA keeps using these credentials for the child's whole lifetime. With **temporary** credentials it stops working once they expire: export fresh ones and run `t rotate child-creds` (checked with `aws sts get-caller-identity` first; CAPA picks them up on its next reconcile, no restart). The destroy commands sync the current credentials automatically before deleting, so `t destroy lab` the next day with fresh credentials just works.

**Teardown**
- `t destroy lab` and `t destroy cluster` delete the child **first** — while CAPA is still running to remove its AWS resources — and only then tear down the lab. They **refuse to continue** if the child can't be deleted, or if a child is recorded (`.child-cluster`) but the management cluster is unreachable. `T_SKIP_CHILD=1 t destroy lab` overrides this; the child's AWS resources are then left behind — remove them by tag `sigs.k8s.io/cluster-api-provider-aws/cluster/<cluster_name>-child`.
- **Auto-expiry and `bin/cleanup-aws.sh` do not cover the child** — they only find the lab's `Cluster`-tagged resources. Destroy the child before the lab expires.

**Limits:** one child per lab, named `<cluster_name>-child` (so its AWS resource names can't collide with another user's); the preflight refuses to start if CAPA resources for that name are left over from an earlier child.

### Cluster configuration

| Command | Description |
|---|---|
| `t config get [mke4\|mke3]` | Pull the **running** cluster's config to a local file |
| `t config apply [mke4\|mke3]` | Push the edited file back to the cluster |
| `t config edit [mke4\|mke3]` | Pull → `$EDITOR` → push (skipped if you saved no changes) |

Reads and writes the configuration of a cluster that is already up — the variant suffix
follows the same convention as `t deploy lab mke3`, and `mke4` is the default.

| Variant | Local file | Get | Apply |
|---|---|---|---|
| `mke4` (default) | `terraform/mke4.yaml` | `mkectl config get` | `mkectl apply -f` |
| `mke3` | `terraform/mke3-config.toml` | `GET /api/ucp/config-toml` | `PUT /api/ucp/config-toml` |

MKE3 uses the [MKE configuration file API](https://docs.mirantis.com/mke/3.9/ops/administer-cluster/configure-an-mke-cluster/use-an-mke-configuration-file.html):
a bearer token from `POST /auth/login` (URL from the MKE3 NLB, credentials from
`terraform/mke3_credentials.txt`), then a TOML `GET`/`PUT`. No manual login needed.

**Airgap is auto-detected.** The MKE3 NLB is internal, so login and transfer both run on
the bastion over SSH — the token never leaves the bastion. The MKE4k path runs `mkectl` on
the bastion the same way. No tunnel or port mapping required.

`apply` asks for confirmation (pushing config restarts MKE components) and first saves the
**running** config to `<file>.bak`, so a bad edit can be rolled back by copying the backup
over the file and applying again.

```bash
# MKE3 — change the session lifetime on a running cluster
t config get mke3                        # -> terraform/mke3-config.toml
vi terraform/mke3-config.toml            # [auth.sessions] lifetime_minutes = 90
t config apply mke3                      # confirm at the prompt

# Or in one step
t config edit mke3

# MKE4k (default)
t config get                             # -> terraform/mke4.yaml
t config apply
```

> `t config get` (mke4) overwrites `terraform/mke4.yaml` — the same file `t deploy cluster`
> generates. That is expected; the next deploy regenerates it from `config` + Terraform
> outputs.

### Tunnels (airgap)

| Command | Description |
|---|---|
| `t tunnel` | Show available SSH tunnels with manual commands |
| `t tunnel dashboard` | MKE4k Dashboard tunnel -> https://localhost:3000 |
| `t tunnel mke3` | MKE3 Dashboard tunnel -> https://localhost:3000 |
| `t tunnel registry` | Harbor Registry tunnel -> https://localhost:8443 (optional; the bastion's Harbor is also reachable directly at `https://<bastion-public-ip>`) |
| `t tunnel msr4` | MSR4 Harbor UI tunnel -> https://localhost:8444 |
| `t tunnel grafana` | KOF Grafana tunnel -> https://localhost:8443 (shares the local port with `t tunnel registry` — run one at a time) |

### General

| Command | Description |
|---|---|
| `t status` | Show cluster node status (`kubectl get nodes`) |
| `t status child` | Show child cluster status + nodes |
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
├── child-cluster/                # MKE4k child cluster templates (AWS identity, MkeChildConfig)
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
| `aws_instance` (controllers) | Ubuntu or RHEL (`os_name`/`os_version`), `m5a.xlarge` (configurable), 50GB gp3 |
| `aws_instance` (workers) | Ubuntu or RHEL (`os_name`/`os_version`), `m5a.large` (configurable), 50GB gp3 |
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

# Airgap: access Harbor UI — the bastion has a public IP and the SG opens 443,
# so browse it directly (no tunnel/port mapping needed):
#   https://<bastion-public-ip>      (see `t show nodes` for the IP)
# Or, if you prefer a tunnel (requires -p 8443:8443 on docker run):
t tunnel registry
# then browse https://localhost:8443

# Airgap: access MSR4 (Harbor) UI (requires -p 8444:8444 on docker run)
t tunnel msr4
# then browse https://localhost:8444

# Airgap: access KOF Grafana (requires -p 8443:8443 on docker run)
t tunnel grafana
# then browse https://localhost:8443

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
| `controller_flavor` | `m5a.xlarge` | EC2 instance type for controllers |
| `worker_flavor` | `m5a.large` | EC2 instance type for workers |
| `region` | `eu-central-1` | AWS region |
| `os_name` | `ubuntu` | Cluster node OS: `ubuntu` or `redhat` (bastion/NFS server always Ubuntu) |
| `os_version` | `22.04` | Node OS version — MKE4-supported: ubuntu `22.04`/`24.04`, redhat `9.6`/`8.10` (others warn) |
| `ccm_enabled` | `false` | Creates IAM role; required for LoadBalancer services. Auto-disabled in airgap |
| `debug` | `true` | `true` adds `-l debug` to mkectl (all modes including airgap) |

### MKE4k settings

| Variable | Default | Description |
|---|---|---|
| `mke4k_version` | `v4.2.0` | MKE4k / mkectl version |

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
| `nfs_enabled` | `true` | Provisions NFS server EC2, installs nfs-common on nodes, deploys nfs-subdir-external-provisioner |
| `nfs_flavor` | `t3.small` | EC2 instance type for the NFS server |
| `nfs_disk_gb` | `150` | Root volume size (GB) for the NFS server. Sized with headroom for KOF's VictoriaMetrics/Logs/Traces PVCs, which land on `nfs-client` |
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
| `kof_enabled` | `false` | Auto-deploy KOF (self-monitoring/M2M) at the end of `t deploy lab` / `t deploy lab airgap`. Even when `false`, KOF can be deployed later with `t deploy kof` / `t deploy kof airgap`. Requires a StorageClass |
| `kof_mode` | `lean` | Deployment scope: `full` (complete observability + FinOps platform) or `lean` (cluster monitoring only). Override per-run: `t deploy kof full` / `t deploy kof lean` |
| `kof_version` | `1.8.1` | KOF Helm umbrella-chart version (matches k0rdent Enterprise 1.3.2 / MKE 4.2.0) |
| `kof_storage_size` | `10Gi` | PVC size for the VictoriaMetrics / VictoriaLogs / VictoriaTraces volumes (doc default is 100Gi) |
| `kof_storage_ha` | `true` | Keep VictoriaMetrics/VictoriaLogs in HA (cluster) topology. Applies to both modes |
| `kof_registry` | `registry.mirantis.com/k0rdent-enterprise` | Image/chart registry. In airgap it is auto-derived to `<registry-hostname>/mke`; override only for a different custom registry |
| `kof_kcm_namespace` | `k0rdent` | Namespace where k0rdent (KCM) runs. KOF's upstream default is `kcm-system`, but MKE4k's k0rdent Enterprise uses `k0rdent`; the KOF Flux objects + KCM integration are created here |
| `kof_grafana_enabled` | `true` | Deploy Grafana (grafana-operator + datasources/dashboards + the `kof/grafana.yaml` instance CR). Grafana is no longer shipped with KOF by default |
| `kof_grafana_image_tag` | `11.0.0` | Grafana image tag in `<kof_registry>/grafana/grafana` (the registry ships `11.0.0`, not the doc's `10.4.18-security-01`) |
| `kof_grafana_gateway_enabled` | `true` | Expose Grafana over HTTPS via a dedicated Envoy Gateway + NLB listener (requires `kof_grafana_enabled`). **Touches terraform** online — `t deploy kof` runs `terraform apply`. In airgap the gateway is auto-enabled regardless (access via `t tunnel grafana`) |
| `kof_grafana_nodeport` | `33002` | NodePort the Grafana Envoy gateway is pinned to (opened in the cluster SG; NLB target group forwards here). Range 32768-35535 |
| `kof_grafana_lb_port` | `8443` | NLB listener port for Grafana (TCP pass-through; the gateway terminates TLS). In airgap this is the local port of `t tunnel grafana` |
| `kof_reuse_mke_monitoring` | `true` | Reuse MKE4's built-in monitoring instead of duplicating it (drops KOF's node-exporter + kube-proxy/coredns/apiserver scrapes, KSM custom-resource-only, adds MKE's Prometheus as Grafana datasource) |
| `kof_reuse_mke_kubelet` | `true` | Sub-option of reuse: also drop KOF's duplicate kubelet/cAdvisor scrape so pod CPU/memory aren't double-counted (~2x otherwise) |
| `kof_sf_notifier_enabled` | `false` | Route alerts with severity critical\|warning\|error to the sf-notifier webhook. sf-notifier itself is deployed separately by hand — leave `false` unless it is running |

### Child cluster settings

| Variable | Default | Description |
|---|---|---|
| `child_control_plane_count` | `1` | Child control-plane nodes (odd) |
| `child_worker_count` | `1` | Child worker nodes |
| `child_region` | `region` | AWS region for the child |
| `child_control_plane_flavor` / `child_worker_flavor` | *(template default: `m5.xlarge` / `m5.large`)* | EC2 instance types, rendered into `spec.infrastructure.configuration.{controlPlane,worker}.instanceType` |
| `child_az_limit` | `1` | Max AZs the child's CAPA VPC spans (`network.vpc.availabilityZoneUsageLimit`) |

The child's MKE4k version is not configurable: `MkeChildConfig` `spec.version` always equals the deployed `mke4k_version` (`vX.Y.Z` — the docs require it to match the management cluster). The preflight also warns when the region lacks Elastic IP quota (CAPA needs one per AZ).
| `child_ready_timeout` / `child_delete_timeout` | `30m` | How long to wait for Ready / deletion |
| `child_ssh_enabled` | `true` | SSH into child nodes via a CAPA bastion (`t connect m1-child`); set before creating the child. `false` = no bastion, no key |
| `child_ssh_allowed_cidr` | *(your public IP/32)* | CIDR allowed to reach the child bastion |
| `child_admin_enabled` | `true` | Create a Dex `admin` login + RBAC for the child UI (password → `terraform/child_credentials.txt`) |

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

**Additional traffic flows (MKE3 airgap, and RHEL nodes in any airgap mode):**
- Cluster nodes -> Bastion: Squid proxy (3128) for MCR apt/dnf package installation (RHEL nodes also use it for RHUI OS packages, e.g. `nfs-utils`)
- Squid proxy -> Internet: HTTPS CONNECT to `*.mirantis.com`, `*.docker.com`, `*.ubuntu.com`, `*.redhat.com` (whitelisted domains only)
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

It does **not** find a child cluster's resources (they are owned by CAPA and tagged `sigs.k8s.io/cluster-api-provider-aws/cluster/<cluster_name>-child`, in their own VPC). If a lab with a child was lost, delete those by that tag from the AWS console — EC2 instances, load balancer, NAT gateway + Elastic IP, then the VPC.
