# Airgap deployments

[← Back to README](../README.md)

## Deploy

Cluster nodes sit in a private subnet with no internet; a bastion runs Harbor and the bundle is mirrored locally. CCM is auto-disabled (no AWS API from the private subnet).

```bash
# config
airgap_registry_disk_gb=100      # holds Harbor + the mirrored bundle
```

```bash
t deploy lab airgap
```

> Airgap bundles only exist for GA versions. If your chosen `mke4k_version` has no published bundle, either pick a GA version or set `mke4k_bundle_url=` to a reachable bundle.

## Accessing an airgap lab

Cluster nodes and the NLB are private. `t connect` jumps through the bastion automatically, and the UIs are reached through SSH tunnels — start the container with the matching `-p` port mappings.

```bash
t connect bastion        # the bastion / registry host
t connect m1             # controller-1, via the bastion
```

### Tunnels

| Command | Description |
|---|---|
| `t tunnel` | Show available SSH tunnels with manual commands |
| `t tunnel dashboard` | MKE4k Dashboard tunnel -> https://localhost:3000 |
| `t tunnel mke3` | MKE3 Dashboard tunnel -> https://localhost:3000 |
| `t tunnel registry` | Harbor Registry tunnel -> https://localhost:8443 (optional; the bastion's Harbor is also reachable directly at `https://<bastion-public-ip>`) |
| `t tunnel msr4` | MSR4 Harbor UI tunnel -> https://localhost:8444 |
| `t tunnel grafana` | KOF Grafana tunnel -> https://localhost:8443 (shares the local port with `t tunnel registry` — run one at a time) |

```bash
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
```

MSR4 on an airgap cluster: see [add-ons](addons.md#deploy-msr4-on-an-airgap-mke4k-cluster). KOF: see [KOF](kof.md#deploy-kof-on-an-airgap-cluster).

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
