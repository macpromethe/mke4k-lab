# mke4k-lab

**Your tool for provisioning [Mirantis Kubernetes Engine 4k](https://www.mirantis.com/software/mke-4/) and MKE3 lab clusters on AWS — fast to stand up, fast to throw away.**

Need a cluster to reproduce an issue, test an upgrade, try a feature or run a demo? Edit one config file, run `t deploy lab`, and you get a fully installed cluster with a summary of its URLs and node IPs. Done with it? `t destroy lab` removes every AWS resource it created.

- **One command each way.** Terraform provisions a dedicated VPC, EC2 instances, load balancer and IAM; `mkectl` / `launchpad` installs the product on top. No manual AWS setup.
- **Nothing to install.** Everything runs in a Docker container that already has Terraform, kubectl, helm, the AWS CLI and k9s; `mkectl` is fetched at the version you pick.
- **Isolated and self-cleaning.** Each lab gets its own VPC, tagged with your name, and deletes itself after a few days (`expiry_days`) if you forget it.
- **Four deployment modes:** **MKE4k** (default), **MKE4k airgap** (no internet on the nodes, with a private MSR4 registry), **MKE3** (for upgrade testing) and **MKE3 airgap**.
- **Add-ons on demand:** NFS storage, MSR4, KOF observability, the k0rdent UI, and MKE4k **child clusters** provisioned through k0rdent.

## Quick start

### 1. Run the container

```bash
docker run -it --name mke4k-lab registry.ci.mirantis.com/ajagiello/mke4k-lab:latest
```

**Need airgap?** Run it with the ports for the UI tunnels instead:

```bash
docker run -it --name mke4k-lab \
  -p 3000:3000 -p 8443:8443 -p 8444:8444 -p 8445:8445 \
  registry.ci.mirantis.com/ajagiello/mke4k-lab:latest
# 3000 = MKE dashboard, 8443 = KOF Grafana / registry, 8444 = MSR4 UI, 8445 = k0rdent UI
```

The latest image is always published to `registry.ci.mirantis.com/ajagiello/mke4k-lab:latest` and includes every change in this repo. To build it yourself, see [docs/development.md](docs/development.md).

To pass AWS credentials from your host, add `-e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_SESSION_TOKEN`. Lab state lives inside the container, so keep it: re-attach later with `docker start -ai mke4k-lab`.

### 2. Set your AWS credentials

Skip this if you passed them with `docker run -e`.

```bash
export AWS_ACCESS_KEY_ID="..."
export AWS_SECRET_ACCESS_KEY="..."
export AWS_SESSION_TOKEN="..."      # temporary credentials only
```

### 3. Edit the config

Version, node counts, add-ons. The defaults work as-is.

```bash
vi /mke4k-lab/config
```

### 4. Deploy

```bash
t deploy lab
```

### 5. Use the cluster

When the deploy finishes it prints a **summary**: cluster name and version, expiry date, node IPs, the load balancer URL, and the URLs and logins of any add-ons. Reprint it any time with `t show summary`.

The **kubeconfig lives inside the container** (`/root/.mke/mke.kubeconf`) and `KUBECONFIG` already points at it, so `kubectl`, `helm` and `k9s` work right away:

```bash
kubectl get nodes      # or: t status
k9s
t connect m1           # SSH to controller-1 (w1 = worker-1)
```

- **MKE dashboard:** `https://<load balancer DNS>` from the summary. `mkectl` prints the admin login at the end of the install output — note it down, it isn't saved by the tool.
- **kubectl from your host:** copy the kubeconfig out with `docker cp mke4k-lab:/root/.mke/mke.kubeconf .` (online labs; an airgap API is only reachable through the bastion).

### 6. Destroy when done

```bash
t destroy lab
```

Labs also delete themselves after `expiry_days` (default 3) — change it with `t expiry <days>`.

## Examples

Each example is a few lines in `config` plus one command. Only the lines that differ from the defaults are shown.

### HA control plane, with LoadBalancer support

```bash
# config
controller_count=3
worker_count=2
ccm_enabled=true
```

```bash
t deploy lab
```

### Airgapped MKE4k

Nodes have no internet; a bastion hosts the MSR4 registry. See [Airgap](#airgap).

```bash
t deploy lab airgap
```

### MKE3, then test the upgrade to MKE4k

The summary prints a ready-to-paste `mkectl upgrade` command.

```bash
t deploy lab mke3
```

### KOF observability

MKE 4.2+. Grafana over HTTPS, login in the summary. More: [docs/kof.md](docs/kof.md).

```bash
# config
kof_enabled=true      # or run 't deploy kof' on a running lab
```

```bash
t deploy lab
```

### MSR4 registry on the cluster

```bash
# config
msr4_enabled=true
```

```bash
t deploy lab
t deploy msr4         # https://<node>:33443, password in terraform/msr4_credentials.txt
```

### MKE4k child cluster

Online MKE4k, on a running lab. UI login and SSH included. More: [docs/child-cluster.md](docs/child-cluster.md).

```bash
t deploy child-cluster
t connect m1-child
t destroy child-cluster   # or just 't destroy lab' — it removes the child first
```

## Airgap

In an airgap lab the cluster nodes and the load balancer are private; a bastion in the public subnet runs the MSR4 registry. The `t` commands handle the hop for you:

```bash
t connect bastion      # SSH to the bastion
t connect m1           # SSH to a node (through the bastion)
t tunnel               # list the UI tunnels
t tunnel dashboard     # MKE4k / MKE3 dashboard -> https://localhost:3000
t tunnel grafana       # KOF Grafana            -> https://localhost:8443
t tunnel msr4          # MSR4 UI                -> https://localhost:8444
t tunnel k0rdent-ui    # k0rdent UI             -> https://localhost:8445
```

Tunnels need the matching `-p` port mappings on `docker run`. The bastion's registry UI is also reachable directly at `https://<bastion-public-ip>`. Details: [docs/airgap.md](docs/airgap.md).

## Everyday commands

| Command | What it does |
|---|---|
| `t status` | `kubectl get nodes` |
| `t show summary` | Reprint the deploy summary (URLs, node IPs, add-on logins) |
| `t show nodes` | Node IPs and load balancer DNS |
| `t connect m1` / `w1` | SSH to controller-1 / worker-1 (`t connect m1 "cmd"` runs one command) |
| `t config edit` | Edit the running cluster's configuration |
| `t expiry <days>` | Change the auto-delete deadline (`t expiry off` disables it) |
| `t help` | All commands |

## Emergency cleanup

If the container (and with it the Terraform state) is lost, delete the lab's AWS resources by tag:

```bash
./bin/cleanup-aws.sh <cluster-name> [region]      # e.g. mke4k-lab-a3f2 eu-central-1
```

It lists everything first and asks before each step. It does not cover child clusters — see [docs/child-cluster.md](docs/child-cluster.md).

## Documentation

| Doc | Contents |
|---|---|
| [CLI reference](docs/commands.md) | Every `t` command, `t config get/apply/edit`, tunnels |
| [Configuration](docs/configuration.md) | Every `config` setting |
| [Airgap](docs/airgap.md) | Airgap deploys, access, architecture and traffic flows |
| [Add-ons](docs/addons.md) | NFS, MSR4, k0rdent UI |
| [KOF](docs/kof.md) | KOF observability: modes, Grafana, airgap |
| [Child cluster](docs/child-cluster.md) | MKE4k child clusters: prerequisites, access, SSH, credentials, teardown |
| [Development](docs/development.md) | Build the image, run without Docker, project layout, what Terraform creates |
