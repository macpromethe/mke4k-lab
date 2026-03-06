# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A standalone AWS lab provisioning tool for [Mirantis Kubernetes Engine 4k](https://www.mirantis.com/software/mke-4/). Terraform provisions a dedicated VPC, EC2 instances, NLB, and IAM; `mkectl apply` installs MKE4k on top. Supports online, MKE3, and fully airgapped deployments (both MKE4k airgap and MKE3 airgap).

## Usage (Docker — recommended)

```bash
# Build (pre-initialises Terraform providers)
docker build -t mke4k-lab .

# Run (pass AWS credentials via env)
docker run -it --name mke4k-lab \
  -e AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
  -e AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
  mke4k-lab

# Run with port mappings for airgap UI tunnels
docker run -it --name mke4k-lab \
  -e AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
  -e AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
  -p 3000:3000 -p 8443:8443 \
  mke4k-lab

# Re-attach (state lives inside the container)
docker start -ai mke4k-lab
```

Inside the container, the `t` command is available globally:

```bash
# MKE4k (default)
t deploy lab              # Full deploy: Terraform + MKE4k install
t deploy instances        # Terraform only
t deploy cluster          # mkectl only (instances already exist)
t destroy lab             # terraform destroy
t destroy cluster         # mkectl reset --force

# MKE3
t deploy lab mke3         # Terraform (both NLBs) + launchpad apply
t deploy cluster mke3     # launchpad only
t destroy cluster mke3    # launchpad reset

# Airgap (MKE4k)
t deploy lab airgap       # Full airgap: Terraform + bastion/registry + bundle upload + mkectl
t deploy instances airgap # Terraform only (bastion + private-subnet nodes)
t deploy registry         # Setup MSR4 (Harbor) + upload MKE4k bundle
t deploy cluster airgap   # mkectl apply from bastion

# Airgap (MKE3)
t deploy lab mke3-airgap       # Full airgap: Terraform + registry + proxy + MKE3
t deploy instances mke3-airgap # Terraform only (MKE3 + bastion + private subnet)
t deploy registry mke3         # Setup MSR4 (Harbor) + upload MKE3 images
t deploy cluster mke3-airgap   # DNS + proxy + launchpad from bastion
t destroy cluster mke3-airgap  # launchpad reset from bastion

# Common
t status                  # kubectl get nodes
t show nodes              # Print IPs + NLB DNS
t connect m1              # SSH into controller-1 (m1/m2/m3 or w1/w2/w3)
t connect m1 "cmd"        # Run a single command on a node

# Airgap UI tunnels (requires -p port mappings on docker run)
t tunnel                  # Show available tunnels with manual SSH commands
t tunnel dashboard        # MKE4k Dashboard → https://localhost:3000
t tunnel mke3             # MKE3 Dashboard  → https://localhost:3000
t tunnel registry         # Harbor Registry  → https://localhost:8443
```

## Usage (Local)

Prerequisites: `terraform` ≥ 0.14.3, `mkectl`, `kubectl`, `jq`, `yq`, AWS credentials exported.

```bash
export AWS_ACCESS_KEY_ID="..."
export AWS_SECRET_ACCESS_KEY="..."
vi config            # edit cluster settings
./bin/t deploy lab
```

## Configuration

Edit `config` before deploying. Key variables:

| Variable | Default | Notes |
|---|---|---|
| `cluster_name` | `mke4k-lab` | Name prefix for all AWS resources. Left as default, a random 4-char suffix is auto-appended (e.g. `mke4k-lab-a3f2`) to avoid collisions. Persisted in `.cluster-id` |
| `controller_count` | `1` | Use 3 for HA (must be odd) |
| `worker_count` | `1` | |
| `cluster_flavor` | `m5.xlarge` | Minimum recommended |
| `region` | `eu-central-1` | |
| `mke4k_version` | `v4.1.2` | mkectl is auto-downloaded at this version |
| `os_distro` | `ubuntu-22.04` | `ubuntu-22.04` or `ubuntu-24.04` |
| `ccm_enabled` | `true` | Creates IAM role; required for LoadBalancer services. Auto-disabled in airgap (no AWS API access) |
| `debug` | `false` | `true` adds `-l debug` to mkectl (works for all modes including airgap) |
| `airgap_registry_flavor` | `t3.xlarge` | Bastion/registry instance type |
| `airgap_registry_disk_gb` | `100` | Bastion root volume size (holds Harbor + image bundle) |
| `airgap_msr_version` | `v4.13.3` | MSR4 (Harbor) version for the airgap registry |

