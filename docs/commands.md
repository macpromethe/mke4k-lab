# CLI reference

[← Back to README](../README.md)

## MKE4k (default)

| Command | Description |
|---|---|
| `t deploy lab` | Full deployment: Terraform + mkectl apply |
| `t deploy instances` | Terraform only (provision infrastructure) |
| `t deploy cluster` | mkectl only (install MKE4k on existing instances) |
| `t destroy cluster` | Uninstall MKE4k (mkectl reset --force) |
| `t destroy lab` | Teardown all AWS infrastructure (terraform destroy); deletes any child cluster first |

## MKE3

| Command | Description |
|---|---|
| `t deploy lab mke3` | Full: Terraform (both NLBs) + launchpad apply |
| `t deploy instances mke3` | Terraform with MKE3 NLB enabled |
| `t deploy cluster mke3` | launchpad apply on existing instances |
| `t destroy cluster mke3` | Uninstall MKE3 (launchpad reset --force) |

## Airgap (MKE4k)

| Command | Description |
|---|---|
| `t deploy lab airgap` | Full: Terraform + registry setup + bundle upload + mkectl (from bastion) |
| `t deploy instances airgap` | Terraform only (bastion + private-subnet nodes) |
| `t deploy registry` | Setup MSR4 on bastion + download & upload MKE4k bundle |
| `t deploy cluster airgap` | mkectl apply from bastion (registry must exist) |
| `t destroy cluster airgap` | Uninstall MKE4k from bastion (mkectl reset) |

## Airgap (MKE3)

| Command | Description |
|---|---|
| `t deploy lab mke3-airgap` | Full: Terraform + registry + proxy + MKE3 images + launchpad (from bastion) |
| `t deploy instances mke3-airgap` | Terraform only (bastion + private-subnet nodes + both NLBs) |
| `t deploy registry mke3` | Setup MSR4 on bastion + download & upload MKE3 images |
| `t deploy cluster mke3-airgap` | DNS + proxy + launchpad apply from bastion |
| `t destroy cluster mke3-airgap` | Uninstall MKE3 from bastion (launchpad reset) |

## Cluster configuration

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

## Tunnels (airgap)

| Command | Description |
|---|---|
| `t tunnel` | Show available SSH tunnels with manual commands |
| `t tunnel dashboard` | MKE4k Dashboard tunnel -> https://localhost:3000 |
| `t tunnel mke3` | MKE3 Dashboard tunnel -> https://localhost:3000 |
| `t tunnel registry` | Harbor Registry tunnel -> https://localhost:8443 (optional; the bastion's Harbor is also reachable directly at `https://<bastion-public-ip>`) |
| `t tunnel msr4` | MSR4 Harbor UI tunnel -> https://localhost:8444 |
| `t tunnel grafana` | KOF Grafana tunnel -> https://localhost:8443 (shares the local port with `t tunnel registry` — run one at a time) |

## General

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

## Add-ons and child cluster

See [add-ons](addons.md) (NFS, MSR4, k0rdent UI), [KOF](kof.md) and [child cluster](child-cluster.md).
