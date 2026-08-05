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

# KOF observability (requires MKE 4.2.0+; kof_enabled=true auto-runs it in lab deploys)
t deploy kof [full|lean]        # Deploy KOF on an existing cluster (online)
t deploy kof [full|lean] airgap # Deploy KOF from the bastion (charts/images from internal registry)
t destroy kof                   # helm uninstall + delete ns kof (auto-detects airgap)

# Common
t deploy nfs [mke3]       # NFS server + provisioner on an existing cluster (auto-detects airgap)
t expiry                  # Show the current auto-expiry deadline
t expiry 5                # Re-arm auto-expiry to 5 days from now (targeted apply; cluster untouched)
t expiry off              # Disable auto-expiry (removes the reaper; lab won't self-delete)
t status                  # kubectl get nodes
t show nodes              # Print IPs + NLB DNS
t show summary            # Reprint the deploy summary box (credentials, URLs, IPs)
t connect m1              # SSH into controller-1 (m1/m2/m3 or w1/w2/w3)
t connect m1 "cmd"        # Run a single command on a node

# Airgap UI tunnels (requires -p port mappings on docker run)
t tunnel                  # Show available tunnels with manual SSH commands
t tunnel dashboard        # MKE4k Dashboard → https://localhost:3000
t tunnel mke3             # MKE3 Dashboard  → https://localhost:3000
t tunnel registry         # Harbor Registry  → https://localhost:8443
t tunnel grafana          # KOF Grafana      → https://localhost:8443 (shares the 8443 -p mapping)
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
| `cluster_name` | `mke4k-lab` | Name prefix for all AWS resources. Left as default, the first `t deploy lab\|instances` prompts for the user's name (interactive TTY only) → `mke4k-lab-<name>` + `Owner` tag on all resources (provider `default_tags`); non-interactive runs fall back to a random 4-char suffix (e.g. `mke4k-lab-a3f2`). Persisted in `.cluster-id` / `.owner` |
| `controller_count` | `1` | Use 3 for HA (must be odd) |
| `worker_count` | `1` | |
| `controller_flavor` | `m5a.xlarge` | Controller instance type (4 vCPU / 16 GB min recommended) |
| `worker_flavor` | `m5a.large` | Worker instance type |
| `region` | `eu-central-1` | |
| `expiry_days` | `3` | Auto-delete the whole lab this many days after creation unless `t destroy lab` is run first. A Terraform-provisioned reaper (EventBridge Scheduler one-shot → Lambda) deletes every `Cluster`-tagged object entirely inside AWS, so it fires even if the container/host is off. `0` = never expire. Works in all deploy modes (incl. airgap — the Lambda runs outside the lab VPC). Minimum window is 1 day (`offset_days`) |
| `expiry_dry_run` | `false` | When `true`, the reaper Lambda logs every resource it *would* delete (CloudWatch) but deletes nothing — for verifying scope before trusting it live. Invoke on demand instead of waiting for the timer: `aws lambda invoke --function-name <cluster_name>-reaper /dev/stdout` |
| `mke4k_version` | `v4.2.0` | mkectl is auto-downloaded at this version |
| `os_name` | `ubuntu` | Cluster node OS: `ubuntu` or `redhat` (bastion/NFS server always Ubuntu). SSH user: `ubuntu`/`ec2-user`. Legacy `os_distro` still accepted with a warning |
| `os_version` | `22.04` | Node OS version — MKE4-supported: ubuntu `22.04`/`24.04`, redhat `9.6`/`8.10` (others warn, AMI lookup may fail) |
| `ccm_enabled` | `false` | Creates IAM role; required for LoadBalancer services. MKE4k: enables `cloudProvider` in mke4.yaml; MKE3: adds `--cloud-provider=aws` install flag. Auto-disabled in airgap (no AWS API access) |
| `nfs_enabled` | `true` | NFS server + `nfs-client` default StorageClass (required by KOF and MSR4-HA). Works in all modes incl. MKE3: MKE3 kubeconfig comes from the launchpad client bundle (`source env.sh`) |
| `debug` | `true` | `true` adds `-l debug` to mkectl (works for all modes including airgap) |
| `kof_enabled` | `false` | Auto-deploy KOF at the end of lab deploys; `t deploy kof [airgap]` works standalone regardless |
| `kof_mode` | `lean` | KOF scope: `full` (observability + FinOps) or `lean` (cluster monitoring only). Grafana + HTTPS gateway and MKE-monitoring reuse are on by default (advanced settings) |
| `airgap_registry_flavor` | `t3.xlarge` | Bastion/registry instance type |
| `airgap_registry_disk_gb` | `100` | Bastion root volume size (holds Harbor + image bundle) |
| `airgap_msr_version` | `v4.13.3` | MSR4 (Harbor) version for the airgap registry |