## Architecture

### Deploy flow (online)

1. `t deploy lab` sources `config` → writes `terraform/terraform.tfvars`
2. `terraform init + apply` provisions: dedicated VPC (172.31.0.0/16), public subnet, RSA-4096 keypair, security group, EC2 instances, NLB with IP-type target groups (6443, 9443, 33001), IAM role+policy for CCM
3. Wait 60 s for NLB to become active
4. `generate_mke4_yaml`: calls `mkectl init` for the schema, then patches it with `yq` using controller/worker IPs and NLB DNS from `terraform output -json`
5. `mkectl apply -f terraform/mke4.yaml` installs MKE4k; kubeconfig lands at `~/.mke/mke.kubeconf`

### Deploy flow (airgap)

1. `t deploy lab airgap` sources `config` → writes tfvars with `airgap_enabled=true`
2. `terraform apply` provisions: dedicated VPC (172.31.0.0/16), public subnet (172.31.0.0/24) + private subnet (172.31.1.0/24), bastion EC2 in public subnet, controller/worker EC2s in private subnet (no internet), **internal** NLB in private subnet with IP-type target groups
3. `setup_registry`: installs MCR (docker-ee) + bind9 + MSR4 (Harbor) on bastion; generates self-signed TLS cert (SAN=registry FQDN + bastion IP); creates Harbor project `mke`
4. `upload_mke4k_bundle`: downloads MKE4k OCI bundle on bastion, uploads all images/charts to Harbor via containerised skopeo (`quay.io/skopeo/stable:v1.18.0`)
5. `setup_node_dns`: configures each cluster node's systemd-resolved → bastion bind9 + `/etc/hosts` fallback for registry hostname
6. `ensure_mkectl_on_bastion`: installs mkectl + kubectl on bastion
7. `generate_mke4_yaml true`: uses private IPs, bastion keypath, embeds registry CA via `caData`, sets `airgap.enabled=true`, forces `cloudProvider.enabled=false`
8. `mkectl_apply_on_bastion`: SCPs mke4.yaml + SSH key to bastion, runs `mkectl apply` there, retrieves kubeconfig

### Deploy flow (MKE3 airgap)

1. `t deploy lab mke3-airgap` sources `config` → writes tfvars with `mke3_enabled=true`, `airgap_enabled=true`
2. `terraform apply` provisions: dedicated VPC, public subnet (bastion) + private subnet (cluster nodes, no internet), both MKE4k and MKE3 NLBs (both internal in private subnet)
3. `setup_registry`: installs MCR + bind9 + MSR4 (Harbor) on bastion (reused from MKE4k airgap)
4. `upload_mke3_images`: downloads `ucp_images_<version>.tar.gz` on bastion, `docker load` + retag + push to Harbor `mke3` project
5. `setup_node_dns`: configures cluster nodes' systemd-resolved → bastion bind9 (reused)
6. `setup_squid_proxy`: installs Squid forward proxy on bastion (port 3128), ACL allows only private subnet to Mirantis/Docker/Ubuntu domains
7. `setup_node_proxy`: configures each cluster node with APT proxy, environment proxy vars, sudoers env_keep, and Docker registry CA cert
8. `ensure_launchpad_on_bastion`: installs launchpad binary on bastion
9. `generate_launchpad_yaml true`: uses private IPs, bastion keypath, sets `imageRepo` to Harbor `mke3` project
10. `launchpad_apply_on_bastion`: SCPs launchpad.yaml + SSH key to bastion, runs `launchpad apply` there
11. Post-deploy: prompts for MKE3 → MKE4k upgrade preparation (uploads MKE4k bundle + generates mke4.yaml on bastion)

### Key files

