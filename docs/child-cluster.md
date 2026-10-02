# MKE4k child cluster

[← Back to README](../README.md)

## Overview (online MKE4k only)

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
- `t destroy lab` and `t destroy cluster` delete the child **first** — while CAPA is still running to remove its AWS resources — and only then tear down the lab. They **refuse to continue** if the child can't be deleted, or if a child is recorded (`.child-cluster`) but the management cluster is unreachable. `T_SKIP_CHILD=1 t destroy lab` overrides this; the child's AWS resources are then left behind — remove them by tag `sigs.k8s.io/cluster-api-provider-aws/cluster/<cluster_name>-child` in the AWS console, in this order: EC2 instances, load balancer, NAT gateway + Elastic IP, then the VPC.
- **Auto-expiry and `bin/cleanup-aws.sh` do not cover the child** — they only find the lab's `Cluster`-tagged resources. Destroy the child before the lab expires.

**Limits:** one child per lab, named `<cluster_name>-child` (so its AWS resource names can't collide with another user's); the preflight refuses to start if CAPA resources for that name are left over from an earlier child.

## Example

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

## Child cluster settings

| Variable | Default | Description |
|---|---|---|
| `child_control_plane_count` | `1` | Child control-plane nodes (odd) |
| `child_worker_count` | `1` | Child worker nodes |
| `child_region` | `region` | AWS region for the child |
| `child_control_plane_flavor` / `child_worker_flavor` | *(template default: `m5.xlarge` / `m5.large`)* | EC2 instance types, rendered into `spec.infrastructure.configuration.{controlPlane,worker}.instanceType` |
| `child_az_limit` | `1` | Max AZs the child's CAPA VPC spans (`network.vpc.availabilityZoneUsageLimit`) |
| `child_ready_timeout` / `child_delete_timeout` | `30m` | How long to wait for Ready / deletion |
| `child_ssh_enabled` | `true` | SSH into child nodes via a CAPA bastion (`t connect m1-child`); set before creating the child. `false` = no bastion, no key |
| `child_ssh_allowed_cidr` | *(your public IP/32)* | CIDR allowed to reach the child bastion |
| `child_admin_enabled` | `true` | Create a Dex `admin` login + RBAC for the child UI (password → `terraform/child_credentials.txt`) |

The child's MKE4k version is not configurable: `MkeChildConfig` `spec.version` always equals the deployed `mke4k_version` (`vX.Y.Z` — the docs require it to match the management cluster). The preflight also warns when the region lacks Elastic IP quota (CAPA needs one per AZ).