## Architecture

### Deploy flow (online)

1. `t deploy lab` sources `config` → writes `terraform/terraform.tfvars`
2. `terraform init + apply` provisions: dedicated VPC (172.31.0.0/16), public subnet, RSA-4096 keypair, security group, EC2 instances, NLB with IP-type target groups (6443, 9443, 33001), IAM role+policy for CCM
3. `ensure_node_hostnames`: verifies every node's hostname is the EC2 `PrivateDnsName` FQDN (repairs it over SSH if not) — CCM matches Nodes by that name
4. Wait 60 s for NLB to become active
5. `generate_mke4_yaml`: calls `mkectl init` for the schema, then patches it with `yq` using controller/worker IPs and NLB DNS from `terraform output -json`
6. `mkectl apply -f terraform/mke4.yaml` installs MKE4k; kubeconfig lands at `~/.mke/mke.kubeconf`

### Deploy flow (airgap)

1. `t deploy lab airgap` sources `config` → writes tfvars with `airgap_enabled=true`
2. `terraform apply` provisions: dedicated VPC (172.31.0.0/16), public subnet (172.31.0.0/24) + private subnet (172.31.1.0/24), bastion EC2 in public subnet, controller/worker EC2s in private subnet (no internet), **internal** NLB in private subnet with IP-type target groups
3. `setup_registry`: installs MCR (docker-ee) + bind9 + MSR4 (Harbor) on bastion; generates self-signed TLS cert (SAN=registry FQDN + bastion IP); creates Harbor project `mke`
4. `setup_node_dns`: configures each cluster node's resolver → bastion bind9 + `/etc/hosts` fallback for registry hostname (systemd-resolved on Ubuntu; NetworkManager `dns=none` + direct /etc/resolv.conf on RHEL). Runs early so RHEL dnf-via-Squid can resolve RHUI
5. `ensure_node_hostnames` (FQDN hostname check on every node — see *Node hostnames*), then `setup_rhel_node_prereqs` (RHEL nodes only): disables nm-cloud-setup (+reboot — k0s incompatibility), disables firewalld/nftables; SELinux stays enforcing for MKE 4.1.3+ (supported), permissive for older target versions
6. `ensure_mkectl_on_bastion`: installs mkectl + kubectl on bastion (moved before bundle upload so mkectl is available for dual-path mode)
7. `upload_mke4k_bundle`: downloads MKE4k OCI bundle on bastion, uploads all images/charts to Harbor via containerised skopeo (`quay.io/skopeo/stable:v1.18.0`). Supports `standard` (filesystem scan) and `dual-path` (v4.1.3 workaround) modes
8. NFS (when enabled): `install_nfs_client_on_nodes` — Ubuntu nodes get `.deb`s bundled on the bastion; RHEL nodes install `nfs-utils` via dnf through a bastion Squid proxy against RHUI (transient `--setopt=proxy=`, no persistent proxy state)
9. `generate_mke4_yaml true`: uses private IPs, bastion keypath, embeds registry CA via `caData`, sets `airgap.enabled=true`, forces `cloudProvider.enabled=false`
10. `mkectl_apply_on_bastion`: SCPs mke4.yaml + SSH key to bastion, runs `mkectl apply` there, retrieves kubeconfig
11. `prompt_mke4k_upgrade_prep_airgap`: interactive prompt to prepare MKE4k → MKE4k airgap upgrade (uploads target version bundle, downloads release-matrix.json, prints upgrade command)

### Deploy flow (MKE3 airgap)