- **`config`** — single user-edited file; sourced by bash, not parsed
- **`bin/t`** — thin launcher that resolves project root and execs `t-commandline.bash`
- **`bin/t-commandline.bash`** — all CLI logic: config loading, tfvars generation, mkectl download, mke4.yaml generation, SSH helpers, deploy summary
- **`bin/cleanup-aws.sh`** — emergency AWS cleanup when Terraform state is lost; finds resources by cluster tag, interactive confirmation
- **`terraform/vpc.tf`** — dedicated VPC (172.31.0.0/16), internet gateway, public subnet (172.31.0.0/24), route table
- **`terraform/main.tf`** — provider config, keypair, AMI lookup (Canonical owner ID), security group
- **`terraform/controller.tf` / `worker.tf`** — EC2 instances (public subnet normally, private subnet in airgap)
- **`terraform/loadbalancer.tf`** — NLB + IP-type target groups + listeners; internal NLB in private subnet when airgap
- **`terraform/airgap.tf`** — private subnet (172.31.1.0/24), route table (no IGW), bastion EC2 in public subnet; gated by `airgap_enabled`
- **`terraform/mke3_loadbalancer.tf`** — MKE3 NLB (443, 6443); gated by `mke3_enabled`
- **`terraform/iam.tf`** — IAM role with CCM minimum permissions (conditional on `ccm_enabled`)
- **`terraform/outputs.tf`** — `lb_dns_name`, `controller_ips`, `worker_ips`, `ssh_key_path`, `bastion_public_ip`, `bastion_private_ip`, `controller_private_ips`, `worker_private_ips`
- **`Dockerfile`** — two-stage build (`--platform=linux/amd64`); stage 1 downloads kubectl/helm/terraform/k9s/yq; stage 2 is the runtime image with `t` symlinked globally and Terraform providers pre-initialised

### State files (live in `terraform/`)

- `terraform.tfstate` — created by `terraform apply`; stays inside the container
- `aws_private.pem` — written by Terraform (`local_file` resource); used for SSH and embedded in `mke4.yaml`
- `mke4.yaml` — generated by `generate_mke4_yaml` after apply

### mkectl download

`ensure_mkectl` in `t-commandline.bash` checks the installed version and downloads from `https://github.com/MirantisContainers/mke-release/releases/download/<version>/mkectl_linux_x86_64.tar.gz` if missing or mismatched. Override with `MKECTL_DOWNLOAD_URL` env var. In airgap mode, `ensure_mkectl_on_bastion` also installs kubectl on the bastion.

### Node addressing

`t connect` resolves short names: `m1`/`m2`/`m3` → controller IPs (1-based index into `controller_ips` output), `w1`/`w2`/`w3` → worker IPs, or any raw IP passes through unchanged. In airgap mode, `t connect` auto-detects the bastion via `bastion_public_ip` output and uses SSH ProxyCommand to reach cluster nodes in the private subnet.

### Networking design notes

- **Dedicated VPC**: Each lab gets its own VPC (172.31.0.0/16) for isolation — no default VPC dependency
- **IP-type target groups**: NLB target groups use `target_type = "ip"` (not instance). This is critical for `controller+worker` nodes where the kubelet bootstraps through the NLB back to itself (hairpin routing). AWS NLBs do not support hairpin with instance-type targets
- **Internal NLB for airgap**: When `airgap_enabled`, the NLB is placed in the private subnet as an internal LB. Cluster nodes resolve it via VPC DNS (forwarded through bastion's bind9)
- **CCM auto-disabled in airgap**: The AWS cloud controller manager requires access to `ec2.amazonaws.com` which is unreachable from the private subnet. `generate_mke4_yaml` forces `cloudProvider.enabled=false` when airgap=true
- **DNS chain (airgap)**: cluster node → systemd-resolved → bastion bind9 → VPC DNS (172.31.0.2). Registry hostname (`registry.<cluster>.local`) is served by bind9; all other queries forwarded to VPC DNS. `/etc/hosts` fallback on all nodes for the registry hostname
- **Registry TLS**: Self-signed cert with SAN covering both FQDN and bastion IP. CA embedded as `caData` in mke4.yaml; mkectl configures containerd trust on each node. Bastion has cert in `/etc/docker/certs.d/` for both FQDN and IP
- **Bundle upload**: Containerised skopeo (`quay.io/skopeo/stable:v1.18.0`) with `--add-host` for DNS resolution inside the container. Filenames decoded: `&` → `/`, `@` → `:`
- **Squid proxy (MKE3 airgap)**: Forward proxy on bastion port 3128. Cluster nodes use it for MCR APT package install (`get.mirantis.com`, `repos.mirantis.com`). ACL restricts to Mirantis/Docker/Ubuntu domains only. CONNECT tunnelling for HTTPS — no SSL bump
- **MKE3 image path (airgap)**: `docker load` from tarball → retag `mirantis/*` → push to `registry.<cluster>.local/mke3/*`. Nodes pull via Docker with `/etc/docker/certs.d/<registry>/ca.crt` trust
- **MKE3 NLB airgap-aware**: When `airgap_enabled`, MKE3 NLB is internal in private subnet (same as MKE4k NLB)
