# KOF observability

[← Back to README](../README.md)

## Overview

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

## Examples

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