1. `t deploy lab mke3-airgap` sources `config` → writes tfvars with `mke3_enabled=true`, `airgap_enabled=true`
2. `terraform apply` provisions: dedicated VPC, public subnet (bastion) + private subnet (cluster nodes, no internet), both MKE4k and MKE3 NLBs (both internal in private subnet)
3. `setup_registry`: installs MCR + bind9 + MSR4 (Harbor) on bastion (reused from MKE4k airgap)
4. `upload_mke3_images`: downloads `ucp_images_<version>.tar.gz` on bastion, `docker load` + retag + push to Harbor `mke3` project
5. `setup_node_dns`: configures cluster nodes' resolver → bastion bind9 (reused; systemd-resolved on Ubuntu, NetworkManager `dns=none` + /etc/resolv.conf on RHEL)
6. `ensure_node_hostnames` (FQDN hostname check on every node — see *Node hostnames*), then `setup_rhel_node_prereqs` (RHEL only): disables nm-cloud-setup (+reboot), disables firewalld; SELinux enforcing kept on MKE 4.1.3+
7. `setup_squid_proxy`: installs Squid forward proxy on bastion (port 3128), ACL allows only private subnet to Mirantis/Docker/Ubuntu/RedHat(RHUI) domains
8. `setup_node_proxy`: configures each cluster node with apt (Ubuntu) or dnf (RHEL) proxy, environment proxy vars, sudoers env_keep, and Docker registry CA cert
9. `ensure_launchpad_on_bastion`: installs launchpad binary on bastion
10. `generate_launchpad_yaml true`: uses private IPs, bastion keypath, sets `imageRepo` to Harbor `mke3` project
11. `launchpad_apply_on_bastion`: SCPs launchpad.yaml + SSH key to bastion, runs `launchpad apply` there
12. NFS (when enabled): `setup_nfs_server` + `install_nfs_client_on_nodes` (reused), then `upload_nfs_provisioner_image` + `deploy_nfs_provisioner_mke3_airgap` — generates the launchpad client bundle on the bastion, `source env.sh` for kubeconfig, helm-installs the provisioner from the pre-pulled chart
13. Post-deploy: prompts for MKE3 → MKE4k upgrade preparation (uploads MKE4k bundle + generates mke4.yaml on bastion)

### Key files

- **`config`** — single user-edited file; sourced by bash, not parsed
- **`bin/t`** — thin launcher that resolves project root and execs `t-commandline.bash`
- **`bin/t-commandline.bash`** — all CLI logic: config loading, tfvars generation, mkectl download, mke4.yaml generation, SSH helpers, deploy summary
- **`bin/cleanup-aws.sh`** — emergency AWS cleanup when Terraform state is lost; finds resources by cluster tag, interactive confirmation
- **`terraform/vpc.tf`** — dedicated VPC (172.31.0.0/16), internet gateway, public subnet (172.31.0.0/24), route table
- **`terraform/main.tf`** — provider config, keypair, AMI lookups (`node` = ubuntu/redhat per `os_name`/`os_version`, `bastion` = always Ubuntu), security group
- **`terraform/controller.tf` / `worker.tf`** — EC2 instances (public subnet normally, private subnet in airgap). All four instance resources (these two plus `airgap.tf` bastion and `nfs.tf`) share the same `#cloud-config` `user_data` that forces the FQDN hostname — see *Node hostnames must be the FQDN (CCM)*
- **`terraform/loadbalancer.tf`** — NLB + IP-type target groups + listeners; internal NLB in private subnet when airgap
- **`terraform/airgap.tf`** — private subnet (172.31.1.0/24), route table (no IGW), bastion EC2 in public subnet; gated by `airgap_enabled`
- **`terraform/mke3_loadbalancer.tf`** — MKE3 NLB (443, 6443); gated by `mke3_enabled`
- **`terraform/iam.tf`** — IAM role with CCM minimum permissions (conditional on `ccm_enabled`)
- **`terraform/expiry.tf`** — auto-expiry reaper (gated on `expiry_days > 0`): `time_offset` fixes the expiry moment at `expiry_base + expiry_days` (base defaults to create time; `t expiry` rebases to "now"); an EventBridge Scheduler one-shot `at()` fires a Lambda (`reaper.py`) at that time; scoped IAM roles for the Lambda and the scheduler. `t destroy lab` (terraform destroy) removes the schedule, so the reaper only fires on abandoned labs. `t expiry [<days>|off|show]` does a **targeted** apply of only these resources (never the cluster) to change/disable the deadline
- **`terraform/reaper.py`** — the reaper Lambda (boto3): non-interactive teardown mirroring `cleanup-aws.sh` — terminates `Cluster`-tagged EC2, deletes NLBs/target groups (matched by the `Cluster` tag via `describe_tags`, never by name alone)/VPC+deps/CCM IAM/key pair, then self-cleans (its own schedule, roles, and function). Best-effort per step; zipped at apply-time by `archive_file` → `terraform/reaper.zip` (git/docker-ignored). Every destructive call funnels through `mutate()`, so `DRY_RUN` (env, from `expiry_dry_run`) guarantees a read-only run that still logs each target. A safety fuse aborts if `CLUSTER_NAME` is empty/<5 chars
- **`terraform/outputs.tf`** — `lb_dns_name`, `controller_ips`, `worker_ips`, `ssh_key_path`, `bastion_public_ip`, `bastion_private_ip`, `controller_private_ips`, `worker_private_ips`
- **`Dockerfile`** — two-stage build (`--platform=linux/amd64`); stage 1 downloads kubectl/helm/terraform/k9s/yq; stage 2 is the runtime image with `t` symlinked globally and Terraform providers pre-initialised

