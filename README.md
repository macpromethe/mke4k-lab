# mke4k-lab

A standalone AWS lab provisioning tool for [Mirantis Kubernetes Engine 4k](https://www.mirantis.com/software/mke-4/).

Terraform provisions EC2 instances + NLB + IAM role; `mkectl apply` installs MKE4k.

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
```

Once inside the container:
```bash
vi /mke4k-lab/config      # edit cluster settings
t deploy lab              # provision EC2 + NLB, then install MKE4k
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
- `jq`

### 1. Edit config

```bash
vi config
```

```bash
cluster_name="mke4k-lab"
controller_count=1
worker_count=1
cluster_flavor="m5.xlarge"
region="us-east-1"
mke4k_version="v4.1.2"
os_distro="ubuntu-22.04"    # ubuntu-22.04 or ubuntu-24.04
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
1. Run `terraform init` + `terraform apply` (provisions EC2 + NLB + IAM)
2. Generate `terraform/mke4.yaml` from the provisioned infrastructure
3. Run `mkectl apply -f terraform/mke4.yaml`

## CLI Commands

| Command | Description |
|---|---|
| `./bin/t deploy lab` | Full deployment: instances + MKE4k cluster |
| `./bin/t deploy instances` | Terraform only (provision infrastructure) |
| `./bin/t deploy cluster` | mkectl only (install MKE4k on existing instances) |
| `./bin/t destroy lab` | Teardown: mkectl delete + terraform destroy |
| `./bin/t status` | Show cluster node status (`kubectl get nodes`) |
| `./bin/t show nodes` | Print IPs and NLB DNS name |

## Project Structure

```
mke4k-lab/
├── config                   # User-edited config (edit this)
├── bin/
│   ├── t                    # Thin launcher
│   └── t-commandline.bash   # CLI implementation
└── terraform/
    ├── main.tf              # Provider, SG, keypair, AMI lookup, mke4.yaml
    ├── variables.tf         # Variable declarations
    ├── controller.tf        # Controller EC2 instances
    ├── worker.tf            # Worker EC2 instances
    ├── loadbalancer.tf      # NLB + target groups + listeners
    ├── iam.tf               # IAM role + CCM policy + instance profile
    └── outputs.tf           # lb_dns_name, IPs, ssh key path
```

## What Terraform Creates

| Resource | Details |
|---|---|
| `tls_private_key` + `aws_key_pair` | RSA-4096 key pair, PEM saved to `terraform/aws_private.pem` |
| `aws_security_group` | Ports 22, 6443, 9443, 33001, 30080 + intra-cluster |
| `aws_instance` (controllers) | Ubuntu, `m5.xlarge` (configurable), 50GB gp3, CCM instance profile |
| `aws_instance` (workers) | Same as controllers |
| `aws_lb` (NLB) | Public, multi-AZ across default VPC subnets |
| `aws_lb_target_group` x3 | kube-api (6443), controller-join (9443), ingress (33001) |
| `aws_iam_role` + `aws_iam_policy` | AWS CCM minimum permissions |
| `aws_iam_instance_profile` | Attached to all EC2 instances |

## After Deployment

```bash
# Check node status
./bin/t status

# SSH to a controller
./bin/t show nodes
ssh -i terraform/aws_private.pem ubuntu/<controller-ip>

# Use kubectl directly
kubectl --kubeconfig ~/.mke/mke.kubeconf get nodes

# Teardown
./bin/t destroy lab
```

## Configuration Reference

| Variable | Default | Description |
|---|---|---|
| `cluster_name` | `mke4k-lab` | Name prefix for all resources |
| `controller_count` | `1` | Number of controller nodes |
| `worker_count` | `1` | Number of worker nodes |
| `cluster_flavor` | `m5.xlarge` | EC2 instance type |
| `region` | `us-east-1` | AWS region |
| `mke4k_version` | `v4.1.2` | MKE4k version to install |
| `os_distro` | `ubuntu-22.04` | OS: `ubuntu-22.04` or `ubuntu-24.04` |
