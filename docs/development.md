# Development: building, running locally, internals

[← Back to README](../README.md)

## Build the Docker image yourself

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

## Run locally (without Docker)

### Prerequisites

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