### State files (live in `terraform/`)

- `terraform.tfstate` — created by `terraform apply`; stays inside the container
- `aws_private.pem` — written by Terraform (`local_file` resource); used for SSH and embedded in `mke4.yaml`
- `mke4.yaml` — generated by `generate_mke4_yaml` after apply
- `.expiry-days` / `.expiry-base` (in project root) — written by `t expiry`; override the config `expiry_days` and anchor the countdown to "now". `load_config` honors them over `config` so the imperative deadline survives tfvars regeneration; `t destroy lab` removes them

### mkectl download

`ensure_mkectl` in `t-commandline.bash` checks the installed version and downloads from `https://github.com/MirantisContainers/mke-release/releases/download/<version>/mkectl_linux_x86_64.tar.gz` if missing or mismatched. Override with `MKECTL_DOWNLOAD_URL` env var. In airgap mode, `ensure_mkectl_on_bastion` also installs kubectl on the bastion.

### Node addressing

`t connect` resolves short names: `m1`/`m2`/`m3` → controller IPs (1-based index into `controller_ips` output), `w1`/`w2`/`w3` → worker IPs, or any raw IP passes through unchanged. In airgap mode, `t connect` auto-detects the bastion via `bastion_public_ip` output and uses SSH ProxyCommand to reach cluster nodes in the private subnet.

### Networking design notes

- **Dedicated VPC**: Each lab gets its own VPC (172.31.0.0/16) for isolation — no default VPC dependency
- **IP-type target groups**: NLB target groups use `target_type = "ip"` (not instance). This is critical for `controller+worker` nodes where the kubelet bootstraps through the NLB back to itself (hairpin routing). AWS NLBs do not support hairpin with instance-type targets
- **Internal NLB for airgap**: When `airgap_enabled`, the NLB is placed in the private subnet as an internal LB. Cluster nodes resolve it via VPC DNS (forwarded through bastion's bind9)
- **CCM auto-disabled in airgap**: The AWS cloud controller manager requires access to `ec2.amazonaws.com` which is unreachable from the private subnet. `generate_mke4_yaml` forces `cloudProvider.enabled=false` when airgap=true
- **Node hostnames must be the FQDN (CCM)**: The Kubernetes node name is the OS hostname — MKE4k/launchpad expose no `nodeName`/`--hostname-override` knob — and AWS CCM resolves a Node to an instance by matching that name against the instance's `PrivateDnsName`. A short hostname yields `failed to get instance metadata for node ip-a-b-c-d: instance not found` forever, so the node never gets `providerID`, zone/region labels, or its `uninitialized` taint removed. Ubuntu's cloud-init defaults to the **short** name (`prefer_fqdn = False` in the Debian distro class; RHEL's sets `True`), so `user_data` on all four instances is a `#cloud-config` forcing `prefer_fqdn_over_hostname: true` + `preserve_hostname: false` — cloud-init fetches `local-hostname` itself over IMDSv2 and re-applies it every boot. `manage_etc_hosts` must stay `localhost`: `true` re-renders `/etc/hosts` from the template each boot and would wipe the airgap registry entry `setup_node_dns` adds. Because `user_data` only runs at first boot (and changing it does not recycle a live instance), `ensure_node_hostnames` independently verifies/repairs the FQDN over SSH before every install — IMDSv2 → IMDSv1 → derive from the primary IP, and it hard-fails when `ccm_enabled=true` and the FQDN can't be set. Do not reintroduce a `curl`-based `user_data` hostname script: the previous one used unauthenticated IMDSv1, and when that returned empty it truncated `/etc/hostname` to nothing
- **DNS chain (airgap)**: cluster node → local resolver → bastion bind9 → VPC DNS (172.31.0.2). Ubuntu: systemd-resolved. RHEL: NetworkManager gets `dns=none` and /etc/resolv.conf points directly at the bastion (survives DHCP renewals/reboots). Registry hostname (`registry.<cluster>.local`) is served by bind9; all other queries forwarded to VPC DNS. `/etc/hosts` fallback on all nodes for the registry hostname
- **Registry TLS**: Self-signed cert with SAN covering both FQDN and bastion IP. CA embedded as `caData` in mke4.yaml; mkectl configures containerd trust on each node. Bastion has cert in `/etc/docker/certs.d/` for both FQDN and IP
- **Bundle upload**: Containerised skopeo (`quay.io/skopeo/stable:v1.18.0`) with `--add-host` for DNS resolution inside the container. Filenames decoded: `&` → `/`, `@` → `:`. Two modes: `standard` (filesystem scan, default) and `dual-path` (v4.1.3 workaround — uses `mkectl airgap list-images/list-charts` to enumerate artifacts, uploads `registry.mirantis.com/mke/*` images to both `<registry>/mke/<path>` and `<registry>/mke/mke/<path>` to work around mkectl v4.1.3's double-prefix bug)
- **mkectl v4.1.3 dual-path workaround**: `mkectl upgrade` v4.1.3 double-prefixes multi-level image names during artifact presence check (e.g. `mke/mke/calico/apiserver` instead of `mke/calico/apiserver`). Workaround: upload images to both paths. Automatically activated when target version is v4.1.3 (for fresh installs and upgrade prep)
- **Squid proxy (MKE3 airgap; also RHEL nodes in MKE4k airgap)**: Forward proxy on bastion port 3128. Cluster nodes use it for MCR apt/dnf package install (`get.mirantis.com`, `repos.mirantis.com`); RHEL nodes also reach RHUI (`rhui.<region>.aws.ce.redhat.com`) through it for OS packages (container-selinux deps, nfs-utils). ACL restricts to Mirantis/Docker/Ubuntu/RedHat/CloudFront domains only. CONNECT tunnelling for HTTPS — no SSL bump
- **RHEL cluster nodes** (`os_name=redhat`): official Red Hat PAYG AMIs (owner 309956199498), SSH user `ec2-user`. `setup_rhel_node_prereqs` disables nm-cloud-setup (documented k0s incompatibility, requires reboot) and firewalld; SELinux is left enforcing when `mke4k_version` ≥ 4.1.3 (SELinux supported since then), set permissive for older targets. Bastion/NFS server stay Ubuntu; RHEL OS packages come from RHUI via Squid (MKE4k airgap uses a transient per-command dnf proxy so nodes keep no proxy state)
- **MKE3 image path (airgap)**: `docker load` from tarball → retag `mirantis/*` → push to `registry.<cluster>.local/mke3/*`. Nodes pull via Docker with `/etc/docker/certs.d/<registry>/ca.crt` trust
- **MKE3 NLB airgap-aware**: When `airgap_enabled`, MKE3 NLB is internal in private subnet (same as MKE4k NLB)
