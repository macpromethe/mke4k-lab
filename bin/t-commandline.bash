#!/usr/bin/env bash
# t-commandline.bash — mke4k-lab CLI
# Usage: t <command> [subcommand]
set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve project root (directory containing 'config')
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TERRAFORM_DIR="${PROJECT_ROOT}/terraform"
CONFIG_FILE="${PROJECT_ROOT}/config"
export KUBECONFIG="${HOME}/.mke/mke.kubeconf"

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

info()    { echo -e "${CYAN}[t]${RESET} $*"; }
success() { echo -e "${GREEN}[t]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[t]${RESET} $*"; }
error()   { echo -e "${RED}[t] ERROR:${RESET} $*" >&2; }
die()     { error "$*"; exit 1; }

# version_gte <a> <b> — returns 0 (true) if version a >= b
version_gte() { printf '%s\n%s\n' "$2" "$1" | sort -V -C; }

# Sanitize a user-typed name for use in AWS resource names: lowercase
# a-z/0-9/hyphen only, max 10 chars. AWS caps NLB/target-group names at 32
# chars and the longest generated name is <cluster_name>-mke3-nlb-sg (+12),
# so cluster_name must stay ≤ 20 chars → "mke4k-lab-" leaves 10 for the name.
sanitize_owner_name() {
    printf '%s' "${1}" \
        | tr '[:upper:]' '[:lower:]' \
        | tr -cd 'a-z0-9-' \
        | head -c 10 \
        | sed 's/^-*//; s/-*$//'
}

# ---------------------------------------------------------------------------
# Deploy phase timers
# ---------------------------------------------------------------------------
_T_DEPLOY_START=0
_T_PHASE_START=0
_T_TERRAFORM=0
_T_NLB=0
_T_MKECTL=0
_T_LAUNCHPAD=0
_T_REGISTRY=0
_T_BUNDLE=0
_T_PROXY=0
_T_MKE3_IMAGES=0
_T_NFS=0

timer_deploy_start() {
    _T_DEPLOY_START=$(date +%s)
    _T_PHASE_START=${_T_DEPLOY_START}
}

timer_phase_end() {
    local var_name="$1"
    local now; now=$(date +%s)
    printf -v "${var_name}" '%d' $(( now - _T_PHASE_START ))
    _T_PHASE_START=${now}
}

fmt_duration() {
    local s=$1
    printf "%dm %02ds" $(( s / 60 )) $(( s % 60 ))
}

# Format the reaper's expiry-time output ("2026-07-24T12:00:00Z") for a
# summary box: "2026-07-24 12:00 UTC (${expiry_days}d)". Empty input -> never.
fmt_expiry() {
    local t="$1"
    if [[ -z "${t}" ]]; then
        printf "never (expiry_days=0)"
        return
    fi
    t="${t/T/ }"        # 2026-07-24 12:00:00Z
    t="${t%Z}"          # 2026-07-24 12:00:00
    t="${t%:*}"         # 2026-07-24 12:00
    local suffix=""
    [[ "${expiry_dry_run:-false}" == "true" ]] && suffix=" [DRY-RUN]"
    printf "%s UTC (%sd)%s" "${t}" "${expiry_days:-?}" "${suffix}"
}

# ---------------------------------------------------------------------------
# Source config and write terraform.tfvars
# ---------------------------------------------------------------------------
load_config() {
    [[ -f "${CONFIG_FILE}" ]] || die "config file not found at ${CONFIG_FILE}"
    # shellcheck source=/dev/null
    source "${CONFIG_FILE}"

    # Auto-generate a unique suffix when cluster_name is the bare default.
    # This prevents resource collisions when multiple people deploy simultaneously.
    # Resource-creating commands (t deploy lab|instances, via _T_ASK_NAME) first
    # ask for the user's name so both the user and the cloud admin can identify
    # the resources (mke4k-lab-<name> prefix + Owner tag). Non-interactive runs
    # and all other commands fall back to a random 4-char suffix.
    # The suffix is persisted in .cluster-id so it stays consistent across commands.
    if [[ "${cluster_name}" == "mke4k-lab" ]]; then
        local id_file="${PROJECT_ROOT}/.cluster-id"
        if [[ ! -f "${id_file}" ]]; then
            local suffix=""
            if [[ "${_T_ASK_NAME:-false}" == "true" && -t 0 ]]; then
                echo ""
                echo -e "${BOLD}Please type your name so that you and the cloud admin can identify your AWS resources.${RESET}"
                local raw_name=""
                read -r -p "  Name (a-z, 0-9, max 10 chars; empty = random ID): " raw_name || true
                suffix="$(sanitize_owner_name "${raw_name}")"
                if [[ -n "${suffix}" ]]; then
                    [[ "${suffix}" != "${raw_name}" ]] && warn "Name sanitised to '${suffix}'."
                    echo "${suffix}" > "${PROJECT_ROOT}/.owner"
                elif [[ -n "${raw_name}" ]]; then
                    warn "Name '${raw_name}' has no usable characters — using a random ID instead."
                fi
            fi
            if [[ -z "${suffix}" ]]; then
                suffix="$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 4)"
            fi
            echo "${suffix}" > "${id_file}"
            info "Cluster name: mke4k-lab-${suffix} (saved to .cluster-id)"
        fi
        cluster_name="mke4k-lab-$(cat "${id_file}")"
    fi

    # Owner name (set by the deploy-time prompt) → Owner tag on all AWS resources
    lab_owner="$(cat "${PROJECT_ROOT}/.owner" 2>/dev/null || true)"

    # Validate required variables
    : "${cluster_name:?cluster_name not set in config}"
    : "${controller_count:?controller_count not set in config}"
    : "${worker_count:?worker_count not set in config}"
    : "${controller_flavor:?controller_flavor not set in config}"
    : "${worker_flavor:?worker_flavor not set in config}"
    : "${region:?region not set in config}"
    : "${mke4k_version:?mke4k_version not set in config}"

    # Cluster node OS. Legacy configs set os_distro="ubuntu-22.04"; map it.
    if [[ -z "${os_name:-}" && -n "${os_distro:-}" ]]; then
        os_name="${os_distro%%-*}"
        os_version="${os_distro#*-}"
        warn "os_distro is deprecated — set os_name=\"${os_name}\" os_version=\"${os_version}\" in config instead."
    fi
    : "${os_name:?os_name not set in config (ubuntu | redhat)}"
    : "${os_version:?os_version not set in config (e.g. 22.04, 9.6)}"
    case "${os_name}" in
        ubuntu|redhat) ;;
        *) die "os_name must be 'ubuntu' or 'redhat' (got: ${os_name})" ;;
    esac
    # MKE4-documented support matrix — warn (not die) on other versions
    case "${os_name}-${os_version}" in
        ubuntu-22.04|ubuntu-24.04|redhat-9.6|redhat-8.10) ;;
        *) warn "${os_name} ${os_version} is not in the MKE4 supported OS matrix (ubuntu 22.04/24.04, redhat 9.6/8.10) — continuing anyway." ;;
    esac

    # ccm_enabled defaults to true if not present in config
    ccm_enabled="${ccm_enabled:-true}"

    # Auto-expiry: whole-lab teardown N days after creation (0 = never).
    # '.expiry-days' / '.expiry-base' override files (written by 't expiry')
    # take precedence over config so the imperative deadline survives later
    # tfvars regeneration; delete them (or 't destroy lab') to reset to config.
    if [[ -f "${PROJECT_ROOT}/.expiry-days" ]]; then
        expiry_days="$(cat "${PROJECT_ROOT}/.expiry-days")"
    else
        expiry_days="${expiry_days:-3}"
    fi
    [[ "${expiry_days}" =~ ^[0-9]+$ ]] || die "expiry_days must be a non-negative integer (got: ${expiry_days})"
    # Countdown anchor: empty = creation time; set to "now" by 't expiry <N>'.
    expiry_base="$(cat "${PROJECT_ROOT}/.expiry-base" 2>/dev/null || true)"
    # Dry-run mode for the reaper (logs would-delete, deletes nothing).
    expiry_dry_run="${expiry_dry_run:-false}"

    # MKE3 defaults (only used when deploying MKE3)
    mke3_version="${mke3_version:-3.8.2}"
    mcr_version="${mcr_version:-25.0.14}"
    mcr_channel="${mcr_channel:-stable-25.0.14}"
    mke3_admin_username="${mke3_admin_username:-admin}"
    launchpad_version="${launchpad_version:-1.5.15}"

    # Airgap defaults
    airgap_registry_flavor="${airgap_registry_flavor:-t3.xlarge}"
    airgap_registry_disk_gb="${airgap_registry_disk_gb:-100}"
    airgap_msr_version="${airgap_msr_version:-v4.13.3}"
    registry_hostname="registry.${cluster_name}.local"

    # NFS defaults
    nfs_enabled="${nfs_enabled:-false}"
    nfs_flavor="${nfs_flavor:-t3.small}"
    nfs_disk_gb="${nfs_disk_gb:-150}"
    nfs_export_path="${nfs_export_path:-/srv/nfs/data}"

    # MSR4 defaults
    msr4_enabled="${msr4_enabled:-false}"
    msr4_version="${msr4_version:-4.13.3}"
    msr4_replicas="${msr4_replicas:-1}"
    msr4_postgres_version="${msr4_postgres_version:-1.15.1}"
    msr4_redis_operator_version="${msr4_redis_operator_version:-0.24.0}"
    msr4_redis_replication_version="${msr4_redis_replication_version:-0.16.13}"
    msr4_storage_size="${msr4_storage_size:-10Gi}"

    # KOF defaults
    kof_enabled="${kof_enabled:-false}"
    kof_mode="${kof_mode:-lean}"
    kof_storage_ha="${kof_storage_ha:-true}"
    # Reuse MKE4's built-in monitoring: drop KOF's duplicate node-exporter (KOF
    # already scrapes MKE's via cluster-wide ServiceMonitor discovery) + add MKE's
    # Prometheus as a Grafana datasource. KSM is kept (unique k0rdent CR metrics).
    kof_reuse_mke_monitoring="${kof_reuse_mke_monitoring:-true}"
    # Sub-option of reuse: also drop KOF's duplicate kubelet/cAdvisor scrape so
    # pod CPU/memory aren't double-counted. On by default when reuse is enabled.
    kof_reuse_mke_kubelet="${kof_reuse_mke_kubelet:-true}"
    # Wire the Alertmanager Salesforce route (severity critical|warning|error ->
    # sf-notifier webhook). sf-notifier itself is deployed by hand (KOF-ON-MKE4.md
    # §7.8); this only adds the routing. Default off (a route to a missing sf-notifier
    # fires AlertmanagerFailedToSendAlerts).
    kof_sf_notifier_enabled="${kof_sf_notifier_enabled:-false}"
    kof_version="${kof_version:-1.8.1}"
    kof_storage_size="${kof_storage_size:-10Gi}"
    kof_registry="${kof_registry:-registry.mirantis.com/k0rdent-enterprise}"
    kof_kcm_namespace="${kof_kcm_namespace:-k0rdent}"
    # Lean-mode dashboard prune lists, comma-separated (folder names contain spaces)
    kof_lean_prune_folders="${kof_lean_prune_folders:-Istio,Opencost,Victoria Traces}"
    kof_lean_prune_dashboards="${kof_lean_prune_dashboards:-kps-nodes-aix,kps-nodes-darwin}"
    kof_grafana_enabled="${kof_grafana_enabled:-true}"
    kof_grafana_image_tag="${kof_grafana_image_tag:-11.0.0}"
    kof_grafana_gateway_enabled="${kof_grafana_gateway_enabled:-true}"
    kof_grafana_nodeport="${kof_grafana_nodeport:-33002}"
    kof_grafana_lb_port="${kof_grafana_lb_port:-8443}"

    # k0rdent UI defaults
    k0rdent_ui_enabled="${k0rdent_ui_enabled:-false}"
    k0rdent_ui_nodeport="${k0rdent_ui_nodeport:-33003}"
    k0rdent_ui_lb_port="${k0rdent_ui_lb_port:-8445}"

    # MKE4k child cluster defaults (one child per lab, named after the lab so
    # its CAPA VPC/ELB names can't collide with another user's child).
    child_name="${cluster_name}-child"
    child_control_plane_count="${child_control_plane_count:-1}"
    child_worker_count="${child_worker_count:-1}"
    child_region="${child_region:-${region}}"
    # MkeChildConfig spec.version must match the management cluster's version,
    # in vX.Y.Z form (official docs) — i.e. mke4k_version verbatim.
    child_version="${mke4k_version}"
    child_az_limit="${child_az_limit:-1}"
    child_control_plane_flavor="${child_control_plane_flavor:-}"
    child_worker_flavor="${child_worker_flavor:-}"
    child_ready_timeout="${child_ready_timeout:-30m}"
    child_delete_timeout="${child_delete_timeout:-30m}"
    child_admin_enabled="${child_admin_enabled:-true}"
    child_ssh_enabled="${child_ssh_enabled:-true}"
    child_ssh_allowed_cidr="${child_ssh_allowed_cidr:-}"
    if [[ -n "${child_ssh_allowed_cidr}" ]]; then
        [[ "${child_ssh_allowed_cidr}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] \
            || die "child_ssh_allowed_cidr must be an IPv4 CIDR like 203.0.113.7/32 (got: ${child_ssh_allowed_cidr})"
    fi
    [[ "${child_control_plane_count}" =~ ^[1-9][0-9]*$ && $(( child_control_plane_count % 2 )) -eq 1 ]] \
        || die "child_control_plane_count must be an odd integer >= 1 (got: ${child_control_plane_count})"
    [[ "${child_worker_count}" =~ ^[0-9]+$ ]] || die "child_worker_count must be a non-negative integer (got: ${child_worker_count})"
    [[ "${child_az_limit}" =~ ^[1-9][0-9]*$ ]] || die "child_az_limit must be an integer >= 1 (got: ${child_az_limit})"
}

msr4_credentials_file() {
    printf '%s\n' "${TERRAFORM_DIR}/msr4_credentials.txt"
}

ensure_msr4_admin_credentials() {
    local creds_file admin_pass
    creds_file="$(msr4_credentials_file)"

    if [[ -f "${creds_file}" ]]; then
        admin_pass="$(grep '^password=' "${creds_file}" | cut -d= -f2)"
        [[ -n "${admin_pass}" ]] || die "MSR4 credentials file is malformed: ${creds_file}"
        info "Reusing MSR4 admin credentials from $(basename "${creds_file}")" >&2
    else
        admin_pass="$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 20)"
        printf 'username=admin\npassword=%s\n' "${admin_pass}" > "${creds_file}"
        chmod 600 "${creds_file}"
        info "Generated MSR4 admin credentials -> $(basename "${creds_file}")" >&2
    fi

    printf '%s\n' "${admin_pass}"
}

mke3_credentials_file() {
    printf '%s\n' "${TERRAFORM_DIR}/mke3_credentials.txt"
}

# Echo the MKE3 admin credentials as "<username>\t<password>".
# Consume with:  IFS=$'\t' read -r user pass < <(read_mke3_credentials)
# Falls back to mke3_admin_username / a "(see ...)" placeholder for display-only
# callers; pass "strict" to die instead when the file is missing or malformed.
read_mke3_credentials() {
    local strict="${1:-}"
    local creds_file admin_user admin_pass
    creds_file="$(mke3_credentials_file)"

    admin_user="$(grep '^username=' "${creds_file}" 2>/dev/null | cut -d= -f2 || true)"
    admin_pass="$(grep '^password=' "${creds_file}" 2>/dev/null | cut -d= -f2 || true)"

    if [[ "${strict}" == "strict" ]]; then
        [[ -f "${creds_file}" ]] \
            || die "MKE3 credentials not found: ${creds_file}. Deploy MKE3 first (t deploy lab mke3)."
        [[ -n "${admin_user}" && -n "${admin_pass}" ]] \
            || die "MKE3 credentials file is malformed: ${creds_file}"
    else
        [[ -n "${admin_user}" ]] || admin_user="${mke3_admin_username:-admin}"
        [[ -n "${admin_pass}" ]] || admin_pass="(see ${creds_file})"
    fi

    printf '%s\t%s\n' "${admin_user}" "${admin_pass}"
}

write_tfvars() {
    local mke3_enabled="${1:-false}"
    local airgap_enabled="${2:-false}"
    # CCM requires internet access to AWS APIs — force off in airgap mode
    local effective_ccm="${ccm_enabled}"
    [[ "${airgap_enabled}" == "true" ]] && effective_ccm=false
    cat > "${TERRAFORM_DIR}/terraform.tfvars" <<EOF
cluster_name             = "${cluster_name}"
owner                    = "${lab_owner:-}"
controller_count         = ${controller_count}
worker_count             = ${worker_count}
controller_flavor        = "${controller_flavor}"
worker_flavor            = "${worker_flavor}"
region                   = "${region}"
expiry_days              = ${expiry_days}
expiry_dry_run           = ${expiry_dry_run}
expiry_base              = "${expiry_base:-}"
mke4k_version            = "${mke4k_version}"
os_name                  = "${os_name}"
os_version               = "${os_version}"
ccm_enabled              = ${effective_ccm}
mke3_enabled             = ${mke3_enabled}
airgap_enabled           = ${airgap_enabled}
airgap_registry_flavor   = "${airgap_registry_flavor}"
airgap_registry_disk_gb  = ${airgap_registry_disk_gb}
nfs_enabled              = ${nfs_enabled}
nfs_flavor               = "${nfs_flavor}"
nfs_disk_gb              = ${nfs_disk_gb}
kof_grafana_gateway_enabled = ${kof_grafana_gateway_enabled:-true}
kof_grafana_nodeport     = ${kof_grafana_nodeport:-33002}
kof_grafana_lb_port      = ${kof_grafana_lb_port:-8443}
k0rdent_ui_enabled       = ${k0rdent_ui_enabled:-false}
k0rdent_ui_nodeport      = ${k0rdent_ui_nodeport:-33003}
k0rdent_ui_lb_port       = ${k0rdent_ui_lb_port:-8445}
EOF
    info "Wrote terraform/terraform.tfvars"
}

# ---------------------------------------------------------------------------
# Terraform helpers
# ---------------------------------------------------------------------------
tf_init() {
    info "Running terraform init..."
    terraform -chdir="${TERRAFORM_DIR}" init -input=false
}

tf_apply() {
    info "Running terraform apply..."
    terraform -chdir="${TERRAFORM_DIR}" apply -auto-approve -compact-warnings
}

tf_destroy() {
    info "Running terraform destroy..."
    terraform -chdir="${TERRAFORM_DIR}" destroy -auto-approve -compact-warnings
}

tf_output() {
    terraform -chdir="${TERRAFORM_DIR}" output -json 2>/dev/null
}

# Echo "airgap" or "online" based on whether terraform provisioned a bastion.
# Optional arg: a pre-fetched tf_output JSON blob (avoids a second terraform call).
detect_deploy_mode() {
    local output="${1:-}"
    [[ -n "${output}" ]] || output="$(tf_output)"
    local bastion_ip
    bastion_ip="$(echo "${output}" | jq -r '.bastion_public_ip.value // empty' 2>/dev/null)"
    if [[ -n "${bastion_ip}" && "${bastion_ip}" != "null" ]]; then
        printf 'airgap\n'
    else
        printf 'online\n'
    fi
}

# ---------------------------------------------------------------------------
# mkectl — download on demand, version pinned to mke4k_version from config
# ---------------------------------------------------------------------------
# Override the download URL by setting MKECTL_DOWNLOAD_URL in the environment.
# Default pattern: https://github.com/Mirantis/mke4/releases/download/<ver>/mkectl_linux_amd64
ensure_mkectl() {
    local want="${mke4k_version}"
    local install_path="/usr/local/bin/mkectl"
    local tarball="mkectl_linux_x86_64.tar.gz"
    local url="${MKECTL_DOWNLOAD_URL:-https://github.com/MirantisContainers/mke-release/releases/download/${want}/${tarball}}"

    # Already at the right version?
    if command -v mkectl &>/dev/null; then
        local got
        got="$(mkectl version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
        if [[ "${got}" == "${want}" ]]; then
            return 0
        fi
        [[ -n "${got}" ]] && warn "mkectl ${got} found, want ${want} — re-downloading"
    fi

    info "Downloading mkectl ${want}..."
    info "  URL: ${url}"
    local tmpdir
    tmpdir="$(mktemp -d)"
    if ! curl -fsSL "${url}" -o "${tmpdir}/${tarball}"; then
        rm -rf "${tmpdir}"
        die "Failed to download mkectl ${want}.\n  URL tried: ${url}\n  Set MKECTL_DOWNLOAD_URL env var to override."
    fi
    tar -xzf "${tmpdir}/${tarball}" -C "${tmpdir}"
    install -m 755 "${tmpdir}/mkectl" "${install_path}"
    rm -rf "${tmpdir}"
    success "mkectl ${want} ready."
}

# ---------------------------------------------------------------------------
# SSH helpers (used for airgap bastion and general remote commands)
# ---------------------------------------------------------------------------

# SSH login user for CLUSTER NODES (controllers/workers). The bastion and NFS
# server always run Ubuntu, so anything targeting them uses the literal "ubuntu".
node_ssh_user() {
    case "${os_name:-}" in
        redhat) echo "ec2-user" ;;
        *)      echo "ubuntu"   ;;
    esac
}

# Ubuntu version of the bastion/NFS server: follows os_version when the cluster
# nodes are Ubuntu, pinned to 22.04 otherwise.
# NOTE: keep in sync with local.bastion_os_version in terraform/main.tf.
bastion_os_version() {
    case "${os_name:-}" in
        ubuntu) echo "${os_version}" ;;
        *)      echo "22.04"         ;;
    esac
}

# Run a command on a remote host via SSH, explicit login user
ssh_host() {
    local user="${1}" ssh_key="${2}" ip="${3}"
    shift 3
    ssh -q -o StrictHostKeyChecking=no -o ConnectTimeout=10 -i "${ssh_key}" "${user}@${ip}" "$@"
}

# Run a command on an Ubuntu host via SSH (bastion, NFS server, or ubuntu nodes)
ssh_node() {
    ssh_host ubuntu "$@"
}

# Run a command on a remote host via SSH through bastion (ProxyJump), explicit
# target user. The ProxyCommand user is always ubuntu (the bastion).
ssh_via_bastion() {
    local user="${1}" ssh_key="${2}" bastion_ip="${3}" ip="${4}"
    shift 4
    ssh -q -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        -i "${ssh_key}" \
        -o "ProxyCommand=ssh -q -o StrictHostKeyChecking=no -i ${ssh_key} -W %h:%p ubuntu@${bastion_ip}" \
        "${user}@${ip}" "$@"
}

# Run a command on a CLUSTER NODE via SSH through bastion (user follows os_name)
ssh_node_via_bastion() {
    ssh_via_bastion "$(node_ssh_user)" "$@"
}

# Wait for SSH to become available (explicit login user)
wait_for_ssh_host() {
    local user="${1}" ssh_key="${2}" ip="${3}" label="${4:-host}" max_wait=180
    info "Waiting for ${label} SSH (${ip})..."
    for (( i=0; i<max_wait; i+=5 )); do
        if ssh_host "${user}" "${ssh_key}" "${ip}" "true" 2>/dev/null; then
            return 0
        fi
        sleep 5
    done
    die "${label} not reachable after ${max_wait}s"
}

# Wait for SSH on an Ubuntu host (bastion, NFS server)
wait_for_ssh() {
    wait_for_ssh_host ubuntu "$@"
}

# Wait for SSH on a CLUSTER NODE reached through the bastion (ProxyJump)
wait_for_ssh_node_via_bastion() {
    local ssh_key="${1}" bastion_ip="${2}" ip="${3}" label="${4:-node}" max_wait=300
    info "Waiting for ${label} SSH (${ip} via bastion)..."
    for (( i=0; i<max_wait; i+=5 )); do
        if ssh_node_via_bastion "${ssh_key}" "${bastion_ip}" "${ip}" "true" 2>/dev/null; then
            return 0
        fi
        sleep 5
    done
    die "${label} not reachable after ${max_wait}s"
}

# ---------------------------------------------------------------------------
# Airgap — registry setup (Docker + MSR4/Harbor on bastion)
# ---------------------------------------------------------------------------
setup_registry() {
    local output ssh_key bastion_ip bastion_private_ip
    output="$(tf_output)"
    ssh_key="$(echo "${output}" | jq -r '.ssh_key_path.value')"
    bastion_ip="$(echo "${output}" | jq -r '.bastion_public_ip.value')"
    bastion_private_ip="$(echo "${output}" | jq -r '.bastion_private_ip.value')"

    [[ -z "${bastion_ip}" || "${bastion_ip}" == "null" ]] \
        && die "bastion_public_ip is empty. Was terraform applied with airgap_enabled=true?"

    wait_for_ssh "${ssh_key}" "${bastion_ip}" "bastion"

    # Generate registry password (reuse if exists)
    local creds_file="${TERRAFORM_DIR}/registry_credentials.txt"
    local registry_pass
    if [[ -f "${creds_file}" ]]; then
        registry_pass="$(grep '^password=' "${creds_file}" | cut -d= -f2)"
        info "Reusing registry credentials from $(basename "${creds_file}")"
    else
        registry_pass="$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 20)"
        printf 'username=admin\npassword=%s\n' "${registry_pass}" > "${creds_file}"
        chmod 600 "${creds_file}"
        info "Generated registry credentials → $(basename "${creds_file}")"
    fi

    info "Setting up MSR4 (Harbor) on bastion (${bastion_ip})..."

    local reg_host="${registry_hostname}"

    # Determine apt suite from the bastion's Ubuntu version (22.04 → jammy, 24.04 → noble).
    # The bastion is always Ubuntu regardless of the cluster node OS.
    local apt_suite
    case "$(bastion_os_version)" in
        22.04) apt_suite="jammy" ;;
        24.04) apt_suite="noble" ;;
        *)     die "Unsupported bastion Ubuntu version for MCR install: $(bastion_os_version)" ;;
    esac

    # Install MCR + docker-compose-plugin-ee + bind9 (idempotent)
    ssh_node "${ssh_key}" "${bastion_ip}" "
        set -euo pipefail
        if ! command -v docker &>/dev/null; then
            echo '>>> Installing MCR + docker-compose-plugin-ee + bind9...'
            sudo apt-get update -qq
            sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl gnupg2 >/dev/null 2>&1

            # Mirantis GPG key + apt repo
            curl -fsSL https://repos.mirantis.com/ubuntu/gpg | \
                sudo gpg --batch --yes --dearmor -o /usr/share/keyrings/mirantis-archive-keyring.gpg
            echo 'Types: deb
URIs: https://repos.mirantis.com/ubuntu
Suites: ${apt_suite}
Architectures: amd64
Components: stable-25.0
Signed-by: /usr/share/keyrings/mirantis-archive-keyring.gpg' | sudo tee /etc/apt/sources.list.d/mirantis.sources >/dev/null

            sudo apt-get update -qq
            sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-ee docker-compose-plugin-ee bind9 bind9utils >/dev/null 2>&1
            sudo usermod -aG docker ubuntu

            # Harbor's install.sh calls 'docker-compose' (standalone); bridge to plugin
            sudo ln -sf /usr/libexec/docker/cli-plugins/docker-compose /usr/local/bin/docker-compose

            # Pull skopeo container image (pinned version, more reliable than apt)
            echo '>>> Pulling skopeo container image...'
            sudo docker pull quay.io/skopeo/stable:v1.18.0
        else
            echo '>>> Docker already installed'
            # Ensure bind9 is present even if Docker was already installed
            if ! command -v named &>/dev/null; then
                echo '>>> Installing bind9...'
                sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq bind9 bind9utils >/dev/null 2>&1
            fi
        fi
    "

    # Configure bind9 DNS on bastion (resolves registry hostname for cluster nodes)
    info "Configuring DNS (bind9) on bastion..."
    ssh_node "${ssh_key}" "${bastion_ip}" "
        set -euo pipefail

        # Zone file
        sudo mkdir -p /etc/bind/zones
        sudo tee /etc/bind/zones/db.${reg_host} > /dev/null <<'ZONEOF'
\$TTL 86400
@   IN  SOA ns1.${reg_host}. admin.${reg_host}. (
        2025010101  ; Serial
        3600        ; Refresh
        1800        ; Retry
        604800      ; Expire
        86400       ; Minimum TTL
)
@       IN  NS  ns1.${reg_host}.
ns1     IN  A   ${bastion_private_ip}
@       IN  A   ${bastion_private_ip}
ZONEOF

        # named.conf.local — add zone
        if ! grep -q '${reg_host}' /etc/bind/named.conf.local 2>/dev/null; then
            sudo tee -a /etc/bind/named.conf.local > /dev/null <<'NAMEDOF'
zone \"${reg_host}\" {
    type master;
    file \"/etc/bind/zones/db.${reg_host}\";
};
NAMEDOF
        fi

        # named.conf.options — forwarders to VPC DNS
        sudo tee /etc/bind/named.conf.options > /dev/null <<'OPTOF'
options {
    directory \"/var/cache/bind\";
    forwarders {
        172.31.0.2;
    };
    allow-query { any; };
    recursion yes;
    dnssec-validation no;
};
OPTOF

        sudo systemctl restart bind9

        # Point the bastion itself at its own bind9 so it can resolve the FQDN
        if ! grep -q '127.0.0.1' /etc/systemd/resolved.conf 2>/dev/null; then
            sudo tee /etc/systemd/resolved.conf > /dev/null <<'RESOLVEOF'
[Resolve]
DNS=127.0.0.1
FallbackDNS=
Domains=~.
RESOLVEOF
            sudo systemctl restart systemd-resolved
        fi

        # Also add /etc/hosts entry as a reliable fallback
        if ! grep -q '${reg_host}' /etc/hosts 2>/dev/null; then
            echo '${bastion_private_ip} ${reg_host}' | sudo tee -a /etc/hosts >/dev/null
        fi

        echo '>>> bind9 configured — ${reg_host} → ${bastion_private_ip}'
    "

    # Install yq on bastion
    ssh_node "${ssh_key}" "${bastion_ip}" "
        set -euo pipefail
        if ! command -v yq &>/dev/null; then
            echo '>>> Installing yq...'
            sudo curl -fsSL 'https://github.com/mikefarah/yq/releases/download/v4.45.1/yq_linux_amd64' -o /usr/local/bin/yq
            sudo chmod +x /usr/local/bin/yq
        fi
    "

    # Download + install MSR4 (idempotent — check if harbor-core is running)
    local msr_ver="${airgap_msr_version}"
    ssh_node "${ssh_key}" "${bastion_ip}" "
        set -euo pipefail
        if sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -q harbor-core; then
            echo '>>> Harbor already running'
            exit 0
        fi

        echo '>>> Downloading MSR4 ${msr_ver}...'
        cd /tmp
        curl -fsSL 'https://s3-us-east-2.amazonaws.com/packages-mirantis.com/msr/msr-offline-installer-${msr_ver}.tgz' -o msr.tar.gz
        mkdir -p ~/msr && tar -xzf msr.tar.gz -C ~/msr --strip-components=1
        rm msr.tar.gz

        echo '>>> Generating two-tier TLS PKI (CA + server cert)...'
        mkdir -p ~/msr/certs

        # 1. Generate CA key + self-signed CA cert (CA:TRUE, no SANs)
        openssl req -x509 -nodes -days 3650 -newkey rsa:4096 \
            -keyout ~/msr/certs/ca.key \
            -out ~/msr/certs/ca.crt \
            -subj '/CN=${reg_host}-ca'

        # 2. Generate server key + CSR
        openssl req -nodes -newkey rsa:4096 \
            -keyout ~/msr/certs/server.key \
            -out ~/msr/certs/server.csr \
            -subj '/CN=${reg_host}'

        # 3. Sign the CSR with the CA to produce the server cert (CA:FALSE, with SANs)
        openssl x509 -req -days 3650 \
            -in ~/msr/certs/server.csr \
            -CA ~/msr/certs/ca.crt \
            -CAkey ~/msr/certs/ca.key \
            -CAcreateserial \
            -out ~/msr/certs/server.crt \
            -extfile <(printf 'subjectAltName=DNS:%s,IP:%s\nbasicConstraints=CA:FALSE\n' \
                '${reg_host}' '${bastion_private_ip}')

        echo '>>> Configuring harbor.yml...'
        mkdir -p ~/msr/data
        cd ~/msr
        cp harbor.yml.tmpl harbor.yml 2>/dev/null || true
        yq e -i '
            .hostname = \"${reg_host}\" |
            .https.port = 443 |
            .https.certificate = \"/home/ubuntu/msr/certs/server.crt\" |
            .https.private_key = \"/home/ubuntu/msr/certs/server.key\" |
            .harbor_admin_password = \"${registry_pass}\" |
            .data_volume = \"/home/ubuntu/msr/data\"
        ' harbor.yml

        # Trust the self-signed cert before starting Harbor so Docker already trusts it
        echo '>>> Adding registry cert to Docker trust store...'
        sudo mkdir -p /etc/docker/certs.d/${reg_host} /etc/docker/certs.d/${bastion_private_ip}
        sudo cp ~/msr/certs/ca.crt /etc/docker/certs.d/${reg_host}/ca.crt
        sudo cp ~/msr/certs/ca.crt /etc/docker/certs.d/${bastion_private_ip}/ca.crt

        echo '>>> Installing Harbor...'
        sudo ./install.sh
    "

    # Wait for Harbor health (use IP with -k; FQDN may not resolve yet in first seconds)
    info "Waiting for Harbor to become healthy..."
    local max_wait=300 harbor_healthy=false
    for (( i=0; i<max_wait; i+=10 )); do
        local health_out
        health_out="$(ssh_node "${ssh_key}" "${bastion_ip}" \
            "curl -sk https://${bastion_private_ip}/api/v2.0/health 2>&1" 2>/dev/null || true)"
        if echo "${health_out}" | grep -q '"status":"healthy"'; then
            success "Harbor is healthy."
            harbor_healthy=true
            break
        fi
        printf "\r${CYAN}[t]${RESET} Harbor not ready yet (%ds / %ds)... " "${i}" "${max_wait}"
        sleep 10
    done
    echo ""
    [[ "${harbor_healthy}" == "true" ]] || die "Harbor did not become healthy within ${max_wait}s. Last response: ${health_out}"

    # Create 'mke' project (idempotent)
    ssh_node "${ssh_key}" "${bastion_ip}" "
        set -euo pipefail
        # Check if project already exists
        if curl -sk -u 'admin:${registry_pass}' \
            'https://${bastion_private_ip}/api/v2.0/projects?name=mke' 2>&1 | grep -q '\"name\":\"mke\"'; then
            echo '>>> Project mke already exists'
        else
            echo '>>> Creating Harbor project: mke'
            curl -sk -u 'admin:${registry_pass}' \
                -X POST 'https://${bastion_private_ip}/api/v2.0/projects' \
                -H 'Content-Type: application/json' \
                -d '{\"project_name\":\"mke\",\"public\":true}'
            echo ''
            echo '>>> Project mke created'
        fi
    "

    # SCP cert back for embedding in mke4.yaml
    local cert_file="${TERRAFORM_DIR}/registry_ca.crt"
    scp -q -o StrictHostKeyChecking=no -i "${ssh_key}" \
        "ubuntu@${bastion_ip}:~/msr/certs/ca.crt" "${cert_file}"
    success "Registry CA cert saved to $(basename "${cert_file}")"

    success "MSR4 registry setup complete on bastion."
}

# ---------------------------------------------------------------------------
# Cluster node hostnames — must equal the EC2 PrivateDnsName (FQDN)
# ---------------------------------------------------------------------------
# The Kubernetes node name is the OS hostname (MKE4k/launchpad expose no
# nodeName/--hostname-override knob), and the AWS cloud controller manager
# resolves a Node to an instance by matching that name against the instance's
# PrivateDnsName. A short hostname yields:
#   failed to get instance metadata for node ip-a-b-c-d: instance not found
#
# terraform user_data already asks cloud-init for the FQDN
# (prefer_fqdn_over_hostname), but that only runs at first boot and only on
# instances created after that change — so verify/repair here before install.
# Runs for every OS. IMDS is link-local, so this works in airgap and needs no
# DNS — hence it can run before setup_node_dns. It is called before
# setup_rhel_node_prereqs so that the RHEL reboot there re-asserts the name.
ensure_node_hostnames() {
    local output ssh_key bastion_ip
    output="$(tf_output)"
    ssh_key="$(echo "${output}" | jq -r '.ssh_key_path.value')"
    bastion_ip="$(echo "${output}" | jq -r '.bastion_public_ip.value // empty' 2>/dev/null)"
    local is_airgap=false
    [[ -n "${bastion_ip}" && "${bastion_ip}" != "null" && "${bastion_ip}" != "" ]] && is_airgap=true

    local all_ips=()
    if [[ "${is_airgap}" == "true" ]]; then
        mapfile -t all_ips < <(echo "${output}" | jq -r '.controller_private_ips.value[], .worker_private_ips.value[]' 2>/dev/null)
    else
        mapfile -t all_ips < <(echo "${output}" | jq -r '.controller_ips.value[], .worker_ips.value[]' 2>/dev/null)
    fi
    [[ ${#all_ips[@]} -eq 0 ]] && { warn "No cluster node IPs found — skipping hostname check."; return; }

    info "Verifying FQDN hostname on ${#all_ips[@]} cluster node(s)..."

    # REGION is interpolated locally; the rest is single-quoted (no local
    # expansion). IMDSv2 first, IMDSv1 second, derive-from-IP last — never write
    # an unvalidated value to /etc/hostname.
    local hostname_script="REGION='${region}'
"'
        set -uo pipefail
        IMDS=http://169.254.169.254

        TOKEN="$(curl -s -m 3 -X PUT "$IMDS/latest/api/token" \
            -H "X-aws-ec2-metadata-token-ttl-seconds: 300" 2>/dev/null || true)"
        FQDN=""
        if [ -n "$TOKEN" ]; then
            FQDN="$(curl -s -m 3 -H "X-aws-ec2-metadata-token: $TOKEN" \
                "$IMDS/latest/meta-data/local-hostname" 2>/dev/null || true)"
        fi
        if [ -z "$FQDN" ]; then
            FQDN="$(curl -s -m 3 "$IMDS/latest/meta-data/local-hostname" 2>/dev/null || true)"
        fi
        if [ -z "$FQDN" ]; then
            # No IMDS: rebuild the name AWS assigns from the primary IP
            IP="$(hostname -I 2>/dev/null | cut -d" " -f1)"
            if [ -n "$IP" ]; then
                SUFFIX="$REGION.compute.internal"
                [ "$REGION" = "us-east-1" ] && SUFFIX="ec2.internal"
                FQDN="ip-$(echo "$IP" | tr . -).$SUFFIX"
            fi
        fi

        # Must be the dotted ip-a-b-c-d.<domain> form — a bare short name is
        # exactly the failure being fixed
        case "$FQDN" in
            ip-[0-9]*-[0-9]*-[0-9]*-[0-9]*.?*) ;;
            *) echo "HOSTNAME_UNRESOLVED"; exit 0 ;;
        esac

        if [ "$(hostname)" = "$FQDN" ] && [ "$(cat /etc/hostname 2>/dev/null)" = "$FQDN" ]; then
            echo "HOSTNAME_OK $FQDN"
            exit 0
        fi

        # hostnamectl (not "hostname"): persists /etc/hostname AND updates the
        # systemd static/transient names
        sudo hostnamectl set-hostname "$FQDN" || { echo "HOSTNAME_SET_FAILED"; exit 0; }
        SHORT="${FQDN%%.*}"
        # Map the FQDN on 127.0.1.1 (Debian convention), leaving every other
        # /etc/hosts entry alone — the airgap registry entry lives here too
        if ! grep -qE "^127\.0\.1\.1[[:space:]]+$FQDN([[:space:]]|$)" /etc/hosts; then
            sudo sed -i "/^127\.0\.1\.1[[:space:]]/d" /etc/hosts
            printf "127.0.1.1\t%s %s\n" "$FQDN" "$SHORT" | sudo tee -a /etc/hosts >/dev/null
        fi
        # Restore the localhost alias if an earlier revision of this lab clobbered
        # it (the old user_data sed replaced "localhost" with the hostname)
        if ! grep -qE "^127\.0\.0\.1[[:space:]]+.*localhost" /etc/hosts; then
            sudo sed -i "/^127\.0\.0\.1[[:space:]]/d" /etc/hosts
            printf "127.0.0.1\tlocalhost\n" | sudo tee -a /etc/hosts >/dev/null
        fi
        echo "HOSTNAME_FIXED $FQDN"
    '

    local node_ip node_out fixed=0
    for node_ip in "${all_ips[@]}"; do
        if [[ "${is_airgap}" == "true" ]]; then
            wait_for_ssh_node_via_bastion "${ssh_key}" "${bastion_ip}" "${node_ip}" "node ${node_ip}"
            node_out="$(ssh_node_via_bastion "${ssh_key}" "${bastion_ip}" "${node_ip}" "${hostname_script}" 2>&1 || true)"
        else
            wait_for_ssh_host "$(node_ssh_user)" "${ssh_key}" "${node_ip}" "node ${node_ip}"
            node_out="$(ssh_host "$(node_ssh_user)" "${ssh_key}" "${node_ip}" "${hostname_script}" 2>&1 || true)"
        fi

        case "${node_out}" in
            *HOSTNAME_OK*)
                info "  hostname → ${node_ip} ($(awk '/HOSTNAME_OK/ {print $2}' <<<"${node_out}"))"
                ;;
            *HOSTNAME_FIXED*)
                warn "  hostname → ${node_ip} repaired to $(awk '/HOSTNAME_FIXED/ {print $2}' <<<"${node_out}")"
                fixed=$((fixed + 1))
                ;;
            *)
                # Wrong node name breaks CCM outright — fail loudly rather than
                # hand back a cluster whose nodes never initialise
                local msg="Could not set the FQDN hostname on ${node_ip}: ${node_out}"
                # Only CCM actually depends on the name matching, and it is
                # always disabled in airgap (no AWS API access)
                if [[ "${ccm_enabled:-false}" == "true" && "${is_airgap}" != "true" ]]; then
                    die "${msg}
CCM matches nodes by PrivateDnsName and will report 'instance not found'.
Set ccm_enabled=false in config to deploy without the cloud provider."
                fi
                warn "${msg}"
                ;;
        esac
    done

    if [[ ${fixed} -gt 0 ]]; then
        success "Node hostnames verified (${fixed} repaired)."
    else
        success "Node hostnames verified."
    fi
}

# ---------------------------------------------------------------------------
# RHEL cluster node preparation (no-op for Ubuntu)
# ---------------------------------------------------------------------------
# - nm-cloud-setup: enabled on RHEL EC2 AMIs; its routing rules are a documented
#   k0s/Kubernetes incompatibility, and it also rewrites /etc/resolv.conf.
#   Disabling requires a reboot to drop the already-installed rules.
# - SELinux: MKE 4.1.3+ supports SELinux enforcing, so it is left as-is. For
#   older MKE4k target versions it is set to permissive (no reboot needed).
# - firewalld/nftables: defensive — usually absent on RHEL EC2 AMIs, but would
#   block Kubernetes ports if present.
setup_rhel_node_prereqs() {
    [[ "${os_name}" == "redhat" ]] || return 0

    local output ssh_key bastion_ip
    output="$(tf_output)"
    ssh_key="$(echo "${output}" | jq -r '.ssh_key_path.value')"
    bastion_ip="$(echo "${output}" | jq -r '.bastion_public_ip.value // empty' 2>/dev/null)"
    local is_airgap=false
    [[ -n "${bastion_ip}" && "${bastion_ip}" != "null" && "${bastion_ip}" != "" ]] && is_airgap=true

    local all_ips=()
    if [[ "${is_airgap}" == "true" ]]; then
        mapfile -t all_ips < <(echo "${output}" | jq -r '.controller_private_ips.value[], .worker_private_ips.value[]' 2>/dev/null)
    else
        mapfile -t all_ips < <(echo "${output}" | jq -r '.controller_ips.value[], .worker_ips.value[]' 2>/dev/null)
    fi
    [[ ${#all_ips[@]} -eq 0 ]] && { warn "No cluster node IPs found — skipping RHEL prereqs."; return; }

    info "Preparing ${#all_ips[@]} RHEL node(s) (nm-cloud-setup, SELinux, firewalld)..."

    # MKE 4.1.3+ supports SELinux enforcing — leave it untouched. Older target
    # versions get permissive to avoid a known install-failure class.
    local selinux_script=""
    if version_gte "${mke4k_version#v}" "4.1.3"; then
        info "  SELinux: leaving enforcing (MKE ${mke4k_version} supports SELinux)"
    else
        info "  SELinux: setting permissive (MKE ${mke4k_version} < 4.1.3)"
        selinux_script='
        if [ "$(getenforce)" = "Enforcing" ]; then
            sudo setenforce 0
        fi
        sudo sed -i "s/^SELINUX=enforcing/SELINUX=permissive/" /etc/selinux/config'
    fi

    local prereq_script='
        set -euo pipefail'"${selinux_script}"'
        sudo systemctl disable --now firewalld 2>/dev/null || true
        sudo systemctl disable --now nftables 2>/dev/null || true
        if systemctl is-enabled nm-cloud-setup.service >/dev/null 2>&1 \
           || systemctl is-enabled nm-cloud-setup.timer >/dev/null 2>&1; then
            sudo systemctl disable --now nm-cloud-setup.service nm-cloud-setup.timer 2>/dev/null || true
            echo NEEDS_REBOOT
        fi
        echo "RHEL prereqs done"
    '

    local node_ip node_out
    for node_ip in "${all_ips[@]}"; do
        info "  prereqs → ${node_ip}"
        # Terraform returns before sshd is up — wait per node
        if [[ "${is_airgap}" == "true" ]]; then
            wait_for_ssh_node_via_bastion "${ssh_key}" "${bastion_ip}" "${node_ip}" "node ${node_ip}"
            node_out="$(ssh_node_via_bastion "${ssh_key}" "${bastion_ip}" "${node_ip}" "${prereq_script}")"
        else
            wait_for_ssh_host "$(node_ssh_user)" "${ssh_key}" "${node_ip}" "node ${node_ip}"
            node_out="$(ssh_host "$(node_ssh_user)" "${ssh_key}" "${node_ip}" "${prereq_script}")"
        fi

        if grep -q 'NEEDS_REBOOT' <<<"${node_out}"; then
            info "  Rebooting ${node_ip} to drop nm-cloud-setup routing rules..."
            if [[ "${is_airgap}" == "true" ]]; then
                ssh_node_via_bastion "${ssh_key}" "${bastion_ip}" "${node_ip}" "sudo systemctl reboot" 2>/dev/null || true
                sleep 10
                wait_for_ssh_node_via_bastion "${ssh_key}" "${bastion_ip}" "${node_ip}" "node ${node_ip}"
            else
                ssh_host "$(node_ssh_user)" "${ssh_key}" "${node_ip}" "sudo systemctl reboot" 2>/dev/null || true
                sleep 10
                wait_for_ssh_host "$(node_ssh_user)" "${ssh_key}" "${node_ip}" "node ${node_ip}"
            fi
        fi
    done

    success "RHEL node prereqs applied."
}

# ---------------------------------------------------------------------------
# Airgap — configure DNS on cluster nodes (point the resolver at bastion)
# ---------------------------------------------------------------------------
# bind9 runs on the bastion and resolves the registry hostname.
# Each cluster node's resolver is configured to use the bastion as its DNS
# server. This means both containerd (on the node) and CoreDNS (which forwards
# to the node's upstream resolver) can resolve the hostname.
# Ubuntu: via systemd-resolved. RHEL: NetworkManager owns /etc/resolv.conf and
# systemd-resolved is not enabled — set dns=none so NM permanently stops
# touching resolv.conf (survives DHCP renewals and reboots), then write it.
setup_node_dns() {
    local output ssh_key bastion_ip bastion_private_ip
    output="$(tf_output)"
    ssh_key="$(echo "${output}" | jq -r '.ssh_key_path.value')"
    bastion_ip="$(echo "${output}" | jq -r '.bastion_public_ip.value')"
    bastion_private_ip="$(echo "${output}" | jq -r '.bastion_private_ip.value')"

    local all_ips=()
    mapfile -t all_ips < <(echo "${output}" | jq -r '.controller_private_ips.value[], .worker_private_ips.value[]' 2>/dev/null)

    if [[ ${#all_ips[@]} -eq 0 ]]; then
        warn "No cluster node IPs found — skipping DNS setup."
        return
    fi

    info "Configuring DNS on ${#all_ips[@]} cluster node(s) → bastion (${bastion_private_ip})..."

    for node_ip in "${all_ips[@]}"; do
        info "  DNS → ${node_ip}"
        if [[ "${os_name}" == "redhat" ]]; then
            ssh_node_via_bastion "${ssh_key}" "${bastion_ip}" "${node_ip}" "
                set -euo pipefail
                # Only configure if not already pointing at bastion
                if grep -q '${bastion_private_ip}' /etc/resolv.conf 2>/dev/null; then
                    echo 'DNS already configured'
                    exit 0
                fi
                # Stop NetworkManager managing resolv.conf (persists across
                # DHCP renewals and reboots); reload keeps the interface up
                sudo mkdir -p /etc/NetworkManager/conf.d
                printf '[main]\ndns=none\n' | sudo tee /etc/NetworkManager/conf.d/90-dns-none.conf >/dev/null
                sudo systemctl reload NetworkManager
                # Preserve the VPC search domain so *.compute.internal keeps working
                search_line=\$(grep '^search' /etc/resolv.conf 2>/dev/null || true)
                { echo \"\${search_line}\"; echo 'nameserver ${bastion_private_ip}'; } \
                    | grep -v '^\$' | sudo tee /etc/resolv.conf >/dev/null

                # /etc/hosts fallback — ensures containerd resolves the registry
                # even if the resolver is briefly unavailable during k0s startup
                if ! grep -q '${registry_hostname}' /etc/hosts 2>/dev/null; then
                    echo '${bastion_private_ip} ${registry_hostname}' | sudo tee -a /etc/hosts >/dev/null
                fi
            "
        else
            ssh_node_via_bastion "${ssh_key}" "${bastion_ip}" "${node_ip}" "
                set -euo pipefail
                # Only configure if not already pointing at bastion
                if grep -q '${bastion_private_ip}' /etc/systemd/resolved.conf 2>/dev/null; then
                    echo 'DNS already configured'
                    exit 0
                fi
                sudo tee /etc/systemd/resolved.conf > /dev/null <<'RESOLVEOF'
[Resolve]
DNS=${bastion_private_ip}
FallbackDNS=
Domains=~.
RESOLVEOF
                sudo systemctl restart systemd-resolved

                # /etc/hosts fallback — ensures containerd resolves the registry
                # even if systemd-resolved is briefly unavailable during k0s startup
                if ! grep -q '${registry_hostname}' /etc/hosts 2>/dev/null; then
                    echo '${bastion_private_ip} ${registry_hostname}' | sudo tee -a /etc/hosts >/dev/null
                fi
            "
        fi
    done

    success "DNS configured on all cluster nodes."
}

# ---------------------------------------------------------------------------
# Airgap — Squid forward proxy on bastion (MCR apt/dnf installs on airgap nodes;
# also RHUI access for RHEL nodes — e.g. nfs-utils, container-selinux)
# ---------------------------------------------------------------------------
setup_squid_proxy() {
    local output ssh_key bastion_ip bastion_private_ip
    output="$(tf_output)"
    ssh_key="$(echo "${output}" | jq -r '.ssh_key_path.value')"
    bastion_ip="$(echo "${output}" | jq -r '.bastion_public_ip.value')"
    bastion_private_ip="$(echo "${output}" | jq -r '.bastion_private_ip.value')"

    info "Setting up Squid proxy on bastion (${bastion_ip})..."

    ssh_node "${ssh_key}" "${bastion_ip}" "
        set -euo pipefail
        if command -v squid &>/dev/null; then
            echo '>>> Squid already installed'
        else
            echo '>>> Installing Squid...'
            sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq squid >/dev/null 2>&1
        fi

        echo '>>> Configuring Squid...'
        sudo tee /etc/squid/squid.conf > /dev/null <<'SQUIDEOF'
# Allow private subnet (cluster nodes)
acl cluster_nodes src 172.31.1.0/24

# Allowed destination domains for MCR + launchpad installs + OS packages
acl allowed_domains dstdomain .mirantis.com .docker.com .docker.io
acl allowed_domains dstdomain .ubuntu.com .canonical.com .amazonaws.com
acl allowed_domains dstdomain .dl.k8s.io
# RHEL nodes: RHUI (rhui.<region>.aws.ce.redhat.com) + possible CDN redirects
acl allowed_domains dstdomain .redhat.com .cloudfront.net

# SSL bump is NOT used — CONNECT tunnelling for HTTPS
acl SSL_ports port 443
acl Safe_ports port 80 443

http_access deny !Safe_ports
http_access deny CONNECT !SSL_ports

# Allow cluster nodes to any of the allowed domains
http_access allow cluster_nodes allowed_domains

# Deny everything else
http_access deny all

http_port 3128
SQUIDEOF

        sudo systemctl restart squid
        sudo systemctl enable squid
        echo '>>> Squid proxy ready on port 3128'
    "

    success "Squid proxy configured on bastion."
}

# ---------------------------------------------------------------------------
# Airgap — configure HTTP proxy on cluster nodes (for MCR package install)
# ---------------------------------------------------------------------------
setup_node_proxy() {
    local output ssh_key bastion_ip bastion_private_ip
    output="$(tf_output)"
    ssh_key="$(echo "${output}" | jq -r '.ssh_key_path.value')"
    bastion_ip="$(echo "${output}" | jq -r '.bastion_public_ip.value')"
    bastion_private_ip="$(echo "${output}" | jq -r '.bastion_private_ip.value')"

    local all_ips=()
    mapfile -t all_ips < <(echo "${output}" | jq -r '.controller_private_ips.value[], .worker_private_ips.value[]' 2>/dev/null)

    if [[ ${#all_ips[@]} -eq 0 ]]; then
        warn "No cluster node IPs found — skipping proxy setup."
        return
    fi

    local reg_host="${registry_hostname}"
    local proxy_url="http://${bastion_private_ip}:3128"

    # Build no_proxy list with all node IPs (curl doesn't support CIDR notation)
    # Also include the NLB DNS name so mkectl upgrade connectivity checks (e.g.
    # curl https://<nlb>:9443) bypass Squid — Squid only allows port 443 and
    # the NLB is internal (private subnet), so it should never go via the proxy.
    local lb_dns mke3_lb_dns
    lb_dns="$(echo "${output}" | jq -r '.lb_dns_name.value // ""')"
    mke3_lb_dns="$(echo "${output}" | jq -r '.mke3_lb_dns_name.value // ""')"
    # 169.254.169.254: RHEL's RHUI dnf plugin (amazon-id) reads the region from
    # IMDS — that link-local call must never go through the proxy. Harmless on Ubuntu.
    local no_proxy_list="localhost,127.0.0.1,169.254.169.254,${bastion_private_ip},${reg_host}"
    [[ -n "${lb_dns}" ]] && no_proxy_list="${no_proxy_list},${lb_dns}"
    [[ -n "${mke3_lb_dns}" ]] && no_proxy_list="${no_proxy_list},${mke3_lb_dns}"
    for ip in "${all_ips[@]}"; do
        no_proxy_list="${no_proxy_list},${ip}"
    done

    info "Configuring HTTP proxy on ${#all_ips[@]} cluster node(s) → bastion (${bastion_private_ip}:3128)..."

    # SCP registry CA cert to each node for Docker trust
    local cert_file="${TERRAFORM_DIR}/registry_ca.crt"
    [[ -f "${cert_file}" ]] || die "Registry CA cert not found at ${cert_file}. Run 't deploy registry' first."

    for node_ip in "${all_ips[@]}"; do
        info "  Proxy → ${node_ip}"

        # SCP cert via bastion
        scp -q -o StrictHostKeyChecking=no -i "${ssh_key}" \
            -o "ProxyCommand=ssh -q -o StrictHostKeyChecking=no -i ${ssh_key} -W %h:%p ubuntu@${bastion_ip}" \
            "${cert_file}" "$(node_ssh_user)@${node_ip}:/tmp/registry_ca.crt"

        if [[ "${os_name}" == "redhat" ]]; then
            ssh_node_via_bastion "${ssh_key}" "${bastion_ip}" "${node_ip}" "
                set -euo pipefail

                # dnf proxy — applies to all repos (RHUI + the Mirantis repo the
                # MCR installer adds). RHUI repos stay ENABLED: docker-ee needs
                # container-selinux from AppStream, and HTTPS-only RHUI through
                # Squid is a pure CONNECT tunnel (no hash-mismatch risk).
                if ! grep -q '^proxy=' /etc/dnf/dnf.conf 2>/dev/null; then
                    echo 'proxy=${proxy_url}' | sudo tee -a /etc/dnf/dnf.conf >/dev/null
                fi

                # Environment proxy (pam_env.so reads on PAM login sessions)
                sudo tee /etc/environment > /dev/null <<'ENVEOF'
http_proxy=${proxy_url}
https_proxy=${proxy_url}
HTTP_PROXY=${proxy_url}
HTTPS_PROXY=${proxy_url}
no_proxy=${no_proxy_list}
NO_PROXY=${no_proxy_list}
ENVEOF

                # System-wide bashrc — sourced for all bash invocations including
                # non-login SSH exec channels (which is how launchpad runs commands)
                if ! grep -q 'http_proxy' /etc/bashrc 2>/dev/null; then
                    sudo tee -a /etc/bashrc > /dev/null <<'BASHRCEOF'

# Proxy settings for airgap MCR installation
export http_proxy=${proxy_url}
export https_proxy=${proxy_url}
export HTTP_PROXY=${proxy_url}
export HTTPS_PROXY=${proxy_url}
export no_proxy=${no_proxy_list}
export NO_PROXY=${no_proxy_list}
BASHRCEOF
                fi

                # Profile.d script for login shells
                sudo tee /etc/profile.d/proxy.sh > /dev/null <<'PROFILEEOF'
export http_proxy=${proxy_url}
export https_proxy=${proxy_url}
export HTTP_PROXY=${proxy_url}
export HTTPS_PROXY=${proxy_url}
export no_proxy=${no_proxy_list}
export NO_PROXY=${no_proxy_list}
PROFILEEOF

                # Preserve proxy vars through sudo
                echo 'Defaults env_keep += \"http_proxy https_proxy HTTP_PROXY HTTPS_PROXY no_proxy NO_PROXY\"' \
                    | sudo tee /etc/sudoers.d/proxy-env >/dev/null
                sudo chmod 440 /etc/sudoers.d/proxy-env

                # Avoid dnf metadata refresh contention with launchpad
                sudo systemctl disable --now dnf-makecache.timer 2>/dev/null || true

                # Docker registry CA trust (MCR will read this on start)
                sudo mkdir -p /etc/docker/certs.d/${reg_host}
                sudo cp /tmp/registry_ca.crt /etc/docker/certs.d/${reg_host}/ca.crt
                rm -f /tmp/registry_ca.crt
            "
        else
            ssh_node_via_bastion "${ssh_key}" "${bastion_ip}" "${node_ip}" "
                set -euo pipefail

                # APT proxy
                echo 'Acquire::http::Proxy \"${proxy_url}\";
Acquire::https::Proxy \"${proxy_url}\";' | sudo tee /etc/apt/apt.conf.d/01proxy >/dev/null

                # Environment proxy (pam_env.so reads on PAM login sessions)
                sudo tee /etc/environment > /dev/null <<'ENVEOF'
http_proxy=${proxy_url}
https_proxy=${proxy_url}
HTTP_PROXY=${proxy_url}
HTTPS_PROXY=${proxy_url}
no_proxy=${no_proxy_list}
NO_PROXY=${no_proxy_list}
ENVEOF

                # System-wide bashrc — sourced for all bash invocations including
                # non-login SSH exec channels (which is how launchpad runs commands)
                if ! grep -q 'http_proxy' /etc/bash.bashrc 2>/dev/null; then
                    sudo tee -a /etc/bash.bashrc > /dev/null <<'BASHRCEOF'

# Proxy settings for airgap MCR installation
export http_proxy=${proxy_url}
export https_proxy=${proxy_url}
export HTTP_PROXY=${proxy_url}
export HTTPS_PROXY=${proxy_url}
export no_proxy=${no_proxy_list}
export NO_PROXY=${no_proxy_list}
BASHRCEOF
                fi

                # Profile.d script for login shells
                sudo tee /etc/profile.d/proxy.sh > /dev/null <<'PROFILEEOF'
export http_proxy=${proxy_url}
export https_proxy=${proxy_url}
export HTTP_PROXY=${proxy_url}
export HTTPS_PROXY=${proxy_url}
export no_proxy=${no_proxy_list}
export NO_PROXY=${no_proxy_list}
PROFILEEOF

                # Preserve proxy vars through sudo
                echo 'Defaults env_keep += \"http_proxy https_proxy HTTP_PROXY HTTPS_PROXY no_proxy NO_PROXY\"' \
                    | sudo tee /etc/sudoers.d/proxy-env >/dev/null
                sudo chmod 440 /etc/sudoers.d/proxy-env

                # Disable unattended-upgrades to prevent apt lock contention with launchpad
                sudo systemctl disable --now unattended-upgrades 2>/dev/null || true
                sudo systemctl disable --now apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
                # Wait for any running apt/dpkg to finish
                while sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do sleep 2; done

                # Disable default Ubuntu repos — they are huge, slow through proxy, and
                # cause hash-sum-mismatch errors via Squid. Launchpad only needs the
                # Mirantis repo (added by the MCR installer script). Base packages
                # (curl, sudo, iptables) are already on the AMI.
                sudo mv /etc/apt/sources.list /etc/apt/sources.list.disabled 2>/dev/null || true
                sudo mv /etc/apt/sources.list.d/ubuntu.sources /etc/apt/sources.list.d/ubuntu.sources.disabled 2>/dev/null || true

                # Docker registry CA trust (MCR will read this on start)
                sudo mkdir -p /etc/docker/certs.d/${reg_host}
                sudo cp /tmp/registry_ca.crt /etc/docker/certs.d/${reg_host}/ca.crt
                rm -f /tmp/registry_ca.crt
            "
        fi
    done

    success "HTTP proxy + registry CA configured on all cluster nodes."
}

# ---------------------------------------------------------------------------
# Airgap — download MKE3 image bundle + upload to Harbor
# ---------------------------------------------------------------------------
upload_mke3_images() {
    local output ssh_key bastion_ip bastion_private_ip
    output="$(tf_output)"
    ssh_key="$(echo "${output}" | jq -r '.ssh_key_path.value')"
    bastion_ip="$(echo "${output}" | jq -r '.bastion_public_ip.value')"
    bastion_private_ip="$(echo "${output}" | jq -r '.bastion_private_ip.value')"

    local creds_file="${TERRAFORM_DIR}/registry_credentials.txt"
    [[ -f "${creds_file}" ]] || die "Registry credentials not found. Run 't deploy registry' first."
    local registry_pass
    registry_pass="$(grep '^password=' "${creds_file}" | cut -d= -f2)"

    local reg_host="${registry_hostname}"
    local bundle_url="${MKE3_BUNDLE_URL:-${mke3_bundle_url:-https://packages.mirantis.com/caas/ucp_images_${mke3_version}.tar.gz}}"

    # Create 'mke3' project in Harbor (idempotent)
    ssh_node "${ssh_key}" "${bastion_ip}" "
        set -euo pipefail
        if curl -sk -u 'admin:${registry_pass}' \
            'https://${bastion_private_ip}/api/v2.0/projects?name=mke3' 2>&1 | grep -q '\"name\":\"mke3\"'; then
            echo '>>> Project mke3 already exists'
        else
            echo '>>> Creating Harbor project: mke3'
            curl -sk -u 'admin:${registry_pass}' \
                -X POST 'https://${bastion_private_ip}/api/v2.0/projects' \
                -H 'Content-Type: application/json' \
                -d '{\"project_name\":\"mke3\",\"public\":true}'
            echo ''
            echo '>>> Project mke3 created'
        fi
    "

    info "Downloading + uploading MKE3 images to registry..."
    ssh_node "${ssh_key}" "${bastion_ip}" "
        set -euo pipefail

        BUNDLE_DIR=~/mke3_bundle
        REGISTRY='${reg_host}'
        BUNDLE_URL='${bundle_url}'

        # Download bundle if not already present
        if [[ ! -f \"\${BUNDLE_DIR}/ucp_images.tar.gz\" ]]; then
            echo '>>> Downloading MKE3 image bundle...'
            mkdir -p \"\${BUNDLE_DIR}\"
            curl -fL --progress-bar \"\${BUNDLE_URL}\" -o \"\${BUNDLE_DIR}/ucp_images.tar.gz\"
        else
            echo '>>> MKE3 bundle already downloaded'
        fi

        # Login to registry
        docker login \${REGISTRY} -u admin -p '${registry_pass}'

        # Load images
        echo '>>> Loading MKE3 images (docker load)...'
        loaded=\$(docker load -i \"\${BUNDLE_DIR}/ucp_images.tar.gz\" 2>&1)
        echo \"\${loaded}\"

        # Parse loaded image names and retag+push
        echo '>>> Retagging and pushing images to Harbor...'
        images=\$(echo \"\${loaded}\" | grep '^Loaded image:' | sed 's/Loaded image: //')
        total=\$(echo \"\${images}\" | wc -l)
        count=0
        echo \"\${images}\" | while IFS= read -r img; do
            [[ -z \"\${img}\" ]] && continue
            count=\$((count + 1))
            # Extract name:tag from image (e.g. mirantis/ucp-agent:3.8.2 → ucp-agent:3.8.2)
            # Handle both mirantis/name:tag and docker.io/mirantis/name:tag formats
            local_part=\$(echo \"\${img}\" | sed -E 's|^(docker\.io/)?mirantis/||')
            target=\"\${REGISTRY}/mke3/\${local_part}\"
            echo \"[\${count}/\${total}] \${img} → \${target}\"
            docker tag \"\${img}\" \"\${target}\"
            docker push \"\${target}\" || echo \"  WARNING: failed to push \${target}\"
        done
        echo '>>> MKE3 image upload complete.'
    "
    success "MKE3 images uploaded to registry."
}

# ---------------------------------------------------------------------------
# Airgap — install launchpad on bastion
# ---------------------------------------------------------------------------
ensure_launchpad_on_bastion() {
    local ssh_key="${1}" bastion_ip="${2}"
    local want="${launchpad_version}"
    local url="${LAUNCHPAD_DOWNLOAD_URL:-https://github.com/Mirantis/launchpad/releases/download/v${want}/launchpad_linux_amd64_${want}}"

    info "Installing launchpad ${want} on bastion..."
    ssh_node "${ssh_key}" "${bastion_ip}" "
        set -euo pipefail
        if command -v launchpad &>/dev/null; then
            got=\$(launchpad version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
            if [[ \"\${got}\" == '${want}' ]]; then
                echo 'launchpad ${want} already installed'
                exit 0
            fi
        fi
        echo '>>> Downloading launchpad ${want}...'
        curl -fsSL '${url}' -o /tmp/launchpad
        sudo install -m 755 /tmp/launchpad /usr/local/bin/launchpad
        rm -f /tmp/launchpad
        echo 'launchpad ${want} installed'
    "
}

# ---------------------------------------------------------------------------
# Airgap — run launchpad apply from bastion
# ---------------------------------------------------------------------------
launchpad_apply_on_bastion() {
    local output ssh_key bastion_ip
    output="$(tf_output)"
    ssh_key="$(echo "${output}" | jq -r '.ssh_key_path.value')"
    bastion_ip="$(echo "${output}" | jq -r '.bastion_public_ip.value')"
    local launchpad_yaml="${TERRAFORM_DIR}/launchpad.yaml"

    [[ -f "${launchpad_yaml}" ]] || die "launchpad.yaml not found. Run 't deploy instances mke3-airgap' first."

    # SCP launchpad.yaml + SSH key to bastion
    scp -q -o StrictHostKeyChecking=no -i "${ssh_key}" "${launchpad_yaml}" "ubuntu@${bastion_ip}:~/launchpad.yaml"
    scp -q -o StrictHostKeyChecking=no -i "${ssh_key}" "${ssh_key}" "ubuntu@${bastion_ip}:~/aws_private.pem"
    ssh_node "${ssh_key}" "${bastion_ip}" "chmod 600 ~/aws_private.pem"

    info "Running launchpad apply on bastion (airgap mode)..."
    ssh_node "${ssh_key}" "${bastion_ip}" "launchpad apply --accept-license -c ~/launchpad.yaml"

    success "MKE3 cluster deployment complete (airgap)."
}

# ---------------------------------------------------------------------------
# Airgap — run launchpad reset from bastion
# ---------------------------------------------------------------------------
launchpad_reset_on_bastion() {
    local output ssh_key bastion_ip
    output="$(tf_output)"
    ssh_key="$(echo "${output}" | jq -r '.ssh_key_path.value')"
    bastion_ip="$(echo "${output}" | jq -r '.bastion_public_ip.value')"

    info "Running launchpad reset --force on bastion..."
    ssh_node "${ssh_key}" "${bastion_ip}" "launchpad reset --force -c ~/launchpad.yaml"
    success "MKE3 cluster reset complete (airgap)."
}

# ---------------------------------------------------------------------------
# Airgap — download MKE4k bundle + upload images to Harbor
# ---------------------------------------------------------------------------
upload_mke4k_bundle() {
    local upload_mode="${1:-standard}"   # "standard" or "dual-path"
    local bundle_base="${2:-bundles}"    # directory name under ~/ on bastion

    local output ssh_key bastion_ip bastion_private_ip
    output="$(tf_output)"
    ssh_key="$(echo "${output}" | jq -r '.ssh_key_path.value')"
    bastion_ip="$(echo "${output}" | jq -r '.bastion_public_ip.value')"
    bastion_private_ip="$(echo "${output}" | jq -r '.bastion_private_ip.value')"

    local creds_file="${TERRAFORM_DIR}/registry_credentials.txt"
    [[ -f "${creds_file}" ]] || die "Registry credentials not found. Run 't deploy registry' first."
    local registry_pass
    registry_pass="$(grep '^password=' "${creds_file}" | cut -d= -f2)"

    local bundle_url="${MKE4K_BUNDLE_URL:-${mke4k_bundle_url:-https://packages.mirantis.com/caas/mke_bundle_${mke4k_version}_amd64.tar.gz}}"

    info "Downloading + uploading MKE4k bundle to registry (mode=${upload_mode}, dir=${bundle_base})..."

    if [[ "${upload_mode}" == "dual-path" ]]; then
        # dual-path mode: use mkectl airgap list-images/list-charts to enumerate artifacts,
        # upload mke/* images to both mke/<path> and mke/mke/<path> (v4.1.3 workaround)
        ssh_node "${ssh_key}" "${bastion_ip}" "
            set -euo pipefail

            BUNDLE_DIR=~/${bundle_base}
            REGISTRY='${registry_hostname}'

            # Download bundle if not already present
            if [[ -z \"\$(find \${BUNDLE_DIR} -name '*.tar' -type f 2>/dev/null | head -1)\" ]]; then
                echo '>>> Downloading MKE4k bundle...'
                mkdir -p \"\${BUNDLE_DIR}\"
                cd /tmp
                curl -fL --progress-bar '${bundle_url}' -o bundle.tar.gz
                echo '>>> Extracting bundle...'
                tar -xzf bundle.tar.gz -C \"\${BUNDLE_DIR}\"
                rm bundle.tar.gz
            else
                echo '>>> Bundle already extracted'
            fi

            docker login \${REGISTRY} -u admin -p '${registry_pass}'
            SKOPEO=\"docker run --rm --add-host ${registry_hostname}:${bastion_private_ip} -v /home/ubuntu/.docker/config.json:/config.json -v \${BUNDLE_DIR}:\${BUNDLE_DIR} quay.io/skopeo/stable:v1.18.0\"

            echo '>>> Uploading images (dual-path mode for v4.1.3 workaround)...'
            count=0; skipped=0; total=0

            # Enumerate images via mkectl airgap list-images
            while IFS= read -r full_ref; do
                [[ -z \"\${full_ref}\" ]] && continue
                total=\$((total + 1))

                # Strip registry prefix to get img_path
                img_path=\"\${full_ref}\"
                is_mke=false
                if [[ \"\${full_ref}\" == registry.mirantis.com/mke/* ]]; then
                    img_path=\"\${full_ref#registry.mirantis.com/mke/}\"
                    is_mke=true
                elif [[ \"\${full_ref}\" == registry.mirantis.com/k0rdent-enterprise/* ]]; then
                    img_path=\"\${full_ref#registry.mirantis.com/k0rdent-enterprise/}\"
                fi

                # Encode to find archive: / → &, : → @
                encoded=\$(echo \"\${img_path}\" | tr '/' '&' | tr ':' '@')

                # Find archive in images/ subdirectory
                archive=\"\"
                for subdir in \$(find \"\${BUNDLE_DIR}\" -type d -name images 2>/dev/null); do
                    if [[ -f \"\${subdir}/\${encoded}.tar\" ]]; then
                        archive=\"\${subdir}/\${encoded}.tar\"
                        break
                    fi
                done
                if [[ -z \"\${archive}\" ]]; then
                    skipped=\$((skipped + 1))
                    continue
                fi

                count=\$((count + 1))
                echo \"[\${count}] \${img_path}\"

                # Standard path: mke/<img_path>
                \${SKOPEO} copy --src-tls-verify=false --dest-tls-verify=false \
                    --authfile=/config.json --retry-times 3 --multi-arch all -q \
                    \"oci-archive:\${archive}\" \"docker://\${REGISTRY}/mke/\${img_path}\" || \
                    echo \"  WARNING: failed to upload \${img_path}\"

                # Dual path: mke/mke/<img_path> (only for mke/* images)
                if [[ \"\${is_mke}\" == \"true\" ]]; then
                    \${SKOPEO} copy --src-tls-verify=false --dest-tls-verify=false \
                        --authfile=/config.json --retry-times 3 --multi-arch all -q \
                        \"oci-archive:\${archive}\" \"docker://\${REGISTRY}/mke/mke/\${img_path}\" || \
                        echo \"  WARNING: failed to upload mke/\${img_path} (dual-path)\"
                fi
            done < <(mkectl airgap list-images 2>/dev/null || true)

            echo \">>> Images: \${count} uploaded, \${skipped} skipped (no archive)\"

            echo '>>> Uploading charts (dual-path mode)...'
            chart_count=0; chart_skipped=0

            while IFS= read -r full_ref; do
                [[ -z \"\${full_ref}\" ]] && continue

                # Strip oci:// prefix and registry
                chart_path=\"\${full_ref}\"
                is_mke_chart=false
                if [[ \"\${full_ref}\" == oci://registry.mirantis.com/mke/* ]]; then
                    chart_path=\"\${full_ref#oci://registry.mirantis.com/mke/}\"
                    is_mke_chart=true
                elif [[ \"\${full_ref}\" == oci://registry.mirantis.com/k0rdent-enterprise/* ]]; then
                    chart_path=\"\${full_ref#oci://registry.mirantis.com/k0rdent-enterprise/}\"
                fi

                encoded=\$(echo \"\${chart_path}\" | tr '/' '&' | tr ':' '@')

                archive=\"\"
                for subdir in \$(find \"\${BUNDLE_DIR}\" -type d -name charts 2>/dev/null); do
                    if [[ -f \"\${subdir}/\${encoded}.tar\" ]]; then
                        archive=\"\${subdir}/\${encoded}.tar\"
                        break
                    fi
                done
                if [[ -z \"\${archive}\" ]]; then
                    chart_skipped=\$((chart_skipped + 1))
                    continue
                fi

                chart_count=\$((chart_count + 1))
                echo \"[chart \${chart_count}] \${chart_path}\"

                \${SKOPEO} copy --src-tls-verify=false --dest-tls-verify=false \
                    --authfile=/config.json --retry-times 3 --multi-arch all -q \
                    \"oci-archive:\${archive}\" \"docker://\${REGISTRY}/mke/\${chart_path}\" || \
                    echo \"  WARNING: failed to upload chart \${chart_path}\"

                if [[ \"\${is_mke_chart}\" == \"true\" ]]; then
                    \${SKOPEO} copy --src-tls-verify=false --dest-tls-verify=false \
                        --authfile=/config.json --retry-times 3 --multi-arch all -q \
                        \"oci-archive:\${archive}\" \"docker://\${REGISTRY}/mke/mke/\${chart_path}\" || \
                        echo \"  WARNING: failed to upload chart mke/\${chart_path} (dual-path)\"
                fi
            done < <(mkectl airgap list-charts 2>/dev/null || true)

            echo \">>> Charts: \${chart_count} uploaded, \${chart_skipped} skipped (no archive)\"
            echo '>>> Bundle upload complete (dual-path).'
        "
    else
        # standard mode: filesystem scan of all .tar files
        ssh_node "${ssh_key}" "${bastion_ip}" "
            set -euo pipefail

            BUNDLE_DIR=~/${bundle_base}
            REGISTRY='${registry_hostname}'

            # Download bundle if not already present
            if [[ -z \"\$(find \${BUNDLE_DIR} -name '*.tar' -type f 2>/dev/null | head -1)\" ]]; then
                echo '>>> Downloading MKE4k bundle...'
                mkdir -p \"\${BUNDLE_DIR}\"
                cd /tmp
                curl -fL --progress-bar '${bundle_url}' -o bundle.tar.gz
                echo '>>> Extracting bundle...'
                tar -xzf bundle.tar.gz -C \"\${BUNDLE_DIR}\"
                rm bundle.tar.gz
            else
                echo '>>> Bundle already extracted'
            fi

            # Login to registry (creates ~/.docker/config.json for skopeo --authfile)
            docker login \${REGISTRY} -u admin -p '${registry_pass}'

            SKOPEO=\"docker run --rm --add-host ${registry_hostname}:${bastion_private_ip} -v /home/ubuntu/.docker/config.json:/config.json -v \${BUNDLE_DIR}:\${BUNDLE_DIR} quay.io/skopeo/stable:v1.18.0\"

            echo '>>> Uploading images to registry...'
            total=\$(find \"\${BUNDLE_DIR}\" -name '*.tar' -type f | wc -l)
            count=0
            for f in \$(find \"\${BUNDLE_DIR}\" -name '*.tar' -type f | sort); do
                count=\$((count + 1))
                # Decode filename: & → /, @ → :
                img=\$(basename \"\${f}\" .tar | tr '&' '/' | tr '@' ':')
                echo \"[\${count}/\${total}] \${img}\"
                \${SKOPEO} copy --src-tls-verify=false --dest-tls-verify=false \
                    --authfile=/config.json --retry-times 3 --multi-arch all -q \
                    \"oci-archive:\${f}\" \"docker://\${REGISTRY}/mke/\${img}\" || \
                    echo \"  WARNING: failed to upload \${img}\"
            done
            echo '>>> Bundle upload complete.'
        "
    fi
    success "MKE4k bundle uploaded to registry."
}

# ---------------------------------------------------------------------------
# Airgap — install mkectl on bastion
# ---------------------------------------------------------------------------
ensure_mkectl_on_bastion() {
    local ssh_key="${1}" bastion_ip="${2}"
    local want="${mke4k_version}"
    local tarball="mkectl_linux_x86_64.tar.gz"
    local url="${MKECTL_DOWNLOAD_URL:-https://github.com/MirantisContainers/mke-release/releases/download/${want}/${tarball}}"

    info "Installing mkectl ${want} + kubectl on bastion..."
    ssh_node "${ssh_key}" "${bastion_ip}" "
        need_install=true
        if command -v mkectl &>/dev/null; then
            got=\$(mkectl version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
            if [[ \"\${got}\" == '${want}' ]]; then
                echo 'mkectl ${want} already installed'
                need_install=false
            else
                echo \"mkectl \${got} found, want ${want} — re-downloading\"
            fi
        fi
        if [[ \"\${need_install}\" == \"true\" ]]; then
            cd /tmp && curl -fsSL '${url}' -o '${tarball}'
            tar -xzf '${tarball}'
            sudo install -m 755 mkectl /usr/local/bin/mkectl
            rm -f '${tarball}' mkectl
            echo 'mkectl ${want} installed'
        fi
        if ! command -v k9s &>/dev/null; then
            echo '>>> Installing k9s...'
            curl -fsSL 'https://github.com/derailed/k9s/releases/latest/download/k9s_Linux_amd64.tar.gz' -o /tmp/k9s.tar.gz
            tar -xzf /tmp/k9s.tar.gz -C /tmp k9s
            sudo install -m 755 /tmp/k9s /usr/local/bin/k9s
            rm -f /tmp/k9s.tar.gz /tmp/k9s
            echo 'k9s installed'
        else
            echo 'k9s already installed'
        fi
    "
    ensure_kubectl_on_bastion "${ssh_key}" "${bastion_ip}"
}

ensure_kubectl_on_bastion() {
    local ssh_key="${1}" bastion_ip="${2}"
    ssh_node "${ssh_key}" "${bastion_ip}" "
        if ! command -v kubectl &>/dev/null; then
            echo '>>> Installing kubectl...'
            curl -fsSL 'https://dl.k8s.io/release/stable.txt' -o /tmp/k8s_ver
            K8S_VER=\$(cat /tmp/k8s_ver)
            curl -fsSL \"https://dl.k8s.io/release/\${K8S_VER}/bin/linux/amd64/kubectl\" -o /tmp/kubectl
            sudo install -m 755 /tmp/kubectl /usr/local/bin/kubectl
            rm -f /tmp/kubectl /tmp/k8s_ver
            echo \"kubectl \${K8S_VER} installed\"
        else
            echo 'kubectl already installed'
        fi
    "
}

# ---------------------------------------------------------------------------
# Airgap — run mkectl apply from bastion
# ---------------------------------------------------------------------------
mkectl_apply_on_bastion() {
    local output ssh_key bastion_ip
    output="$(tf_output)"
    ssh_key="$(echo "${output}" | jq -r '.ssh_key_path.value')"
    bastion_ip="$(echo "${output}" | jq -r '.bastion_public_ip.value')"
    local mke4_yaml="${TERRAFORM_DIR}/mke4.yaml"

    [[ -f "${mke4_yaml}" ]] || die "mke4.yaml not found. Run 't deploy instances airgap' first."

    # SCP mke4.yaml + SSH key to bastion
    scp -q -o StrictHostKeyChecking=no -i "${ssh_key}" "${mke4_yaml}" "ubuntu@${bastion_ip}:~/mke4.yaml"
    scp -q -o StrictHostKeyChecking=no -i "${ssh_key}" "${ssh_key}" "ubuntu@${bastion_ip}:~/aws_private.pem"
    ssh_node "${ssh_key}" "${bastion_ip}" "chmod 600 ~/aws_private.pem"

    # Clear known_hosts on bastion to avoid host key mismatch with mkectl
    # (prior SSH via ProxyCommand may have cached keys with different hashing)
    ssh_node "${ssh_key}" "${bastion_ip}" "rm -f ~/.ssh/known_hosts"

    local debug_flag=""
    [[ "${debug:-false}" == "true" ]] && debug_flag="-l debug"

    info "Running mkectl apply on bastion (airgap mode)..."
    ssh_node "${ssh_key}" "${bastion_ip}" "mkectl ${debug_flag} apply -f ~/mke4.yaml"

    # SCP kubeconfig back
    info "Retrieving kubeconfig from bastion..."
    mkdir -p "$(dirname "${KUBECONFIG}")"
    scp -q -o StrictHostKeyChecking=no -i "${ssh_key}" \
        "ubuntu@${bastion_ip}:~/.mke/mke.kubeconf" "${KUBECONFIG}" 2>/dev/null || \
        warn "Could not retrieve kubeconfig. Use 't connect bastion' to access the cluster."

    success "Cluster deployment complete (airgap)."
}

# ---------------------------------------------------------------------------
# Airgap — patch CoreDNS to resolve registry hostname directly
# ---------------------------------------------------------------------------
# Adds a `hosts` block to CoreDNS Corefile so pods can resolve the registry
# hostname without going through the systemd-resolved → bind9 chain (which
# causes transient "no such host" errors due to timeouts).
patch_coredns_hosts() {
    local output ssh_key bastion_ip bastion_private_ip
    output="$(tf_output)"
    ssh_key="$(echo "${output}" | jq -r '.ssh_key_path.value')"
    bastion_ip="$(echo "${output}" | jq -r '.bastion_public_ip.value')"
    bastion_private_ip="$(echo "${output}" | jq -r '.bastion_private_ip.value')"

    info "Patching CoreDNS to resolve ${registry_hostname} → ${bastion_private_ip}..."
    ssh_node "${ssh_key}" "${bastion_ip}" "
        set -euo pipefail
        export KUBECONFIG=~/.mke/mke.kubeconf

        # Check if hosts block already present
        if kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}' | grep -q '${registry_hostname}'; then
            echo 'CoreDNS already has registry host entry — skipping'
            exit 0
        fi

        # Save current Corefile to a temp file
        kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}' > /tmp/Corefile

        # Inject hosts block right after '.:53 {'
        sed -i '/^\\.:53 {$/a\\
\\thosts {\\
\\t\\t${bastion_private_ip} ${registry_hostname}\\
\\t\\tfallthrough\\
\\t}' /tmp/Corefile

        # Replace the configmap in-place (avoids kubectl apply annotation warning)
        kubectl -n kube-system create configmap coredns --from-file=Corefile=/tmp/Corefile --dry-run=client -o yaml | \
            kubectl replace -f -
        rm -f /tmp/Corefile

        # Restart CoreDNS to pick up changes
        kubectl -n kube-system rollout restart deployment coredns
        kubectl -n kube-system rollout status deployment coredns --timeout=300s

        echo 'CoreDNS patched — registry hostname resolves directly in pods'
    "
}

# ---------------------------------------------------------------------------
# NFS — server setup, client install, provisioner deploy
# ---------------------------------------------------------------------------
setup_nfs_server() {
    local output ssh_key nfs_ip
    output="$(tf_output)"
    ssh_key="$(echo "${output}" | jq -r '.ssh_key_path.value')"

    local bastion_ip=""
    bastion_ip="$(echo "${output}" | jq -r '.bastion_public_ip.value // empty' 2>/dev/null)"
    local is_airgap=false
    [[ -n "${bastion_ip}" && "${bastion_ip}" != "null" && "${bastion_ip}" != "" ]] && is_airgap=true

    if [[ "${is_airgap}" == "true" ]]; then
        nfs_ip="$(echo "${output}" | jq -r '.nfs_server_private_ip.value')"
    else
        nfs_ip="$(echo "${output}" | jq -r '.nfs_server_public_ip.value')"
    fi

    [[ -z "${nfs_ip}" || "${nfs_ip}" == "null" || "${nfs_ip}" == "" ]] \
        && die "NFS server IP not found. Was terraform applied with nfs_enabled=true?"

    info "Setting up NFS server (${nfs_ip})..."

    if [[ "${is_airgap}" == "true" ]]; then
        # Airgap: download .deb packages on bastion, transfer to NFS server
        wait_for_ssh "${ssh_key}" "${bastion_ip}" "bastion"
        # Ensure SSH key is on bastion for SCP to private-subnet nodes
        scp -q -o StrictHostKeyChecking=no -i "${ssh_key}" "${ssh_key}" "ubuntu@${bastion_ip}:~/aws_private.pem"
        info "  Downloading NFS server packages on bastion..."
        ssh_node "${ssh_key}" "${bastion_ip}" "
            set -euo pipefail
            if [[ -d /tmp/nfs-server-debs ]]; then
                echo 'NFS server packages already downloaded'
                exit 0
            fi
            mkdir -p /tmp/nfs-server-debs
            cd /tmp/nfs-server-debs
            sudo apt-get update -qq
            apt-get download \$(apt-cache depends --recurse --no-recommends --no-suggests \
                --no-conflicts --no-breaks --no-replaces --no-enhances \
                nfs-kernel-server | grep '^\w' | sort -u) 2>/dev/null || true
            echo \"Downloaded \$(ls *.deb 2>/dev/null | wc -l) packages\"
        "

        info "  Transferring packages to NFS server..."
        ssh_node "${ssh_key}" "${bastion_ip}" "
            set -euo pipefail
            tar czf /tmp/nfs-server-debs.tar.gz -C /tmp nfs-server-debs
            scp -q -o StrictHostKeyChecking=no -i ~/aws_private.pem \
                /tmp/nfs-server-debs.tar.gz ubuntu@${nfs_ip}:/tmp/
        "

        # Make sure we can reach the NFS server via bastion (always Ubuntu)
        info "  Installing NFS server packages..."
        ssh_via_bastion ubuntu "${ssh_key}" "${bastion_ip}" "${nfs_ip}" "
            set -euo pipefail
            if dpkg -l nfs-kernel-server 2>/dev/null | grep -q '^ii'; then
                echo 'nfs-kernel-server already installed'
            else
                cd /tmp
                tar xzf nfs-server-debs.tar.gz
                sudo dpkg -i --force-depends nfs-server-debs/*.deb 2>/dev/null || true
                rm -rf nfs-server-debs nfs-server-debs.tar.gz
            fi
            sudo mkdir -p ${nfs_export_path}
            sudo chown nobody:nogroup ${nfs_export_path}
            sudo chmod 755 ${nfs_export_path}
            echo '${nfs_export_path}    *(rw,sync,no_root_squash,no_subtree_check)' | sudo tee /etc/exports >/dev/null
            sudo exportfs -ra
            sudo systemctl enable --now nfs-kernel-server
            echo 'NFS server ready'
        "
    else
        # Online: direct SSH
        wait_for_ssh "${ssh_key}" "${nfs_ip}" "nfs-server"
        ssh_node "${ssh_key}" "${nfs_ip}" "
            set -euo pipefail
            if dpkg -l nfs-kernel-server 2>/dev/null | grep -q '^ii'; then
                echo 'nfs-kernel-server already installed'
            else
                sudo apt-get update -qq
                sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nfs-kernel-server >/dev/null 2>&1
            fi
            sudo mkdir -p ${nfs_export_path}
            sudo chown nobody:nogroup ${nfs_export_path}
            sudo chmod 755 ${nfs_export_path}
            echo '${nfs_export_path}    *(rw,sync,no_root_squash,no_subtree_check)' | sudo tee /etc/exports >/dev/null
            sudo exportfs -ra
            sudo systemctl enable --now nfs-kernel-server
            echo 'NFS server ready'
        "
    fi
    success "NFS server configured (export: ${nfs_export_path})."
}

install_nfs_client_on_nodes() {
    local output ssh_key
    output="$(tf_output)"
    ssh_key="$(echo "${output}" | jq -r '.ssh_key_path.value')"

    local bastion_ip=""
    bastion_ip="$(echo "${output}" | jq -r '.bastion_public_ip.value // empty' 2>/dev/null)"
    local is_airgap=false
    [[ -n "${bastion_ip}" && "${bastion_ip}" != "null" && "${bastion_ip}" != "" ]] && is_airgap=true

    local all_ips=()
    if [[ "${is_airgap}" == "true" ]]; then
        mapfile -t all_ips < <(echo "${output}" | jq -r '.controller_private_ips.value[], .worker_private_ips.value[]' 2>/dev/null)
    else
        mapfile -t all_ips < <(echo "${output}" | jq -r '.controller_ips.value[], .worker_ips.value[]' 2>/dev/null)
    fi

    [[ ${#all_ips[@]} -eq 0 ]] && { warn "No cluster nodes found — skipping NFS client install."; return; }

    info "Installing NFS client on ${#all_ips[@]} cluster node(s)..."

    if [[ "${is_airgap}" == "true" && "${os_name}" == "redhat" ]]; then
        # RHEL nodes: the Ubuntu bastion cannot build RPM bundles, so install
        # nfs-utils via dnf through the bastion's Squid proxy against RHUI
        # (requires setup_node_dns to have run so RHUI hostnames resolve).
        # The proxy is passed per-command (--setopt) — no persistent proxy
        # state is left on MKE4k-airgap nodes.
        local bastion_private_ip
        bastion_private_ip="$(echo "${output}" | jq -r '.bastion_private_ip.value')"
        setup_squid_proxy
        for node_ip in "${all_ips[@]}"; do
            info "  nfs-utils → ${node_ip}"
            ssh_node_via_bastion "${ssh_key}" "${bastion_ip}" "${node_ip}" "
                set -euo pipefail
                if rpm -q nfs-utils >/dev/null 2>&1; then
                    echo 'nfs-utils already installed'
                    exit 0
                fi
                sudo dnf -y -q --setopt=proxy=http://${bastion_private_ip}:3128 install nfs-utils >/dev/null
                echo 'nfs-utils installed'
            " || die "nfs-utils install failed on ${node_ip} (see output above). The cluster itself is deployed — re-run 't deploy nfs [mke3]' to finish NFS setup."
        done
    elif [[ "${is_airgap}" == "true" ]]; then
        # Ubuntu nodes: download .deb bundle on the (Ubuntu) bastion, push + dpkg -i
        info "  Downloading nfs-common packages on bastion..."
        ssh_node "${ssh_key}" "${bastion_ip}" "
            set -euo pipefail
            if [[ -d /tmp/nfs-client-debs ]]; then
                echo 'NFS client packages already downloaded'
                exit 0
            fi
            mkdir -p /tmp/nfs-client-debs
            cd /tmp/nfs-client-debs
            sudo apt-get update -qq
            apt-get download \$(apt-cache depends --recurse --no-recommends --no-suggests \
                --no-conflicts --no-breaks --no-replaces --no-enhances \
                nfs-common | grep '^\w' | sort -u) 2>/dev/null || true
            tar czf /tmp/nfs-client-debs.tar.gz -C /tmp nfs-client-debs
            echo \"Downloaded \$(ls *.deb 2>/dev/null | wc -l) packages\"
        "

        for node_ip in "${all_ips[@]}"; do
            info "  nfs-common → ${node_ip}"
            ssh_node "${ssh_key}" "${bastion_ip}" "
                scp -q -o StrictHostKeyChecking=no -i ~/aws_private.pem \
                    /tmp/nfs-client-debs.tar.gz ubuntu@${node_ip}:/tmp/
            "
            ssh_node_via_bastion "${ssh_key}" "${bastion_ip}" "${node_ip}" "
                set -euo pipefail
                if dpkg -l nfs-common 2>/dev/null | grep -q '^ii'; then
                    echo 'nfs-common already installed'
                    exit 0
                fi
                cd /tmp
                tar xzf nfs-client-debs.tar.gz
                sudo dpkg -i --force-depends nfs-client-debs/*.deb 2>/dev/null || true
                rm -rf nfs-client-debs nfs-client-debs.tar.gz
                dpkg -l nfs-common 2>/dev/null | grep -q '^ii'
            " || die "nfs-common install failed on ${node_ip} (see output above). The cluster itself is deployed — re-run 't deploy nfs [mke3]' to finish NFS setup."
        done
    elif [[ "${os_name}" == "redhat" ]]; then
        for node_ip in "${all_ips[@]}"; do
            info "  nfs-utils → ${node_ip}"
            ssh_host "$(node_ssh_user)" "${ssh_key}" "${node_ip}" "
                set -euo pipefail
                if rpm -q nfs-utils >/dev/null 2>&1; then
                    echo 'nfs-utils already installed'
                    exit 0
                fi
                sudo dnf -y -q install nfs-utils >/dev/null
                echo 'nfs-utils installed'
            " || die "nfs-utils install failed on ${node_ip} (see output above). The cluster itself is deployed — re-run 't deploy nfs [mke3]' to finish NFS setup."
        done
    else
        for node_ip in "${all_ips[@]}"; do
            info "  nfs-common → ${node_ip}"
            # DPkg::Lock::Timeout: apt/dpkg locks may still be held by
            # unattended-upgrades or the just-finished product install
            ssh_node "${ssh_key}" "${node_ip}" "
                set -euo pipefail
                if dpkg -l nfs-common 2>/dev/null | grep -q '^ii'; then
                    echo 'nfs-common already installed'
                    exit 0
                fi
                sudo apt-get -o DPkg::Lock::Timeout=300 update -qq
                sudo DEBIAN_FRONTEND=noninteractive \
                    apt-get -o DPkg::Lock::Timeout=300 install -y -qq nfs-common
            " || die "nfs-common install failed on ${node_ip} (see output above). The cluster itself is deployed — re-run 't deploy nfs [mke3]' to finish NFS setup."
        done
    fi
    success "NFS client installed on all cluster nodes."
}

deploy_nfs_provisioner() {
    local output nfs_private_ip
    output="$(tf_output)"
    nfs_private_ip="$(echo "${output}" | jq -r '.nfs_server_private_ip.value')"

    [[ -z "${nfs_private_ip}" || "${nfs_private_ip}" == "null" || "${nfs_private_ip}" == "" ]] \
        && die "NFS server private IP not found."

    info "Deploying nfs-subdir-external-provisioner (online)..."
    helm repo add nfs-subdir-external-provisioner \
        https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/ 2>/dev/null || true
    helm repo update nfs-subdir-external-provisioner

    helm install nfs-subdir-external-provisioner \
        nfs-subdir-external-provisioner/nfs-subdir-external-provisioner \
        --set nfs.server="${nfs_private_ip}" \
        --set nfs.path="${nfs_export_path}" \
        --wait --timeout 300s 2>/dev/null \
    || {
        # Already installed? Try upgrade instead
        helm upgrade nfs-subdir-external-provisioner \
            nfs-subdir-external-provisioner/nfs-subdir-external-provisioner \
            --set nfs.server="${nfs_private_ip}" \
            --set nfs.path="${nfs_export_path}" \
            --wait --timeout 300s
    }

    kubectl patch storageclass nfs-client \
        -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

    success "NFS StorageClass 'nfs-client' deployed and set as default."
}

upload_nfs_provisioner_image() {
    local output ssh_key bastion_ip bastion_private_ip
    output="$(tf_output)"
    ssh_key="$(echo "${output}" | jq -r '.ssh_key_path.value')"
    bastion_ip="$(echo "${output}" | jq -r '.bastion_public_ip.value')"
    bastion_private_ip="$(echo "${output}" | jq -r '.bastion_private_ip.value')"

    local creds_file="${TERRAFORM_DIR}/registry_credentials.txt"
    [[ -f "${creds_file}" ]] || die "Registry credentials not found. Run 't deploy registry' first."
    local registry_pass
    registry_pass="$(grep '^password=' "${creds_file}" | cut -d= -f2)"

    local reg_host="${registry_hostname}"
    local nfs_image="registry.k8s.io/sig-storage/nfs-subdir-external-provisioner:v4.0.2"

    info "Uploading NFS provisioner image to registry..."

    ssh_node "${ssh_key}" "${bastion_ip}" "
        set -euo pipefail

        # Create 'nfs' project in Harbor
        if ! curl -sk -u 'admin:${registry_pass}' \
                'https://${reg_host}/api/v2.0/projects?name=nfs' | grep -q '\"name\":\"nfs\"'; then
            curl -sk -u 'admin:${registry_pass}' \
                -X POST 'https://${reg_host}/api/v2.0/projects' \
                -H 'Content-Type: application/json' \
                -d '{\"project_name\":\"nfs\",\"public\":true}' || true
            echo 'Created Harbor project: nfs'
        else
            echo 'Harbor project nfs already exists'
        fi

        # Copy image via skopeo
        echo '>>> Copying NFS provisioner image...'
        docker run --rm \
            --add-host '${reg_host}:${bastion_private_ip}' \
            -v /etc/docker/certs.d/${reg_host}/ca.crt:/etc/docker/certs.d/${reg_host}/ca.crt:ro \
            quay.io/skopeo/stable:v1.18.0 copy \
                --dest-tls-verify=false \
                --dest-creds 'admin:${registry_pass}' \
                'docker://${nfs_image}' \
                'docker://${reg_host}/nfs/nfs-subdir-external-provisioner:v4.0.2'
        echo 'NFS provisioner image uploaded'

        # Install helm if not present
        if ! command -v helm &>/dev/null; then
            echo '>>> Installing helm...'
            curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
        fi

        # Pull chart for offline install
        CHART_DIR=~/nfs-provisioner-chart
        if [[ ! -d \"\${CHART_DIR}/nfs-subdir-external-provisioner\" ]]; then
            echo '>>> Pulling NFS provisioner chart...'
            helm repo add nfs-subdir-external-provisioner \
                https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/ 2>/dev/null || true
            helm repo update nfs-subdir-external-provisioner
            mkdir -p \"\${CHART_DIR}\"
            helm pull nfs-subdir-external-provisioner/nfs-subdir-external-provisioner \
                --untar --untardir \"\${CHART_DIR}\"
        else
            echo 'Chart already pulled'
        fi
    "
    success "NFS provisioner image + chart ready on bastion."
}

deploy_nfs_provisioner_airgap() {
    local output ssh_key bastion_ip nfs_private_ip
    output="$(tf_output)"
    ssh_key="$(echo "${output}" | jq -r '.ssh_key_path.value')"
    bastion_ip="$(echo "${output}" | jq -r '.bastion_public_ip.value')"
    nfs_private_ip="$(echo "${output}" | jq -r '.nfs_server_private_ip.value')"

    [[ -z "${nfs_private_ip}" || "${nfs_private_ip}" == "null" || "${nfs_private_ip}" == "" ]] \
        && die "NFS server private IP not found."

    local reg_host="${registry_hostname}"

    info "Deploying nfs-subdir-external-provisioner (airgap, from bastion)..."

    ssh_node "${ssh_key}" "${bastion_ip}" "
        set -euo pipefail
        export KUBECONFIG=~/.mke/mke.kubeconf

        CHART_DIR=~/nfs-provisioner-chart/nfs-subdir-external-provisioner
        [[ -d \"\${CHART_DIR}\" ]] || { echo 'ERROR: Chart not found. Run upload_nfs_provisioner_image first.'; exit 1; }

        helm install nfs-subdir-external-provisioner \"\${CHART_DIR}\" \
            --set nfs.server='${nfs_private_ip}' \
            --set nfs.path='${nfs_export_path}' \
            --set image.repository='${reg_host}/nfs/nfs-subdir-external-provisioner' \
            --set image.tag='v4.0.2' \
            --wait --timeout 300s 2>/dev/null \
        || {
            helm upgrade nfs-subdir-external-provisioner \"\${CHART_DIR}\" \
                --set nfs.server='${nfs_private_ip}' \
                --set nfs.path='${nfs_export_path}' \
                --set image.repository='${reg_host}/nfs/nfs-subdir-external-provisioner' \
                --set image.tag='v4.0.2' \
                --wait --timeout 300s
        }

        kubectl patch storageclass nfs-client \
            -p '{\"metadata\":{\"annotations\":{\"storageclass.kubernetes.io/is-default-class\":\"true\"}}}'

        echo 'NFS StorageClass nfs-client deployed and set as default'
    "
    success "NFS StorageClass 'nfs-client' deployed (airgap)."
}

# ---------------------------------------------------------------------------
# MKE3 — kubectl/helm access goes through the launchpad client bundle
# (source env.sh inside the bundle dir to set KUBECONFIG + certs)
# ---------------------------------------------------------------------------
# Generates (or refreshes) the MKE3 admin client bundle locally and prints
# its directory on stdout. Status output goes to stderr so callers can
# capture the path with $(...).
ensure_mke3_client_bundle() {
    local launchpad_yaml="${TERRAFORM_DIR}/launchpad.yaml"
    [[ -f "${launchpad_yaml}" ]] || die "launchpad.yaml not found. Deploy MKE3 first."
    ensure_launchpad >&2
    info "Generating MKE3 client bundle..." >&2
    launchpad client-config -a -c "${launchpad_yaml}" >&2

    local bundle_dir
    bundle_dir="$(ls -d "${HOME}"/.mirantis-launchpad/cluster/*/bundle/admin 2>/dev/null | head -1 || true)"
    [[ -n "${bundle_dir}" ]] || die "Client bundle not found."
    echo "${bundle_dir}"
}

# ---------------------------------------------------------------------------
# MKE3 configuration file (TOML)
# https://docs.mirantis.com/mke/3.9/ops/administer-cluster/configure-an-mke-cluster/use-an-mke-configuration-file.html
#
# GET/PUT https://<mke3-nlb>/api/ucp/config-toml, authenticated with a bearer
# token from POST /auth/login. Online the NLB is public and curl runs locally;
# in airgap the MKE3 NLB is *internal*, so login + transfer both run on the
# bastion in a single ssh call (token never leaves the bastion). The bastion has
# no jq, so the remote side parses the token with sed, and the login payload is
# handed over base64-encoded to sidestep shell quoting entirely.
# ---------------------------------------------------------------------------

mke3_config_file() {
    printf '%s\n' "${TERRAFORM_DIR}/mke3-config.toml"
}

# Resolve the MKE3 API host (the MKE3 NLB DNS name) from terraform output.
# Optional arg: a pre-fetched tf_output JSON blob.
mke3_api_host() {
    local output="${1:-}"
    [[ -n "${output}" ]] || output="$(tf_output)"
    local mke3_lb_dns
    mke3_lb_dns="$(echo "${output}" | jq -r '.mke3_lb_dns_name.value // empty' 2>/dev/null)"
    [[ -n "${mke3_lb_dns}" && "${mke3_lb_dns}" != "null" ]] \
        || die "mke3_lb_dns_name is empty. Was terraform applied with mke3_enabled=true?"
    printf '%s\n' "${mke3_lb_dns}"
}

# Build the /auth/login JSON body from terraform/mke3_credentials.txt.
# jq -n does the quoting, so odd characters in the password are safe.
mke3_login_payload() {
    local creds admin_user admin_pass
    # Not a process substitution: read_mke3_credentials must be able to abort
    # the caller, and a dying <(...) subshell would go unnoticed here.
    creds="$(read_mke3_credentials strict)" || exit 1
    IFS=$'\t' read -r admin_user admin_pass <<< "${creds}"
    jq -nc --arg u "${admin_user}" --arg p "${admin_pass}" '{username:$u,password:$p}'
}

# POST /auth/login from this host -> auth token on stdout. Online mode only.
mke3_api_login() {
    local host="$1" payload="$2"
    local token
    # `|| true` so a connection failure lands on the die below (set -e/pipefail)
    token="$(curl -sk --max-time 30 --data "${payload}" \
        "https://${host}/auth/login" 2>/dev/null | jq -r '.auth_token // empty' 2>/dev/null || true)"
    [[ -n "${token}" ]] \
        || die "MKE3 login failed at https://${host}/auth/login. Check $(basename "$(mke3_credentials_file)") and that the cluster is up."
    printf '%s\n' "${token}"
}

# Remote (bastion) prologue: decode the login payload and export TOKEN.
# Emitted into the ssh command string; the caller appends the actual curl call.
_mke3_remote_login_snippet() {
    local host="$1" payload_b64="$2"
    cat <<REMOTE
set -eo pipefail
LOGIN=\$(printf '%s' '${payload_b64}' | base64 -d)
TOKEN=\$(curl -sk --max-time 30 --data "\${LOGIN}" "https://${host}/auth/login" \
    | sed -n 's/.*"auth_token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
if [ -z "\${TOKEN}" ]; then
    echo "ERROR: MKE3 login failed at https://${host}/auth/login" >&2
    exit 1
fi
REMOTE
}

# Fetch the running MKE3 config into terraform/mke3-config.toml.
# Usage: mke3_config_get <online|airgap> [dest_file]
mke3_config_get() {
    local mode="$1"
    local dest="${2:-$(mke3_config_file)}"
    local output host payload tmp
    output="$(tf_output)" || die "Could not read terraform output. Has terraform been applied?"
    host="$(mke3_api_host "${output}")"
    payload="$(mke3_login_payload)"
    tmp="$(mktemp)"

    info "Fetching MKE3 config from https://${host}/api/ucp/config-toml (${mode})..."

    if [[ "${mode}" == "airgap" ]]; then
        local ssh_key bastion_ip payload_b64
        ssh_key="$(echo "${output}" | jq -r '.ssh_key_path.value')"
        bastion_ip="$(echo "${output}" | jq -r '.bastion_public_ip.value')"
        payload_b64="$(printf '%s' "${payload}" | openssl base64 -A)"

        if ! ssh_node "${ssh_key}" "${bastion_ip}" "
$(_mke3_remote_login_snippet "${host}" "${payload_b64}")
curl -sk --max-time 60 -X GET \"https://${host}/api/ucp/config-toml\" \
    -H 'accept: application/toml' \
    -H \"Authorization: Bearer \${TOKEN}\"
" < /dev/null > "${tmp}"; then
            rm -f "${tmp}"
            die "Failed to fetch the MKE3 config from the bastion."
        fi
    else
        local token
        token="$(mke3_api_login "${host}" "${payload}")"
        if ! curl -sk --max-time 60 -X GET "https://${host}/api/ucp/config-toml" \
            -H 'accept: application/toml' \
            -H "Authorization: Bearer ${token}" -o "${tmp}"; then
            rm -f "${tmp}"
            die "Failed to fetch the MKE3 config from https://${host}."
        fi
    fi

    # Guard against an error page / empty body landing in the file
    [[ -s "${tmp}" ]] || { rm -f "${tmp}"; die "MKE3 returned an empty config. Is the cluster up?"; }
    if ! grep -q '^\[' "${tmp}"; then
        local preview
        preview="$(head -c 200 "${tmp}")"
        rm -f "${tmp}"
        die "MKE3 config response is not TOML (no [table] header). First bytes: ${preview}"
    fi

    mv "${tmp}" "${dest}"
    chmod 600 "${dest}"
}

# Push a TOML file back to the cluster. Re-acquires the auth token immediately
# before the upload (tokens expire; the docs warn about this explicitly).
# Usage: mke3_config_apply <online|airgap> [src_file]
mke3_config_apply() {
    local mode="$1"
    local src="${2:-$(mke3_config_file)}"
    [[ -s "${src}" ]] || die "${src} not found or empty. Run 't config get mke3' first."
    grep -q '^\[' "${src}" || die "${src} does not look like an MKE3 config (no [table] header)."

    local output host payload
    output="$(tf_output)" || die "Could not read terraform output. Has terraform been applied?"
    host="$(mke3_api_host "${output}")"
    payload="$(mke3_login_payload)"

    info "Uploading MKE3 config to https://${host}/api/ucp/config-toml (${mode})..."

    if [[ "${mode}" == "airgap" ]]; then
        local ssh_key bastion_ip payload_b64
        ssh_key="$(echo "${output}" | jq -r '.ssh_key_path.value')"
        bastion_ip="$(echo "${output}" | jq -r '.bastion_public_ip.value')"
        payload_b64="$(printf '%s' "${payload}" | openssl base64 -A)"

        scp -q -o StrictHostKeyChecking=no -i "${ssh_key}" \
            "${src}" "ubuntu@${bastion_ip}:~/mke3-config.toml" \
            || die "Failed to copy ${src} to the bastion."

        ssh_node "${ssh_key}" "${bastion_ip}" "
$(_mke3_remote_login_snippet "${host}" "${payload_b64}")
CODE=\$(curl -sk --max-time 120 -o /tmp/mke3-config-put.out -w '%{http_code}' \
    -X PUT -H 'accept: application/toml' \
    -H \"Authorization: Bearer \${TOKEN}\" \
    --upload-file ~/mke3-config.toml \
    \"https://${host}/api/ucp/config-toml\")
echo \">>> HTTP \${CODE}\"
if [ \"\${CODE#2}\" = \"\${CODE}\" ]; then
    { cat /tmp/mke3-config-put.out; echo; } >&2
    exit 1
fi
" < /dev/null || die "MKE3 rejected the config upload (see the response above)."
    else
        local token resp code
        token="$(mke3_api_login "${host}" "${payload}")"
        resp="$(mktemp)"
        code="$(curl -sk --max-time 120 -o "${resp}" -w '%{http_code}' \
            -X PUT -H 'accept: application/toml' \
            -H "Authorization: Bearer ${token}" \
            --upload-file "${src}" \
            "https://${host}/api/ucp/config-toml")"
        info "  HTTP ${code}"
        if [[ "${code#2}" == "${code}" ]]; then
            error "$(cat "${resp}")"
            rm -f "${resp}"
            die "MKE3 rejected the config upload (HTTP ${code})."
        fi
        rm -f "${resp}"
    fi
}

deploy_nfs_provisioner_mke3() {
    local bundle_dir
    bundle_dir="$(ensure_mke3_client_bundle)"
    info "Using MKE3 client bundle: ${bundle_dir}"
    (
        cd "${bundle_dir}"
        set +u   # env.sh may reference unset vars
        # shellcheck source=/dev/null
        source env.sh
        set -u
        deploy_nfs_provisioner
    )
}

deploy_nfs_provisioner_mke3_airgap() {
    local output ssh_key bastion_ip nfs_private_ip
    output="$(tf_output)"
    ssh_key="$(echo "${output}" | jq -r '.ssh_key_path.value')"
    bastion_ip="$(echo "${output}" | jq -r '.bastion_public_ip.value')"
    nfs_private_ip="$(echo "${output}" | jq -r '.nfs_server_private_ip.value')"

    [[ -z "${nfs_private_ip}" || "${nfs_private_ip}" == "null" || "${nfs_private_ip}" == "" ]] \
        && die "NFS server private IP not found."

    local reg_host="${registry_hostname}"

    ensure_kubectl_on_bastion "${ssh_key}" "${bastion_ip}"

    info "Deploying nfs-subdir-external-provisioner (MKE3 airgap, from bastion)..."

    # No 'set -u': env.sh may reference unset vars
    ssh_node "${ssh_key}" "${bastion_ip}" "
        set -eo pipefail

        command -v launchpad &>/dev/null || { echo 'ERROR: launchpad not found on bastion. Deploy MKE3 first.'; exit 1; }
        [[ -f ~/launchpad.yaml ]] || { echo 'ERROR: launchpad.yaml not found on bastion. Deploy MKE3 first.'; exit 1; }

        echo '>>> Generating MKE3 client bundle...'
        launchpad client-config -a -c ~/launchpad.yaml
        BUNDLE_DIR=\$(ls -d ~/.mirantis-launchpad/cluster/*/bundle/admin 2>/dev/null | head -1 || true)
        [[ -n \"\${BUNDLE_DIR}\" ]] || { echo 'ERROR: client bundle not found on bastion.'; exit 1; }
        cd \"\${BUNDLE_DIR}\"
        source env.sh

        CHART_DIR=~/nfs-provisioner-chart/nfs-subdir-external-provisioner
        [[ -d \"\${CHART_DIR}\" ]] || { echo 'ERROR: Chart not found. Run upload_nfs_provisioner_image first.'; exit 1; }

        helm install nfs-subdir-external-provisioner \"\${CHART_DIR}\" \
            --set nfs.server='${nfs_private_ip}' \
            --set nfs.path='${nfs_export_path}' \
            --set image.repository='${reg_host}/nfs/nfs-subdir-external-provisioner' \
            --set image.tag='v4.0.2' \
            --wait --timeout 300s 2>/dev/null \
        || {
            helm upgrade nfs-subdir-external-provisioner \"\${CHART_DIR}\" \
                --set nfs.server='${nfs_private_ip}' \
                --set nfs.path='${nfs_export_path}' \
                --set image.repository='${reg_host}/nfs/nfs-subdir-external-provisioner' \
                --set image.tag='v4.0.2' \
                --wait --timeout 300s
        }

        kubectl patch storageclass nfs-client \
            -p '{\"metadata\":{\"annotations\":{\"storageclass.kubernetes.io/is-default-class\":\"true\"}}}'

        echo 'NFS StorageClass nfs-client deployed and set as default'
    "
    success "NFS StorageClass 'nfs-client' deployed (MKE3 airgap)."
}

# ---------------------------------------------------------------------------
# mke4.yaml generation — mkectl init provides the schema, we patch values in
# ---------------------------------------------------------------------------
generate_mke4_yaml() {
    local airgap="${1:-false}"

    ensure_mkectl

    local mke4_yaml="${TERRAFORM_DIR}/mke4.yaml"
    local output
    output="$(tf_output)" || die "Could not read terraform output. Has terraform been applied?"

    local lb_dns ssh_key
    lb_dns="$(echo "${output}" | jq -r '.lb_dns_name.value')"
    ssh_key="$(echo "${output}" | jq -r '.ssh_key_path.value')"

    info "Generating mke4.yaml via mkectl init..."
    mkectl init > "${mke4_yaml}"

    # Single-node: 1 controller, 0 workers → role "single" (manager+worker combined)
    # Otherwise controllers get "controller+worker"
    local ctrl_role="controller+worker"
    if [[ "${controller_count}" -eq 1 && "${worker_count}" -eq 0 ]]; then
        ctrl_role="single"
        info "Single-node setup detected — using role: single"
    fi

    # In airgap mode, use private IPs and bastion keypath
    local ctrl_ips_field="controller_ips"
    local wkr_ips_field="worker_ips"
    local key_path="${ssh_key}"

    if [[ "${airgap}" == "true" ]]; then
        ctrl_ips_field="controller_private_ips"
        wkr_ips_field="worker_private_ips"
        key_path="/home/ubuntu/aws_private.pem"   # Path ON the bastion
    fi

    # Build hosts JSON array with jq, then patch the YAML with yq
    local hosts_json
    hosts_json="$(echo "${output}" | jq -c \
        --arg key "${key_path}" \
        --arg user "$(node_ssh_user)" \
        --arg crole "${ctrl_role}" \
        --arg ctrl_field "${ctrl_ips_field}" \
        --arg wkr_field "${wkr_ips_field}" \
        '[
            (.[$ctrl_field].value[] | {
                ssh: { address: ., user: $user, keyPath: $key },
                role: $crole
            }),
            (.[$wkr_field].value[] | {
                ssh: { address: ., user: $user, keyPath: $key },
                role: "worker"
            })
        ]')"

    yq e -i "
        .spec.version = \"${mke4k_version}\" |
        .spec.apiServer.externalAddress = \"${lb_dns}\" |
        .spec.cloudProvider.enabled = ${ccm_enabled} |
        .spec.cloudProvider.provider = \"aws\" |
        .spec.hosts = ${hosts_json}
    " "${mke4_yaml}"

    # Airgap-specific patches
    if [[ "${airgap}" == "true" ]]; then
        local reg_host="${registry_hostname}"

        # Read the saved CA cert
        local cert_file="${TERRAFORM_DIR}/registry_ca.crt"
        [[ -f "${cert_file}" ]] || die "Registry CA cert not found at ${cert_file}. Run 't deploy registry' first."

        export CERT_DATA
        CERT_DATA="$(cat "${cert_file}")"

        yq e -i "
            .spec.airgap.enabled = true |
            .spec.cloudProvider.enabled = false |
            .spec.registries.imageRegistry.url = \"${reg_host}/mke\" |
            .spec.registries.chartRegistry.url = \"oci://${reg_host}/mke\"
        " "${mke4_yaml}"

        yq e -i '
            .spec.registries.imageRegistry.caData = strenv(CERT_DATA) |
            .spec.registries.imageRegistry.caData style = "literal" |
            .spec.registries.chartRegistry.caData = strenv(CERT_DATA) |
            .spec.registries.chartRegistry.caData style = "literal"
        ' "${mke4_yaml}"
        unset CERT_DATA

        info "Airgap mode: registry=${reg_host}, caData embedded"
    fi

    success "mke4.yaml written to ${mke4_yaml}"
}

# ---------------------------------------------------------------------------
# NLB wait — AWS NLBs take ~60s to become active after terraform apply
# ---------------------------------------------------------------------------
wait_for_lb() {
    local seconds=60
    info "Waiting ${seconds}s for NLB to become active..."
    for (( i=seconds; i>0; i-- )); do
        printf "\r${CYAN}[t]${RESET} NLB stabilising: %2ds remaining..." "${i}"
        sleep 1
    done
    printf "\r${GREEN}[t]${RESET} NLB ready, continuing.                  \n"
}

# ---------------------------------------------------------------------------
# mkectl helpers
# ---------------------------------------------------------------------------
mkectl_apply() {
    ensure_mkectl
    local mke4_yaml="${TERRAFORM_DIR}/mke4.yaml"
    [[ -f "${mke4_yaml}" ]] || die "mke4.yaml not found at ${mke4_yaml}. Run 't deploy instances' first."
    local debug_flag=""
    [[ "${debug:-false}" == "true" ]] && debug_flag="-l debug"
    info "Running mkectl apply${debug_flag:+ (debug mode)}..."
    mkectl ${debug_flag} apply -f "${mke4_yaml}"
    success "Cluster deployment complete."
    info "Kubeconfig written to ${KUBECONFIG}"
}

mkectl_reset() {
    ensure_mkectl
    local mke4_yaml="${TERRAFORM_DIR}/mke4.yaml"
    [[ -f "${mke4_yaml}" ]] || die "mke4.yaml not found at ${mke4_yaml}. Has the cluster been deployed?"
    local debug_flag=""
    [[ "${debug:-false}" == "true" ]] && debug_flag="-l debug"
    info "Running mkectl reset --force${debug_flag:+ (debug mode)}..."
    mkectl ${debug_flag} reset --force -f "${mke4_yaml}"
    success "Cluster reset complete."
}

# ---------------------------------------------------------------------------
# launchpad — download on demand, version pinned to launchpad_version from config
# ---------------------------------------------------------------------------
# Override the download URL by setting LAUNCHPAD_DOWNLOAD_URL in the environment.
ensure_launchpad() {
    local want="${launchpad_version}"
    local install_path="/usr/local/bin/launchpad"
    # Version stored without 'v' in config; GitHub tag uses 'v' prefix
    local url="${LAUNCHPAD_DOWNLOAD_URL:-https://github.com/Mirantis/launchpad/releases/download/v${want}/launchpad_linux_amd64_${want}}"

    # Already at the right version?
    if command -v launchpad &>/dev/null; then
        local got
        got="$(launchpad version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
        if [[ "${got}" == "${want}" ]]; then
            return 0
        fi
        [[ -n "${got}" ]] && warn "launchpad ${got} found, want ${want} — re-downloading"
    fi

    info "Downloading launchpad ${want}..."
    info "  URL: ${url}"
    if ! curl -fsSL "${url}" -o "${install_path}"; then
        die "Failed to download launchpad ${want}.\n  URL tried: ${url}\n  Set LAUNCHPAD_DOWNLOAD_URL env var to override."
    fi
    chmod +x "${install_path}"
    success "launchpad ${want} ready."
}

# ---------------------------------------------------------------------------
# launchpad.yaml generation
# ---------------------------------------------------------------------------
generate_launchpad_yaml() {
    local airgap="${1:-false}"

    # In airgap mode launchpad runs from bastion — don't download locally
    if [[ "${airgap}" != "true" ]]; then
        ensure_launchpad
    fi

    local launchpad_yaml="${TERRAFORM_DIR}/launchpad.yaml"
    local creds_file
    creds_file="$(mke3_credentials_file)"
    local output
    output="$(tf_output)" || die "Could not read terraform output. Has terraform been applied?"

    local mke3_lb_dns ssh_key
    mke3_lb_dns="$(echo "${output}" | jq -r '.mke3_lb_dns_name.value')"
    ssh_key="$(echo "${output}" | jq -r '.ssh_key_path.value')"

    [[ -z "${mke3_lb_dns}" || "${mke3_lb_dns}" == "null" || "${mke3_lb_dns}" == "" ]] \
        && die "mke3_lb_dns_name is empty. Was terraform applied with mke3_enabled=true?"

    # Generate admin password on first run; reuse on subsequent runs
    local admin_pass
    if [[ -f "${creds_file}" ]]; then
        admin_pass="$(grep '^password=' "${creds_file}" | cut -d= -f2)"
        info "Reusing MKE3 credentials from $(basename "${creds_file}")"
    else
        admin_pass="$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 20)"
        printf 'username=%s\npassword=%s\n' "${mke3_admin_username}" "${admin_pass}" > "${creds_file}"
        chmod 600 "${creds_file}"
        info "Generated MKE3 admin credentials → $(basename "${creds_file}")"
    fi

    info "Generating launchpad.yaml..."

    # In airgap mode, use private IPs and bastion keypath
    local ctrl_ips_field="controller_ips"
    local wkr_ips_field="worker_ips"
    local key_path="${ssh_key}"

    if [[ "${airgap}" == "true" ]]; then
        ctrl_ips_field="controller_private_ips"
        wkr_ips_field="worker_private_ips"
        key_path="/home/ubuntu/aws_private.pem"   # Path ON the bastion
    fi

    # Build hosts JSON array with jq
    local hosts_json
    hosts_json="$(echo "${output}" | jq -c \
        --arg key "${key_path}" \
        --arg user "$(node_ssh_user)" \
        --arg ctrl_field "${ctrl_ips_field}" \
        --arg wkr_field "${wkr_ips_field}" \
        'def mcr_cfg: {
            debug: true,
            "log-opts": { "max-size": "100m", "max-file": "3" }
        };
        [
            (.[$ctrl_field].value[] | {
                role: "manager",
                ssh: { address: ., user: $user, keyPath: $key },
                mcrConfig: mcr_cfg
            }),
            (.[$wkr_field].value[] | {
                role: "worker",
                ssh: { address: ., user: $user, keyPath: $key },
                mcrConfig: mcr_cfg
            })
        ]')"

    cat > "${launchpad_yaml}" <<EOF
apiVersion: launchpad.mirantis.com/mke/v1.3
kind: mke
metadata:
  name: ${cluster_name}
spec:
  hosts: []
  mcr:
    version: "${mcr_version}"
    channel: "${mcr_channel}"
    repoURL: "https://repos.mirantis.com"
    installURLLinux: "https://get.mirantis.com/"
  mke:
    version: "${mke3_version}"
    adminUsername: "${mke3_admin_username}"
    adminPassword: "${admin_pass}"
    installFlags:
      - "--san=${mke3_lb_dns}"
      - "--default-node-orchestrator=kubernetes"
  cluster:
    prune: false
EOF

    yq e -i ".spec.hosts = ${hosts_json}" "${launchpad_yaml}"

    # MKE3 >= 3.7.12 requires --calico-datastore-type-kdd
    if version_gte "${mke3_version}" "3.7.12"; then
        yq e -i '.spec.mke.installFlags += ["--calico-datastore-type-kdd"]' "${launchpad_yaml}"
        info "Added --calico-datastore-type-kdd (mke3_version ${mke3_version} >= 3.7.12)"
    fi

    # AWS cloud provider — nodes carry the CCM IAM instance profile when ccm_enabled.
    # Skipped in airgap: no IAM profile is attached and AWS APIs are unreachable
    if [[ "${ccm_enabled}" == "true" && "${airgap}" != "true" ]]; then
        yq e -i '.spec.mke.installFlags += ["--cloud-provider=aws"]' "${launchpad_yaml}"
        info "Added --cloud-provider=aws (ccm_enabled=true)"
    fi

    # Airgap-specific patches: imageRepo → Harbor
    if [[ "${airgap}" == "true" ]]; then
        local reg_host="${registry_hostname}"
        yq e -i ".spec.mke.imageRepo = \"${reg_host}/mke3\"" "${launchpad_yaml}"
        info "Airgap mode: imageRepo=${reg_host}/mke3"
    fi

    success "launchpad.yaml written to ${launchpad_yaml}"

    # Generate nodes.yaml for mkectl upgrade (all nodes, no role field)
    generate_nodes_yaml "${output}" "${key_path}" "${airgap}"
}

generate_nodes_yaml() {
    local output="${1}"
    local key_path="${2}"
    local airgap="${3:-false}"
    local nodes_yaml="${TERRAFORM_DIR}/nodes.yaml"

    local ctrl_field="controller_ips" wkr_field="worker_ips"
    if [[ "${airgap}" == "true" ]]; then
        ctrl_field="controller_private_ips"
        wkr_field="worker_private_ips"
    fi

    local nodes_json
    nodes_json="$(echo "${output}" | jq -c \
        --arg key "${key_path}" \
        --arg user "$(node_ssh_user)" \
        --arg ctrl_field "${ctrl_field}" \
        --arg wkr_field "${wkr_field}" \
        '[
            (.[$ctrl_field].value[], .[$wkr_field].value[]) |
            { address: ., port: 22, user: $user, keyPath: $key }
        ]')"

    printf 'hosts:\n' > "${nodes_yaml}"
    echo "${nodes_json}" | jq -r '.[] | "  - address: \(.address)\n    port: \(.port)\n    user: \(.user)\n    keyPath: \(.keyPath)"' \
        >> "${nodes_yaml}"

    success "nodes.yaml written to ${nodes_yaml}"
}

# ---------------------------------------------------------------------------
# Interactive mkectl download prompt (offered after MKE3 deploy)
# ---------------------------------------------------------------------------
prompt_mkectl_for_upgrade() {
    echo ""
    local answer
    read -r -p "$(echo -e "  ${BOLD}Download mkectl now to prepare for MKE3 → MKE4k upgrade?${RESET} [y/N] ")" answer < /dev/tty
    case "${answer}" in
        [yY]|[yY][eE][sS])
            local ver_input
            read -r -p "  MKE4k version [${mke4k_version}]: " ver_input < /dev/tty
            local target="${ver_input:-${mke4k_version}}"
            # Temporarily set mke4k_version so ensure_mkectl uses the chosen value
            local saved="${mke4k_version}"
            mke4k_version="${target}"
            ensure_mkectl
            mke4k_version="${saved}"
            ;;
        *)
            info "Skipping. Edit mke4k_version in config and run 't deploy cluster mke4' when ready."
            ;;
    esac
    echo ""
}

# ---------------------------------------------------------------------------
# Interactive upgrade prep for MKE3 airgap → MKE4k
# ---------------------------------------------------------------------------
prompt_upgrade_prep_airgap() {
    echo ""
    local answer
    read -r -p "$(echo -e "  ${BOLD}Prepare for MKE3 → MKE4k upgrade? (upload bundle + generate config)${RESET} [y/N] ")" answer < /dev/tty
    case "${answer}" in
        [yY]|[yY][eE][sS])
            local ver_input
            read -r -p "  MKE4k version [${mke4k_version}]: " ver_input < /dev/tty
            local target="${ver_input:-${mke4k_version}}"
            local saved="${mke4k_version}"
            mke4k_version="${target}"

            local output ssh_key bastion_ip
            output="$(tf_output)"
            ssh_key="$(echo "${output}" | jq -r '.ssh_key_path.value')"
            bastion_ip="$(echo "${output}" | jq -r '.bastion_public_ip.value')"

            # 1. Download mkectl locally (needed for mkectl init to generate yaml schema)
            ensure_mkectl

            # 2. Install mkectl on bastion
            ensure_mkectl_on_bastion "${ssh_key}" "${bastion_ip}"

            # 3. Upload MKE4k bundle to Harbor
            local upload_mode="standard"
            [[ "${target}" == "v4.1.3" ]] && upload_mode="dual-path"
            upload_mke4k_bundle "${upload_mode}" "bundles-${target}"

            # 4. Generate mke4.yaml with airgap settings
            generate_mke4_yaml true

            # 5. SCP mke4.yaml + nodes.yaml + key to bastion
            local mke4_yaml="${TERRAFORM_DIR}/mke4.yaml"
            local nodes_yaml="${TERRAFORM_DIR}/nodes.yaml"
            scp -q -o StrictHostKeyChecking=no -i "${ssh_key}" "${mke4_yaml}" "ubuntu@${bastion_ip}:~/mke4.yaml"
            scp -q -o StrictHostKeyChecking=no -i "${ssh_key}" "${nodes_yaml}" "ubuntu@${bastion_ip}:~/nodes.yaml"
            scp -q -o StrictHostKeyChecking=no -i "${ssh_key}" "${ssh_key}" "ubuntu@${bastion_ip}:~/aws_private.pem"
            ssh_node "${ssh_key}" "${bastion_ip}" "chmod 600 ~/aws_private.pem"
            success "Upgrade files uploaded to bastion."

            # Read MKE3 credentials for the command
            local admin_user admin_pass
            IFS=$'\t' read -r admin_user admin_pass < <(read_mke3_credentials)

            local mke4k_lb_dns
            mke4k_lb_dns="$(echo "${output}" | jq -r '.lb_dns_name.value')"

            local reg_host="${registry_hostname}"
            local ca_path="/etc/docker/certs.d/${reg_host}/ca.crt"

            local debug_flag=""
            [[ "${debug:-false}" == "true" ]] && debug_flag="-l debug"

            echo ""
            echo -e "  ${BOLD}To upgrade to MKE4k, SSH to bastion and run:${RESET}"
            echo ""
            echo -e "    ${CYAN}mkectl upgrade${RESET} \\"
            echo "      --hosts-path ~/nodes.yaml \\"
            echo "      --mke3-admin-username ${admin_user} \\"
            echo "      --mke3-admin-password ${admin_pass} \\"
            echo "      --external-address ${mke4k_lb_dns} \\"
            echo "      --image-registry=${reg_host}/mke \\"
            echo "      --chart-registry=oci://${reg_host}/mke \\"
            echo "      --image-registry-ca-file=${ca_path} \\"
            echo "      --chart-registry-ca-file=${ca_path} \\"
            echo "      --mke3-airgapped=true \\"
            echo "      --force${debug_flag:+ \\}"
            [[ -n "${debug_flag}" ]] && echo "      ${debug_flag}"
            echo ""

            mke4k_version="${saved}"
            ;;
        *)
            info "Skipping. Run upgrade prep later with the appropriate commands."
            ;;
    esac
    echo ""
}

# ---------------------------------------------------------------------------
# Interactive upgrade prep for MKE4k airgap → MKE4k (newer version)
# ---------------------------------------------------------------------------
prompt_mke4k_upgrade_prep_airgap() {
    echo ""
    local answer
    read -r -p "$(echo -e "  ${BOLD}Prepare for MKE4k → MKE4k airgap upgrade? (upload bundle + release-matrix)${RESET} [y/N] ")" answer < /dev/tty
    case "${answer}" in
        [yY]|[yY][eE][sS])
            local ver_input
            read -r -p "  Target MKE4k version [${mke4k_version}]: " ver_input < /dev/tty
            local target="${ver_input:-${mke4k_version}}"
            local saved="${mke4k_version}"
            mke4k_version="${target}"

            local output ssh_key bastion_ip
            output="$(tf_output)"
            ssh_key="$(echo "${output}" | jq -r '.ssh_key_path.value')"
            bastion_ip="$(echo "${output}" | jq -r '.bastion_public_ip.value')"

            # Determine upload mode: dual-path for v4.1.3 (workaround for double-prefix bug)
            local upload_mode="standard"
            [[ "${target}" == "v4.1.3" ]] && upload_mode="dual-path"

            # 1. Install target mkectl locally (needed for mkectl init to generate yaml schema)
            ensure_mkectl

            # 2. Install target mkectl on bastion
            ensure_mkectl_on_bastion "${ssh_key}" "${bastion_ip}"

            # 3. Upload target version bundle to Harbor
            upload_mke4k_bundle "${upload_mode}" "bundles-${target}"

            # 4. Download release-matrix.json to bastion
            info "Downloading release-matrix.json to bastion..."
            ssh_node "${ssh_key}" "${bastion_ip}" "
                curl -fsSL 'https://raw.githubusercontent.com/MirantisContainers/mke-release/refs/heads/main/release-matrix/release-matrix.json' -o ~/release-matrix.json
                echo 'release-matrix.json downloaded'
            "

            local debug_flag=""
            [[ "${debug:-false}" == "true" ]] && debug_flag="-l debug"

            echo ""
            echo -e "  ${BOLD}To upgrade MKE4k, SSH to bastion and run:${RESET}"
            echo ""
            echo -e "    ${CYAN}mkectl upgrade${RESET} \\"
            echo "      --upgrade-version ${target} \\"
            echo "      --release-matrix ~/release-matrix.json${debug_flag:+ \\}"
            [[ -n "${debug_flag}" ]] && echo "      ${debug_flag}"
            echo ""

            mke4k_version="${saved}"
            ;;
        *)
            info "Skipping. Run upgrade prep later with the appropriate commands."
            ;;
    esac
    echo ""
}

# ---------------------------------------------------------------------------
# launchpad helpers
# ---------------------------------------------------------------------------
launchpad_apply() {
    ensure_launchpad
    local launchpad_yaml="${TERRAFORM_DIR}/launchpad.yaml"
    [[ -f "${launchpad_yaml}" ]] || die "launchpad.yaml not found at ${launchpad_yaml}. Run 't deploy instances mke3' first."
    info "Running launchpad apply..."
    launchpad apply --accept-license -c "${launchpad_yaml}"
    success "MKE3 cluster deployment complete."
}

launchpad_reset() {
    ensure_launchpad
    local launchpad_yaml="${TERRAFORM_DIR}/launchpad.yaml"
    [[ -f "${launchpad_yaml}" ]] || die "launchpad.yaml not found at ${launchpad_yaml}. Has the MKE3 cluster been deployed?"
    info "Running launchpad reset --force..."
    launchpad reset --force -c "${launchpad_yaml}"
    success "MKE3 cluster reset complete."
}

# ---------------------------------------------------------------------------
# SSH connect helper
# ---------------------------------------------------------------------------
# resolve_node <name> [output_json] → prints the IP for the node
# When airgap is detected (bastion_public_ip non-empty), uses private IPs.
# Accepted names:
#   m1, m2, m3, …   controllers (1-based)
#   w1, w2, w3, …   workers (1-based)
#   bastion          bastion host (airgap only)
#   any raw IP / hostname — passed through as-is
resolve_node() {
    local name="${1}"
    local output="${2:-}"
    [[ -z "${output}" ]] && output="$(tf_output 2>/dev/null)" \
        || true
    [[ -z "${output}" ]] && die "Could not read terraform output. Has terraform been applied?"

    # Detect airgap mode
    local bastion_ip
    bastion_ip="$(echo "${output}" | jq -r '.bastion_public_ip.value // empty' 2>/dev/null)"
    local is_airgap=false
    [[ -n "${bastion_ip}" && "${bastion_ip}" != "null" && "${bastion_ip}" != "" ]] && is_airgap=true

    # bastion → public IP
    if [[ "${name}" == "bastion" ]]; then
        [[ "${is_airgap}" == "true" ]] || die "No bastion in non-airgap mode."
        echo "${bastion_ip}"
        return 0
    fi

    # nfs → NFS server IP
    if [[ "${name}" == "nfs" ]]; then
        local nfs_ip
        if [[ "${is_airgap}" == "true" ]]; then
            nfs_ip="$(echo "${output}" | jq -r '.nfs_server_private_ip.value // empty')"
        else
            nfs_ip="$(echo "${output}" | jq -r '.nfs_server_public_ip.value // empty')"
        fi
        [[ -n "${nfs_ip}" && "${nfs_ip}" != "" ]] || die "No NFS server found."
        echo "${nfs_ip}"
        return 0
    fi

    # Choose IP field based on airgap mode
    local ctrl_field="controller_ips" wkr_field="worker_ips"
    if [[ "${is_airgap}" == "true" ]]; then
        ctrl_field="controller_private_ips"
        wkr_field="worker_private_ips"
    fi

    local ip=""
    if [[ "${name}" =~ ^m([0-9]+)$ ]]; then
        local idx=$(( BASH_REMATCH[1] - 1 ))
        ip="$(echo "${output}" | jq -r ".${ctrl_field}.value[${idx}]" 2>/dev/null)"
    elif [[ "${name}" =~ ^w([0-9]+)$ ]]; then
        local idx=$(( BASH_REMATCH[1] - 1 ))
        ip="$(echo "${output}" | jq -r ".${wkr_field}.value[${idx}]" 2>/dev/null)"
    else
        ip="${name}"
    fi

    [[ -z "${ip}" || "${ip}" == "null" ]] \
        && die "Could not resolve node '${name}'. Use m1/m2/m3 (controllers), w1/w2/w3 (workers), bastion, or a raw IP."
    echo "${ip}"
}

cmd_connect() {
    local target="${1:-}"
    local remote_cmd="${2:-}"

    if [[ -z "${target}" ]]; then
        cat <<EOF

${BOLD}Usage:${RESET}
  t connect <node> [command]

${BOLD}Node names:${RESET}
  bastion            bastion/registry host (airgap)
  nfs                NFS server (when nfs_enabled=true)
  m1, m2, m3, …     controllers (managers)
  w1, w2, w3, …     workers
  m1-child, w1-child child cluster nodes (child_ssh_enabled=true)
  child-bastion      child cluster bastion
  <ip>               any raw IP or hostname

${BOLD}Examples:${RESET}
  t connect bastion                direct SSH to bastion (airgap)
  t connect m1                     interactive SSH into controller-1
  t connect w1                     interactive SSH into worker-1
  t connect m1 "docker ps"         run a single command and return
  t connect 1.2.3.4                SSH to a raw IP
EOF
        return 0
    fi

    # Child cluster nodes (via the child's CAPA bastion)
    case "${target}" in
        m[0-9]*-child|w[0-9]*-child|child-bastion)
            cmd_connect_child "${target}" "${remote_cmd}"
            return
            ;;
    esac

    local ssh_key="${TERRAFORM_DIR}/aws_private.pem"
    [[ -f "${ssh_key}" ]] \
        || die "SSH key not found at ${ssh_key}. Has terraform been applied?"

    # Needed for os_name → node_ssh_user resolution
    load_config

    local output
    output="$(tf_output 2>/dev/null)" || die "Could not read terraform output."

    local ip
    ip="$(resolve_node "${target}" "${output}")"

    # Detect airgap mode
    local bastion_pub_ip
    bastion_pub_ip="$(echo "${output}" | jq -r '.bastion_public_ip.value // empty' 2>/dev/null)"
    local is_airgap=false
    [[ -n "${bastion_pub_ip}" && "${bastion_pub_ip}" != "null" && "${bastion_pub_ip}" != "" ]] && is_airgap=true

    # Bastion and NFS server are always Ubuntu; cluster nodes follow os_name
    local conn_user
    case "${target}" in
        bastion|nfs) conn_user="ubuntu" ;;
        *)           conn_user="$(node_ssh_user)" ;;
    esac

    local ssh_opts=(-q -i "${ssh_key}" -o StrictHostKeyChecking=no -o BatchMode=no -l "${conn_user}")

    # In airgap mode, non-bastion targets need ProxyJump through bastion
    if [[ "${is_airgap}" == "true" && "${target}" != "bastion" ]]; then
        ssh_opts+=(-o "ProxyCommand=ssh -q -o StrictHostKeyChecking=no -i ${ssh_key} -W %h:%p ubuntu@${bastion_pub_ip}")
    fi

    if [[ -n "${remote_cmd}" ]]; then
        info "Running command on ${target} (${ip})..."
        ssh "${ssh_opts[@]}" "${ip}" "${remote_cmd}"
    else
        info "Connecting to ${target} (${ip})..."
        ssh "${ssh_opts[@]}" "${ip}"
    fi
}

# ---------------------------------------------------------------------------
# Deploy summary box
# ---------------------------------------------------------------------------
print_deploy_summary() {
    local output
    output="$(tf_output 2>/dev/null)" || { warn "Could not read terraform output for summary."; return; }

    local lb_dns
    lb_dns="$(echo "${output}" | jq -r '.lb_dns_name.value' 2>/dev/null || echo "(unknown)")"

    local controller_ips=() worker_ips=()
    mapfile -t controller_ips < <(echo "${output}" | jq -r '.controller_ips.value[]' 2>/dev/null)
    mapfile -t worker_ips     < <(echo "${output}" | jq -r '.worker_ips.value[]'     2>/dev/null)

    local total=$(( _T_TERRAFORM + _T_NLB + _T_MKECTL + _T_NFS ))
    local ccm_str="CCM disabled"
    [[ "${ccm_enabled:-false}" == "true" ]] && ccm_str="CCM enabled"

    local nfs_priv_ip=""
    nfs_priv_ip="$(echo "${output}" | jq -r '.nfs_server_private_ip.value // empty' 2>/dev/null)"

    local W=58
    local SEP; SEP="$(printf '═%.0s' $(seq 1 ${W}))"
    local HDIV; HDIV="$(printf '%.0s-' $(seq 1 33))"

    bline() { printf "║%-${W}s║\n" "$1"; }
    cline() {
        local t="$1" lp rp
        lp=$(( (W - ${#t}) / 2 ))
        rp=$(( W - ${#t} - lp ))
        printf "║%*s%s%*s║\n" $lp "" "$t" $rp ""
    }
    sep() { printf "╠%s╣\n" "${SEP}"; }

    printf "╔%s╗\n" "${SEP}"
    cline "mke4k-lab -- Deployment Complete"
    sep
    bline "$(printf '  %-12s %-20s %s' 'Cluster' "${cluster_name}" "${region}")"
    bline "$(printf '  %-12s %-20s %s' 'MKE4k' "${mke4k_version}" "${ccm_str}")"
    bline "$(printf '  %-12s %s' 'Expires' "$(fmt_expiry "$(echo "${output}" | jq -r '.expiry_time.value // empty' 2>/dev/null)")")"
    if [[ -n "${nfs_priv_ip}" && "${nfs_priv_ip}" != "" ]]; then
        bline "$(printf '  %-12s %s' 'NFS' "${nfs_priv_ip} (${nfs_export_path})")"
    fi
    if [[ ${_T_TERRAFORM} -gt 0 ]]; then
        sep
        bline "  Timing"
        bline "$(printf '    %-22s %s' 'Terraform'     "$(fmt_duration ${_T_TERRAFORM})")"
        bline "$(printf '    %-22s %s' 'NLB stabilise' "$(fmt_duration ${_T_NLB})")"
        bline "$(printf '    %-22s %s' 'MKE4k install' "$(fmt_duration ${_T_MKECTL})")"
        if [[ ${_T_NFS} -gt 0 ]]; then
            bline "$(printf '    %-22s %s' 'NFS setup'     "$(fmt_duration ${_T_NFS})")"
        fi
        bline "    ${HDIV}"
        bline "$(printf '    %-22s %s' 'Total'         "$(fmt_duration ${total})")"
    fi
    sep
    bline "  Controllers"
    local i=1
    for ip in "${controller_ips[@]}"; do
        bline "$(printf '    m%-3s %-17s connect m%s' "${i}" "${ip}" "${i}")"
        (( i++ )) || true
    done
    sep
    bline "  Workers"
    i=1
    for ip in "${worker_ips[@]}"; do
        bline "$(printf '    w%-3s %-17s connect w%s' "${i}" "${ip}" "${i}")"
        (( i++ )) || true
    done
    sep
    bline "  Load Balancer"
    local lb_chunk_w=$(( W - 4 ))
    local lb_remaining="https://${lb_dns}"
    while [[ ${#lb_remaining} -gt ${lb_chunk_w} ]]; do
        bline "    ${lb_remaining:0:${lb_chunk_w}}"
        lb_remaining="${lb_remaining:${lb_chunk_w}}"
    done
    bline "    ${lb_remaining}"
    if [[ "${kof_enabled:-false}" == "true" ]]; then
        sep
        bline "  KOF (observability / M2M, mode=${kof_mode:-full})"
        if [[ "${kof_grafana_enabled:-false}" == "true" && "${kof_grafana_gateway_enabled:-false}" == "true" ]]; then
            bline "    Grafana (HTTPS, self-signed):"
            local chunk=$(( W - 6 )) gurl="https://${lb_dns}:${kof_grafana_lb_port}"
            while [[ ${#gurl} -gt ${chunk} ]]; do
                bline "      ${gurl:0:${chunk}}"
                gurl="${gurl:${chunk}}"
            done
            bline "      ${gurl}"
            bline "      (or https://<node-ip>:${kof_grafana_nodeport})"
        elif [[ "${kof_grafana_enabled:-false}" == "true" ]]; then
            bline "    Grafana: kubectl -n kof port-forward"
            bline "      svc/grafana-vm-service 3000:3000 -> :3000"
        else
            bline "    Grafana: not enabled (kof_grafana_enabled)"
        fi
        if [[ "${kof_reuse_mke_monitoring:-false}" == "true" ]]; then
            bline "    Reusing MKE monitoring (no KOF node-exporter)"
            bline "    + MKE Prometheus datasource in Grafana"
        fi
    fi
    if [[ -f "$(child_marker_file)" ]]; then
        local cname cjson cready="?" cver="?" caddr="" ccreds
        cname="$(cat "$(child_marker_file)")"
        ccreds="$(child_credentials_file)"
        cjson="$(kubectl -n "${kof_kcm_namespace:-k0rdent}" get mkechildconfig "${cname}" \
            -o json --request-timeout=10s 2>/dev/null || true)"
        if [[ -n "${cjson}" ]]; then
            cready="$(jq -r '[.status.conditions[]? | select(.type == "Ready") | .status][0] // "?"' <<<"${cjson}")"
            cver="$(jq -r '.spec.version // "?"' <<<"${cjson}")"
            caddr="$(jq -r '[.. | objects | .externalAddress? | select(type == "string" and . != "")][0] // empty' <<<"${cjson}")"
            if [[ "${cready}" == "?" ]]; then
                # Same source as child_wait_ready: the CRD's READY printer column.
                local rpath; rpath="$(_child_printer_path READY)"
                [[ -n "${rpath}" ]] && cready="$(kubectl -n "${kof_kcm_namespace:-k0rdent}" get mkechildconfig "${cname}" \
                    --no-headers -o "custom-columns=R:{${rpath}}" --request-timeout=10s 2>/dev/null || echo '?')"
            fi
        fi
        sep
        bline "  Child cluster (k0rdent / CAPI on AWS)"
        bline "$(printf '    %-12s %s' 'Name' "${cname}")"
        if [[ -n "${cjson}" ]]; then
            bline "$(printf '    %-12s Ready=%s  version=%s' 'Status' "${cready}" "${cver}")"
        else
            bline "$(printf '    %-12s %s' 'Status' '(management cluster unreachable)')"
        fi
        if [[ -n "${caddr}" ]]; then
            bline "    UI (HTTPS, self-signed):"
            local cchunk=$(( W - 6 )) curl_rem="${caddr}"
            while [[ ${#curl_rem} -gt ${cchunk} ]]; do
                bline "      ${curl_rem:0:${cchunk}}"
                curl_rem="${curl_rem:${cchunk}}"
            done
            bline "      ${curl_rem}"
        fi
        if [[ -f "${ccreds}" ]]; then
            bline "$(printf '    %-12s %s' 'Username' "$(grep '^username=' "${ccreds}" | cut -d= -f2)")"
            bline "$(printf '    %-12s %s' 'Password' "$(grep '^password=' "${ccreds}" | cut -d= -f2)")"
        fi
        bline "$(printf '    %-12s %s' 'Kubeconfig' 'terraform/child.kubeconfig')"
        if [[ -n "${cjson}" ]]; then
            local cbip; cbip="$(_child_bastion_ip)"
            if [[ -n "${cbip}" ]]; then
                bline "$(printf '    %-12s %s' 'Bastion' "${cbip}")"
                bline "    t connect m1-child | w1-child | child-bastion"
            fi
        fi
        bline "    t status child  |  t destroy child-cluster"
    fi
    sep
    bline "  kubectl get nodes"
    printf "╚%s╝\n" "${SEP}"
}

print_mke3_deploy_summary() {
    local output
    output="$(tf_output 2>/dev/null)" || { warn "Could not read terraform output for summary."; return; }

    local mke3_lb_dns mke4k_lb_dns
    mke3_lb_dns="$(echo "${output}" | jq -r '.mke3_lb_dns_name.value' 2>/dev/null || echo "(unknown)")"
    mke4k_lb_dns="$(echo "${output}" | jq -r '.lb_dns_name.value'     2>/dev/null || echo "(unknown)")"

    local controller_ips=() worker_ips=()
    mapfile -t controller_ips < <(echo "${output}" | jq -r '.controller_ips.value[]' 2>/dev/null)
    mapfile -t worker_ips     < <(echo "${output}" | jq -r '.worker_ips.value[]'     2>/dev/null)

    # Read credentials saved by generate_launchpad_yaml
    local admin_user admin_pass
    IFS=$'\t' read -r admin_user admin_pass < <(read_mke3_credentials)

    local nodes_yaml="${TERRAFORM_DIR}/nodes.yaml"

    local total=$(( _T_TERRAFORM + _T_NLB + _T_LAUNCHPAD + _T_NFS ))

    local W=58
    local SEP; SEP="$(printf '═%.0s' $(seq 1 ${W}))"
    local HDIV; HDIV="$(printf '%.0s-' $(seq 1 33))"

    bline() { printf "║%-${W}s║\n" "$1"; }
    cline() {
        local t="$1" lp rp
        lp=$(( (W - ${#t}) / 2 ))
        rp=$(( W - ${#t} - lp ))
        printf "║%*s%s%*s║\n" $lp "" "$t" $rp ""
    }
    sep() { printf "╠%s╣\n" "${SEP}"; }

    printf "╔%s╗\n" "${SEP}"
    cline "mke4k-lab -- MKE3 Deployment Complete"
    sep
    bline "$(printf '  %-12s %-20s %s' 'Cluster' "${cluster_name}" "${region}")"
    bline "$(printf '  %-12s %s' 'MKE3' "${mke3_version}")"
    bline "$(printf '  %-12s %s' 'MCR' "${mcr_version} (${mcr_channel})")"
    bline "$(printf '  %-12s %s' 'Expires' "$(fmt_expiry "$(echo "${output}" | jq -r '.expiry_time.value // empty' 2>/dev/null)")")"
    if [[ ${_T_TERRAFORM} -gt 0 ]]; then
        sep
        bline "  Timing"
        bline "$(printf '    %-22s %s' 'Terraform'       "$(fmt_duration ${_T_TERRAFORM})")"
        bline "$(printf '    %-22s %s' 'NLB stabilise'   "$(fmt_duration ${_T_NLB})")"
        bline "$(printf '    %-22s %s' 'MKE3 install'    "$(fmt_duration ${_T_LAUNCHPAD})")"
        if [[ ${_T_NFS} -gt 0 ]]; then
            bline "$(printf '    %-22s %s' 'NFS setup'       "$(fmt_duration ${_T_NFS})")"
        fi
        bline "    ${HDIV}"
        bline "$(printf '    %-22s %s' 'Total'           "$(fmt_duration ${total})")"
    fi
    sep
    bline "  Controllers"
    local i=1
    for ip in "${controller_ips[@]}"; do
        bline "$(printf '    m%-3s %-17s connect m%s' "${i}" "${ip}" "${i}")"
        (( i++ )) || true
    done
    sep
    bline "  Workers"
    i=1
    for ip in "${worker_ips[@]}"; do
        bline "$(printf '    w%-3s %-17s connect w%s' "${i}" "${ip}" "${i}")"
        (( i++ )) || true
    done
    sep
    bline "  MKE3 Admin Credentials"
    bline "$(printf '    %-12s %s' 'Username' "${admin_user}")"
    bline "$(printf '    %-12s %s' 'Password' "${admin_pass}")"
    bline "  (saved to terraform/mke3_credentials.txt)"
    printf "╚%s╝\n" "${SEP}"

    # Print URLs and upgrade command outside the box (no width constraint)
    echo ""
    echo -e "  ${BOLD}MKE3 UI${RESET}"
    echo -e "    https://${mke3_lb_dns}"
    echo ""
    echo -e "  ${BOLD}Client bundle:${RESET}"
    echo -e "    ${CYAN}t gen client-bundle${RESET}    (downloads certs + sets KUBECONFIG)"
    echo ""
    echo -e "  ${BOLD}To upgrade to MKE4k:${RESET}"
    echo -e "    ${CYAN}mkectl upgrade${RESET} \\"
    echo -e "      --hosts-path ${nodes_yaml} \\"
    echo -e "      --mke3-admin-username ${admin_user} \\"
    echo -e "      --mke3-admin-password ${admin_pass} \\"
    echo -e "      --external-address ${mke4k_lb_dns} \\"
    echo -e "      --force"
    echo ""
}

# ---------------------------------------------------------------------------
# Airgap deploy summary
# ---------------------------------------------------------------------------
print_airgap_deploy_summary() {
    local output
    output="$(tf_output 2>/dev/null)" || { warn "Could not read terraform output for summary."; return; }

    local lb_dns bastion_pub_ip bastion_priv_ip
    lb_dns="$(echo "${output}" | jq -r '.lb_dns_name.value' 2>/dev/null || echo "(unknown)")"
    bastion_pub_ip="$(echo "${output}" | jq -r '.bastion_public_ip.value' 2>/dev/null || echo "(unknown)")"
    bastion_priv_ip="$(echo "${output}" | jq -r '.bastion_private_ip.value' 2>/dev/null || echo "(unknown)")"

    local controller_ips=() worker_ips=()
    mapfile -t controller_ips < <(echo "${output}" | jq -r '.controller_private_ips.value[]' 2>/dev/null)
    mapfile -t worker_ips     < <(echo "${output}" | jq -r '.worker_private_ips.value[]'     2>/dev/null)

    local creds_file="${TERRAFORM_DIR}/registry_credentials.txt"
    local registry_pass
    registry_pass="$(grep '^password=' "${creds_file}" 2>/dev/null | cut -d= -f2 || echo "(unknown)")"

    local total=$(( _T_TERRAFORM + _T_REGISTRY + _T_BUNDLE + _T_NLB + _T_MKECTL + _T_NFS ))

    local nfs_priv_ip=""
    nfs_priv_ip="$(echo "${output}" | jq -r '.nfs_server_private_ip.value // empty' 2>/dev/null)"

    local W=58
    local SEP; SEP="$(printf '═%.0s' $(seq 1 ${W}))"
    local HDIV; HDIV="$(printf '%.0s-' $(seq 1 33))"

    bline() { printf "║%-${W}s║\n" "$1"; }
    cline() {
        local t="$1" lp rp
        lp=$(( (W - ${#t}) / 2 ))
        rp=$(( W - ${#t} - lp ))
        printf "║%*s%s%*s║\n" $lp "" "$t" $rp ""
    }
    sep() { printf "╠%s╣\n" "${SEP}"; }

    printf "╔%s╗\n" "${SEP}"
    cline "mke4k-lab -- Airgap Deploy Summary"
    sep
    bline "$(printf '  %-18s %s' 'MKE4k version' "${mke4k_version}")"
    bline "$(printf '  %-18s %s' 'Expires' "$(fmt_expiry "$(echo "${output}" | jq -r '.expiry_time.value // empty' 2>/dev/null)")")"
    bline "$(printf '  %-18s %s' 'Controllers' "${controller_count}")"
    bline "$(printf '  %-18s %s' 'Workers' "${worker_count}")"
    bline "$(printf '  %-18s %s' 'Registry' "MSR4 ${airgap_msr_version}")"
    bline "$(printf '  %-18s %s' 'Airgap' 'true')"
    if [[ -n "${nfs_priv_ip}" && "${nfs_priv_ip}" != "" ]]; then
        bline "$(printf '  %-18s %s' 'NFS' "${nfs_priv_ip} (${nfs_export_path})")"
    fi
    sep
    bline "$(printf '  %-18s %s' 'Bastion (public)' "${bastion_pub_ip}")"
    bline "$(printf '  %-18s %s' 'Registry host' "${registry_hostname}")"
    bline "$(printf '  %-18s %s' 'Registry IP' "${bastion_priv_ip}")"
    bline "$(printf '  %-18s %s' 'Registry user' 'admin')"
    bline "$(printf '  %-18s %s' 'Registry password' "${registry_pass}")"
    if [[ ${_T_TERRAFORM} -gt 0 ]]; then
        sep
        bline "  Timing"
        bline "$(printf '    %-22s %s' 'Terraform'       "$(fmt_duration ${_T_TERRAFORM})")"
        bline "$(printf '    %-22s %s' 'Registry setup'  "$(fmt_duration ${_T_REGISTRY})")"
        bline "$(printf '    %-22s %s' 'Bundle upload'   "$(fmt_duration ${_T_BUNDLE})")"
        bline "$(printf '    %-22s %s' 'NLB stabilise'   "$(fmt_duration ${_T_NLB})")"
        bline "$(printf '    %-22s %s' 'mkectl apply'    "$(fmt_duration ${_T_MKECTL})")"
        if [[ ${_T_NFS} -gt 0 ]]; then
            bline "$(printf '    %-22s %s' 'NFS setup'       "$(fmt_duration ${_T_NFS})")"
        fi
        bline "    ${HDIV}"
        bline "$(printf '    %-22s %s' 'Total'           "$(fmt_duration ${total})")"
    fi
    sep
    bline "  Controllers (private)"
    local i=1
    for ip in "${controller_ips[@]}"; do
        bline "$(printf '    m%-3s %s' "${i}" "${ip}")"
        (( i++ )) || true
    done
    sep
    bline "  Workers (private)"
    i=1
    for ip in "${worker_ips[@]}"; do
        bline "$(printf '    w%-3s %s' "${i}" "${ip}")"
        (( i++ )) || true
    done
    if [[ "${kof_enabled:-false}" == "true" ]]; then
        sep
        bline "  KOF (observability / M2M, mode=${kof_mode:-full})"
        if [[ "${kof_grafana_enabled:-false}" == "true" ]]; then
            bline "    Grafana: t tunnel grafana"
            bline "      -> https://localhost:${kof_grafana_lb_port} (self-signed)"
        else
            bline "    Grafana: not enabled (kof_grafana_enabled)"
        fi
        if [[ "${kof_reuse_mke_monitoring:-false}" == "true" ]]; then
            bline "    Reusing MKE monitoring (no KOF node-exporter)"
            bline "    + MKE Prometheus datasource in Grafana"
        fi
    fi
    printf "╚%s╝\n" "${SEP}"

    echo ""
    echo -e "  ${BOLD}NLB:${RESET}       https://${lb_dns}"
    echo -e "  ${BOLD}Registry:${RESET}  https://${bastion_pub_ip}  (Harbor, publicly accessible)"
    echo -e "  ${BOLD}SSH:${RESET}       t connect bastion      (direct)"
    echo -e "             t connect m1           (via bastion ProxyJump)"
    echo -e "  ${BOLD}Tunnels:${RESET}   t tunnel dashboard     → https://localhost:3000"
    if [[ "${kof_enabled:-false}" == "true" && "${kof_grafana_enabled:-false}" == "true" ]]; then
        echo -e "             t tunnel grafana       → https://localhost:${kof_grafana_lb_port}"
    fi
    echo -e "             t tunnel               (show all + manual commands)"
    echo ""
}

# ---------------------------------------------------------------------------
# MKE3 Airgap deploy summary
# ---------------------------------------------------------------------------
print_mke3_airgap_deploy_summary() {
    local output
    output="$(tf_output 2>/dev/null)" || { warn "Could not read terraform output for summary."; return; }

    local mke3_lb_dns mke4k_lb_dns bastion_pub_ip bastion_priv_ip
    mke3_lb_dns="$(echo "${output}" | jq -r '.mke3_lb_dns_name.value' 2>/dev/null || echo "(unknown)")"
    mke4k_lb_dns="$(echo "${output}" | jq -r '.lb_dns_name.value'     2>/dev/null || echo "(unknown)")"
    bastion_pub_ip="$(echo "${output}" | jq -r '.bastion_public_ip.value' 2>/dev/null || echo "(unknown)")"
    bastion_priv_ip="$(echo "${output}" | jq -r '.bastion_private_ip.value' 2>/dev/null || echo "(unknown)")"

    local controller_ips=() worker_ips=()
    mapfile -t controller_ips < <(echo "${output}" | jq -r '.controller_private_ips.value[]' 2>/dev/null)
    mapfile -t worker_ips     < <(echo "${output}" | jq -r '.worker_private_ips.value[]'     2>/dev/null)

    local admin_user admin_pass
    IFS=$'\t' read -r admin_user admin_pass < <(read_mke3_credentials)

    local reg_creds_file="${TERRAFORM_DIR}/registry_credentials.txt"
    local registry_pass
    registry_pass="$(grep '^password=' "${reg_creds_file}" 2>/dev/null | cut -d= -f2 || echo "(unknown)")"

    local total=$(( _T_TERRAFORM + _T_REGISTRY + _T_MKE3_IMAGES + _T_PROXY + _T_NLB + _T_LAUNCHPAD + _T_NFS ))

    local W=58
    local SEP; SEP="$(printf '═%.0s' $(seq 1 ${W}))"
    local HDIV; HDIV="$(printf '%.0s-' $(seq 1 33))"

    bline() { printf "║%-${W}s║\n" "$1"; }
    cline() {
        local t="$1" lp rp
        lp=$(( (W - ${#t}) / 2 ))
        rp=$(( W - ${#t} - lp ))
        printf "║%*s%s%*s║\n" $lp "" "$t" $rp ""
    }
    sep() { printf "╠%s╣\n" "${SEP}"; }

    printf "╔%s╗\n" "${SEP}"
    cline "mke4k-lab -- MKE3 Airgap Deploy Complete"
    sep
    bline "$(printf '  %-18s %-20s %s' 'Cluster' "${cluster_name}" "${region}")"
    bline "$(printf '  %-18s %s' 'MKE3' "${mke3_version}")"
    bline "$(printf '  %-18s %s' 'MCR' "${mcr_version} (${mcr_channel})")"
    bline "$(printf '  %-18s %s' 'Registry' "MSR4 ${airgap_msr_version}")"
    bline "$(printf '  %-18s %s' 'Airgap' 'true')"
    bline "$(printf '  %-18s %s' 'Expires' "$(fmt_expiry "$(echo "${output}" | jq -r '.expiry_time.value // empty' 2>/dev/null)")")"
    sep
    bline "$(printf '  %-18s %s' 'Bastion (public)' "${bastion_pub_ip}")"
    bline "$(printf '  %-18s %s' 'Registry host' "${registry_hostname}")"
    bline "$(printf '  %-18s %s' 'Registry IP' "${bastion_priv_ip}")"
    bline "$(printf '  %-18s %s' 'Registry user' 'admin')"
    bline "$(printf '  %-18s %s' 'Registry password' "${registry_pass}")"
    sep
    bline "  MKE3 Admin Credentials"
    bline "$(printf '    %-12s %s' 'Username' "${admin_user}")"
    bline "$(printf '    %-12s %s' 'Password' "${admin_pass}")"
    bline "  (saved to terraform/mke3_credentials.txt)"
    if [[ ${_T_TERRAFORM} -gt 0 ]]; then
        sep
        bline "  Timing"
        bline "$(printf '    %-22s %s' 'Terraform'       "$(fmt_duration ${_T_TERRAFORM})")"
        bline "$(printf '    %-22s %s' 'Registry setup'  "$(fmt_duration ${_T_REGISTRY})")"
        bline "$(printf '    %-22s %s' 'MKE3 images'     "$(fmt_duration ${_T_MKE3_IMAGES})")"
        bline "$(printf '    %-22s %s' 'Proxy setup'     "$(fmt_duration ${_T_PROXY})")"
        bline "$(printf '    %-22s %s' 'NLB stabilise'   "$(fmt_duration ${_T_NLB})")"
        bline "$(printf '    %-22s %s' 'launchpad apply'  "$(fmt_duration ${_T_LAUNCHPAD})")"
        if [[ ${_T_NFS} -gt 0 ]]; then
            bline "$(printf '    %-22s %s' 'NFS setup'       "$(fmt_duration ${_T_NFS})")"
        fi
        bline "    ${HDIV}"
        bline "$(printf '    %-22s %s' 'Total'           "$(fmt_duration ${total})")"
    fi
    sep
    bline "  Controllers (private)"
    local i=1
    for ip in "${controller_ips[@]}"; do
        bline "$(printf '    m%-3s %s' "${i}" "${ip}")"
        (( i++ )) || true
    done
    sep
    bline "  Workers (private)"
    i=1
    for ip in "${worker_ips[@]}"; do
        bline "$(printf '    w%-3s %s' "${i}" "${ip}")"
        (( i++ )) || true
    done
    printf "╚%s╝\n" "${SEP}"

    echo ""
    echo -e "  ${BOLD}Registry:${RESET}  https://${bastion_pub_ip}  (Harbor, publicly accessible)"
    echo -e "  ${BOLD}SSH:${RESET}       t connect bastion      (direct)"
    echo -e "             t connect m1           (via bastion ProxyJump)"
    echo -e "  ${BOLD}Tunnels:${RESET}   t tunnel mke3          → https://localhost:3000"
    echo -e "             t tunnel               (show all + manual commands)"
    echo -e "  ${BOLD}Bundle:${RESET}    t gen client-bundle    (downloads certs + sets KUBECONFIG)"
    echo ""
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
cmd_deploy_lab_mke4() {
    load_config
    write_tfvars false
    timer_deploy_start
    tf_init
    tf_apply
    timer_phase_end _T_TERRAFORM
    ensure_node_hostnames      # node name must equal the EC2 PrivateDnsName (CCM)
    setup_rhel_node_prereqs    # no-op for Ubuntu
    wait_for_lb
    timer_phase_end _T_NLB
    generate_mke4_yaml
    mkectl_apply
    timer_phase_end _T_MKECTL
    if [[ "${nfs_enabled}" == "true" ]]; then
        setup_nfs_server
        install_nfs_client_on_nodes
        deploy_nfs_provisioner
        timer_phase_end _T_NFS
    fi
    if [[ "${kof_enabled}" == "true" ]]; then
        cmd_deploy_kof
    fi
    if [[ "${k0rdent_ui_enabled}" == "true" ]]; then
        cmd_deploy_k0rdent_ui
    fi
    print_deploy_summary
    export KUBECONFIG=/root/.mke/mke.kubeconf
}

# Backward-compat alias
cmd_deploy_lab() { cmd_deploy_lab_mke4; }

cmd_deploy_lab_mke3() {
    load_config
    write_tfvars true
    timer_deploy_start
    tf_init
    tf_apply
    timer_phase_end _T_TERRAFORM
    ensure_node_hostnames      # node name must equal the EC2 PrivateDnsName (CCM)
    setup_rhel_node_prereqs    # no-op for Ubuntu
    wait_for_lb
    timer_phase_end _T_NLB
    generate_launchpad_yaml
    launchpad_apply
    timer_phase_end _T_LAUNCHPAD
    if [[ "${nfs_enabled}" == "true" ]]; then
        setup_nfs_server
        install_nfs_client_on_nodes
        deploy_nfs_provisioner_mke3
        timer_phase_end _T_NFS
    fi
    print_mke3_deploy_summary
    prompt_mkectl_for_upgrade
}

cmd_deploy_instances() {
    load_config
    write_tfvars false
    tf_init
    tf_apply
    ensure_node_hostnames      # node name must equal the EC2 PrivateDnsName (CCM)
    generate_mke4_yaml
    success "Instances deployed. Run 't deploy cluster' to install MKE4k."
}

cmd_deploy_instances_mke3() {
    load_config
    write_tfvars true
    tf_init
    tf_apply
    ensure_node_hostnames      # node name must equal the EC2 PrivateDnsName (CCM)
    generate_launchpad_yaml
    success "Instances deployed. Run 't deploy cluster mke3' to install MKE3."
}

cmd_deploy_cluster() {
    load_config
    ensure_node_hostnames      # node name must equal the EC2 PrivateDnsName (CCM)
    setup_rhel_node_prereqs    # no-op for Ubuntu
    mkectl_apply
}

cmd_deploy_cluster_mke3() {
    load_config
    ensure_node_hostnames      # node name must equal the EC2 PrivateDnsName (CCM)
    setup_rhel_node_prereqs    # no-op for Ubuntu
    generate_launchpad_yaml
    launchpad_apply
}

cmd_destroy_cluster() {
    load_config
    child_destroy_before_teardown
    mkectl_reset
}

cmd_destroy_cluster_mke3() {
    load_config
    launchpad_reset
}

# ---------------------------------------------------------------------------
# Airgap commands
# ---------------------------------------------------------------------------
cmd_deploy_lab_airgap() {
    load_config
    write_tfvars false true    # mke3_enabled=false, airgap_enabled=true
    timer_deploy_start

    tf_init
    tf_apply
    timer_phase_end _T_TERRAFORM

    setup_registry             # Docker + bind9 + MSR4 + cert + project
    timer_phase_end _T_REGISTRY

    setup_node_dns             # Point each node's resolver at bastion — must run
                               # before any RHEL dnf-via-Squid (RHUI resolution)
    ensure_node_hostnames      # node name must equal the EC2 PrivateDnsName (CCM)
    setup_rhel_node_prereqs    # no-op for Ubuntu

    local output ssh_key bastion_ip
    output="$(tf_output)"
    ssh_key="$(echo "${output}" | jq -r '.ssh_key_path.value')"
    bastion_ip="$(echo "${output}" | jq -r '.bastion_public_ip.value')"

    ensure_mkectl_on_bastion "${ssh_key}" "${bastion_ip}"

    local upload_mode="standard"
    [[ "${mke4k_version}" == "v4.1.3" ]] && upload_mode="dual-path"
    upload_mke4k_bundle "${upload_mode}"
    timer_phase_end _T_BUNDLE

    if [[ "${nfs_enabled}" == "true" ]]; then
        setup_nfs_server
        install_nfs_client_on_nodes
        upload_nfs_provisioner_image
    fi

    wait_for_lb
    timer_phase_end _T_NLB

    generate_mke4_yaml true    # airgap=true — uses hostname, caData
    mkectl_apply_on_bastion    # SCP mke4.yaml to bastion, run mkectl there
    patch_coredns_hosts         # Resolve registry hostname directly in pods
    timer_phase_end _T_MKECTL

    if [[ "${nfs_enabled}" == "true" ]]; then
        deploy_nfs_provisioner_airgap
        timer_phase_end _T_NFS
    fi

    if [[ "${kof_enabled}" == "true" ]]; then
        cmd_deploy_kof    # auto-detects the bastion → runs from there
    fi

    if [[ "${k0rdent_ui_enabled}" == "true" ]]; then
        cmd_deploy_k0rdent_ui
    fi

    print_airgap_deploy_summary
    export KUBECONFIG=/root/.mke/mke.kubeconf

    prompt_mke4k_upgrade_prep_airgap
}

cmd_deploy_instances_airgap() {
    load_config
    write_tfvars false true
    tf_init
    tf_apply
    generate_mke4_yaml true
    success "Instances deployed (airgap). Run 't deploy registry' then 't deploy cluster airgap'."
}

cmd_deploy_registry() {
    load_config
    setup_registry
    local upload_mode="standard"
    [[ "${mke4k_version}" == "v4.1.3" ]] && upload_mode="dual-path"
    upload_mke4k_bundle "${upload_mode}"
    success "Registry setup + bundle upload complete."
}

cmd_deploy_cluster_airgap() {
    load_config
    setup_node_dns             # Ensure DNS is configured before mkectl
    ensure_node_hostnames      # node name must equal the EC2 PrivateDnsName (CCM)
    setup_rhel_node_prereqs    # no-op for Ubuntu
    local output ssh_key bastion_ip
    output="$(tf_output)"
    ssh_key="$(echo "${output}" | jq -r '.ssh_key_path.value')"
    bastion_ip="$(echo "${output}" | jq -r '.bastion_public_ip.value')"

    ensure_mkectl_on_bastion "${ssh_key}" "${bastion_ip}"
    generate_mke4_yaml true
    mkectl_apply_on_bastion
    patch_coredns_hosts

    prompt_mke4k_upgrade_prep_airgap
}

cmd_destroy_cluster_airgap() {
    load_config
    local output ssh_key bastion_ip
    output="$(tf_output)"
    ssh_key="$(echo "${output}" | jq -r '.ssh_key_path.value')"
    bastion_ip="$(echo "${output}" | jq -r '.bastion_public_ip.value')"

    ssh_node "${ssh_key}" "${bastion_ip}" "mkectl reset --force -f ~/mke4.yaml"
    success "Cluster reset complete (airgap)."
}

# ---------------------------------------------------------------------------
# MKE3 Airgap commands
# ---------------------------------------------------------------------------
cmd_deploy_lab_mke3_airgap() {
    load_config
    write_tfvars true true     # mke3_enabled=true, airgap_enabled=true
    timer_deploy_start

    tf_init
    tf_apply
    timer_phase_end _T_TERRAFORM

    setup_registry             # Docker + bind9 + MSR4 + cert + 'mke' project
    timer_phase_end _T_REGISTRY

    upload_mke3_images         # Download MKE3 bundle + retag + push to Harbor/mke3
    timer_phase_end _T_MKE3_IMAGES

    setup_node_dns             # Point each node's resolver at bastion
    ensure_node_hostnames      # node name must equal the EC2 PrivateDnsName (CCM)
    setup_rhel_node_prereqs    # no-op for Ubuntu

    setup_squid_proxy          # Squid on bastion for MCR package installs
    setup_node_proxy           # apt/dnf proxy + env vars + registry CA on nodes
    timer_phase_end _T_PROXY

    local output ssh_key bastion_ip
    output="$(tf_output)"
    ssh_key="$(echo "${output}" | jq -r '.ssh_key_path.value')"
    bastion_ip="$(echo "${output}" | jq -r '.bastion_public_ip.value')"

    ensure_launchpad_on_bastion "${ssh_key}" "${bastion_ip}"
    wait_for_lb
    timer_phase_end _T_NLB

    generate_launchpad_yaml true   # airgap=true — private IPs, bastion keypath, imageRepo
    launchpad_apply_on_bastion
    timer_phase_end _T_LAUNCHPAD

    if [[ "${nfs_enabled}" == "true" ]]; then
        setup_nfs_server
        install_nfs_client_on_nodes
        upload_nfs_provisioner_image
        deploy_nfs_provisioner_mke3_airgap
        timer_phase_end _T_NFS
    fi

    print_mke3_airgap_deploy_summary
    prompt_upgrade_prep_airgap
}

cmd_deploy_instances_mke3_airgap() {
    load_config
    write_tfvars true true
    tf_init
    tf_apply
    generate_launchpad_yaml true
    success "Instances deployed (mke3-airgap). Run 't deploy registry mke3' then 't deploy cluster mke3-airgap'."
}

cmd_deploy_registry_mke3() {
    load_config
    setup_registry
    upload_mke3_images
    success "Registry setup + MKE3 image upload complete."
}

cmd_deploy_cluster_mke3_airgap() {
    load_config
    setup_node_dns
    ensure_node_hostnames      # node name must equal the EC2 PrivateDnsName (CCM)
    setup_rhel_node_prereqs    # no-op for Ubuntu
    setup_squid_proxy
    setup_node_proxy

    local output ssh_key bastion_ip
    output="$(tf_output)"
    ssh_key="$(echo "${output}" | jq -r '.ssh_key_path.value')"
    bastion_ip="$(echo "${output}" | jq -r '.bastion_public_ip.value')"

    ensure_launchpad_on_bastion "${ssh_key}" "${bastion_ip}"
    generate_launchpad_yaml true
    launchpad_apply_on_bastion

    print_mke3_airgap_deploy_summary
    prompt_upgrade_prep_airgap
}

cmd_destroy_cluster_mke3_airgap() {
    load_config
    launchpad_reset_on_bastion
}

cmd_destroy_lab() {
    load_config
    # CAPA-owned child clusters must go while the management cluster still runs.
    child_destroy_before_teardown
    write_tfvars
    tf_destroy
    # Clear any 't expiry' override so a future lab starts from config defaults.
    rm -f "${PROJECT_ROOT}/.expiry-days" "${PROJECT_ROOT}/.expiry-base"
    rm -f "$(child_marker_file)" "$(child_kubeconfig_file)" "$(child_credentials_file)"
    success "Lab destroyed."
}

# Reaper resources only — an 't expiry' apply must never touch the cluster.
_EXPIRY_TARGETS=(
    -target=time_offset.expiry
    -target=aws_iam_role.reaper
    -target=aws_iam_role_policy.reaper
    -target=aws_lambda_function.reaper
    -target=aws_iam_role.scheduler
    -target=aws_iam_role_policy.scheduler
    -target=aws_scheduler_schedule.expiry
)

# t expiry [<days>|off|show] — view, change, or disable the lab's auto-expiry.
# Changing it re-arms the reaper to "now + <days>" and applies ONLY the reaper
# resources (a targeted apply), so a running cluster is never touched.
cmd_expiry() {
    local arg="${1:-show}"
    load_config
    tf_output >/dev/null 2>&1 || die "No lab found (no terraform state). Deploy a lab first with 't deploy lab'."

    if [[ "${arg}" == "show" ]]; then
        local et
        et="$(tf_output 2>/dev/null | jq -r '.expiry_time.value // empty')"
        if [[ -z "${et}" ]]; then
            info "Auto-expiry: disabled (the lab will not self-delete)."
        else
            info "Auto-expiry: $(fmt_expiry "${et}")"
            info "  change with 't expiry <days>', disable with 't expiry off'."
        fi
        return 0
    fi

    case "${arg}" in
        off|never|0)
            echo "0" > "${PROJECT_ROOT}/.expiry-days"
            rm -f "${PROJECT_ROOT}/.expiry-base"
            info "Disabling auto-expiry (removing the reaper)..."
            ;;
        *)
            [[ "${arg}" =~ ^[1-9][0-9]*$ ]] || die "Usage: t expiry [<days≥1>|off|show]"
            date -u +%Y-%m-%dT%H:%M:%SZ > "${PROJECT_ROOT}/.expiry-base"
            echo "${arg}" > "${PROJECT_ROOT}/.expiry-days"
            info "Re-arming auto-expiry to ${arg} day(s) from now..."
            ;;
    esac

    # Reload so expiry_* reflect the new override files, then regenerate tfvars
    # preserving the deployed topology (mke3/airgap flags read back from tfvars).
    load_config
    local airgap_tf mke3_tf
    mke3_tf="$(grep -E '^mke3_enabled'   "${TERRAFORM_DIR}/terraform.tfvars" 2>/dev/null | awk '{print $3}')"
    airgap_tf="$(grep -E '^airgap_enabled' "${TERRAFORM_DIR}/terraform.tfvars" 2>/dev/null | awk '{print $3}')"
    write_tfvars "${mke3_tf:-false}" "${airgap_tf:-false}"

    terraform -chdir="${TERRAFORM_DIR}" apply -auto-approve -compact-warnings "${_EXPIRY_TARGETS[@]}"

    local et
    et="$(tf_output 2>/dev/null | jq -r '.expiry_time.value // empty')"
    if [[ -z "${et}" ]]; then
        success "Auto-expiry disabled — the lab will NOT self-delete. Remember to 't destroy lab' when done."
    else
        success "Auto-expiry updated: $(fmt_expiry "${et}")"
    fi
}

cmd_deploy_nfs() {
    local product="${1:-mke4}"   # mke4 | mke3
    load_config
    [[ "${nfs_enabled}" == "true" ]] || die "nfs_enabled is not true in config"

    local output
    output="$(tf_output 2>/dev/null)" || die "Could not read terraform output. Has terraform been applied?"

    local bastion_ip=""
    bastion_ip="$(echo "${output}" | jq -r '.bastion_public_ip.value // empty' 2>/dev/null)"
    local is_airgap=false
    [[ -n "${bastion_ip}" && "${bastion_ip}" != "null" && "${bastion_ip}" != "" ]] && is_airgap=true

    setup_nfs_server
    install_nfs_client_on_nodes
    if [[ "${is_airgap}" == "true" ]]; then
        upload_nfs_provisioner_image
        if [[ "${product}" == "mke3" ]]; then
            deploy_nfs_provisioner_mke3_airgap
        else
            deploy_nfs_provisioner_airgap
        fi
    elif [[ "${product}" == "mke3" ]]; then
        deploy_nfs_provisioner_mke3
    else
        deploy_nfs_provisioner
    fi
    success "NFS setup complete."
}

# ---------------------------------------------------------------------------
# KOF (k0rdent Observability & FinOps) — self-monitoring (M2M) mode
# ---------------------------------------------------------------------------
# Targets KOF 1.8.x as shipped with k0rdent Enterprise 1.3.2 (MKE 4.2.0).
# M2M (Management-to-Management): the cluster stores its own metrics/logs/traces
# locally — no regional cluster, no child ClusterDeployment, no external DNS, no
# Istio. For 1.8.x this is expressed as kof-storage.enabled=true + a kof-collectors
# patch (NOT the 1.10+ 'regionless' / fromManagement form).
# KOF is a FluxCD-sequenced OCI umbrella Helm chart; installed with helm v3
# (helm v4 has a webhook bug, kof issue #715 — the container ships helm v3).
# Depends on a StorageClass (the 'nfs' add-on provides default 'nfs-client').
#
# Airgap: the MKE 4.2.0 offline bundle ships every KOF 1.8.1 chart and image;
# upload_mke4k_bundle lands them at <registry>/mke/... (charts at
# oci://<registry>/mke/charts/kof*). helm/kubectl/mkectl then run on the bastion
# (the cluster API is private-subnet-only); all values-file generation stays
# local. Values files and patch files travel by scp — never inline through ssh
# (OTTL literals like ${env:OTEL_K8S_NODE_NAME} would be corrupted by shell
# expansion). Per the k0rdent Enterprise airgap docs, no helmRepo secretRef /
# certSecretRef is needed: the 'mke' Harbor project is public and the cluster
# already trusts the registry CA (established by the MKE airgap install itself).
# ---------------------------------------------------------------------------

# KOF remoting state — set once by cmd_deploy_kof / cmd_destroy_kof. The online
# defaults keep every kof_* helper callable standalone (mode=online → local exec).
_kof_mode="online"        # online | airgap
_kof_ssh_key=""
_kof_bastion_ip=""

# Run one complete cluster-touching shell-command string: locally (online) or on
# the bastion with the cluster kubeconfig (airgap). The string is shell-parsed
# exactly once in both modes (bash -c locally, the remote shell via ssh), so a
# call that works online works identically in airgap. stdin is closed so calls
# inside `while read` loops can't be drained by ssh.
_kof_kexec() {
    _msr_kexec "${_kof_mode}" "${_kof_ssh_key}" "${_kof_bastion_ip}" "$@" </dev/null
}

# kubectl apply a LOCAL file: online directly; airgap scp to the bastion first.
# Usage: _kof_kapply <local-file> [kubectl apply args, e.g. -n kof]
_kof_kapply() {
    local f="$1"; shift
    if [[ "${_kof_mode}" == "airgap" ]]; then
        local rf="/tmp/$(basename "${f}")"
        scp -q -o StrictHostKeyChecking=no -i "${_kof_ssh_key}" \
            "${f}" "ubuntu@${_kof_bastion_ip}:${rf}"
        _kof_kexec "kubectl apply $* -f '${rf}' && rm -f '${rf}'"
    else
        kubectl apply "$@" -f "${f}"
    fi
}

# kubectl patch with a LOCAL --patch-file (patch has no stdin form; the patch
# bytes must never ride an interpolated ssh command line — see section header).
# Usage: _kof_kpatch_file <local-patch-file> <kubectl args before --patch-file>
#   e.g. _kof_kpatch_file "${pf}" -n kof patch opentelemetrycollector "${cr}" --type=merge
_kof_kpatch_file() {
    local f="$1"; shift
    if [[ "${_kof_mode}" == "airgap" ]]; then
        local rf="/tmp/$(basename "${f}")"
        scp -q -o StrictHostKeyChecking=no -i "${_kof_ssh_key}" \
            "${f}" "ubuntu@${_kof_bastion_ip}:${rf}"
        _kof_kexec "kubectl $* --patch-file='${rf}' && rm -f '${rf}'"
    else
        kubectl "$@" --patch-file="${f}"
    fi
}

# One-time bastion prep for a KOF airgap deploy (idempotent, no-op online):
# kubeconfig + registry DNS sanity, registry CA into the system trust store (so
# helm's OCI pull validates TLS — same idiom as upload_msr4_artifacts), helm v3
# if missing, then a chart presence check so a missing/partial bundle upload
# fails fast with a clear message instead of mid-install.
kof_bastion_prep() {
    [[ "${_kof_mode}" == "airgap" ]] || return 0
    info "Preparing bastion for KOF (helm, registry CA trust, chart check)..."
    ssh_node "${_kof_ssh_key}" "${_kof_bastion_ip}" "
        set -euo pipefail
        [[ -f ~/.mke/mke.kubeconf ]] \
            || { echo 'ERROR: ~/.mke/mke.kubeconf not found on bastion — deploy the cluster first.'; exit 1; }
        grep -q '${registry_hostname}' /etc/hosts \
            || { echo 'ERROR: ${registry_hostname} missing from bastion /etc/hosts — run t deploy registry first.'; exit 1; }
        if [[ ! -f /usr/local/share/ca-certificates/msr-registry-ca.crt ]]; then
            sudo cp ~/msr/certs/ca.crt /usr/local/share/ca-certificates/msr-registry-ca.crt
            sudo update-ca-certificates >/dev/null
        fi
        if ! command -v helm >/dev/null 2>&1; then
            echo '>>> Installing helm on bastion...'
            curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
        fi
        command -v kubectl >/dev/null 2>&1 && command -v mkectl >/dev/null 2>&1 \
            || { echo 'ERROR: kubectl/mkectl missing on bastion — run t deploy lab airgap (or ensure_mkectl_on_bastion).'; exit 1; }
    " || die "Bastion prep for KOF failed."
    _kof_kexec "helm show chart 'oci://${kof_registry}/charts/kof' --version '${kof_version}' >/dev/null 2>&1" \
        || die "KOF chart not found at oci://${kof_registry}/charts/kof:${kof_version} — is the MKE ${mke4k_version} bundle uploaded to the registry? (t deploy registry)"
    return 0
}

# Flux's source-controller pulls the KOF sub-charts (HelmChart objects created by
# the umbrella) and validates registry TLS PER HelmRepository via certSecretRef —
# it does NOT inherit the caData trust that mke4.yaml distributes to MKE's own
# components. Per the k0rdent Enterprise airgap docs, create a secret holding the
# registry CA in the KCM namespace (where the umbrella's HelmRepositories live)
# and reference it from global.helmRepo.spec + every *-service-template/istio
# repo.spec (done in cmd_deploy_kof). The 'mke' project is public, so only the
# cert is needed — no secretRef/credentials. Airgap-only, idempotent.
kof_ensure_registry_cert_secret() {
    [[ "${_kof_mode}" == "airgap" ]] || return 0
    info "Ensuring registry CA secret 'kof-registry-cert' in ns ${kof_kcm_namespace} (Flux chart-pull TLS)..."
    _kof_kexec "kubectl -n '${kof_kcm_namespace}' create secret generic kof-registry-cert \
        --from-file=ca.crt=/home/ubuntu/msr/certs/ca.crt \
        --dry-run=client -o yaml | kubectl apply -f -" \
        || die "Failed to create the kof-registry-cert secret in ns ${kof_kcm_namespace}."
    return 0
}

# Grafana is bring-your-own in KOF (Mirantis does not ship it with MKE), so the
# grafana image is NOT in the offline bundle — and its VictoriaMetrics datasource
# plugins are worse: GF_INSTALL_PLUGINS makes the pod download them from
# grafana.com AT STARTUP, impossible from the private subnet (and the chart's
# datasources are of type victoriametrics-*-datasource, so the plugins are not
# optional). Fix both on the bastion (which has internet + docker + Harbor):
# build a derived image with the plugins baked in and push it to the internal
# registry as <tag>-airgap. Plugins are installed to /opt/grafana-plugins with
# GF_PATHS_PLUGINS pointing there — NOT the default /var/lib/grafana/plugins,
# which the grafana-data PVC mounts over and would shadow. kof_install_grafana
# then uses the -airgap tag and strips GF_INSTALL_PLUGINS from the CR.
# Idempotent: skips the build when the tag is already in Harbor.
kof_prepare_grafana_airgap() {
    [[ "${_kof_mode}" == "airgap" && "${kof_grafana_enabled}" == "true" ]] || return 0

    local registry_pass
    registry_pass="$(grep '^password=' "${TERRAFORM_DIR}/registry_credentials.txt" 2>/dev/null | cut -d= -f2)"
    [[ -n "${registry_pass}" ]] || die "Registry password not found in ${TERRAFORM_DIR}/registry_credentials.txt"

    local upstream="registry.mirantis.com/k0rdent-enterprise/grafana/grafana:${kof_grafana_image_tag}"
    local target="${registry_hostname}/mke/grafana/grafana:${kof_grafana_image_tag}-airgap"

    # Plugin list from the committed CR ("id ver,id ver") -> one install command each.
    local plugins entry install_cmds=""
    plugins="$(yq '.spec.deployment.spec.template.spec.containers[] | select(.name == "grafana")
        | .env[] | select(.name == "GF_INSTALL_PLUGINS") | .value' "${PROJECT_ROOT}/kof/grafana.yaml")"
    while IFS= read -r entry; do
        [[ -n "${entry}" ]] || continue
        install_cmds+="    grafana cli --pluginsDir /opt/grafana-plugins plugins install ${entry} && \\"$'\n'
    done < <(tr ',' '\n' <<< "${plugins}")
    [[ -n "${install_cmds}" ]] || { info "No GF_INSTALL_PLUGINS in kof/grafana.yaml — skipping grafana image prep."; return 0; }

    # Render the Dockerfile locally, ship it, build+push on the bastion.
    local df
    df="$(mktemp "${TMPDIR:-/tmp}/kof-grafana-XXXX.Dockerfile")"
    cat > "${df}" <<EOF
FROM ${upstream}
USER root
RUN mkdir -p /opt/grafana-plugins && \\
${install_cmds}    chown -R 472:472 /opt/grafana-plugins
ENV GF_PATHS_PLUGINS=/opt/grafana-plugins
USER 472
EOF

    info "Preparing airgap Grafana image on bastion (${target})..."
    scp -q -o StrictHostKeyChecking=no -i "${_kof_ssh_key}" \
        "${df}" "ubuntu@${_kof_bastion_ip}:/tmp/kof-grafana.Dockerfile"
    rm -f "${df}"
    ssh_node "${_kof_ssh_key}" "${_kof_bastion_ip}" "
        set -euo pipefail
        docker login '${registry_hostname}' -u admin -p '${registry_pass}' >/dev/null 2>&1
        if docker manifest inspect '${target}' >/dev/null 2>&1; then
            echo '>>> Airgap Grafana image already in Harbor — skipping build.'
        else
            echo '>>> Building Grafana image with baked-in VM plugins (pull + plugin download need internet)...'
            mkdir -p ~/kof-grafana-build
            mv /tmp/kof-grafana.Dockerfile ~/kof-grafana-build/Dockerfile
            docker build -t '${target}' ~/kof-grafana-build
            docker push '${target}'
            echo '>>> Pushed ${target}'
        fi
        rm -f /tmp/kof-grafana.Dockerfile
    " || die "Airgap Grafana image preparation failed on the bastion."
    return 0
}

kof_preflight() {
    local tool
    local -a need_tools=(yq jq)
    [[ "${_kof_mode}" == "online" ]] && need_tools+=(helm kubectl)
    for tool in "${need_tools[@]}"; do
        command -v "${tool}" >/dev/null 2>&1 \
            || die "KOF requires '${tool}' in PATH."
    done
    _kof_kexec "kubectl get nodes >/dev/null 2>&1" \
        || die "Cluster not reachable (mode=${_kof_mode}). Deploy the cluster first."
    [[ -f "${PROJECT_ROOT}/kof/global-values.yaml" ]] \
        || die "Missing committed asset ${PROJECT_ROOT}/kof/global-values.yaml."
    [[ -f "${PROJECT_ROOT}/kof/umbrella-defaults.yaml" ]] \
        || die "Missing committed asset ${PROJECT_ROOT}/kof/umbrella-defaults.yaml."
    [[ -f "${PROJECT_ROOT}/kof/profiles/${kof_mode}.yaml" ]] \
        || die "Missing KOF profile asset ${PROJECT_ROOT}/kof/profiles/${kof_mode}.yaml (kof_mode=${kof_mode})."
    [[ "${kof_grafana_enabled}" != "true" || -f "${PROJECT_ROOT}/kof/grafana.yaml" ]] \
        || die "kof_grafana_enabled=true but missing committed asset ${PROJECT_ROOT}/kof/grafana.yaml."
    if [[ "${kof_grafana_gateway_enabled}" == "true" ]]; then
        [[ "${kof_grafana_enabled}" == "true" ]] \
            || die "kof_grafana_gateway_enabled=true requires kof_grafana_enabled=true."
        [[ -f "${PROJECT_ROOT}/kof/grafana-gateway.yaml" ]] \
            || die "kof_grafana_gateway_enabled=true but missing committed asset ${PROJECT_ROOT}/kof/grafana-gateway.yaml."
    fi
    _kof_kexec "kubectl get ns '${kof_kcm_namespace}' >/dev/null 2>&1" \
        || die "k0rdent (KCM) namespace '${kof_kcm_namespace}' not found. Set kof_kcm_namespace in config to the namespace where k0rdent runs (check 'kubectl get ns')."
    # HA (cluster) storage is the only supported topology today; single-node
    # (vmsingle / single VictoriaLogs) is a future seam pending chart support.
    [[ "${kof_storage_ha}" == "true" ]] \
        || die "kof_storage_ha=false (single-node storage) is not yet implemented — keep kof_storage_ha=true."
    if [[ "${kof_reuse_mke_monitoring}" == "true" ]]; then
        [[ "${kof_grafana_enabled}" != "true" || -f "${PROJECT_ROOT}/kof/mke-prometheus-datasource.yaml" ]] \
            || die "kof_reuse_mke_monitoring=true but missing committed asset ${PROJECT_ROOT}/kof/mke-prometheus-datasource.yaml."
        # Soft checks: the reuse depends on MKE's monitoring stack being present.
        _kof_kexec "kubectl get ns mke >/dev/null 2>&1" \
            || warn "kof_reuse_mke_monitoring=true but namespace 'mke' not found — MKE monitoring may be absent; node metrics could go missing."
        _kof_kexec "kubectl get svc prometheus-operated -n mke >/dev/null 2>&1" \
            || warn "MKE Prometheus service 'prometheus-operated' not found in ns 'mke' — the MKE Prometheus datasource will not resolve."
    fi
}

# Echo a usable StorageClass: cluster default, else 'nfs-client', else die.
kof_resolve_storageclass() {
    # jsonpath hoisted into a single-quoted local: it contains no single quotes,
    # so it can be safely re-wrapped in single quotes inside the kexec string.
    local jp='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}'
    local sc
    sc="$(_kof_kexec "kubectl get sc -o jsonpath='${jp}' 2>/dev/null" | head -n1)"
    if [[ -z "${sc}" ]]; then
        if _kof_kexec "kubectl get sc nfs-client >/dev/null 2>&1"; then
            sc="nfs-client"
        else
            die "No default StorageClass and no 'nfs-client' found. Run 't deploy nfs' (or set nfs_enabled=true) first."
        fi
    fi
    printf '%s\n' "${sc}"
}

# Lean-mode dashboard curation. The kof-dashboards subchart renders a
# GrafanaDashboard CR for EVERY bundled dashboard unconditionally (no per-folder
# values toggle), so disabling the OpenCost/VictoriaTraces components leaves their
# dashboards behind showing "No data". Prune them (and OS-specific clutter) after
# the chart settles. Selection is by Grafana folder (kof_lean_prune_folders,
# comma-separated since folder names contain spaces) and by dashboard name
# (kof_lean_prune_dashboards). Idempotent and re-run every deploy: helm recreates
# the CRs, this removes them again. Robust because Flux v2 HelmReleases do not
# drift-correct deleted child resources unless driftDetection is explicitly on.
kof_prune_dashboards() {
    if [[ "${kof_grafana_enabled}" != "true" ]]; then
        info "Grafana disabled — no dashboards to prune."
        return 0
    fi
    local folders="${kof_lean_prune_folders}" names="${kof_lean_prune_dashboards}"
    if [[ -z "${folders}" && -z "${names}" ]]; then
        return 0
    fi
    info "Lean: pruning dashboards (folders: [${folders:-none}]; names: [${names:-none}])..."

    local to_delete
    to_delete="$(_kof_kexec "kubectl get grafanadashboard -n kof -o json 2>/dev/null" \
        | FOLDERS="${folders}" NAMES="${names}" jq -r '
            ($ENV.FOLDERS | split(",") | map(select(length > 0))) as $folders
          | ($ENV.NAMES   | split(",") | map(select(length > 0))) as $names
          | .items[]
          | (.spec.folder // "") as $f
          | .metadata.name as $n
          | select(($folders | index($f)) != null or ($names | index($n)) != null)
          | $n')"

    if [[ -z "${to_delete}" ]]; then
        info "  No matching dashboards found (already pruned, or chart layout changed)."
        return 0
    fi

    local count=0 d
    while IFS= read -r d; do
        [[ -n "${d}" ]] || continue
        _kof_kexec "kubectl delete grafanadashboard -n kof '${d}' --ignore-not-found >/dev/null 2>&1" \
            && count=$((count + 1))
    done <<< "${to_delete}"
    success "Pruned ${count} Lean dashboard(s)."
    return 0
}

# MKE4k ships a built-in ucpauthz Validating Admission Policy that blocks
# service accounts (e.g. kof's opentelemetry-operator) from creating workloads
# like DaemonSets. Left in place, KOF's collector CRs reconcile but their
# DaemonSets are never created (no node/host-log collection). Exempt the kof
# namespace + operator SA via mkectl BEFORE installing KOF.
# Idempotent: merges into any existing exemptions and only re-applies the
# cluster config when the exemption is missing (mkectl apply is heavyweight).
kof_exempt_ucpauthz() {
    # Airgap: mkectl runs on the bastion (it SSHes to the private-subnet nodes and
    # is already installed there — verified by kof_bastion_prep); the yq edit of
    # the fetched config stays local either way.
    [[ "${_kof_mode}" == "online" ]] && ensure_mkectl

    local cfg ns_sa
    ns_sa="system:serviceaccount:kof:opentelemetry-operator"
    cfg="$(mktemp "${TMPDIR:-/tmp}/kof-ucpauthz-XXXX.yaml")"

    info "Checking MKE ucpauthz admission-policy exemptions..."
    _kof_kexec "mkectl config get 2>/dev/null" | sed -n '/^apiVersion:/,$p' > "${cfg}"
    [[ -s "${cfg}" ]] || { rm -f "${cfg}"; die "mkectl config get returned empty output. Is the cluster up?"; }

    if NS_SA="${ns_sa}" yq -e '
        ((.spec.apiServer.ucpauthz.exemptNamespaces // []) | contains(["kof"]))
        and ((.spec.apiServer.ucpauthz.exemptUsers // []) | contains([strenv(NS_SA)]))
    ' "${cfg}" >/dev/null 2>&1; then
        info "  ucpauthz already exempts kof — skipping mkectl apply."
    else
        info "Exempting kof from ucpauthz and applying cluster config (mkectl)..."
        NS_SA="${ns_sa}" yq -i '
            .spec.apiServer.ucpauthz.disabled = (.spec.apiServer.ucpauthz.disabled // false)
          | .spec.apiServer.ucpauthz.exemptNamespaces = ((.spec.apiServer.ucpauthz.exemptNamespaces // []) + ["kof"] | unique)
          | .spec.apiServer.ucpauthz.exemptUsers = ((.spec.apiServer.ucpauthz.exemptUsers // []) + [strenv(NS_SA)] | unique)
        ' "${cfg}"

        local debug_flag=""
        [[ "${debug:-false}" == "true" ]] && debug_flag="-l debug"
        if [[ "${_kof_mode}" == "airgap" ]]; then
            local rcfg="/tmp/$(basename "${cfg}")"
            scp -q -o StrictHostKeyChecking=no -i "${_kof_ssh_key}" \
                "${cfg}" "ubuntu@${_kof_bastion_ip}:${rcfg}"
            _kof_kexec "mkectl ${debug_flag} apply -f '${rcfg}' \
                --skip-helm-extensions-check --skip-cni-check --cni-check-timeout 1 && rm -f '${rcfg}'"
        else
            mkectl ${debug_flag} apply -f "${cfg}" \
                --skip-helm-extensions-check --skip-cni-check --cni-check-timeout 1
        fi
        success "ucpauthz exemption applied."
    fi

    rm -f "${cfg}"
    return 0
}

# Apply the Grafana instance CR (the chart enables the operator + datasources but
# does NOT create the instance). Pins image+version explicitly to the configured
# registry/tag so the operator doesn't try docker.io/grafana/grafana:<version>.
# Must run after the chart install so the grafana-operator + CRDs exist.
kof_install_grafana() {
    local gf gf_img="${kof_registry}/grafana/grafana:${kof_grafana_image_tag}"
    gf="$(mktemp "${TMPDIR:-/tmp}/kof-grafana-XXXX.yaml")"
    cp "${PROJECT_ROOT}/kof/grafana.yaml" "${gf}"

    # Airgap: use the plugins-baked image built by kof_prepare_grafana_airgap and
    # strip GF_INSTALL_PLUGINS (the entrypoint would try grafana.com and crash;
    # the baked image serves the plugins from GF_PATHS_PLUGINS instead).
    if [[ "${_kof_mode}" == "airgap" ]]; then
        gf_img="${gf_img}-airgap"
        yq -i 'del(.spec.deployment.spec.template.spec.containers[] | select(.name == "grafana")
            | .env[] | select(.name == "GF_INSTALL_PLUGINS"))' "${gf}"
    fi

    GF_IMG="${gf_img}" TAG="${kof_grafana_image_tag}" yq -i '
        .spec.version = strenv(TAG)
      | (.spec.deployment.spec.template.spec.containers[] | select(.name == "grafana") | .image) = strenv(GF_IMG)
    ' "${gf}"

    info "Applying Grafana instance (image ${gf_img})..."
    _kof_kexec "kubectl wait --for=condition=Established crd/grafanas.grafana.integreatly.org --timeout=5m" || true
    _kof_kapply "${gf}" -n kof
    rm -f "${gf}"

    info "Waiting for Grafana instance to become ready..."
    _kof_kexec "kubectl wait grafana grafana-vm -n kof \
        --for=jsonpath='{.status.stageStatus}'=success --timeout=5m" || true
    return 0
}

# Register MKE4's built-in Prometheus (svc prometheus-operated.mke:9090) as an
# extra datasource in KOF's Grafana — a one-pane view alongside KOF's
# VictoriaMetrics. Applied when kof_reuse_mke_monitoring=true. Must run after the
# chart install so the GrafanaDatasource CRD + grafana-operator exist.
kof_add_mke_datasource() {
    info "Adding MKE Prometheus as a Grafana datasource (prometheus-operated.mke:9090)..."
    _kof_kexec "kubectl wait --for=condition=Established \
        crd/grafanadatasources.grafana.integreatly.org --timeout=5m" || true
    _kof_kapply "${PROJECT_ROOT}/kof/mke-prometheus-datasource.yaml" -n kof
    return 0
}

# Companion to dropping KOF's node-exporter + reusing MKE's kubelet
# (kof_reuse_mke_monitoring / kof_reuse_mke_kubelet): MKE's node-exporter AND kubelet
# ServiceMonitors do NOT add the node-identity target labels KOF's dashboards key on.
# KOF's own scrapes relabeled BOTH `node` and `nodename` onto every series, and KOF
# dashboards filter on BOTH across THREE metric families:
#   - node_*      (node-exporter)  e.g. node_cpu_seconds_total{nodename="$node"}
#   - machine_*   (cAdvisor)       e.g. machine_memory_bytes{nodename="$node"} (CPU/RAM Total)
#   - container_* (cAdvisor)       e.g. container_cpu_usage_seconds_total{nodename="$node"} (by-Pod)
#   - kubelet_*   (kubelet)        e.g. kubelet_volume_stats_used_bytes{nodename="$node"} (PVC stats)
# Also the node-exporter-full Host picker is label_values(node_uname_info, node).
# MKE's series carry neither label, so the host picker is empty AND every
# nodename-keyed panel (CPU/RAM Total, CPU/Mem usage by Pod, PVC volume stats, etc.)
# shows no data. Stamp both `node` and `nodename` from the per-node downward-API env
# var OTEL_K8S_NODE_NAME onto every node_*/machine_*/container_*/kubelet_* metric
# that lacks them, on the target-allocator DaemonSet collector. This is correct
# because the daemon TA allocates each node's targets (node-exporter + kubelet, both
# per-node) to the collector ON that node (proven: the node-exporter fix landed
# distinct per-node FQDNs — non-local allocation would have collapsed them). The set
# is an ALLOWLIST of per-node metric families, NOT "stamp everything missing
# nodename": the same collector also scrapes cluster-scoped SM targets (KSM kube_*,
# MKE's apiserver/coredns) and stamping those with the collector's node would be
# wrong. Each set is also guarded `== nil` so node_uname_info's intrinsic uname
# `nodename` and KOF's own series (full mode) are never touched. `job` can't be used as the guard — the prometheus receiver promotes it to
# a resource attribute, so it isn't a datapoint attribute at transform time; the
# metric-name match is reliable instead. (OTEL_K8S_NODE_NAME is the k8s node name,
# which on these nodes equals the uname nodename, e.g. ip-172-31-0-113....)
# The OpenTelemetryCollector is Flux-managed, so (like kof_prune_dashboards) this is
# a post-install reconcile re-applied each deploy; the collector is rolled after.
kof_apply_node_label_transform() {
    local cr="kof-collectors-ta-daemon" ds="kof-collectors-ta-daemon-collector"
    local stmt_node='set(datapoint.attributes["node"], "${env:OTEL_K8S_NODE_NAME}") where IsMatch(metric.name, "^(node_|machine_|container_|kubelet_)") and datapoint.attributes["node"] == nil'
    local stmt_nodename='set(datapoint.attributes["nodename"], "${env:OTEL_K8S_NODE_NAME}") where IsMatch(metric.name, "^(node_|machine_|container_|kubelet_)") and datapoint.attributes["nodename"] == nil'

    _kof_kexec "kubectl get opentelemetrycollector '${cr}' -n kof >/dev/null 2>&1" \
        || { warn "Collector ${cr} not found — skipping node-label transform."; return 0; }

    info "Adding node-label transform to ${cr} (reuse-MKE-monitoring node-exporter fix)..."

    # Read the current metrics-pipeline processor list and insert transform/setnode
    # just before "batch" (idempotent — no-op if already present), so we don't
    # clobber whatever processors the chart shipped.
    local cur_json new_json
    cur_json="$(_kof_kexec "kubectl -n kof get opentelemetrycollector '${cr}' -o json 2>/dev/null" \
        | jq -c '.spec.config.service.pipelines.metrics.processors // []')"
    if [[ -z "${cur_json}" || "${cur_json}" == "null" ]]; then
        warn "Could not read ${cr} metrics pipeline — skipping node-label transform."
        return 0
    fi
    new_json="$(jq -c '
        if index("transform/setnode") then .
        elif index("batch") then index("batch") as $b | .[0:$b] + ["transform/setnode"] + .[$b:]
        else . + ["transform/setnode"] end' <<<"${cur_json}")"

    local patch_file
    patch_file="$(mktemp "${TMPDIR:-/tmp}/kof-setnode-XXXX.json")"
    jq -n --arg s1 "${stmt_node}" --arg s2 "${stmt_nodename}" --argjson procs "${new_json}" '
        {spec:{config:{
            processors:{"transform/setnode":{metric_statements:[{context:"datapoint",statements:[$s1,$s2]}]}},
            service:{pipelines:{metrics:{processors:$procs}}}
        }}}' > "${patch_file}"
    _kof_kpatch_file "${patch_file}" -n kof patch opentelemetrycollector "${cr}" --type=merge
    rm -f "${patch_file}"

    # Roll the collector so the operator regenerates its config, then wait it out.
    _kof_kexec "kubectl -n kof rollout restart 'ds/${ds}' >/dev/null 2>&1" || true
    _kof_kexec "kubectl -n kof rollout status 'ds/${ds}' --timeout=180s" || true
    success "Node-label transform applied to ${cr}."
    return 0
}

# Drop the k0s metrics-scraper PUSHGATEWAY's re-export of the control-plane
# components (kof_reuse_mke_monitoring). On k0s, scheduler/controller-manager/etcd
# are scraped TWICE and land in KOF's VM:
#   (1) DIRECT, on the node IP:secure-port (kube-scheduler :10259, kube-controller-
#       manager :10257, etcd :2381) — per-controller `instance`, full fidelity; and
#   (2) the k0s pushgateway (ns k0s-system, --enable-metrics-scraper) which
#       re-exports the SAME series with the real target moved to exported_job/
#       exported_instance and `instance` collapsed to the pushgateway pod.
# KOF's cluster-wide target-allocator (on kof-collectors-ta-daemon) discovers the
# `k0s` ServiceMonitor (ns mke) and scrapes the pushgateway, so both copies exist.
# Unlike apiserver (both copies hit the same endpoint -> collapse to one series),
# these carry DIFFERENT `instance` labels and do NOT collapse, so aggregating
# panels (sum/rate over a control-plane job) double-count (verified live: equal
# cardinality in ns={} and ns=k0s-system for all three jobs).
# The clean fix is `--enable-metrics-scraper=false`, but MKE hardcodes it =true
# AFTER user installFlags (k0s pflag last-wins), so it can't be turned off from
# mke4.yaml. So we drop the pushgateway copies at the collector instead.
# Discriminator: `exported_job` — present ONLY on the pushgateway re-export (the
# direct scrape has no exported_* label), and it stays a DATAPOINT attribute (only
# `job`/`instance` get promoted to resource attrs by the prometheus receiver — the
# same gotcha noted in kof_apply_node_label_transform), so it's reliable to match.
# Same Flux-managed CR + post-install reconcile pattern as the node-label transform.
kof_apply_k0s_pushgateway_dedup() {
    local cr="kof-collectors-ta-daemon" ds="kof-collectors-ta-daemon-collector"

    _kof_kexec "kubectl get opentelemetrycollector '${cr}' -n kof >/dev/null 2>&1" \
        || { warn "Collector ${cr} not found — skipping k0s-pushgateway dedup."; return 0; }

    info "Dropping k0s-pushgateway scheduler/controller-manager/etcd re-exports on ${cr}..."

    # Append filter/drop_k0s_pushgateway to the metrics pipeline (before batch,
    # idempotent) without clobbering transform/setnode or anything the chart ships.
    local cur_json new_json
    cur_json="$(_kof_kexec "kubectl -n kof get opentelemetrycollector '${cr}' -o json 2>/dev/null" \
        | jq -c '.spec.config.service.pipelines.metrics.processors // []')"
    if [[ -z "${cur_json}" || "${cur_json}" == "null" ]]; then
        warn "Could not read ${cr} metrics pipeline — skipping k0s-pushgateway dedup."
        return 0
    fi
    new_json="$(jq -c '
        if index("filter/drop_k0s_pushgateway") then .
        elif index("batch") then index("batch") as $b | .[0:$b] + ["filter/drop_k0s_pushgateway"] + .[$b:]
        else . + ["filter/drop_k0s_pushgateway"] end' <<<"${cur_json}")"

    # Build the whole patch with jq --argjson (embeds the real array; errors loudly
    # if empty — never writes a literal "$var" that the collector would env-expand).
    local patch_file
    patch_file="$(mktemp "${TMPDIR:-/tmp}/kof-pgwdrop-XXXX.json")"
    jq -n --argjson procs "${new_json}" '
        {spec:{config:{
            processors:{"filter/drop_k0s_pushgateway":{
                error_mode:"ignore",
                metrics:{datapoint:[
                    "attributes[\"exported_job\"] == \"kube-scheduler\"",
                    "attributes[\"exported_job\"] == \"kube-controller-manager\"",
                    "attributes[\"exported_job\"] == \"etcd\""
                ]}
            }},
            service:{pipelines:{metrics:{processors:$procs}}}
        }}}' > "${patch_file}"
    _kof_kpatch_file "${patch_file}" -n kof patch opentelemetrycollector "${cr}" --type=merge
    rm -f "${patch_file}"

    # Roll the collector so the operator regenerates its config, then wait it out.
    _kof_kexec "kubectl -n kof rollout restart 'ds/${ds}' >/dev/null 2>&1" || true
    _kof_kexec "kubectl -n kof rollout status 'ds/${ds}' --timeout=180s" || true
    success "k0s-pushgateway dedup applied to ${cr}."
    return 0
}

# Remove KOF's duplicate kubelet/cAdvisor scrape so MKE's kubelet ServiceMonitor
# is the single source (kof_reuse_mke_kubelet). KOF's daemon collectors scrape
# each node's kubelet :10250 directly via prometheus scrape_configs jobs
# (kubelet-cadvisor / kubelet / kubelet-resources / kubelet-probes) — NOT a
# ServiceMonitor and NOT the kubeletMetrics preset (that's the separate, OTEL-only
# kubeletstats receiver). Both KOF's and MKE's land in KOF's VM, so container_*
# and kubelet_* metrics are double-counted and any sum-by-pod panel over-reports
# (verified: a 2m pod showed ~10m). Dropping the kubelet* jobs (keeping
# kubernetes-pods) leaves MKE's kubelet SM as the single, accurate source.
# Post-install reconcile (the scrape_configs list is too large to override in
# values; Flux-managed CR, so re-applied each deploy). Idempotent: skips a
# collector that already has no kubelet* jobs. Touches both daemon collectors
# (worker + control-plane). NOTE: trades KOF's richer cAdvisor series set for
# MKE's kube-prometheus-stack-filtered set; the standard dashboards are built
# against the filtered set, so this is accuracy-positive.
kof_apply_kubelet_dedup() {
    local cr pf has rolled=0
    for cr in kof-collectors-daemon kof-collectors-controller-k0s-daemon; do
        _kof_kexec "kubectl get opentelemetrycollector '${cr}' -n kof >/dev/null 2>&1" || continue
        has="$(_kof_kexec "kubectl -n kof get opentelemetrycollector '${cr}' -o json 2>/dev/null" \
            | jq -r '[.spec.config.receivers.prometheus.config.scrape_configs[]?.job_name
                      | select(startswith("kubelet"))] | length')"
        if [[ -z "${has}" || "${has}" == "0" ]]; then
            info "  ${cr}: no kubelet* scrape jobs (already deduped) — skipping."
            continue
        fi
        info "  ${cr}: dropping ${has} kubelet* scrape job(s) (reuse-MKE kubelet dedup)..."
        pf="$(mktemp "${TMPDIR:-/tmp}/kof-nokubelet-XXXX.json")"
        _kof_kexec "kubectl -n kof get opentelemetrycollector '${cr}' -o json" \
            | jq '.spec.config.receivers.prometheus.config.scrape_configs
                  |= map(select(.job_name | startswith("kubelet") | not))
                | {spec:{config:{receivers:{prometheus:{config:{scrape_configs:
                    .spec.config.receivers.prometheus.config.scrape_configs}}}}}}' > "${pf}"
        _kof_kpatch_file "${pf}" -n kof patch opentelemetrycollector "${cr}" --type=merge
        rm -f "${pf}"
        _kof_kexec "kubectl -n kof rollout restart 'ds/${cr}-collector' >/dev/null 2>&1" || true
        rolled=1
    done
    [[ "${rolled}" == "1" ]] && success "Kubelet dedup applied (MKE's kubelet ServiceMonitor is now the single source)."
    return 0
}

# Apply the dedicated Grafana Envoy Gateway (Issuer/Certificate/EnvoyProxy/Gateway/
# HTTPRoute). Pins the Envoy NodePort to kof_grafana_nodeport so the terraform NLB
# target group hits a known port, and fills the cert SANs from terraform output.
kof_install_grafana_gateway() {
    local output lb_dns
    output="$(tf_output 2>/dev/null)" || die "Could not read terraform output for the Grafana gateway."
    # SANs: NLB DNS + node public IPs online; private node IPs + 127.0.0.1 in
    # airgap (access is `t tunnel grafana` → https://localhost, no NLB involved).
    local -a sans_ip=()
    if [[ "${_kof_mode}" == "airgap" ]]; then
        lb_dns=""
        mapfile -t sans_ip < <(echo "${output}" | jq -r '(.controller_private_ips.value // [])[], (.worker_private_ips.value // [])[]' 2>/dev/null)
        sans_ip+=("127.0.0.1")
    else
        lb_dns="$(echo "${output}" | jq -r '.lb_dns_name.value // empty')"
        mapfile -t sans_ip < <(echo "${output}" | jq -r '(.controller_ips.value // [])[], (.worker_ips.value // [])[]' 2>/dev/null)
    fi

    local gw
    gw="$(mktemp "${TMPDIR:-/tmp}/kof-gw-XXXX.yaml")"
    cp "${PROJECT_ROOT}/kof/grafana-gateway.yaml" "${gw}"

    NP="${kof_grafana_nodeport}" yq -i '
        (select(.kind == "EnvoyProxy").spec.provider.kubernetes.envoyService.patch.value.spec.ports[0].nodePort)
        = (strenv(NP) | tonumber)
    ' "${gw}"

    # Airgap: pin the Envoy data-plane image. Our EnvoyProxy CR doesn't set one,
    # so MKE's Envoy Gateway controller falls back to its compiled-in default
    # (docker.io/envoyproxy/envoy:...) — unpullable from the private subnet.
    # MKE's own gateways pin the internal-registry image in their EnvoyProxy CRs;
    # reuse the exact image ref from MKE's running envoy pod (right registry AND
    # tag, auto-tracks MKE versions), falling back to the bundle's known path.
    if [[ "${_kof_mode}" == "airgap" ]]; then
        local envoy_img
        envoy_img="$(_kof_kexec "kubectl get pods -n mke -l app.kubernetes.io/name=envoy \
            -o jsonpath='{.items[0].spec.containers[?(@.name==\"envoy\")].image}' 2>/dev/null" || true)"
        if [[ -z "${envoy_img}" ]]; then
            envoy_img="${kof_registry}/envoyproxy/envoy:distroless-v1.37.3"
            warn "Could not discover MKE's envoy data-plane image — falling back to ${envoy_img}."
        fi
        info "Pinning Envoy data-plane image to ${envoy_img} (airgap)."
        EIMG="${envoy_img}" yq -i '
            (select(.kind == "EnvoyProxy").spec.provider.kubernetes.envoyDeployment.container.image) = strenv(EIMG)
        ' "${gw}"
    fi

    # Cert SANs: NLB DNS + node public IPs (fall back to a placeholder if neither).
    yq -i '(select(.kind == "Certificate").spec.dnsNames) = [] | (select(.kind == "Certificate").spec.ipAddresses) = []' "${gw}"
    [[ -n "${lb_dns}" ]] && D="${lb_dns}" yq -i '(select(.kind == "Certificate").spec.dnsNames) += [strenv(D)]' "${gw}"
    local ip
    for ip in "${sans_ip[@]}"; do
        [[ -n "${ip}" ]] && IP="${ip}" yq -i '(select(.kind == "Certificate").spec.ipAddresses) += [strenv(IP)]' "${gw}"
    done
    if [[ -z "${lb_dns}" && ${#sans_ip[@]} -eq 0 ]]; then
        yq -i '(select(.kind == "Certificate").spec.dnsNames) = ["grafana.kof.local"]' "${gw}"
    fi

    info "Applying Grafana Envoy gateway (NodePort ${kof_grafana_nodeport}, NLB :${kof_grafana_lb_port})..."
    _kof_kapply "${gw}"
    rm -f "${gw}"

    _kof_kexec "kubectl wait --for=condition=Ready certificate/kof-grafana -n kof --timeout=2m" || true
    _kof_kexec "kubectl wait --for=condition=Programmed gateway/kof-grafana -n kof --timeout=3m" || true
    return 0
}

# Install the KOF umbrella chart from the generated values files in the CURRENT
# directory (cmd_deploy_kof's workdir). Online: helm runs locally, byte-identical
# to the original inline invocation. Airgap: the five values files are scp'd to
# the bastion and helm runs there (kof_bastion_prep guaranteed helm + CA trust;
# the 'mke' Harbor project is public so the OCI pull needs no login).
kof_helm_install() {
    info "Installing KOF umbrella chart (mode=${kof_mode}, helm v3, FluxCD-sequenced)..."
    if [[ "${_kof_mode}" == "airgap" ]]; then
        local rdir="/tmp/$(basename "$(pwd)")"    # kof-XXXX — unique per run
        ssh_node "${_kof_ssh_key}" "${_kof_bastion_ip}" "mkdir -p '${rdir}'"
        scp -q -o StrictHostKeyChecking=no -i "${_kof_ssh_key}" \
            umbrella-defaults.yaml global-components.yaml profile.yaml version.yaml runtime.yaml \
            "ubuntu@${_kof_bastion_ip}:${rdir}/"
        _kof_kexec "cd '${rdir}' && helm upgrade -i --reset-values --wait \
            --create-namespace -n kof kof \
            'oci://${kof_registry}/charts/kof' \
            --version '${kof_version}' \
            -f umbrella-defaults.yaml \
            -f global-components.yaml \
            -f profile.yaml \
            -f version.yaml \
            -f runtime.yaml \
            && cd / && rm -rf '${rdir}'"
    else
        helm upgrade -i --reset-values --wait \
            --create-namespace -n kof kof \
            "oci://${kof_registry}/charts/kof" \
            --version "${kof_version}" \
            -f umbrella-defaults.yaml \
            -f global-components.yaml \
            -f profile.yaml \
            -f version.yaml \
            -f runtime.yaml
    fi
    return 0
}

cmd_deploy_kof() {
    local mode_arg="${1:-}" airgap_arg="${2:-}"
    load_config

    # Resolve deployment mode: CLI positional overrides config (kof_mode).
    #   full = complete observability + FinOps platform (default)
    #   lean = cluster monitoring only (drops tracing + FinOps + dead dashboards)
    local mode="${mode_arg:-${kof_mode}}"
    case "${mode}" in
        full|lean) kof_mode="${mode}" ;;
        *) die "Unknown KOF mode '${mode}'. Try: full, lean." ;;
    esac

    # Resolve online vs airgap: the airgap topology is a property of the deployed
    # lab (bastion present), so auto-detect from terraform output — the explicit
    # `t deploy kof ... airgap` token just asserts it (die on mismatch).
    local output bastion_ip
    output="$(tf_output 2>/dev/null)" || die "Could not read terraform output. Has terraform been applied?"
    bastion_ip="$(echo "${output}" | jq -r '.bastion_public_ip.value // empty' 2>/dev/null)"
    if [[ -n "${bastion_ip}" && "${bastion_ip}" != "null" ]]; then
        _kof_mode="airgap"
        _kof_bastion_ip="${bastion_ip}"
        _kof_ssh_key="$(echo "${output}" | jq -r '.ssh_key_path.value')"
        [[ -z "${airgap_arg}" ]] && info "Airgap lab detected (bastion ${bastion_ip}) — deploying KOF from the bastion."
    else
        [[ "${airgap_arg}" == "airgap" ]] \
            && die "'t deploy kof ... airgap' requested but no bastion found — deploy the airgap lab first (t deploy lab airgap)."
        _kof_mode="online"
    fi

    if [[ "${_kof_mode}" == "airgap" ]]; then
        # Point KOF at the internal registry: the MKE bundle upload lands every
        # KOF chart/image under <registry>/mke/ (charts at .../mke/charts/kof*).
        # Only auto-derive when the config still holds the upstream default so a
        # deliberate kof_registry override wins.
        if [[ "${kof_registry}" == "registry.mirantis.com/k0rdent-enterprise" ]]; then
            kof_registry="${registry_hostname}/mke"
        fi
        if [[ "${kof_sf_notifier_enabled}" == "true" ]]; then
            warn "kof_sf_notifier_enabled=true in airgap: the private subnet has no internet, so sf-notifier cannot reach Salesforce."
            warn "The Alertmanager route will be wired anyway; expect AlertmanagerFailedToSendAlerts unless sf-notifier has a working egress path."
        fi
        kof_bastion_prep
    fi

    kof_preflight
    kof_ensure_registry_cert_secret
    kof_prepare_grafana_airgap

    local sc
    sc="$(kof_resolve_storageclass)"
    info "KOF deploy: mode=${kof_mode} exec=${_kof_mode} version=${kof_version} storageClass=${sc} kcmNamespace=${kof_kcm_namespace} registry=${kof_registry}"

    # Must run before the chart install so the operator can create collector
    # DaemonSets without being rejected by MKE's admission policy.
    kof_exempt_ucpauthz

    # Grafana access path. Online with the gateway toggle: the gateway needs an
    # NLB listener + SG NodePort rule (terraform) — reconcile infra here so
    # standalone 't deploy kof' also gets them (idempotent — a no-op when
    # 't deploy lab' already applied with the gateway enabled). Airgap: the
    # gateway is AUTO-ENABLED whenever Grafana is (it's the only way to reach
    # Grafana — `t tunnel grafana` → bastion → NodePort ${kof_grafana_nodeport});
    # no terraform needed (internal NLB is bypassed by the tunnel and the SG
    # already opens the NodePort).
    local effective_gateway="${kof_grafana_gateway_enabled}"
    if [[ "${_kof_mode}" == "airgap" ]]; then
        if [[ "${kof_grafana_enabled}" == "true" && "${effective_gateway}" != "true" ]]; then
            info "Airgap: auto-enabling the Grafana gateway (required for 't tunnel grafana' access)."
            effective_gateway="true"
        fi
    elif [[ "${effective_gateway}" == "true" ]]; then
        info "Ensuring NLB listener + SG NodePort for the Grafana gateway (terraform)..."
        write_tfvars false false
        tf_init
        tf_apply
    fi

    local workdir
    workdir="$(mktemp -d "${TMPDIR:-/tmp}/kof-XXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '${workdir}'" RETURN

    cp "${PROJECT_ROOT}/kof/global-values.yaml" "${workdir}/global-values.yaml"
    cp "${PROJECT_ROOT}/kof/profiles/${kof_mode}.yaml" "${workdir}/profile.yaml"
    # Upstream (1.8.x umbrella) baseline for kof-storage/kof-collectors — see the
    # file header; passed first to helm so everything else overrides it.
    cp "${PROJECT_ROOT}/kof/umbrella-defaults.yaml" "${workdir}/umbrella-defaults.yaml"
    # Version-scoped fixes (kof/version-overrides/<major.minor>.yaml, e.g. 1.4.yaml
    # for kof_version=1.4.1). Only for fixes that would CHANGE what another KOF
    # version renders; absent file -> empty overlay, so e.g. 1.8.x is untouched.
    local kof_mm="${kof_version#v}"; kof_mm="${kof_mm%.*}"
    if [[ -f "${PROJECT_ROOT}/kof/version-overrides/${kof_mm}.yaml" ]]; then
        info "Applying KOF ${kof_mm}.x version overlay (kof/version-overrides/${kof_mm}.yaml)..."
        cp "${PROJECT_ROOT}/kof/version-overrides/${kof_mm}.yaml" "${workdir}/version.yaml"
    else
        echo '{}' > "${workdir}/version.yaml"
    fi
    cd "${workdir}"

    # Airgap seam (no-op online): repoint every image to a custom registry.
    if [[ "${kof_registry}" != "registry.mirantis.com/k0rdent-enterprise" ]]; then
        info "Repointing KOF images to ${kof_registry}..."
        sed -i "s#registry.mirantis.com/k0rdent-enterprise#${kof_registry}#g" global-values.yaml
    fi

    # Airgap: hand the registry CA to every Flux HelmRepository the charts create
    # (certSecretRef per the k0rdent Enterprise airgap docs — Flux does NOT share
    # MKE's caData trust). Covers the umbrella's two HelmRepositories
    # (global.helmRepo.spec is merged verbatim into both, incl. victoria-metrics,
    # and kcm.kof.repo.name just points at the umbrella's 'oci-registry' one) and
    # the kgst service-template / istio repos. The secret itself is created by
    # kof_ensure_registry_cert_secret. Edited here in global-values.yaml so the
    # components fan-out below propagates it everywhere, like the sed above.
    if [[ "${_kof_mode}" == "airgap" ]]; then
        yq -i '
            .global.helmRepo.spec.certSecretRef.name = "kof-registry-cert"
          | .["cert-manager-service-template"].repo.spec.certSecretRef.name = "kof-registry-cert"
          | .["envoy-gateway-service-template"].repo.spec.certSecretRef.name = "kof-registry-cert"
          | .["ingress-nginx-service-template"].repo.spec.certSecretRef.name = "kof-registry-cert"
          | .["victoria-metrics-operator-service-template"].repo.spec.certSecretRef.name = "kof-registry-cert"
          | .["k0rdent-istio"].repo.spec.certSecretRef.name = "kof-registry-cert"
          | .istio.repo.spec.certSecretRef.name = "kof-registry-cert"
        ' global-values.yaml
    fi

    # Shrink VictoriaMetrics / VictoriaLogs / VictoriaTraces volumes for lab use.
    SIZE="${kof_storage_size}" yq -i '
        .victoriametrics.vmcluster.spec.vmstorage.storage.volumeClaimTemplate.spec.resources.requests.storage = strenv(SIZE)
      | .victoria-logs-cluster.vlstorage.persistentVolume.size = strenv(SIZE)
      | .victoria-traces-cluster.vtstorage.persistentVolume.size = strenv(SIZE)
    ' global-values.yaml

    # Generate the umbrella-chart components file (verbatim install-doc commands).
    yq -n 'load("global-values.yaml") as $gv
      | "operators mothership regional child storage collectors" / " "
      | map({"key": ("kof-" + .), "value": {"values": $gv}})
      | $gv * from_entries' > global-components.yaml

    yq -i 'load("global-values.yaml") as $gv
      | .kof-regional.values.operators = $gv
      | .kof-regional.values.storage *= $gv
      | .kof-regional.values.collectors = $gv
      | .kof-child.values.operators = $gv
      | .kof-child.values.collectors = $gv
      | .victoria-metrics-operator as $vmo
      | .global as $g
      | .victoria-metrics-operator.values = $vmo
      | .victoria-metrics-operator.values.global = $g' global-components.yaml

    # Runtime overlay — ONLY values that must be computed at deploy time: the
    # resolved StorageClass and the k0rdent (KCM) namespace repointing. The KOF
    # umbrella + mothership charts default every KCM namespace to "kcm-system",
    # but MKE4k's k0rdent Enterprise build runs KCM in ${kof_kcm_namespace};
    # repoint all of them or helm pre-install hooks fail with
    # 'namespaces "kcm-system" not found':
    #   - global.helmRepo.namespace            : umbrella Flux HelmRepository/HelmChart
    #   - kof-mothership.values.kcm.namespace   : KCM integration
    #   - kof-mothership.values.*-service-template.namespace : kgst hooks create a
    #     Flux HelmRepository per ServiceTemplate (cert-manager/ingress-nginx/envoy,
    #     plus victoria-metrics-operator on the KOF 1.4.x line; unknown keys are
    #     ignored by charts that lack the subchart, so this is safe on 1.8.x)
    #   - kof-collectors.values.kcm.namespace + global.clusterNamespace
    # Plus the M2M cluster identity "mothership" (collector labels below; and
    # kof-storage global.clusterName, which KOF 1.4.x uses as the promxy
    # server-group cluster_name — chart default "storage"; 1.8.x hardcodes it)
    # The component SCOPE (what's enabled, the prometheus-node-exporter :9100 fix,
    # the kof-regional/kof-child M2M disable, cluster identity) now lives in the
    # editable kof/profiles/<mode>.yaml overlay copied above — edit that to tune
    # what KOF deploys. This overlay only carries the deploy-time substitutions.
    SC="${sc}" KCM_NS="${kof_kcm_namespace}" yq -n '
        .global.helmRepo.namespace = strenv(KCM_NS)
      | .["kof-mothership"].values.global.storageClass = strenv(SC)
      | .["kof-mothership"].values.kcm.namespace = strenv(KCM_NS)
      | .["kof-mothership"].values["cert-manager-service-template"].namespace = strenv(KCM_NS)
      | .["kof-mothership"].values["ingress-nginx-service-template"].namespace = strenv(KCM_NS)
      | .["kof-mothership"].values["envoy-gateway-service-template"].namespace = strenv(KCM_NS)
      | .["kof-mothership"].values["victoria-metrics-operator-service-template"].namespace = strenv(KCM_NS)
      | .["kof-storage"].values.global.storageClass = strenv(SC)
      | .["kof-storage"].values.global.clusterName = "mothership"
      | .["kof-collectors"].values.kcm.namespace = strenv(KCM_NS)
      | .["kof-collectors"].values.global.clusterNamespace = strenv(KCM_NS)
      | .["kof-collectors"].values["opentelemetry-kube-stack"].defaultCRConfig.config.processors["resource/k8sclustername"].attributes = [
            {"action": "insert", "key": "k8s.cluster.name", "value": "mothership"},
            {"action": "insert", "key": "k8s.cluster.namespace", "value": strenv(KCM_NS)}
        ]
      | .["kof-collectors"].values["opentelemetry-kube-stack"].defaultCRConfig.config.exporters.prometheusremotewrite.external_labels.cluster = "mothership"
      | .["kof-collectors"].values["opentelemetry-kube-stack"].defaultCRConfig.config.exporters.prometheusremotewrite.external_labels.clusterNamespace = strenv(KCM_NS)
    ' > runtime.yaml
    # KOF 1.4.x read path for logs/traces: the mothership's Grafana datasources
    # query multilevel selects (VLCluster kof-mothership-logs-multilevel-select,
    # VTCluster kof-mothership-multilevel-select) whose storage nodes are wired
    # by kof-operator from VMStorageConnection CRs. kof-storage renders those
    # connections (logs + audit-logs, traces) only when its own
    # victoria-{logs,traces}-multilevel-select.enabled is set — default false,
    # so without this kof-logs/kof-traces query nothing (empty Logs dashboards).
    # The traces connection follows the profile's traces storage (lean drops it;
    # a connection to a missing vtselect would just be a dead storage node).
    # KOF 1.8.x has none of these keys/templates (logs go via vlogxy), so this
    # is a no-op there.
    local traces_on
    traces_on="$(yq '.["kof-storage"].values["victoria-traces-cluster"].enabled != false' profile.yaml)"
    TRACES_ON="${traces_on}" yq -i '
        .["kof-storage"].values["victoria-logs-multilevel-select"].enabled = true
      | .["kof-storage"].values["victoria-traces-multilevel-select"].enabled = (strenv(TRACES_ON) == "true")
    ' runtime.yaml

    # KOF 1.4.x adds an audit-logs VictoriaLogs cluster (kof-storage
    # victoriametrics.vlcluster_audit -> VLCluster/audit-logs, fed by the collectors'
    # otlphttp/logs-audit exporter). Its vlstorage PVCs default to 2 x 100Gi and are
    # NOT covered by the global-values size edit above (different key), so size them
    # with the same kof_storage_size. StorageClass already follows kof-storage
    # global.storageClass (the chart copies it in). KOF 1.8.x has no vlcluster_audit,
    # so this is a no-op there. NOTE: STS volumeClaimTemplates are immutable and PVCs
    # can't shrink — on an existing install the old PVC size stays until redeploy.
    SIZE="${kof_storage_size}" yq -i '
        .["kof-storage"].values.victoriametrics.vlcluster_audit.spec.vlstorage.storage.volumeClaimTemplate.spec.resources.requests.storage = strenv(SIZE)
    ' runtime.yaml

    # NOTE: MKE4k is k0s and KOF's default PKI_PATH is already var/lib/k0s, so NO
    # collector env override (PKI_PATH) is needed here. Only non-k0s clusters
    # (e.g. kind -> etc/kubernetes) require it.

    # Persist Alertmanager state on a PVC instead of the chart-default EmptyDir.
    # The mothership's VMAlertmanager (kof-mothership chart key
    # victoriametrics.vmalert.manager.spec -> CR vmalertmanager-cluster) defaults
    # to an EmptyDir at /alertmanager, which holds the notification log AND all
    # SILENCES created via the Grafana/Alertmanager UI. EmptyDir means those are
    # lost on every pod/STS rollout. Giving the operator a volumeClaimTemplate
    # makes it mount a PVC at /alertmanager so customer-created silences survive
    # restarts/upgrades. Always-on: KOF already requires a default StorageClass
    # (every VictoriaMetrics/Logs PVC binds to one — nfs-client in this lab), so
    # this adds no new dependency. storageClassName is intentionally omitted to
    # inherit the cluster default, matching how KOF's own VM PVCs are provisioned.
    # 1Gi is far more than silences + nflog need (KB-scale) and nfs-client allows
    # expansion. NOTE on redeploy: STS volumeClaimTemplates are immutable, so the
    # VM operator recreates the vmalertmanager-cluster STS to apply this — expected
    # on the first deploy that introduces it.
    yq -i '
        .["kof-mothership"].values.victoriametrics.vmalert.manager.spec.storage.volumeClaimTemplate.spec = {
            "accessModes": ["ReadWriteOnce"],
            "resources": {"requests": {"storage": "1Gi"}}
        }
    ' runtime.yaml

    # Retime + raise the severity of the node-down alerts (always-on, every deploy).
    # KubeNodeNotReady / KubeNodeUnreachable default to for=15m, severity=warning. A
    # downed node is high-signal and should be known fast, so drop the dwell to 5m and
    # raise severity to critical (so it routes as critical to whatever receiver the
    # operator wires — see KOF-ON-MKE4.md §7.8). Both fields are dig-templated from
    # .Values.customRules in the kof-mothership chart's
    # templates/prometheus/rules/kubernetes-system-kubelet.yaml:
    #   for:      {{ dig "KubeNodeNotReady" "for" "15m" .Values.customRules }}
    #   severity: {{ dig "KubeNodeNotReady" "severity" "warning" .Values.customRules }}
    # so customRules.<AlertName>.{for,severity} is the surgical override (no group key,
    # no expr redefinition). This is a general sensitivity preference, not reuse-specific,
    # so it lives here (always-on), not in the reuse block below.
    #
    # Also remap Watchdog's severity none -> informational (also dig-templated:
    # severity: {{ dig "Watchdog" "severity" "none" .Values.customRules }} in
    # general.rules.yaml). Watchdog is the always-firing heartbeat; sf-notifier files its
    # Salesforce ticket priority from STATE_MAP[severity.upper()], and "none" isn't a key
    # -> "070 Unknown". "informational" maps to "060 Informational" (NOTE: the key is
    # INFORMATIONAL, not INFO — "info" would also fall to 070 Unknown). Harmless without
    # sf-notifier (just a cosmetic label); does not affect routing (Watchdog routes by
    # alertname, §7.8) or InfoInhibitor (which targets severity=info, not informational).
    yq -i '
        .["kof-mothership"].values.customRules.KubeNodeNotReady.for = "5m"
      | .["kof-mothership"].values.customRules.KubeNodeNotReady.severity = "critical"
      | .["kof-mothership"].values.customRules.KubeNodeUnreachable.for = "5m"
      | .["kof-mothership"].values.customRules.KubeNodeUnreachable.severity = "critical"
      | .["kof-mothership"].values.customRules.Watchdog.severity = "informational"
    ' runtime.yaml

    # Salesforce alert routing (opt-in: kof_sf_notifier_enabled). Sets the mothership
    # VMAlertmanager's configRawYaml so two kinds of alerts reach the sf-notifier webhook
    # (http://sf-notifier:5000/hook): (1) anything with severity critical|warning|error,
    # and (2) the always-firing Watchdog — sf-notifier/Salesforce treats Watchdog as a
    # DEAD-MAN'S-SWITCH (if it stops arriving, monitoring is presumed down), so it must be
    # delivered even though its severity is "none". Watchdog needs its own route (matchers
    # within one route are AND-ed, and its severity is none, so it can't share the severity
    # route). Everything else (other info/none, e.g. InfoInhibitor) falls through to a
    # blackhole sink. send_resolved lets sf-notifier CLOSE the Salesforce ticket on resolve.
    # sf-notifier itself is NOT deployed here — it's a customer-provided chart/image
    # installed by hand (see KOF-ON-MKE4.md §7.8); this only wires the route. Default off,
    # because routing to a missing sf-notifier makes Alertmanager log failed deliveries and
    # fire AlertmanagerFailedToSendAlerts. configRawYaml must be a literal block, so we set
    # it from an env var and force yq's literal style (same as the registry caData handling).
    if [[ "${kof_sf_notifier_enabled}" == "true" ]]; then
        info "Wiring Alertmanager Salesforce route (severity critical|warning|error + Watchdog -> sf-notifier:5000/hook)..."
        local sf_alertmanager_config
        sf_alertmanager_config="$(cat <<'YAML'
global:
  resolve_timeout: 5m
route:
  receiver: blackhole
  group_by: [alertname, promxyCluster, namespace]
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 1h
  routes:
    - receiver: Salesforce
      matchers:
        - severity=~"critical|warning|error"
      continue: false
    - receiver: Salesforce
      matchers:
        - alertname="Watchdog"
      continue: false
receivers:
  - name: blackhole
  - name: Salesforce
    webhook_configs:
      - send_resolved: true
        http_config:
          follow_redirects: true
          enable_http2: true
        url: 'http://sf-notifier:5000/hook'
        max_alerts: 0
YAML
)"
        SF_AM_CFG="${sf_alertmanager_config}" yq -i '
            .["kof-mothership"].values.victoriametrics.vmalert.manager.spec.configRawYaml = strenv(SF_AM_CFG)
          | .["kof-mothership"].values.victoriametrics.vmalert.manager.spec.configRawYaml style="literal"
        ' runtime.yaml
    fi

    # Grafana (on by default in both modes): turn on the grafana-operator + the
    # mothership's Grafana datasources/dashboards/admin-secret. The Grafana
    # *instance* itself is applied separately after install (kof_install_grafana) —
    # the chart does not create it.
    if [[ "${kof_grafana_enabled}" == "true" ]]; then
        yq -i '
            .["kof-operators"].values["grafana-operator"].enabled = true
          | .["kof-mothership"].values.grafana.enabled = true
        ' runtime.yaml
    fi

    # Reuse MKE4's monitoring: drop KOF's own node-exporter DaemonSet, and make
    # KOF's kube-state-metrics emit ONLY the k0rdent custom-resource metrics.
    # KOF's target-allocator already discovers MKE's node-exporter + KSM
    # ServiceMonitors (ns mke) cluster-wide with identical labels, so:
    #   - node-exporter: disable KOF's entirely; node dashboards stay populated
    #     from MKE's exporter (removes the duplicate pod-per-node). Needs the
    #     node-label transform (kof_apply_node_label_transform) since MKE's SM
    #     doesn't set the `node` label KOF's dashboards key on.
    #   - KSM: KOF's is NOT disabled (it uniquely emits kube_customresource_*
    #     for k0rdent CRs that MKE's vanilla KSM lacks) — instead add
    #     --custom-resource-state-only so it stops duplicating the standard
    #     kube_* series, which MKE's KSM then serves alone (no doubled counts).
    #     extraArgs is a list (helm REPLACES it), so the existing config-file arg
    #     must be repeated. Path/arg are chart-pinned to kof_version 1.8.1.
    #   - kube-proxy / coredns: KOF ships its own ServiceMonitor for each AND its
    #     cluster-wide target-allocator also discovers MKE's, so they're
    #     double-scraped. Disable KOF's SMs; MKE's (monitoring-kube-prometheus-*)
    #     remain the single source (verified live: single source after disable).
    #   - apiserver: BOTH KOF's SM (kof-collectors-apiserver) and MKE's
    #     (monitoring-kube-prometheus-apiserver) relabel job=apiserver and scrape
    #     the SAME single endpoint (the kubernetes svc -> apiserver host process),
    #     so the series collapse to one (no double-count — verified live, count=1)
    #     but the heaviest /metrics endpoint in the cluster is scraped twice. This
    #     is a load/noise fix, not an accuracy fix: disabling KOF's SM halves that
    #     scrape and clears the target-allocator "duplicated targets" warning;
    #     MKE's SM remains the single source (KOF's cluster-wide TA still scrapes
    #     it, so the apiserver dashboards stay populated — verified live).
    #   - kubelet/cAdvisor: handled SEPARATELY below (kof_apply_kubelet_dedup,
    #     gated on kof_reuse_mke_kubelet) — it's not a values toggle but a
    #     post-install scrape_config edit on the daemon collectors.
    #   NOT deduped (k0s-pushgateway double-count — known, not yet wired):
    #   - scheduler/controller-manager/etcd: each is scraped TWICE. (1) a DIRECT
    #     scrape on the node IP:secure-port (kube-scheduler :10259, kube-controller-
    #     manager :10257, etcd :2381) — per-controller `instance` labels, full
    #     fidelity; and (2) the k0s metrics-scraper PUSHGATEWAY (ns k0s-system,
    #     --enable-metrics-scraper) which re-exports the same series with the real
    #     target moved to exported_job/exported_instance and `instance` collapsed
    #     to the pushgateway pod. KOF's cluster-wide TA discovers the `k0s`
    #     ServiceMonitor (ns mke) and scrapes the pushgateway, so BOTH copies land
    #     in VM. Unlike apiserver (both copies hit the same endpoint -> collapse to
    #     one series), these carry DIFFERENT `instance` labels and do NOT collapse,
    #     so aggregating panels (sum/rate over a control-plane job) double-count.
    #     Components bind to the node IP (NOT localhost) — verified live: series at
    #     instance=172.31.0.x:10257/10259 — so the direct scrape is the complete,
    #     authoritative source and the pushgateway copy is pure redundancy.
    #     The clean fix is `--enable-metrics-scraper=false`, but MKE HARDCODES
    #     `--enable-metrics-scraper=true` AFTER user installFlags (k0s pflag
    #     last-wins), so it can't be turned off from mke4.yaml. Instead we drop the
    #     pushgateway copies at the collector post-install — see
    #     kof_apply_k0s_pushgateway_dedup() (filter processor on ta-daemon keyed on
    #     exported_job), called alongside kof_apply_node_label_transform below.
    if [[ "${kof_reuse_mke_monitoring}" == "true" ]]; then
        info "Reusing MKE monitoring: disabling KOF's node-exporter + kube-proxy/coredns/apiserver scrapes + KOF KSM custom-resource-only."
        yq -i '
            .["kof-collectors"].values["opentelemetry-kube-stack"].nodeExporter.enabled = false
          | .["kof-collectors"].values["opentelemetry-kube-stack"].kubeProxy.enabled = false
          | .["kof-collectors"].values["opentelemetry-kube-stack"].coreDns.enabled = false
          | .["kof-collectors"].values["opentelemetry-kube-stack"].kubeApiServer.enabled = false
          | .["kof-collectors"].values["opentelemetry-kube-stack"]["kube-state-metrics"].extraArgs = [
                "--custom-resource-state-config-file=/etc/config/crd-metrics-config.yaml",
                "--custom-resource-state-only"
            ]
        ' runtime.yaml

        # Fix etcdMembersDown for reuse-mode scrape topology.
        # The upstream rule (kube-prometheus etcd mixin) is:
        #   max without(endpoint) (
        #     sum without(instance,pod)(up{job=~".*etcd.*"} == bool 0)          <- clause 1
        #     or
        #     count without(To)(sum without(instance,pod)(rate(etcd_network_peer_sent_failures_total[2m])) > 0.01)  <- clause 2
        #   ) > 0
        # RCA (verified live, 3-CP, stop k0s on a controller): clause 1 is ALWAYS a
        # value-0 series (the surviving members), with labels
        # {job,cluster,clusterNamespace,promxyCluster,promxyClusterNamespace}. clause 2's
        # direct-scrape series carries the SAME labels, so PromQL `or` (left wins on a
        # label match) MASKS it -> max(...)>0 is false -> never fires. In a NON-reuse
        # (full) deploy the alert only fires by accident: the k0s-pushgateway re-export of
        # etcd_network_peer_sent_failures_total carries extra provenance labels
        # (container/namespace/service/exported_job/exported_instance) that survive the
        # sum/count and make clause 2's pushgateway copy a DIFFERENT series that escapes the
        # mask. Our reuse-mode pushgateway dedup (kof_apply_k0s_pushgateway_dedup, drops
        # exported_job=etcd) removes that escaping copy -> only the maskable direct-scrape
        # copy remains -> the alert can never fire. (The dead member's own up goes ABSENT,
        # not 0, because its on-node collector dies with the node, so clause 1 can't fire
        # directly either.)
        # FIX: append `> 0` to clause 1 so it is EMPTY when healthy instead of a masking 0,
        # letting clause 2's clean direct-scrape peer-failure series (verified present and
        # sustained on node loss) survive the `or` and fire. Override by same name via the
        # chart's defaultAlertRules surface (Mirantis kof-alerts docs); also drop `for` to
        # 5m (etcd member down is a quorum-risk condition worth knowing about fast, matching
        # the node-down alerts, and the peer-failure signal is steady from the moment the
        # member drops).
        local etcd_members_down_expr='max without(endpoint) ((sum without(instance, pod) (up{job=~".*etcd.*"} == bool 0) > 0) or count without(To) (sum without(instance, pod) (rate(etcd_network_peer_sent_failures_total{job=~".*etcd.*"}[2m])) > 0.01)) > 0'
        EMD_EXPR="${etcd_members_down_expr}" yq -i '
            .["kof-mothership"].values.defaultAlertRules.etcd.etcdMembersDown.expr = strenv(EMD_EXPR)
          | .["kof-mothership"].values.defaultAlertRules.etcd.etcdMembersDown.for = "5m"
        ' runtime.yaml
    fi

    kof_helm_install

    info "Waiting for KOF HelmReleases to become Ready (Flux-driven)..."
    _kof_kexec "kubectl wait --for=condition=Ready helmreleases --all -n kof --timeout=10m" || true
    _kof_kexec "kubectl get hr -n kof" || true
    _kof_kexec "kubectl get pod -n kof" || true

    if [[ "${kof_grafana_enabled}" == "true" ]]; then
        kof_install_grafana
        if [[ "${effective_gateway}" == "true" ]]; then
            kof_install_grafana_gateway
        fi
        if [[ "${kof_reuse_mke_monitoring}" == "true" ]]; then
            kof_add_mke_datasource
        fi
    fi

    # Reuse-MKE-monitoring: relabel MKE's node-exporter series with `node` so the
    # node dashboards (whose Host picker keys on `node`) work after dropping KOF's
    # own node-exporter. Runs regardless of Grafana (it fixes the data in VM).
    if [[ "${kof_reuse_mke_monitoring}" == "true" ]]; then
        kof_apply_node_label_transform
        kof_apply_k0s_pushgateway_dedup
    fi

    # Reuse-MKE-monitoring: drop KOF's duplicate kubelet/cAdvisor scrape so MKE's
    # kubelet ServiceMonitor is the single source (fixes 2x over-reported pod
    # CPU/memory). Opt-out via kof_reuse_mke_kubelet=false (keeps KOF's richer set
    # at the cost of double-counting).
    if [[ "${kof_reuse_mke_monitoring}" == "true" && "${kof_reuse_mke_kubelet}" == "true" ]]; then
        info "Reusing MKE monitoring: deduplicating kubelet/cAdvisor scrapes..."
        kof_apply_kubelet_dedup
    fi

    # Lean: prune the dashboards that have no backing data (tracing/FinOps removed,
    # plus platform/OS-specific clutter). The chart renders every dashboard CR
    # unconditionally, so curation has to happen post-install.
    if [[ "${kof_mode}" == "lean" ]]; then
        kof_prune_dashboards
    fi

    cd "${PROJECT_ROOT}"
    echo ""
    echo -e "  ${BOLD}KOF access (self-monitoring / M2M, mode=${kof_mode}):${RESET}"
    if [[ "${_kof_mode}" == "airgap" ]]; then
        echo -e "    List services:  t connect m1 \"kubectl get svc -n kof\"  (or kubectl on the bastion)"
    else
        echo -e "    List services:  kubectl get svc -n kof"
    fi
    if [[ "${kof_grafana_enabled}" == "true" ]]; then
        if [[ "${_kof_mode}" == "airgap" ]]; then
            echo -e "    Grafana (HTTPS): t tunnel grafana   → https://localhost:${kof_grafana_lb_port}  (self-signed; accept the cert)"
        elif [[ "${effective_gateway}" == "true" ]]; then
            local _lb_dns
            _lb_dns="$(tf_output 2>/dev/null | jq -r '.lb_dns_name.value // empty' 2>/dev/null)"
            echo -e "    Grafana (HTTPS): https://${_lb_dns:-<nlb-dns>}:${kof_grafana_lb_port}  (self-signed; accept the cert)"
            echo -e "                     or https://<node-public-ip>:${kof_grafana_nodeport}"
        else
            echo -e "    Grafana:        kubectl -n kof port-forward svc/grafana-vm-service 3000:3000"
            echo -e "                    then open http://localhost:3000  (dashboards + metrics/logs/traces datasources)"
        fi
        local _gf_user _gf_pass
        _gf_user="$(_kof_kexec "kubectl get secret -n kof grafana-admin-credentials -o jsonpath='{.data.GF_SECURITY_ADMIN_USER}' 2>/dev/null" | base64 -d 2>/dev/null)"
        _gf_pass="$(_kof_kexec "kubectl get secret -n kof grafana-admin-credentials -o jsonpath='{.data.GF_SECURITY_ADMIN_PASSWORD}' 2>/dev/null" | base64 -d 2>/dev/null)"
        if [[ -n "${_gf_user}" && -n "${_gf_pass}" ]]; then
            echo -e "    Grafana login:  ${BOLD}${_gf_user}${RESET} / ${BOLD}${_gf_pass}${RESET}"
        else
            echo -e "    Grafana creds:  kubectl get secret -n kof grafana-admin-credentials -o yaml | yq '{\"user\": .data.GF_SECURITY_ADMIN_USER | @base64d, \"pass\": .data.GF_SECURITY_ADMIN_PASSWORD | @base64d}'"
        fi
    else
        echo -e "    Grafana:        not deployed (set kof_grafana_enabled=true). Built-in VMUI below:"
    fi
    echo -e "    Logs (VMUI):    kubectl -n kof port-forward svc/kof-storage-victoria-logs-cluster-vlselect 9471:9471"
    echo -e "                    then open http://localhost:9471/select/vmui/"
    echo -e "    Metrics (VMUI): kubectl -n kof port-forward svc/vmselect-cluster 8481:8481"
    echo -e "                    then open http://localhost:8481/select/0/vmui/"
    if [[ "${_kof_mode}" == "airgap" ]]; then
        echo -e "                    (airgap: run the port-forwards on the bastion — KUBECONFIG=~/.mke/mke.kubeconf)"
    fi
    if [[ "${kof_reuse_mke_monitoring}" == "true" ]]; then
        echo -e "    MKE reuse:      KOF node-exporter disabled; node metrics scraped from MKE's (ns mke)"
        echo -e "                    'MKE Prometheus' datasource added to Grafana (prometheus-operated.mke:9090)"
    fi
    echo ""
    success "KOF deployed."
    return 0
}

cmd_destroy_kof() {
    load_config

    # Same airgap auto-detection as cmd_deploy_kof: with a bastion present, helm
    # and kubectl only work from there.
    local output bastion_ip
    output="$(tf_output 2>/dev/null)" || die "Could not read terraform output. Has terraform been applied?"
    bastion_ip="$(echo "${output}" | jq -r '.bastion_public_ip.value // empty' 2>/dev/null)"
    if [[ -n "${bastion_ip}" && "${bastion_ip}" != "null" ]]; then
        _kof_mode="airgap"
        _kof_bastion_ip="${bastion_ip}"
        _kof_ssh_key="$(echo "${output}" | jq -r '.ssh_key_path.value')"
    else
        _kof_mode="online"
    fi

    info "Removing KOF (exec=${_kof_mode})..."
    _kof_kexec "helm uninstall kof -n kof" || true
    _kof_kexec "kubectl delete ns kof --wait=false" || true
    warn "If namespace 'kof' hangs in Terminating, PVCs/finalizers may need manual cleanup."
    success "KOF removed."
    return 0
}

# ---------------------------------------------------------------------------
# k0rdent Enterprise UI — rotate password + publish via Envoy gateway
# ---------------------------------------------------------------------------
# MKE4k installs the k0rdent UI (service kcm-k0rdent-ui:3000 in namespace k0rdent)
# but ships it ClusterIP-only with a fixed default basic-auth password. When
# k0rdent_ui_enabled=true, after MKE4k is installed we:
#   1. rotate the UI password to a random value via the Management/kcm object
#      (spec.core.kcm.config.k0rdent-ui.auth.basic.password)
#   2. publish the UI over HTTPS through a dedicated Envoy gateway + NLB listener
#      (same pattern as the KOF Grafana gateway).
# Nothing new is pulled (the UI image, Envoy, cert-manager already exist), so the
# only online/airgap difference is whether kubectl runs locally or on the bastion
# (via _msr_kexec, defined in the MSR4 section below).
# ---------------------------------------------------------------------------

k0rdent_ui_credentials_file() {
    printf '%s\n' "${TERRAFORM_DIR}/k0rdent_ui_credentials.txt"
}

# Get-or-create the random k0rdent UI password; persist to a 0600 creds file.
# Echoes the password on stdout (info messages go to stderr).
ensure_k0rdent_ui_credentials() {
    local creds_file ui_pass
    creds_file="$(k0rdent_ui_credentials_file)"

    if [[ -f "${creds_file}" ]]; then
        ui_pass="$(grep '^password=' "${creds_file}" | cut -d= -f2)"
        [[ -n "${ui_pass}" ]] || die "k0rdent UI credentials file is malformed: ${creds_file}"
        info "Reusing k0rdent UI credentials from $(basename "${creds_file}")" >&2
    else
        ui_pass="$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 20)"
        printf 'username=admin\npassword=%s\n' "${ui_pass}" > "${creds_file}"
        chmod 600 "${creds_file}"
        info "Generated k0rdent UI credentials -> $(basename "${creds_file}")" >&2
    fi

    printf '%s\n' "${ui_pass}"
}

# Verify the cluster is reachable and the Management/kcm object + UI service + gateway
# asset exist. Usage: k0rdent_ui_preflight <mode> <ssh_key> <bastion_ip>
k0rdent_ui_preflight() {
    local mode="$1" ssh_key="$2" bastion_ip="$3"
    command -v yq >/dev/null 2>&1 || die "k0rdent UI requires 'yq' in PATH."
    [[ -f "${PROJECT_ROOT}/k0rdent-ui/k0rdent-ui-gateway.yaml" ]] \
        || die "Missing committed asset ${PROJECT_ROOT}/k0rdent-ui/k0rdent-ui-gateway.yaml."
    _msr_kexec "${mode}" "${ssh_key}" "${bastion_ip}" "kubectl get nodes" >/dev/null 2>&1 \
        || die "Cluster not reachable. Deploy MKE4k first."
    _msr_kexec "${mode}" "${ssh_key}" "${bastion_ip}" "kubectl get management kcm" >/dev/null 2>&1 \
        || die "Management object 'kcm' not found — is this an MKE4k (k0rdent Enterprise) cluster?"
    _msr_kexec "${mode}" "${ssh_key}" "${bastion_ip}" "kubectl get svc -n k0rdent kcm-k0rdent-ui" >/dev/null 2>&1 \
        || die "Service kcm-k0rdent-ui not found in namespace k0rdent."
    return 0
}

# Rotate the k0rdent UI basic-auth password in the Management/kcm object.
# JSON merge patch deep-merges into spec.core.kcm.config.k0rdent-ui, preserving
# sibling keys (enabled stays true; any OIDC config is untouched).
# Usage: k0rdent_ui_rotate_password <mode> <ssh_key> <bastion_ip>
k0rdent_ui_rotate_password() {
    local mode="$1" ssh_key="$2" bastion_ip="$3"
    local ui_pass patch
    ui_pass="$(ensure_k0rdent_ui_credentials)"
    patch="{\"spec\":{\"core\":{\"kcm\":{\"config\":{\"k0rdent-ui\":{\"enabled\":true,\"auth\":{\"basic\":{\"enabled\":true,\"password\":\"${ui_pass}\"}}}}}}}}"

    info "Rotating k0rdent UI password in Management/kcm..."
    _msr_kexec "${mode}" "${ssh_key}" "${bastion_ip}" \
        "kubectl patch management kcm --type merge -p '${patch}'" \
        || die "Failed to patch Management/kcm."

    info "Waiting for the k0rdent UI to roll out the new password..."
    _msr_kexec "${mode}" "${ssh_key}" "${bastion_ip}" \
        "kubectl -n k0rdent rollout status deploy/kcm-k0rdent-ui --timeout=5m" || true
    return 0
}

# Apply the dedicated k0rdent UI Envoy gateway (Issuer/Certificate/EnvoyProxy/Gateway/
# HTTPRoute). Pins the Envoy NodePort to k0rdent_ui_nodeport and fills the cert SANs
# from terraform output. Online: kubectl applies locally; airgap: scp to bastion + apply.
# Usage: k0rdent_ui_install_gateway <mode> <ssh_key> <bastion_ip> <tf_output_json>
k0rdent_ui_install_gateway() {
    local mode="$1" ssh_key="$2" bastion_ip="$3" output="$4"
    local lb_dns
    lb_dns="$(echo "${output}" | jq -r '.lb_dns_name.value // empty')"

    # SANs: NLB DNS + node IPs (public online, private + 127.0.0.1 airgap).
    local -a sans_ip=()
    if [[ "${mode}" == "airgap" ]]; then
        mapfile -t sans_ip < <(echo "${output}" | jq -r '(.controller_private_ips.value // [])[], (.worker_private_ips.value // [])[]' 2>/dev/null)
        sans_ip+=("127.0.0.1")
    else
        mapfile -t sans_ip < <(echo "${output}" | jq -r '(.controller_ips.value // [])[], (.worker_ips.value // [])[]' 2>/dev/null)
    fi

    local gw
    gw="$(mktemp "${TMPDIR:-/tmp}/k0rdent-ui-gw-XXXX.yaml")"
    cp "${PROJECT_ROOT}/k0rdent-ui/k0rdent-ui-gateway.yaml" "${gw}"

    NP="${k0rdent_ui_nodeport}" yq -i '
        (select(.kind == "EnvoyProxy").spec.provider.kubernetes.envoyService.patch.value.spec.ports[0].nodePort)
        = (strenv(NP) | tonumber)
    ' "${gw}"

    # Airgap: pin the Envoy data-plane image (same fix as the KOF Grafana gateway
    # — an unpinned EnvoyProxy falls back to the controller's docker.io default,
    # unpullable from the private subnet). Reuse MKE's own envoy pod image ref.
    if [[ "${mode}" == "airgap" ]]; then
        local envoy_img
        envoy_img="$(_msr_kexec "${mode}" "${ssh_key}" "${bastion_ip}" \
            "kubectl get pods -n mke -l app.kubernetes.io/name=envoy \
            -o jsonpath='{.items[0].spec.containers[?(@.name==\"envoy\")].image}' 2>/dev/null" || true)"
        if [[ -z "${envoy_img}" ]]; then
            envoy_img="${registry_hostname}/mke/envoyproxy/envoy:distroless-v1.37.3"
            warn "Could not discover MKE's envoy data-plane image — falling back to ${envoy_img}."
        fi
        info "Pinning Envoy data-plane image to ${envoy_img} (airgap)."
        EIMG="${envoy_img}" yq -i '
            (select(.kind == "EnvoyProxy").spec.provider.kubernetes.envoyDeployment.container.image) = strenv(EIMG)
        ' "${gw}"
    fi

    yq -i '(select(.kind == "Certificate").spec.dnsNames) = [] | (select(.kind == "Certificate").spec.ipAddresses) = []' "${gw}"
    [[ -n "${lb_dns}" ]] && D="${lb_dns}" yq -i '(select(.kind == "Certificate").spec.dnsNames) += [strenv(D)]' "${gw}"
    local ip
    for ip in "${sans_ip[@]}"; do
        [[ -n "${ip}" ]] && IP="${ip}" yq -i '(select(.kind == "Certificate").spec.ipAddresses) += [strenv(IP)]' "${gw}"
    done
    if [[ -z "${lb_dns}" && ${#sans_ip[@]} -eq 0 ]]; then
        yq -i '(select(.kind == "Certificate").spec.dnsNames) = ["k0rdent-ui.local"]' "${gw}"
    fi

    info "Applying k0rdent UI Envoy gateway (NodePort ${k0rdent_ui_nodeport}, NLB :${k0rdent_ui_lb_port})..."
    if [[ "${mode}" == "airgap" ]]; then
        scp -q -o StrictHostKeyChecking=no -i "${ssh_key}" "${gw}" "ubuntu@${bastion_ip}:/tmp/k0rdent-ui-gw.yaml"
        rm -f "${gw}"
        ssh_node "${ssh_key}" "${bastion_ip}" "
            export KUBECONFIG=~/.mke/mke.kubeconf
            kubectl apply -f /tmp/k0rdent-ui-gw.yaml
            rm -f /tmp/k0rdent-ui-gw.yaml
            kubectl wait --for=condition=Ready certificate/k0rdent-ui -n k0rdent --timeout=2m || true
            kubectl wait --for=condition=Programmed gateway/k0rdent-ui -n k0rdent --timeout=3m || true
        "
    else
        kubectl apply -f "${gw}"
        rm -f "${gw}"
        kubectl wait --for=condition=Ready certificate/k0rdent-ui -n k0rdent --timeout=2m || true
        kubectl wait --for=condition=Programmed gateway/k0rdent-ui -n k0rdent --timeout=3m || true
    fi
    return 0
}

# Print k0rdent UI access info + login. Usage: print_k0rdent_ui_summary <mode> <tf_output_json>
print_k0rdent_ui_summary() {
    local mode="$1" output="$2"
    local ui_user ui_pass creds_file
    creds_file="$(k0rdent_ui_credentials_file)"
    ui_user="$(grep '^username=' "${creds_file}" 2>/dev/null | cut -d= -f2)"
    ui_pass="$(grep '^password=' "${creds_file}" 2>/dev/null | cut -d= -f2)"

    echo ""
    echo -e "  ${BOLD}k0rdent UI (HTTPS, self-signed):${RESET}"
    if [[ "${mode}" == "airgap" ]]; then
        echo -e "    Access:  t tunnel k0rdent-ui   → https://localhost:${k0rdent_ui_lb_port}  (accept the cert)"
    else
        local lb_dns
        lb_dns="$(echo "${output}" | jq -r '.lb_dns_name.value // empty' 2>/dev/null)"
        echo -e "    Access:  https://${lb_dns:-<nlb-dns>}:${k0rdent_ui_lb_port}  (accept the cert)"
        echo -e "             or https://<node-public-ip>:${k0rdent_ui_nodeport}"
    fi
    echo -e "    Login:   ${BOLD}${ui_user:-admin}${RESET} / ${BOLD}${ui_pass:-<see terraform/k0rdent_ui_credentials.txt>}${RESET}"
    echo ""
    return 0
}

cmd_deploy_k0rdent_ui() {
    load_config
    [[ "${k0rdent_ui_enabled}" == "true" ]] || die "k0rdent_ui_enabled is not true in config"

    local output ssh_key bastion_ip mode
    output="$(tf_output 2>/dev/null)" || die "Could not read terraform output. Has terraform been applied?"
    ssh_key="$(echo "${output}" | jq -r '.ssh_key_path.value')"
    bastion_ip="$(echo "${output}" | jq -r '.bastion_public_ip.value // empty' 2>/dev/null)"
    if [[ -n "${bastion_ip}" && "${bastion_ip}" != "null" ]]; then
        mode="airgap"
    else
        mode="online"; bastion_ip=""
    fi

    # The gateway needs an NLB listener + SG NodePort rule (terraform). Reconcile
    # here so standalone 't deploy k0rdent-ui' also gets them (idempotent — a no-op
    # when 't deploy lab' already applied with k0rdent_ui_enabled=true). Preserve the
    # deployed mke3/airgap topology by reading it back from the existing tfvars.
    info "Ensuring NLB listener + SG NodePort for the k0rdent UI gateway (terraform)..."
    local mke3_tf airgap_tf="false"
    [[ "${mode}" == "airgap" ]] && airgap_tf="true"
    mke3_tf="$(grep -E '^mke3_enabled' "${TERRAFORM_DIR}/terraform.tfvars" 2>/dev/null | awk '{print $3}')"
    write_tfvars "${mke3_tf:-false}" "${airgap_tf}"
    tf_init
    tf_apply
    output="$(tf_output)"   # refresh after apply

    k0rdent_ui_preflight "${mode}" "${ssh_key}" "${bastion_ip}"
    k0rdent_ui_rotate_password "${mode}" "${ssh_key}" "${bastion_ip}"
    k0rdent_ui_install_gateway "${mode}" "${ssh_key}" "${bastion_ip}" "${output}"

    print_k0rdent_ui_summary "${mode}" "${output}"
    success "k0rdent UI published."
    return 0
}

cmd_destroy_k0rdent_ui() {
    load_config
    local output ssh_key bastion_ip mode
    output="$(tf_output 2>/dev/null)" || die "Could not read terraform output. Has terraform been applied?"
    ssh_key="$(echo "${output}" | jq -r '.ssh_key_path.value')"
    bastion_ip="$(echo "${output}" | jq -r '.bastion_public_ip.value // empty' 2>/dev/null)"
    if [[ -n "${bastion_ip}" && "${bastion_ip}" != "null" ]]; then
        mode="airgap"
    else
        mode="online"; bastion_ip=""
    fi

    info "Removing k0rdent UI gateway resources..."
    _msr_kexec "${mode}" "${ssh_key}" "${bastion_ip}" \
        "kubectl delete -n k0rdent httproute/k0rdent-ui gateway/k0rdent-ui envoyproxy/k0rdent-ui-nodeport certificate/k0rdent-ui issuer/k0rdent-ui-selfsigned --ignore-not-found" || true
    warn "The rotated UI password stays in Management/kcm (and terraform/k0rdent_ui_credentials.txt)."
    warn "The NLB listener stays until you set k0rdent_ui_enabled=false and re-run 't deploy lab' (terraform)."
    success "k0rdent UI gateway removed."
    return 0
}

# ---------------------------------------------------------------------------
# MKE4k child cluster — k0rdent / CAPI (CAPA) on AWS
# ---------------------------------------------------------------------------
# Follows https://docs.mirantis.com/mke4/4.2.0/tutorials/deploy-mke4-child-cluster/aws/:
#   1. enable the CAPA + k0smotron providers on Management/kcm
#   2. AWS identity: Secret + AWSClusterStaticIdentity + Credential + resource-template CM
#   3. MkeChildConfig -> k0rdent provisions the child in its own CAPA VPC
#   4. wait for READY, pull <name>-kubeconfig -> terraform/child.kubeconfig
# Online MKE4k only (CAPA needs the AWS API). One child per lab: <cluster_name>-child,
# so CAPA's VPC/ELB names can't collide with another user's child.
# The identity reuses the container's AWS credentials (CHILD_AWS_ACCESS_KEY_ID /
# CHILD_AWS_SECRET_ACCESS_KEY override them); no IAM user is created.
# The child's AWS resources belong to CAPA, not terraform, so the child must be
# deleted while the CAPA controllers still run: 't destroy lab' / 't destroy
# cluster' call child_destroy_before_teardown first. The expiry reaper does NOT
# cover child clusters.
# ---------------------------------------------------------------------------

CHILD_PROVIDERS=(cluster-api-provider-aws cluster-api-provider-k0sproject-k0smotron)
CHILD_CRD="mkechildconfigs.mke.mirantis.com"
CHILD_CAPA_TAG_PREFIX="sigs.k8s.io/cluster-api-provider-aws/cluster"

child_kubeconfig_file() { printf '%s\n' "${TERRAFORM_DIR}/child.kubeconfig"; }
child_marker_file()     { printf '%s\n' "${PROJECT_ROOT}/.child-cluster"; }

# -- Child SSH (optional, child_ssh_enabled) ------------------------------------
# The child's nodes stay private (publicIP=false); CAPA only allows SSH into them
# from its bastion's security group, so SSH = a CAPA bastion in the child's public
# subnet, locked to this host's public IP. Machines get the lab's own EC2 key pair
# (${cluster_name}-key / terraform/aws_private.pem) — fixed at child creation.
# Nodes run Amazon Linux 2023 (template imageLookup) -> ec2-user.
CHILD_NODE_SSH_USER="ec2-user"

# CIDR allowed to reach the bastion: child_ssh_allowed_cidr, else this host's
# public IPv4 as /32.
_child_ssh_cidr() {
    if [[ -n "${child_ssh_allowed_cidr}" ]]; then
        printf '%s\n' "${child_ssh_allowed_cidr}"
        return 0
    fi
    local ip
    ip="$(curl -fsS --max-time 10 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]')"
    [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    printf '%s/32\n' "${ip}"
}

# Public IP of the child's CAPA bastion (empty when it has none).
_child_bastion_ip() {
    kubectl -n "${kof_kcm_namespace}" get awsclusters.infrastructure.cluster.x-k8s.io \
        -l "cluster.x-k8s.io/cluster-name=${child_name}" --request-timeout=10s \
        -o jsonpath='{.items[0].status.bastion.publicIp}' 2>/dev/null || true
}

# SSH user of the bastion (CAPA's default bastion AMI is Ubuntu; a custom one may
# be Amazon Linux) — the first that accepts the lab key.
_child_bastion_user() {
    local bip="$1" key="$2" u
    for u in ubuntu ec2-user; do
        ssh -q -i "${key}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o BatchMode=yes -o ConnectTimeout=10 "${u}@${bip}" true </dev/null 2>/dev/null \
            && { printf '%s\n' "${u}"; return 0; }
    done
    return 1
}

# Internal IP of the <idx>-th (1-based, by node name) control-plane (m) or worker (w) node.
_child_node_ip() {
    local role="$1" idx="$2" sel='node-role.kubernetes.io/control-plane'
    [[ "${role}" == "w" ]] && sel='!node-role.kubernetes.io/control-plane'
    kubectl --kubeconfig="$(child_kubeconfig_file)" get nodes -l "${sel}" --sort-by=.metadata.name \
        --request-timeout=15s \
        -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' 2>/dev/null \
        | sed -n "${idx}p"
}

# t connect m<N>-child | w<N>-child | child-bastion [command]
cmd_connect_child() {
    local target="$1" remote_cmd="$2"
    load_config
    local key="${TERRAFORM_DIR}/aws_private.pem" bip user ip
    [[ -f "${key}" ]] || die "SSH key not found at ${key}. Has terraform been applied?"
    [[ -f "$(child_marker_file)" ]] || die "No child cluster deployed ('t deploy child-cluster')."

    bip="$(_child_bastion_ip)"
    if [[ -z "${bip}" ]]; then
        error "The child cluster has no bastion, so its private nodes can't be reached over SSH."
        echo "  Enable it: child_ssh_enabled=true in config, then 't destroy child-cluster' + 't deploy child-cluster'" >&2
        echo "  (the SSH key can only be set when the child is created)." >&2
        echo "  Shell without SSH: kubectl --kubeconfig $(child_kubeconfig_file) debug node/<node> -it --image=busybox -- chroot /host sh" >&2
        exit 1
    fi
    user="$(_child_bastion_user "${bip}" "${key}")" \
        || die "Cannot SSH to the child bastion ${bip}. If your public IP changed, re-run 't deploy child-cluster' to update its allowed CIDR."

    local -a opts=(-q -i "${key}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
    if [[ "${target}" == "child-bastion" ]]; then
        ip="${bip}"
        opts+=(-l "${user}")
    else
        local role="${target:0:1}" idx="${target:1}"
        idx="${idx%-child}"
        ip="$(_child_node_ip "${role}" "${idx}")"
        [[ -n "${ip}" ]] || die "Child node ${target} not found ('t status child' lists the nodes)."
        opts+=(-l "${CHILD_NODE_SSH_USER}"
               -o "ProxyCommand=ssh -q -i ${key} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -W %h:%p ${user}@${bip}")
    fi

    if [[ -n "${remote_cmd}" ]]; then
        info "Running command on ${target} (${ip})..."
        ssh "${opts[@]}" "${ip}" "${remote_cmd}"
    else
        info "Connecting to ${target} (${ip})..."
        ssh "${opts[@]}" "${ip}"
    fi
}

# "30m" / "600s" / "1h" / "90" -> seconds
_duration_to_seconds() {
    case "$1" in
        *s) echo "${1%s}" ;;
        *m) echo $(( ${1%m} * 60 )) ;;
        *h) echo $(( ${1%h} * 3600 )) ;;
        *)  echo "$1" ;;
    esac
}

# Succeeds when the terraform output describes an online MKE4k lab
# (provisioned, no bastion, no MKE3 NLB).
_child_lab_supported() {
    local output="$1"
    [[ -n "$(jq -r '.lb_dns_name.value // empty' <<<"${output}" 2>/dev/null)" ]] || return 1
    [[ "$(detect_deploy_mode "${output}")" == "online" ]] || return 1
    [[ -z "$(jq -r '.mke3_lb_dns_name.value // empty' <<<"${output}" 2>/dev/null)" ]]
}

# AWS credentials for the CAPA identity: CHILD_AWS_* override the container's.
_child_aws_creds() {
    if [[ -n "${CHILD_AWS_ACCESS_KEY_ID:-}" ]]; then
        _child_key="${CHILD_AWS_ACCESS_KEY_ID}"
        _child_secret="${CHILD_AWS_SECRET_ACCESS_KEY:-}"
        _child_token="${CHILD_AWS_SESSION_TOKEN:-}"
    else
        _child_key="${AWS_ACCESS_KEY_ID:-}"
        _child_secret="${AWS_SECRET_ACCESS_KEY:-}"
        _child_token="${AWS_SESSION_TOKEN:-}"
    fi
}

# VPC IDs CAPA created for the child (tag key sigs.k8s.io/.../cluster/<name>*).
_child_capa_vpcs() {
    aws ec2 describe-vpcs --region "${child_region}" \
        --filters "Name=tag-key,Values=${CHILD_CAPA_TAG_PREFIX}/${child_name}*" \
        --query 'Vpcs[].VpcId' --output text 2>/dev/null | sed 's/None//' | xargs
}

child_preflight() {
    local output tool p ns="${kof_kcm_namespace}"
    output="$(tf_output 2>/dev/null || true)"
    _child_lab_supported "${output}" \
        || die "Child clusters need a deployed online MKE4k lab (not airgap / MKE3). Run 't deploy lab' first."
    for tool in kubectl jq yq aws; do
        command -v "${tool}" >/dev/null 2>&1 || die "Child cluster deploy requires '${tool}' in PATH."
    done
    for p in aws-identity.yaml mkechildconfig.yaml; do
        [[ -f "${PROJECT_ROOT}/child-cluster/${p}" ]] || die "Missing committed asset ${PROJECT_ROOT}/child-cluster/${p}."
    done
    [[ -f "${KUBECONFIG}" ]] || die "Kubeconfig not found at ${KUBECONFIG}. Has the cluster been deployed?"
    kubectl get nodes --request-timeout=20s >/dev/null 2>&1 || die "Cluster not reachable. Deploy MKE4k first."
    kubectl get management kcm >/dev/null 2>&1 \
        || die "Management object 'kcm' not found — is this an MKE4k (k0rdent Enterprise) cluster?"
    kubectl get crd "${CHILD_CRD}" >/dev/null 2>&1 \
        || die "CRD ${CHILD_CRD} not found — this MKE4k version does not support child clusters."
    kubectl get ns "${ns}" >/dev/null 2>&1 \
        || die "k0rdent (KCM) namespace '${ns}' not found. Set kof_kcm_namespace in config (check 'kubectl get ns')."

    _child_aws_creds
    [[ -n "${_child_key}" && -n "${_child_secret}" ]] \
        || die "AWS credentials not set. Export AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY (or CHILD_AWS_ACCESS_KEY_ID/CHILD_AWS_SECRET_ACCESS_KEY)."
    if [[ -n "${_child_token}" ]]; then
        warn "Temporary AWS credentials (session token) detected. CAPA keeps using them for the child's"
        warn "lifetime: once they expire, export fresh ones and run 't rotate child-creds' (the destroy"
        warn "commands sync them automatically)."
    fi

    # The mke4k-aws cluster template puts control-plane AND worker machines on this
    # instance profile (from the account's clusterawsadm bootstrap stack); without
    # it machines fail to launch.
    aws iam get-instance-profile --instance-profile-name control-plane.cluster-api-provider-aws.sigs.k8s.io >/dev/null 2>&1 \
        || warn "IAM instance profile control-plane.cluster-api-provider-aws.sigs.k8s.io not found (or not readable) — child machines may fail to launch."

    # CAPA allocates one Elastic IP (NAT gateway) per AZ the child spans.
    local eip_used eip_quota
    eip_used="$(aws ec2 describe-addresses --region "${child_region}" --query 'length(Addresses)' --output text 2>/dev/null || true)"
    eip_quota="$(aws service-quotas get-service-quota --region "${child_region}" --service-code ec2 \
        --quota-code L-0263D0A3 --query 'Quota.Value' --output text 2>/dev/null || true)"
    eip_quota="${eip_quota%%.*}"
    if [[ "${eip_used}" =~ ^[0-9]+$ && "${eip_quota}" =~ ^[0-9]+$ ]] \
        && (( eip_used + child_az_limit > eip_quota )); then
        warn "Elastic IPs in ${child_region}: ${eip_used} of ${eip_quota} used; the child needs ${child_az_limit} more (one per AZ) — CAPA will fail to create NAT gateways."
    fi

    if [[ "${child_ssh_enabled}" == "true" ]]; then
        [[ "${child_region}" == "${region}" ]] \
            || die "child_ssh_enabled reuses the lab's EC2 key pair ${cluster_name}-key, which only exists in ${region}. Set child_region=${region} or child_ssh_enabled=false."
        [[ -f "${TERRAFORM_DIR}/aws_private.pem" ]] || die "SSH key ${TERRAFORM_DIR}/aws_private.pem not found."
        aws ec2 describe-key-pairs --region "${region}" --key-names "${cluster_name}-key" >/dev/null 2>&1 \
            || die "EC2 key pair ${cluster_name}-key not found in ${region}."
        _child_cidr="$(_child_ssh_cidr)" \
            || die "Could not detect this host's public IP (checkip.amazonaws.com). Set child_ssh_allowed_cidr in config."
        [[ "${_child_cidr}" == "0.0.0.0/0" ]] && warn "child_ssh_allowed_cidr=0.0.0.0/0 opens the child bastion's SSH port to the whole internet."
        info "Child SSH: bastion allowed from ${_child_cidr}, key ${cluster_name}-key"
    fi

    # A CAPA VPC for this name that we didn't create (no MkeChildConfig) is a
    # leftover that would collide with the new child's resources.
    if ! kubectl -n "${ns}" get mkechildconfig "${child_name}" >/dev/null 2>&1; then
        local vpcs
        vpcs="$(_child_capa_vpcs)"
        [[ -z "${vpcs}" ]] \
            || die "CAPA VPC(s) for '${child_name}' already exist in ${child_region} (${vpcs}) with no MkeChildConfig — leftovers from a previous child. Delete them first."
    fi
}

# Add the CAPA + k0smotron providers to Management/kcm (only the missing ones —
# a blind JSON-patch 'add' would duplicate entries on re-runs), then wait for
# them to report success in the Management status.
child_enable_providers() {
    local mgmt have p patch ready i
    mgmt="$(kubectl get management kcm -o json)" || die "Failed to read Management/kcm."
    have="$(jq -r '.spec.providers[]?.name' <<<"${mgmt}")"
    local -a missing=()
    for p in "${CHILD_PROVIDERS[@]}"; do
        grep -qxF "${p}" <<<"${have}" || missing+=("${p}")
    done

    if (( ${#missing[@]} )); then
        info "Enabling CAPI providers on Management/kcm: ${missing[*]}"
        if [[ "$(jq '.spec.providers == null' <<<"${mgmt}")" == "true" ]]; then
            patch="$(printf '%s\n' "${missing[@]}" | jq -R '{name: .}' | jq -sc '[{op: "add", path: "/spec/providers", value: .}]')"
        else
            patch="$(printf '%s\n' "${missing[@]}" | jq -R '{op: "add", path: "/spec/providers/-", value: {name: .}}' | jq -sc .)"
        fi
        kubectl patch management kcm --type=json -p "${patch}" >/dev/null || die "Failed to patch Management/kcm."
    else
        info "CAPI providers already enabled: ${CHILD_PROVIDERS[*]}"
    fi

    # Component keys may carry a template suffix, so match by prefix.
    local want; want="$(printf '%s\n' "${CHILD_PROVIDERS[@]}" | jq -R . | jq -sc .)"
    info "Waiting for the providers to become ready (up to 15m)..."
    for (( i = 1; i <= 90; i++ )); do
        ready="$(kubectl get management kcm -o json 2>/dev/null | jq -r --argjson want "${want}" '
            (.status.components // {} | to_entries) as $c
            | [ $want[] as $p | [ $c[] | select(.key | startswith($p)) ] as $m
                | ($m | length > 0) and ($m | all(.value.success == true)) ]
            | all' 2>/dev/null || echo false)"
        if [[ "${ready}" == "true" ]]; then
            info "  providers ready"
            return 0
        fi
        (( i % 6 == 1 )) && echo "  [$(( (i - 1) * 10 ))s] waiting for ${CHILD_PROVIDERS[*]} in Management/kcm status..."
        sleep 10
    done
    warn "Providers not reported ready in Management/kcm status after 15m — continuing."
    warn "Check 'kubectl get management kcm -o yaml' (.status.components) if the next steps fail."
}

# Secret + AWSClusterStaticIdentity + Credential + resource-template ConfigMap.
# Write the current AWS credentials (_child_aws_creds) into the identity secret.
# CAPA re-reads it on every reconcile (its session cache is keyed by a hash of the
# credentials), so an in-place update takes effect without restarting CAPA.
# 'apply' prunes keys from the previous apply, so moving from temporary to
# long-lived keys also drops a stale SessionToken.
_child_apply_identity_secret() {
    local ns="${kof_kcm_namespace}"
    _child_aws_creds
    # Keys go through a process-substitution env file: never in argv or on disk.
    kubectl -n "${ns}" create secret generic aws-cluster-identity-secret \
        --from-env-file=<(
            printf 'AccessKeyID=%s\nSecretAccessKey=%s\n' "${_child_key}" "${_child_secret}"
            if [[ -n "${_child_token}" ]]; then printf 'SessionToken=%s\n' "${_child_token}"; fi
        ) --dry-run=client -o yaml \
        | kubectl label --local -f - k0rdent.mirantis.com/component=kcm -o yaml \
        | kubectl apply -f - >/dev/null
}

# Succeeds when the current child credentials authenticate against AWS.
_child_creds_valid() {
    _child_aws_creds
    [[ -n "${_child_key}" && -n "${_child_secret}" ]] || return 1
    if [[ -n "${_child_token}" ]]; then
        AWS_ACCESS_KEY_ID="${_child_key}" AWS_SECRET_ACCESS_KEY="${_child_secret}" AWS_SESSION_TOKEN="${_child_token}" \
            aws sts get-caller-identity --region "${child_region}" >/dev/null 2>&1
    else
        env -u AWS_SESSION_TOKEN AWS_ACCESS_KEY_ID="${_child_key}" AWS_SECRET_ACCESS_KEY="${_child_secret}" \
            aws sts get-caller-identity --region "${child_region}" >/dev/null 2>&1
    fi
}

# Before a delete: push the current (working) credentials so CAPA isn't stuck
# on expired ones. Best-effort — only when they validate and the identity exists.
_child_sync_identity() {
    kubectl -n "${kof_kcm_namespace}" get secret aws-cluster-identity-secret >/dev/null 2>&1 || return 0
    if _child_creds_valid; then
        _child_apply_identity_secret && info "Synced the current AWS credentials into the child identity secret." \
            || warn "Could not update the child identity secret — CAPA may still use expired credentials."
    else
        warn "Current AWS credentials are missing/invalid — not syncing the child identity secret."
    fi
}

child_apply_identity() {
    local ns="${kof_kcm_namespace}" i rendered

    info "Applying AWS identity secret in ns ${ns} (from the container's AWS credentials)..."
    _child_apply_identity_secret || die "Failed to apply secret ${ns}/aws-cluster-identity-secret."

    rendered="$(NS="${ns}" yq '(select(.metadata.namespace != null) | .metadata.namespace) = strenv(NS)' \
        "${PROJECT_ROOT}/child-cluster/aws-identity.yaml")" || die "Failed to render child-cluster/aws-identity.yaml."

    # AWSClusterStaticIdentity's CRD only appears once CAPA is installed — retry.
    info "Applying AWSClusterStaticIdentity + Credential..."
    for (( i = 1; i <= 20; i++ )); do
        kubectl apply -f - <<<"${rendered}" >/dev/null 2>&1 && break
        (( i == 20 )) && { kubectl apply -f - <<<"${rendered}"; die "Failed to apply the AWS identity (is CAPA installed?)."; }
        sleep 15
    done

    for (( i = 1; i <= 24; i++ )); do
        if [[ "$(kubectl -n "${ns}" get credential aws-cluster-identity-cred -o jsonpath='{.status.ready}' 2>/dev/null)" == "true" ]]; then
            info "  Credential aws-cluster-identity-cred ready"
            return 0
        fi
        sleep 5
    done
    warn "Credential aws-cluster-identity-cred not reported ready after 2m — continuing."
}

child_apply_config() {
    local f
    f="$(mktemp "${TMPDIR:-/tmp}/mkechildconfig-XXXX.yaml")"
    NAME="${child_name}" NS="${kof_kcm_namespace}" VER="${child_version}" REGION="${child_region}" \
    CP="${child_control_plane_count}" W="${child_worker_count}" AZ="${child_az_limit}" yq '
        .metadata.name = strenv(NAME) |
        .metadata.namespace = strenv(NS) |
        .spec.version = strenv(VER) |
        .spec.infrastructure.controlPlaneNumber = (strenv(CP) | tonumber) |
        .spec.infrastructure.workersNumber = (strenv(W) | tonumber) |
        .spec.infrastructure.region = strenv(REGION) |
        .spec.infrastructure.configuration.network.vpc.availabilityZoneUsageLimit = (strenv(AZ) | tonumber)
    ' "${PROJECT_ROOT}/child-cluster/mkechildconfig.yaml" > "${f}" \
        || { rm -f "${f}"; die "Failed to render child-cluster/mkechildconfig.yaml."; }
    if [[ -n "${child_control_plane_flavor}" ]]; then
        T="${child_control_plane_flavor}" yq -i '.spec.infrastructure.configuration.controlPlane.instanceType = strenv(T)' "${f}"
    fi
    if [[ -n "${child_worker_flavor}" ]]; then
        T="${child_worker_flavor}" yq -i '.spec.infrastructure.configuration.worker.instanceType = strenv(T)' "${f}"
    fi

    # SSH. sshKeyName lives in the machine templates and only applies when the
    # child is created, so an existing child keeps the key it was created with;
    # the bastion (and its allowed CIDR) can change at any time.
    local existing key=""
    [[ "${child_ssh_enabled}" == "true" ]] && key="${cluster_name}-key"
    existing="$(kubectl -n "${kof_kcm_namespace}" get mkechildconfig "${child_name}" -o json 2>/dev/null || true)"
    if [[ -n "${existing}" ]]; then
        local key_have
        key_have="$(jq -r '.spec.infrastructure.configuration.sshKeyName // ""' <<<"${existing}")"
        if [[ "${key_have}" != "${key}" ]]; then
            warn "The child's SSH key is fixed at creation (it has: ${key_have:-none}). To change it,"
            warn "recreate the child: 't destroy child-cluster' then 't deploy child-cluster'."
            key="${key_have}"
        fi
    fi
    if [[ -n "${key}" ]]; then
        K="${key}" yq -i '.spec.infrastructure.configuration.sshKeyName = strenv(K)' "${f}"
    fi
    if [[ "${child_ssh_enabled}" == "true" ]]; then
        CIDR="${_child_cidr}" yq -i '
            .spec.infrastructure.configuration.publicIP = false |
            .spec.infrastructure.configuration.bastion = {"enabled": true, "allowedCIDRBlocks": [strenv(CIDR)]}
        ' "${f}"
    else
        yq -i '.spec.infrastructure.configuration.bastion.enabled = false' "${f}"
    fi

    info "Applying MkeChildConfig/${child_name}..."
    kubectl apply -f "${f}" || { rm -f "${f}"; die "Failed to apply MkeChildConfig/${child_name}."; }
    rm -f "${f}"
}

# JSONPath of an MkeChildConfig printer column (READY / STATUS), from the CRD.
_child_printer_path() {
    kubectl get crd "${CHILD_CRD}" -o json 2>/dev/null | jq -r --arg c "$1" '
        [.spec.versions[] | select(.served) | .additionalPrinterColumns[]?
         | select((.name | ascii_upcase) == ($c | ascii_upcase)) | .jsonPath][0] // empty'
}

child_wait_ready() {
    local ns="${kof_kcm_namespace}" name="${child_name}"
    local rpath spath to_sec start line ready status last="" next_beat
    rpath="$(_child_printer_path READY)"
    spath="$(_child_printer_path STATUS)"
    [[ -n "${rpath}" ]] || rpath='.status.conditions[?(@.type=="Ready")].status'
    [[ -n "${spath}" ]] || spath='.status.conditions[?(@.type=="Ready")].message'
    to_sec="$(_duration_to_seconds "${child_ready_timeout}")"
    start="${SECONDS}"; next_beat=$(( SECONDS + 120 ))

    info "Waiting for MkeChildConfig/${name} to become Ready (up to ${child_ready_timeout}; typically 12-15 min)..."
    while (( SECONDS - start < to_sec )); do
        line="$(kubectl -n "${ns}" get mkechildconfig "${name}" --no-headers \
            -o "custom-columns=R:{${rpath}},S:{${spath}}" 2>/dev/null || true)"
        read -r ready status <<<"${line}"
        if [[ "${ready,,}" == "true" ]]; then
            info "  [$(fmt_duration $(( SECONDS - start )))] Ready: ${status}"
            return 0
        fi
        if [[ "${status}" != "${last}" || ${SECONDS} -ge ${next_beat} ]]; then
            echo "  [$(fmt_duration $(( SECONDS - start )))] ready=${ready:-<none>} status=${status:-<none>}"
            last="${status}"; next_beat=$(( SECONDS + 120 ))
        fi
        sleep 15
    done

    error "MkeChildConfig/${name} not Ready after ${child_ready_timeout}. Debug with:"
    echo "  kubectl -n ${ns} describe mkechildconfig ${name}"
    echo "  kubectl -n ${ns} get clusterdeployments,clusters.cluster.x-k8s.io,machines.cluster.x-k8s.io"
    echo "  Infra not ready (VPC/subnets/ELB/EC2)   -> logs of the capa-* and capi-* pods"
    echo "  EC2 running but control plane not ready -> logs of the k0smotron pods"
    echo "  kubectl get pods -A | grep -E 'capa|capi-|k0smotron'"
    echo "  The child stays in place: re-run 't deploy child-cluster' to keep waiting, or 't destroy child-cluster'."
    exit 1
}

# First value of <field> anywhere in the MkeChildConfig (status layout varies
# between releases; the docs only name the fields).
_child_status_field() {
    kubectl -n "${kof_kcm_namespace}" get mkechildconfig "${child_name}" -o json 2>/dev/null \
        | jq -r --arg f "$1" '[.. | objects | .[$f]? | select(type == "string" and . != "")][0] // empty'
}

child_fetch_kubeconfig() {
    local ns="${kof_kcm_namespace}" kc tmp i secret
    kc="$(child_kubeconfig_file)"
    tmp="$(mktemp "${TMPDIR:-/tmp}/child-kubeconfig-XXXX")"
    secret="$(_child_status_field kubeConfigSecret)"
    secret="${secret:-${child_name}-kubeconfig}"
    for (( i = 1; i <= 24; i++ )); do
        kubectl -n "${ns}" get secret "${secret}" -o jsonpath='{.data.value}' 2>/dev/null \
            | base64 -d > "${tmp}" 2>/dev/null || true
        [[ -s "${tmp}" ]] && break
        sleep 5
    done
    [[ -s "${tmp}" ]] || { rm -f "${tmp}"; die "Secret ${ns}/${secret} not found or empty."; }
    install -m 600 "${tmp}" "${kc}"
    rm -f "${tmp}"
    info "Child kubeconfig -> ${kc}"
    kubectl --kubeconfig="${kc}" get nodes -o wide 2>/dev/null \
        || warn "Child API not reachable yet with ${kc} — retry 't status child' in a minute."
}

# -- Child Dex admin user ------------------------------------------------------
# MKE4k creates no Dex admin user on child clusters, so the child UI has no
# usable login. When child_admin_enabled=true we create one
# the same way mkectl does on a standalone cluster: a Dex 'Password' object
# (kubernetes storage, bcrypt hash) on the child, plus the RBAC the management
# cluster gives its own admin. The plain password only lives in
# terraform/child_credentials.txt (chmod 600) — Dex stores just the hash.
CHILD_DEX_NS="mke"
# Dex's kubernetes storage names a Password object idToName(email) =
# lowercase unpadded base32 of (email + FNV-64a of empty input). For "admin":
CHILD_DEX_ADMIN_OBJ="mfsg22lozpzjzzeeeirsk"

child_credentials_file() { printf '%s\n' "${TERRAFORM_DIR}/child_credentials.txt"; }

# htpasswd (apache2-utils) produces the bcrypt hash; install it in the container
# on demand when missing.
_child_ensure_htpasswd() {
    command -v htpasswd >/dev/null 2>&1 && return 0
    if [[ ${EUID} -eq 0 ]] && command -v apt-get >/dev/null 2>&1; then
        info "Installing apache2-utils (htpasswd, for the bcrypt hash)..."
        apt-get update -qq >/dev/null 2>&1 \
            && apt-get install -y -qq --no-install-recommends apache2-utils >/dev/null 2>&1 \
            && return 0
    fi
    return 1
}

# Copy the management cluster's ClusterRoleBindings for its Dex admin onto the
# child. Only the admin subjects are copied, into bindings with our own name
# prefix, so no existing child binding is modified.
# Usage: child_admin_rbac <child-kubeconfig> <admin-userID>
child_admin_rbac() {
    local kc="$1" uid="$2" bindings n role
    bindings="$(kubectl get clusterrolebindings -o json 2>/dev/null | jq -c --arg uid "${uid}" '
        def adm: .kind == "User" and (.name == "admin" or (.name | endswith(":admin"))
                                      or ($uid != "" and (.name | contains($uid))));
        [.items[] | select(any(.subjects[]?; adm))
         | {apiVersion: "rbac.authorization.k8s.io/v1", kind: "ClusterRoleBinding",
            metadata: {name: ("mke4k-lab-child-admin-" + .metadata.name),
                       labels: {"app.kubernetes.io/managed-by": "mke4k-lab"}},
            roleRef: .roleRef, subjects: [.subjects[] | select(adm)]}]')" || bindings="[]"
    n="$(jq length <<<"${bindings:-[]}" 2>/dev/null || echo 0)"
    if (( n == 0 )); then
        warn "No ClusterRoleBinding for the Dex admin found on the management cluster —"
        warn "binding cluster-admin to User 'admin' on the child (may not match its OIDC username claim)."
        bindings='[{"apiVersion":"rbac.authorization.k8s.io/v1","kind":"ClusterRoleBinding","metadata":{"name":"mke4k-lab-child-admin","labels":{"app.kubernetes.io/managed-by":"mke4k-lab"}},"roleRef":{"apiGroup":"rbac.authorization.k8s.io","kind":"ClusterRole","name":"cluster-admin"},"subjects":[{"apiGroup":"rbac.authorization.k8s.io","kind":"User","name":"admin"}]}]'
    fi
    jq '{apiVersion: "v1", kind: "List", items: .}' <<<"${bindings}" \
        | kubectl --kubeconfig="${kc}" apply -f - >/dev/null || return 1
    info "  RBAC: $(jq -r '[.[] | "\(.roleRef.name) -> \([.subjects[].name] | join(","))"] | join("; ")' <<<"${bindings}")"
    for role in $(jq -r '.[] | select(.roleRef.kind == "ClusterRole") | .roleRef.name' <<<"${bindings}"); do
        kubectl --kubeconfig="${kc}" get clusterrole "${role}" >/dev/null 2>&1 \
            || warn "  ClusterRole ${role} does not exist on the child — that binding grants nothing."
    done
}

child_create_admin_user() {
    [[ "${child_admin_enabled}" == "true" ]] || return 0
    local kc creds ns="${CHILD_DEX_NS}" uid="" pass hash i
    kc="$(child_kubeconfig_file)"; creds="$(child_credentials_file)"

    info "Creating the child's Dex admin user (none is created on child clusters by default)..."
    for (( i = 1; i <= 30; i++ )); do
        kubectl --kubeconfig="${kc}" get crd passwords.dex.coreos.com >/dev/null 2>&1 && break
        if (( i == 30 )); then
            warn "Dex Passwords CRD not present on the child after 5m — skipping the admin user."
            return 0
        fi
        sleep 10
    done

    if kubectl --kubeconfig="${kc}" -n "${ns}" get password "${CHILD_DEX_ADMIN_OBJ}" >/dev/null 2>&1; then
        uid="$(kubectl --kubeconfig="${kc}" -n "${ns}" get password "${CHILD_DEX_ADMIN_OBJ}" -o jsonpath='{.userID}' 2>/dev/null || true)"
        if [[ -f "${creds}" ]]; then
            info "  admin user already exists (password in $(basename "${creds}"))"
        else
            warn "  An admin user already exists on the child but wasn't created by t, so its password is unknown."
            warn "  To regenerate: kubectl --kubeconfig ${kc} -n ${ns} delete password ${CHILD_DEX_ADMIN_OBJ}; t deploy child-cluster"
        fi
    else
        _child_ensure_htpasswd \
            || { warn "htpasswd not found (apt-get install apache2-utils) — skipping the child admin user."; return 0; }
        # Reuse the management admin's userID so copied RBAC subjects that embed it stay valid.
        uid="$(kubectl -n "${ns}" get password "${CHILD_DEX_ADMIN_OBJ}" -o jsonpath='{.userID}' 2>/dev/null || true)"
        [[ -n "${uid}" ]] || uid="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen | tr '[:upper:]' '[:lower:]')"
        pass="$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 20)"
        # Password on stdin (-i), not in argv.
        hash="$(printf '%s' "${pass}" | htpasswd -niBC 10 '' | tr -d ':\n')"
        [[ "${hash}" == \$2* ]] || { warn "bcrypt hashing failed — skipping the child admin user."; return 0; }
        # Dex's kubernetes storage keeps the hash as []byte, i.e. base64 in the object.
        kubectl --kubeconfig="${kc}" apply -f - >/dev/null <<EOF || { warn "Failed to create the child Dex admin user."; return 0; }
apiVersion: dex.coreos.com/v1
kind: Password
metadata:
  name: ${CHILD_DEX_ADMIN_OBJ}
  namespace: ${ns}
email: admin
username: admin
userID: ${uid}
hash: $(printf '%s' "${hash}" | base64 | tr -d '\n')
EOF
        ( umask 077; printf 'username=admin\npassword=%s\n' "${pass}" > "${creds}" )
        info "  admin user created -> $(basename "${creds}")"
    fi
    child_admin_rbac "${kc}" "${uid}" || warn "Failed to apply the child admin RBAC."
}

# With SSH enabled, wait (best-effort) for CAPA to report the bastion's public IP.
child_wait_bastion() {
    [[ "${child_ssh_enabled}" == "true" ]] || return 0
    local i
    info "Waiting for the child bastion's public IP..."
    for (( i = 1; i <= 30; i++ )); do
        [[ -n "$(_child_bastion_ip)" ]] && { info "  bastion: $(_child_bastion_ip)"; return 0; }
        sleep 10
    done
    warn "Child bastion has no public IP after 5m — check 'kubectl -n ${kof_kcm_namespace} get awscluster -o yaml' (.status.bastion)."
}

print_child_cluster_summary() {
    local kc; kc="$(child_kubeconfig_file)"
    echo ""
    echo -e "${BOLD}Child cluster: ${child_name}${RESET}  (region ${child_region}, version ${child_version})"
    kubectl -n "${kof_kcm_namespace}" get mkechildconfig "${child_name}" -o wide 2>/dev/null | sed 's/^/  /' || true
    local addr creds; addr="$(_child_status_field externalAddress)"; creds="$(child_credentials_file)"
    [[ -n "${addr}" ]] && echo "  UI:         ${addr}"
    if [[ -f "${creds}" ]]; then
        echo "  UI login:   $(grep '^username=' "${creds}" | cut -d= -f2) / $(grep '^password=' "${creds}" | cut -d= -f2)   (${creds})"
    fi
    echo "  Kubeconfig: ${kc}"
    local bip; bip="$(_child_bastion_ip)"
    if [[ -n "${bip}" ]]; then
        echo "  SSH:        t connect m1-child | w1-child | child-bastion   (bastion ${bip})"
    fi
    echo "  Nodes:      t status child   (or KUBECONFIG=${kc} kubectl get nodes)"
    echo "  Delete:     t destroy child-cluster   ('t destroy lab' does this first automatically)"
    echo ""
}

cmd_deploy_child_cluster() {
    load_config
    child_preflight
    info "Child cluster ${child_name}: ${child_control_plane_count} control plane / ${child_worker_count} worker(s), region=${child_region}, version=${child_version}"
    local start="${SECONDS}"
    child_enable_providers
    child_apply_identity
    child_apply_config
    # Written as soon as the child exists in AWS, so 't destroy lab' knows about
    # it even if the wait below fails or the management cluster later goes away.
    printf '%s\n' "${child_name}" > "$(child_marker_file)"
    child_wait_ready
    child_fetch_kubeconfig
    child_wait_bastion
    child_create_admin_user
    print_child_cluster_summary
    if (( expiry_days > 0 )); then
        warn "Auto-expiry does NOT cover the child cluster: if the lab expires, its CAPA resources"
        warn "(VPC, NAT GW, ELB, EC2) stay in AWS. Run 't destroy child-cluster' or 't destroy lab' first."
    fi
    success "Child cluster ${child_name} ready ($(fmt_duration $(( SECONDS - start ))))."
}

# Prints the child's remaining objects (one per kind) or "?" when the API
# can't be queried — callers must not treat an API error as "gone".
_child_remaining() {
    local name="$1" ns="${kof_kcm_namespace}" out kind
    local -a left=()
    out="$(kubectl -n "${ns}" get mkechildconfig "${name}" --ignore-not-found -o name 2>/dev/null)" || { echo "?"; return; }
    [[ -n "${out}" ]] && left+=("${out}")
    for kind in clusterdeployments.k0rdent.mirantis.com clusters.cluster.x-k8s.io; do
        out="$(kubectl -n "${ns}" get "${kind}" -o name 2>/dev/null)" || { echo "?"; return; }
        out="$(grep -E "/${name}(-|$)" <<<"${out}" || true)"
        [[ -n "${out}" ]] && left+=(${out})
    done
    echo "${left[*]}"
}

# Delete one child and wait until k0rdent/CAPI have removed it (CAPA tears
# down its AWS resources before the CAPI Cluster object goes). Returns 1 on timeout.
_child_delete() {
    local name="$1" ns="${kof_kcm_namespace}" to_sec start left next_beat vpcs
    to_sec="$(_duration_to_seconds "${child_delete_timeout}")"
    _child_sync_identity
    info "Deleting child cluster ${name} (CAPA removes its VPC/ELB/EC2; up to ${child_delete_timeout})..."
    kubectl -n "${ns}" delete mkechildconfig "${name}" --wait=false >/dev/null 2>&1 || true
    start="${SECONDS}"; next_beat="${SECONDS}"
    while (( SECONDS - start < to_sec )); do
        left="$(_child_remaining "${name}")"
        if [[ -z "${left}" ]]; then
            info "  [$(fmt_duration $(( SECONDS - start )))] ${name}: all k0rdent/CAPI objects gone"
            vpcs="$(_child_capa_vpcs)"
            [[ -z "${vpcs}" ]] || warn "CAPA VPC(s) still present for ${name}: ${vpcs} — check the AWS console (tag ${CHILD_CAPA_TAG_PREFIX}/${name})."
            return 0
        fi
        if (( SECONDS >= next_beat )); then
            echo "  [$(fmt_duration $(( SECONDS - start )))] still deleting: ${left}"
            next_beat=$(( SECONDS + 60 ))
        fi
        sleep 15
    done
    error "Child cluster ${name} not deleted after ${child_delete_timeout} (remaining: ${left})."
    echo "  kubectl -n ${ns} get clusters.cluster.x-k8s.io,awsclusters -o wide; logs of the capa-* pods" >&2
    return 1
}

cmd_destroy_child_cluster() {
    load_config
    local ns="${kof_kcm_namespace}"
    _child_lab_supported "$(tf_output 2>/dev/null || true)" \
        || die "Child clusters are only supported on an online MKE4k lab."
    kubectl get nodes --request-timeout=20s >/dev/null 2>&1 || die "Cluster not reachable."
    if kubectl get crd "${CHILD_CRD}" >/dev/null 2>&1 \
        && kubectl -n "${ns}" get mkechildconfig "${child_name}" >/dev/null 2>&1; then
        _child_delete "${child_name}" || die "Child cluster deletion did not finish — re-run 't destroy child-cluster'."
    else
        info "MkeChildConfig ${ns}/${child_name} not found — nothing to delete."
    fi
    rm -f "$(child_marker_file)" "$(child_kubeconfig_file)" "$(child_credentials_file)"
    success "Child cluster removed."
}

# Called by 't destroy lab' / 't destroy cluster' BEFORE tearing down the
# management cluster: deletes every MkeChildConfig so CAPA can still remove
# the children's AWS resources. Dies rather than orphan them.
# T_SKIP_CHILD=1 skips the check.
child_destroy_before_teardown() {
    local ns="${kof_kcm_namespace}" marker output names n
    marker="$(child_marker_file)"
    if [[ "${T_SKIP_CHILD:-}" == "1" ]]; then
        warn "T_SKIP_CHILD=1: not deleting child clusters — their CAPA resources (VPC/ELB/EC2) stay in AWS."
        return 0
    fi
    output="$(tf_output 2>/dev/null || true)"
    _child_lab_supported "${output}" || return 0

    if [[ -f "${KUBECONFIG}" ]] && kubectl get nodes --request-timeout=20s >/dev/null 2>&1; then
        if ! kubectl get crd "${CHILD_CRD}" >/dev/null 2>&1; then
            rm -f "${marker}"
            return 0
        fi
        names="$(kubectl -n "${ns}" get mkechildconfig -o jsonpath='{.items[*].metadata.name}')" \
            || die "Could not list MkeChildConfigs in ${ns}. Re-run, or set T_SKIP_CHILD=1 to skip (child AWS resources would be orphaned)."
        if [[ -n "${names}" ]]; then
            info "Child cluster(s) found: ${names} — deleting them first so CAPA can remove their AWS resources."
            for n in ${names}; do
                _child_delete "${n}" \
                    || die "Child cluster ${n} was not deleted. Fix and re-run, or set T_SKIP_CHILD=1 to skip (its AWS resources would be orphaned)."
            done
        fi
        rm -f "${marker}" "$(child_kubeconfig_file)" "$(child_credentials_file)"
    elif [[ -f "${marker}" ]]; then
        die "A child cluster ($(cat "${marker}")) was deployed, but the management cluster is unreachable, so CAPA can't delete it.
       Restore access and re-run, or set T_SKIP_CHILD=1 and remove its AWS resources by hand
       (tag ${CHILD_CAPA_TAG_PREFIX}/$(cat "${marker}"), region ${child_region})."
    fi
}

# 't rotate child-creds': export fresh AWS credentials, then push them into the
# CAPA identity secret (e.g. after temporary session credentials expired).
cmd_rotate_child_creds() {
    load_config
    _child_lab_supported "$(tf_output 2>/dev/null || true)" \
        || die "Child clusters are only supported on an online MKE4k lab."
    kubectl get nodes --request-timeout=20s >/dev/null 2>&1 || die "Cluster not reachable."
    kubectl -n "${kof_kcm_namespace}" get secret aws-cluster-identity-secret >/dev/null 2>&1 \
        || die "No child identity secret in ${kof_kcm_namespace} — run 't deploy child-cluster' first."
    _child_aws_creds
    [[ -n "${_child_key}" && -n "${_child_secret}" ]] \
        || die "AWS credentials not set. Export AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY[/AWS_SESSION_TOKEN] (or CHILD_AWS_*)."
    _child_creds_valid || die "The exported AWS credentials are rejected by AWS (sts get-caller-identity) — not rotating."
    _child_apply_identity_secret || die "Failed to update ${kof_kcm_namespace}/aws-cluster-identity-secret."
    [[ -n "${_child_token}" ]] && warn "These are temporary credentials too — rotate again before they expire."
    success "Child identity secret updated; CAPA uses the new credentials on its next reconcile."
}

cmd_status_child() {
    load_config
    local kc; kc="$(child_kubeconfig_file)"
    [[ -f "${kc}" ]] || die "Child kubeconfig not found at ${kc}. Run 't deploy child-cluster' first."
    kubectl -n "${kof_kcm_namespace}" get mkechildconfig "${child_name}" 2>/dev/null || true
    info "Child cluster node status:"
    kubectl --kubeconfig="${kc}" get nodes -o wide
}

# ---------------------------------------------------------------------------
# MSR4 (Harbor) deployment — k0rdent ServiceTemplate based
# ---------------------------------------------------------------------------
# Exposed as NodePort 33443 (inside MKE4k default nodePortRange 32768-35535).
# TLS: two-tier PKI (CA + server cert); cert CN = msr.<cluster>.local.
# Simple mode (replicas=1): Harbor's built-in DB + Redis.
# HA mode    (replicas>=2): postgres-operator + redis-operator, 3 mkectl-apply rounds.
# ---------------------------------------------------------------------------

# Run kubectl/helm locally (online) or on bastion via ssh (airgap).
# Usage: _msr_kexec <mode> <ssh_key> <bastion_ip> <shell command...>
_msr_kexec() {
    local mode="$1" ssh_key="$2" bastion_ip="$3"
    shift 3
    if [[ "${mode}" == "airgap" ]]; then
        ssh_node "${ssh_key}" "${bastion_ip}" "export KUBECONFIG=~/.mke/mke.kubeconf; $*"
    else
        bash -c "$*"
    fi
}

# Pulls the current cluster config into local ${TERRAFORM_DIR}/mke4.yaml,
# stripping ANSI INF/WRN log lines emitted by mkectl < v4.1.3.
# Usage: fetch_current_mke4_yaml <online|airgap>
fetch_current_mke4_yaml() {
    local mode="$1"
    local mke4_yaml="${TERRAFORM_DIR}/mke4.yaml"
    local output ssh_key bastion_ip tmp

    info "Fetching current cluster config (mkectl config get, ${mode})..."

    # Stage in a temp file — a failed fetch must not truncate an existing
    # mke4.yaml (it is the deploy input for 't deploy cluster').
    tmp="$(mktemp)"

    if [[ "${mode}" == "airgap" ]]; then
        output="$(tf_output)"
        ssh_key="$(echo "${output}" | jq -r '.ssh_key_path.value')"
        bastion_ip="$(echo "${output}" | jq -r '.bastion_public_ip.value')"
        # `|| true` so a failing mkectl reaches the checks below with a useful
        # message instead of tripping set -e/pipefail silently.
        ssh_node "${ssh_key}" "${bastion_ip}" \
            "export KUBECONFIG=~/.mke/mke.kubeconf; mkectl config get 2>/dev/null" \
            < /dev/null | sed -n '/^apiVersion:/,$p' > "${tmp}" || true
    else
        mkectl config get 2>/dev/null | sed -n '/^apiVersion:/,$p' > "${tmp}" || true
    fi

    [[ -s "${tmp}" ]] \
        || { rm -f "${tmp}"; die "mkectl config get returned empty output. Is the cluster up?"; }
    # Sanity check
    grep -q '^apiVersion:' "${tmp}" \
        || { rm -f "${tmp}"; die "mke4.yaml missing apiVersion header — check mkectl output"; }

    mv "${tmp}" "${mke4_yaml}"
    info "  Wrote ${mke4_yaml} ($(wc -l < "${mke4_yaml}") lines)"
}

# Generates two-tier PKI: CA + server cert with DNS + IP SANs.
# Writes: ${TERRAFORM_DIR}/msr4_ca.crt, msr4_ca.key, msr4_tls.crt, msr4_tls.key
# Regens if CN changed OR if the SAN set changed (supports scale-up).
# Usage: generate_msr4_tls_cert <fqdn> <san_entry>...
#   Each san_entry is pre-formatted: "DNS:name" or "IP:1.2.3.4".
#   The fqdn is always added as DNS:<fqdn> if not already present.
generate_msr4_tls_cert() {
    local fqdn="$1"; shift
    local -a san_inputs=("$@")
    local d="${TERRAFORM_DIR}"

    # Dedupe + sort SAN entries; ensure DNS:<fqdn> is present.
    local -a san_parts=()
    local entry
    local has_fqdn="false"
    while IFS= read -r entry; do
        [[ -z "${entry}" ]] && continue
        san_parts+=("${entry}")
        [[ "${entry}" == "DNS:${fqdn}" ]] && has_fqdn="true"
    done < <(printf '%s\n' "${san_inputs[@]}" | awk 'NF' | sort -u)
    if [[ "${has_fqdn}" == "false" ]]; then
        san_parts=("DNS:${fqdn}" "${san_parts[@]}")
    fi
    local san_want
    san_want="$(IFS=,; echo "${san_parts[*]}")"

    if [[ -f "${d}/msr4_tls.crt" && -f "${d}/msr4_tls.key" && -f "${d}/msr4_ca.crt" ]]; then
        # Compare full SAN (DNS+IPs) normalised
        local existing_san
        existing_san="$(openssl x509 -in "${d}/msr4_tls.crt" -noout -ext subjectAltName 2>/dev/null \
            | grep -Ev '^(X509v3|subjectAltName|$)' \
            | tr -d ' ' \
            | sed 's/Address://g')"
        # openssl prints SANs as "DNS:foo, IP Address:1.2.3.4" — normalise "IP Address:" -> "IP:"
        existing_san="${existing_san//IPAddress:/IP:}"
        existing_san="${existing_san//IP Address:/IP:}"
        # Sort parts for comparison
        local existing_norm
        existing_norm="$(echo "${existing_san}" | tr ',' '\n' | sort -u | paste -sd, -)"
        local want_norm
        want_norm="$(echo "${san_want}" | tr ',' '\n' | sort -u | paste -sd, -)"
        if [[ "${existing_norm}" == "${want_norm}" ]]; then
            info "MSR4 TLS certs already match SANs (${san_want}) — reusing"
            return 0
        fi
        info "Existing MSR4 certs have different SANs — regenerating"
        info "  want:   ${san_want}"
        info "  existing: ${existing_san}"
    fi

    info "Generating MSR4 TLS certs (SANs: ${san_want})..."

    # CA cert
    openssl req -x509 -nodes -days 3650 -newkey rsa:4096 \
        -keyout "${d}/msr4_ca.key" -out "${d}/msr4_ca.crt" \
        -subj "/CN=${fqdn}-ca" 2>/dev/null

    # Server CSR
    openssl req -nodes -newkey rsa:4096 \
        -keyout "${d}/msr4_tls.key" -out "${d}/msr4_tls.csr" \
        -subj "/CN=${fqdn}" 2>/dev/null

    # Sign server cert (CA:FALSE, DNS + IP SANs)
    openssl x509 -req -days 3650 \
        -in "${d}/msr4_tls.csr" \
        -CA "${d}/msr4_ca.crt" -CAkey "${d}/msr4_ca.key" \
        -CAcreateserial -out "${d}/msr4_tls.crt" \
        -extfile <(printf 'subjectAltName=%s\nbasicConstraints=CA:FALSE\n' "${san_want}") \
        2>/dev/null

    rm -f "${d}/msr4_tls.csr"
    success "MSR4 TLS certs written to ${d}/msr4_{ca,tls}.{crt,key}"
}

# Upsert .spec.services[] entry in local mke4.yaml by name. Values are a
# multi-line yaml string forced to literal block style.
# Usage: add_service_to_mke4_yaml <name> <template> <ns> <values_file>
add_service_to_mke4_yaml() {
    local name="$1" template="$2" ns="$3" values_file="$4"
    local mke4_yaml="${TERRAFORM_DIR}/mke4.yaml"

    [[ -f "${mke4_yaml}" ]] || die "mke4.yaml not found. Run fetch_current_mke4_yaml first."
    [[ -f "${values_file}" ]] || die "Values file not found: ${values_file}"

    export SVC_NAME="${name}"
    export SVC_TEMPLATE="${template}"
    export SVC_NS="${ns}"
    export SVC_VALUES
    SVC_VALUES="$(cat "${values_file}")"

    # Robust upsert: ensure services is a sequence, filter OUT any entries
    # matching the name (removes *all* duplicates in case the file accumulated
    # them from prior runs), then append the fresh entry. `map(select(...))`
    # is more reliable across yq versions than `del(... select(...))`.
    yq e -i '.spec.services = (.spec.services // [])' "${mke4_yaml}"
    yq e -i '.spec.services |= map(select(.name != strenv(SVC_NAME)))' "${mke4_yaml}"
    yq e -i '.spec.services += [{
        "name": strenv(SVC_NAME),
        "template": strenv(SVC_TEMPLATE),
        "namespace": strenv(SVC_NS),
        "values": strenv(SVC_VALUES)
    }]' "${mke4_yaml}"
    yq e -i '(.spec.services[] | select(.name == strenv(SVC_NAME)) | .values) style = "literal"' "${mke4_yaml}"

    unset SVC_NAME SVC_TEMPLATE SVC_NS SVC_VALUES
    info "  service ${BOLD}${name}${RESET} -> template=${template} ns=${ns}"
}

# Creates (or no-ops) the 'msr' namespace via kubectl apply.
# Usage: create_msr4_namespace <online|airgap>
create_msr4_namespace() {
    local mode="$1"
    local output="" ssh_key="" bastion_ip=""
    if [[ "${mode}" == "airgap" ]]; then
        output="$(tf_output)"
        ssh_key="$(echo "${output}" | jq -r '.ssh_key_path.value')"
        bastion_ip="$(echo "${output}" | jq -r '.bastion_public_ip.value')"
    fi
    _msr_kexec "${mode}" "${ssh_key}" "${bastion_ip}" \
        "kubectl create namespace msr --dry-run=client -o yaml | kubectl apply -f -"
}

# Creates the msr-tls-cert k8s TLS secret (holds tls.crt, tls.key, ca.crt).
# In airgap mode, SCPs the cert files to /tmp/msr4-bundle/ on bastion first.
# Usage: create_msr4_tls_secret <online|airgap>
create_msr4_tls_secret() {
    local mode="$1"
    local d="${TERRAFORM_DIR}"

    if [[ "${mode}" == "airgap" ]]; then
        local output ssh_key bastion_ip
        output="$(tf_output)"
        ssh_key="$(echo "${output}" | jq -r '.ssh_key_path.value')"
        bastion_ip="$(echo "${output}" | jq -r '.bastion_public_ip.value')"

        ssh_node "${ssh_key}" "${bastion_ip}" "mkdir -p /tmp/msr4-bundle && chmod 700 /tmp/msr4-bundle"
        scp -q -o StrictHostKeyChecking=no -i "${ssh_key}" \
            "${d}/msr4_tls.crt" "${d}/msr4_tls.key" "${d}/msr4_ca.crt" \
            "ubuntu@${bastion_ip}:/tmp/msr4-bundle/"

        ssh_node "${ssh_key}" "${bastion_ip}" "
            export KUBECONFIG=~/.mke/mke.kubeconf
            kubectl -n msr create secret generic msr-tls-cert \
                --from-file=tls.crt=/tmp/msr4-bundle/msr4_tls.crt \
                --from-file=tls.key=/tmp/msr4-bundle/msr4_tls.key \
                --from-file=ca.crt=/tmp/msr4-bundle/msr4_ca.crt \
                --dry-run=client -o yaml | kubectl apply -f -
        "
    else
        kubectl -n msr create secret generic msr-tls-cert \
            --from-file=tls.crt="${d}/msr4_tls.crt" \
            --from-file=tls.key="${d}/msr4_tls.key" \
            --from-file=ca.crt="${d}/msr4_ca.crt" \
            --dry-run=client -o yaml | kubectl apply -f -
    fi
    info "  secret msr/msr-tls-cert applied"
}

# Wait for pods matching label selector in namespace to become Ready.
# Usage: wait_for_pods <online|airgap> <ns> <selector> <desc> <timeout>
wait_for_pods() {
    local mode="$1" ns="$2" selector="$3" desc="$4" timeout="$5"
    local output="" ssh_key="" bastion_ip=""
    if [[ "${mode}" == "airgap" ]]; then
        output="$(tf_output)"
        ssh_key="$(echo "${output}" | jq -r '.ssh_key_path.value')"
        bastion_ip="$(echo "${output}" | jq -r '.bastion_public_ip.value')"
    fi

    # Convert timeout like "600s" / "15m" into integer seconds
    local to_val="${timeout}"
    local to_sec
    case "${to_val}" in
        *s) to_sec="${to_val%s}" ;;
        *m) to_sec=$(( ${to_val%m} * 60 )) ;;
        *h) to_sec=$(( ${to_val%h} * 3600 )) ;;
        *)  to_sec="${to_val}" ;;
    esac
    local max_iter=$(( to_sec / 10 ))
    [[ ${max_iter} -lt 6 ]] && max_iter=6  # minimum ~60s

    info "Waiting for ${desc} (ns=${ns}, ${selector}, up to ${timeout})..."

    # Single polling loop that exits immediately when ready_count == total_count.
    # Prints per-iteration progress so SSH output stays live.
    local poll_cmd="
        for i in \$(seq 1 ${max_iter}); do
            total=\$(kubectl -n '${ns}' get pod -l '${selector}' --no-headers 2>/dev/null | wc -l | tr -d ' ')
            ready=\$(kubectl -n '${ns}' get pod -l '${selector}' \
                -o jsonpath='{range .items[*]}{.status.conditions[?(@.type==\"Ready\")].status} {end}' 2>/dev/null \
                | tr ' ' '\\n' | grep -c True || true)
            if [[ \${total:-0} -gt 0 && \${ready:-0} -eq \${total:-0} ]]; then
                echo \"  [\${i}/${max_iter}] ${desc}: \${ready}/\${total} Ready — done\"
                exit 0
            fi
            echo \"  [\${i}/${max_iter}] ${desc}: \${ready:-0}/\${total:-0} Ready\"
            sleep 10
        done
        echo \"  [timeout] ${desc}: \${ready:-0}/\${total:-0} Ready after ${timeout}\" >&2
        exit 1
    "
    _msr_kexec "${mode}" "${ssh_key}" "${bastion_ip}" "${poll_cmd}" \
        || die "Timed out waiting for ${desc}"
    info "  ${desc} is Ready"
}

# Renders the k0rdent HelmRepository + ServiceTemplate manifests to a local
# temp file, then applies them to the cluster.
# Usage: apply_msr4_k8s_resources <online|airgap> <reg_url>
#   reg_url: for online this is ignored (public URLs used); for airgap pass e.g. "registry.mke4k-lab.local"
apply_msr4_k8s_resources() {
    local mode="$1" reg_url="$2"
    local manifest
    manifest="$(mktemp "${TMPDIR:-/tmp}/msr4-k0rdent-XXXX.yaml")"

    # HelmRepository URL + type (Flux source API)
    # - OCI  : type=oci
    # - HTTP : type omitted (default)
    local pg_url pg_type redis_url redis_type msr_url msr_type
    if [[ "${mode}" == "airgap" ]]; then
        pg_url="oci://${reg_url}/postgres";          pg_type="oci"
        redis_url="oci://${reg_url}/redis";          redis_type="oci"
        msr_url="oci://${reg_url}/harbor";           msr_type="oci"
    else
        pg_url="https://opensource.zalando.com/postgres-operator/charts/postgres-operator"; pg_type=""
        redis_url="https://ot-container-kit.github.io/helm-charts";                         redis_type=""
        msr_url="oci://registry.mirantis.com/harbor/helm";                                  msr_type="oci"
    fi

    _emit_helm_repo() {
        local name="$1" url="$2" type="$3"
        cat <<EOF
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: ${name}
  namespace: k0rdent
  labels:
    k0rdent.mirantis.com/managed: "true"
spec:
  interval: 10m0s
  provider: generic
  url: ${url}
EOF
        if [[ -n "${type}" ]]; then
            echo "  type: ${type}"
        fi
        return 0
    }

    _emit_service_template() {
        local name="$1" chart="$2" version="$3" repo_name="$4"
        cat <<EOF
---
apiVersion: k0rdent.mirantis.com/v1beta1
kind: ServiceTemplate
metadata:
  name: ${name}
  namespace: k0rdent
  annotations:
    helm.sh/resource-policy: keep
spec:
  helm:
    chartSpec:
      chart: ${chart}
      version: ${version}
      interval: 10m0s
      sourceRef:
        kind: HelmRepository
        name: ${repo_name}
EOF
    }

    {
        if [[ "${msr4_replicas}" -ge 2 ]]; then
            _emit_helm_repo "postgres-operator" "${pg_url}"   "${pg_type}"
            _emit_helm_repo "redis-operator"    "${redis_url}" "${redis_type}"
            _emit_service_template "postgres-operator-${msr4_postgres_version}" \
                "postgres-operator" "${msr4_postgres_version}" "postgres-operator"
            _emit_service_template "redis-operator-${msr4_redis_operator_version}" \
                "redis-operator" "${msr4_redis_operator_version}" "redis-operator"
            _emit_service_template "redis-replication-${msr4_redis_replication_version}" \
                "redis-replication" "${msr4_redis_replication_version}" "redis-operator"
        fi
        _emit_helm_repo "msr" "${msr_url}" "${msr_type}"
        _emit_service_template "msr-${msr4_version}" "msr" "${msr4_version}" "msr"
    } > "${manifest}"

    unset -f _emit_helm_repo _emit_service_template

    info "Applying k0rdent HelmRepository + ServiceTemplate CRs..."
    if [[ "${mode}" == "airgap" ]]; then
        local output ssh_key bastion_ip
        output="$(tf_output)"
        ssh_key="$(echo "${output}" | jq -r '.ssh_key_path.value')"
        bastion_ip="$(echo "${output}" | jq -r '.bastion_public_ip.value')"
        scp -q -o StrictHostKeyChecking=no -i "${ssh_key}" \
            "${manifest}" "ubuntu@${bastion_ip}:/tmp/msr4-k0rdent.yaml"
        ssh_node "${ssh_key}" "${bastion_ip}" \
            "export KUBECONFIG=~/.mke/mke.kubeconf; kubectl apply -f /tmp/msr4-k0rdent.yaml"
    else
        kubectl apply -f "${manifest}"
    fi
    rm -f "${manifest}"
    info "  k0rdent MSR4 resources applied"
}

# Run `mkectl apply -f mke4.yaml` — locally for online, on bastion for airgap.
# Usage: mkectl_apply_mode <online|airgap>
mkectl_apply_mode() {
    local mode="$1"
    local mke4_yaml="${TERRAFORM_DIR}/mke4.yaml"
    [[ -f "${mke4_yaml}" ]] || die "mke4.yaml not found — fetch_current_mke4_yaml first"

    local debug_flag=""
    [[ "${debug:-false}" == "true" ]] && debug_flag="-l debug"

    if [[ "${mode}" == "airgap" ]]; then
        mkectl_apply_on_bastion
    else
        info "Running mkectl apply (online)..."
        mkectl ${debug_flag} apply -f "${mke4_yaml}"
    fi
}

# HA (msr4_replicas >= 2) requires at least msr4_replicas workers because
# MKE4k taints controllers (node-role.kubernetes.io/master), so postgres-operator
# (pod anti-affinity), redis-replication (clusterSize), and Harbor (replicas per
# component) can only be scheduled on worker nodes. Fail fast with a clear
# message instead of letting pods sit pending.
msr4_preflight_ha_nodes() {
    if [[ "${msr4_replicas:-1}" -ge 2 ]]; then
        local need="${msr4_replicas}"
        if [[ "${worker_count:-0}" -lt "${need}" ]]; then
            die "HA mode requires worker_count >= msr4_replicas (${need}). Current: worker_count=${worker_count:-0}.
  Controllers are tainted node-role.kubernetes.io/master and cannot host postgres/redis/harbor replicas.
  Fix: set worker_count=${need} (and optionally controller_count=3 for HA control plane) in 'config', then rerun 't deploy lab'."
        fi
    fi
}

# Renders postgres-operator helm values and adds the service entry to mke4.yaml.
# Does NOT apply mkectl or wait — caller runs the batched apply in
# deploy_msr4_ha_backends().
# Usage: prepare_msr4_postgres_service <online|airgap> <image_registry>
prepare_msr4_postgres_service() {
    local mode="$1" image_registry="$2"

    # Image split: online uses upstream repos, airgap uses Harbor
    local pg_img_registry pg_img_repo spilo_image
    if [[ "${mode}" == "airgap" ]]; then
        pg_img_registry="${image_registry}"
        pg_img_repo="postgres/postgres-operator"
        spilo_image="${image_registry}/postgres/spilo:17-4.0-p3"
    else
        pg_img_registry="ghcr.io"
        pg_img_repo="zalando/postgres-operator"
        spilo_image="registry.mirantis.com/msr/spilo:17-4.0-p3-20251117010013"
    fi

    local values_file
    values_file="$(mktemp "${TMPDIR:-/tmp}/msr4-postgres-values-XXXX.yaml")"
    cat > "${values_file}" <<EOF
image:
  registry: "${pg_img_registry}"
  repository: ${pg_img_repo}
  tag: v${msr4_postgres_version}
configGeneral:
  docker_image: "${spilo_image}"
configKubernetes:
  spilo_privileged: false
  spilo_allow_privilege_escalation: false
  enable_pod_antiaffinity: true
installNamespaces: true
EOF

    add_service_to_mke4_yaml "postgres-operator" \
        "postgres-operator-${msr4_postgres_version}" "msr" "${values_file}"
    rm -f "${values_file}"
}

# Creates msr-redis-secret (idempotent), renders redis-operator +
# redis-replication helm values, adds them as services in mke4.yaml. No apply.
# Usage: prepare_msr4_redis_services <online|airgap> <image_registry>
prepare_msr4_redis_services() {
    local mode="$1" image_registry="$2"
    local output="" ssh_key="" bastion_ip=""
    if [[ "${mode}" == "airgap" ]]; then
        output="$(tf_output)"
        ssh_key="$(echo "${output}" | jq -r '.ssh_key_path.value')"
        bastion_ip="$(echo "${output}" | jq -r '.bastion_public_ip.value')"
    fi

    # Generate + persist redis password
    info "Ensuring msr-redis-secret..."
    local pw_file="${TERRAFORM_DIR}/msr4_redis_password.txt"
    [[ -f "${pw_file}" ]] || openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 32 > "${pw_file}"
    local redis_pw
    redis_pw="$(cat "${pw_file}")"

    # Key must be REDIS_PASSWORD (uppercase) — Harbor chart's redis.pwdfromsecret
    # template and redis-replication's secretKey both look up this exact key name.
    if [[ "${mode}" == "airgap" ]]; then
        ssh_node "${ssh_key}" "${bastion_ip}" "
            export KUBECONFIG=~/.mke/mke.kubeconf
            if ! kubectl -n msr get secret msr-redis-secret &>/dev/null; then
                kubectl -n msr create secret generic msr-redis-secret \
                    --from-literal=REDIS_PASSWORD='${redis_pw}'
            fi
        "
    else
        if ! kubectl -n msr get secret msr-redis-secret &>/dev/null; then
            kubectl -n msr create secret generic msr-redis-secret \
                --from-literal=REDIS_PASSWORD="${redis_pw}"
        fi
    fi

    # Image split
    local redis_op_image redis_image
    if [[ "${mode}" == "airgap" ]]; then
        redis_op_image="${image_registry}/redis/redis-operator"
        redis_image="${image_registry}/redis/redis"
    else
        redis_op_image="quay.io/opstree/redis-operator"
        redis_image="quay.io/opstree/redis"
    fi

    local op_values rep_values
    op_values="$(mktemp "${TMPDIR:-/tmp}/msr4-redis-op-values-XXXX.yaml")"
    rep_values="$(mktemp "${TMPDIR:-/tmp}/msr4-redis-rep-values-XXXX.yaml")"

    cat > "${op_values}" <<EOF
redisOperator:
  imageName: ${redis_op_image}
  imageTag: v${msr4_redis_operator_version}
  imagePullPolicy: IfNotPresent
EOF

    # NOTE: redisSecret and storageSpec MUST be nested under redisReplication
    # (OT-Container-Kit chart contract). Top-level placement silently no-ops,
    # leaving Redis with no password, and Harbor fails to AUTH.
    cat > "${rep_values}" <<EOF
redisReplication:
  name: msr-redis
  clusterSize: ${msr4_replicas}
  image: ${redis_image}
  tag: v8.2.2
  imagePullPolicy: IfNotPresent
  redisSecret:
    secretName: msr-redis-secret
    secretKey: REDIS_PASSWORD
  storageSpec:
    volumeClaimTemplate:
      spec:
        storageClassName: nfs-client
        accessModes:
          - ReadWriteOnce
        resources:
          requests:
            storage: 1Gi
EOF

    add_service_to_mke4_yaml "redis-operator" \
        "redis-operator-${msr4_redis_operator_version}" "msr" "${op_values}"
    add_service_to_mke4_yaml "redis-replication" \
        "redis-replication-${msr4_redis_replication_version}" "msr" "${rep_values}"
    rm -f "${op_values}" "${rep_values}"
}

# Applies the postgresql CR (acid.zalan.do/v1) and waits for
# PostgresClusterStatus=Running. Assumes postgres-operator is already Ready.
# Usage: apply_postgresql_cr <online|airgap>
apply_postgresql_cr() {
    local mode="$1"
    local output="" ssh_key="" bastion_ip=""
    if [[ "${mode}" == "airgap" ]]; then
        output="$(tf_output)"
        ssh_key="$(echo "${output}" | jq -r '.ssh_key_path.value')"
        bastion_ip="$(echo "${output}" | jq -r '.bastion_public_ip.value')"
    fi

    info "Creating postgresql CR (msr-postgres)..."
    local pg_cr_file
    pg_cr_file="$(mktemp "${TMPDIR:-/tmp}/msr4-postgresql-XXXX.yaml")"
    cat > "${pg_cr_file}" <<EOF
apiVersion: acid.zalan.do/v1
kind: postgresql
metadata:
  name: msr-postgres
  namespace: msr
spec:
  teamId: msr
  numberOfInstances: ${msr4_replicas}
  postgresql:
    version: "17"
  volume:
    size: ${msr4_storage_size}
    storageClass: nfs-client
  users:
    msr:
      - superuser
      - createdb
  databases:
    registry: msr
  enableLogicalBackup: false
  enableShmVolume: true
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 1000m
      memory: 1Gi
EOF

    if [[ "${mode}" == "airgap" ]]; then
        scp -q -o StrictHostKeyChecking=no -i "${ssh_key}" \
            "${pg_cr_file}" "ubuntu@${bastion_ip}:/tmp/msr4-postgresql.yaml"
        ssh_node "${ssh_key}" "${bastion_ip}" "
            export KUBECONFIG=~/.mke/mke.kubeconf
            kubectl apply -f /tmp/msr4-postgresql.yaml
        "
    else
        kubectl apply -f "${pg_cr_file}"
    fi
    rm -f "${pg_cr_file}"

    info "Waiting for PostgresClusterStatus=Running (up to 15 min)..."
    local wait_cmd="
        export KUBECONFIG=\${KUBECONFIG:-~/.mke/mke.kubeconf}
        for _ in \$(seq 1 90); do
            s=\$(kubectl -n msr get postgresql/msr-postgres -o jsonpath='{.status.PostgresClusterStatus}' 2>/dev/null)
            if [[ \"\${s}\" == 'Running' ]]; then
                echo 'postgres cluster is Running'
                exit 0
            fi
            echo \"  [\${s:-pending}] waiting for postgres...\"
            sleep 10
        done
        echo 'Timed out waiting for postgres cluster' >&2
        exit 1
    "
    _msr_kexec "${mode}" "${ssh_key}" "${bastion_ip}" "${wait_cmd}" \
        || die "postgresql/msr-postgres did not reach Running state"
}

# Option B orchestrator — ROUND 1 of the HA deploy:
# 1. Prepare postgres-operator + redis-operator + redis-replication services
# 2. Single mkectl apply (all three at once)
# 3. Wait for postgres-operator pod
# 4. Apply postgresql CR, wait for PostgresClusterStatus=Running
# 5. Wait for redis-operator + redis-replication pods
# Usage: deploy_msr4_ha_backends <online|airgap> <pg_image_registry> <redis_image_registry>
deploy_msr4_ha_backends() {
    local mode="$1" pg_registry="$2" redis_registry="$3"

    info "HA Round 1 — preparing postgres + redis services..."
    prepare_msr4_postgres_service "${mode}" "${pg_registry}"
    prepare_msr4_redis_services   "${mode}" "${redis_registry}"

    info "HA Round 1 — running mkectl apply (postgres + redis in one shot)..."
    mkectl_apply_mode "${mode}"

    wait_for_pods "${mode}" "msr" "app.kubernetes.io/name=postgres-operator" \
        "postgres-operator pod" "600s"
    apply_postgresql_cr "${mode}"
    wait_for_pods "${mode}" "msr" "name=redis-operator" "redis-operator pod" "600s"
    wait_for_pods "${mode}" "msr" "app=msr-redis" "redis replication pods" "600s"

    success "HA Round 1 complete — postgres + redis ready"
}

# Deploy MSR4 (Harbor) service. Always called (simple + HA).
# Usage: deploy_msr4_service <online|airgap> <fqdn> <image_registry>
#   image_registry: "registry.mirantis.com" (online) or "<reg_host>" (airgap)
deploy_msr4_service() {
    local mode="$1" fqdn="$2" image_registry="$3"
    local admin_pass
    admin_pass="$(ensure_msr4_admin_credentials)"

    info "Deploying MSR4 (Harbor) service (${mode})..."

    local values_file
    values_file="$(mktemp "${TMPDIR:-/tmp}/msr4-harbor-values-XXXX.yaml")"

    # Base (simple) values
    {
        cat <<EOF
expose:
  type: nodePort
  tls:
    enabled: true
    certSource: secret
    secret:
      secretName: msr-tls-cert
  nodePort:
    name: harbor
    ports:
      http:
        port: 80
        nodePort: 33442
      https:
        port: 443
        nodePort: 33443
externalURL: https://${fqdn}:33443
harborAdminPassword: "${admin_pass}"
persistence:
  persistentVolumeClaim:
    registry:
      storageClass: nfs-client
      accessMode: ReadWriteMany
      size: ${msr4_storage_size}
    jobservice:
      storageClass: nfs-client
      accessMode: ReadWriteMany
    database:
      storageClass: nfs-client
      accessMode: ReadWriteOnce
    redis:
      storageClass: nfs-client
      accessMode: ReadWriteOnce
    trivy:
      storageClass: nfs-client
      accessMode: ReadWriteOnce
EOF

        # Airgap: pin all chart images to bastion Harbor via global.registry.
        # Per-component image.repository overrides were ineffective (the Mirantis
        # MSR chart doesn't honor them consistently); global.registry is the
        # canonical hook per the k0rdent MSR4 installation docs.
        if [[ "${mode}" == "airgap" ]]; then
            cat <<EOF
global:
  registry: ${image_registry}/harbor
imagePullPolicy: IfNotPresent
trivy:
  enabled: false
EOF
        fi

        # HA mode overlay
        if [[ "${msr4_replicas}" -ge 2 ]]; then
            cat <<EOF
portal:
  replicas: ${msr4_replicas}
core:
  replicas: ${msr4_replicas}
jobservice:
  replicas: ${msr4_replicas}
registry:
  replicas: ${msr4_replicas}
database:
  type: external
  external:
    sslmode: require
    host: msr-postgres.msr.svc.cluster.local
    port: "5432"
    username: msr
    coreDatabase: registry
    existingSecret: msr.msr-postgres.credentials.postgresql.acid.zalan.do
redis:
  type: external
  external:
    addr: "msr-redis-master:6379"
    existingSecret: msr-redis-secret
EOF
        fi
    } > "${values_file}"

    add_service_to_mke4_yaml "msr" "msr-${msr4_version}" "msr" "${values_file}"
    rm -f "${values_file}"

    mkectl_apply_mode "${mode}"

    wait_for_pods "${mode}" "msr" "component=core" "MSR4 core pod" "900s"
    success "MSR4 (Harbor) deployed"
}

# Airgap — upload MSR4 images + helm charts to bastion Harbor.
# Creates Harbor projects (postgres, redis, harbor), trusts CA in system store
# (so helm push works over TLS), then:
#   - skopeo-copies images in containerized docker (--add-host pattern).
#   - helm-pulls charts, helm-pushes to Harbor OCI.
# Always uploads Harbor chart+images. HA mode also uploads postgres+redis.
upload_msr4_artifacts() {
    load_config
    local output ssh_key bastion_ip bastion_private_ip
    output="$(tf_output)"
    ssh_key="$(echo "${output}" | jq -r '.ssh_key_path.value')"
    bastion_ip="$(echo "${output}" | jq -r '.bastion_public_ip.value')"
    bastion_private_ip="$(echo "${output}" | jq -r '.bastion_private_ip.value')"

    local creds_file="${TERRAFORM_DIR}/registry_credentials.txt"
    [[ -f "${creds_file}" ]] || die "Registry credentials not found. Run 't deploy registry' first."
    local registry_pass
    registry_pass="$(grep '^password=' "${creds_file}" | cut -d= -f2)"

    local reg_host="${registry_hostname}"
    local ha=false
    [[ "${msr4_replicas}" -ge 2 ]] && ha=true

    info "Uploading MSR4 images + charts to ${reg_host} (HA=${ha})..."

    ssh_node "${ssh_key}" "${bastion_ip}" "
        set -euo pipefail

        # --- Install CA into system trust store (one-time) so helm trusts Harbor TLS
        if [[ ! -f /usr/local/share/ca-certificates/msr-registry-ca.crt ]]; then
            sudo cp ~/msr/certs/ca.crt /usr/local/share/ca-certificates/msr-registry-ca.crt
            sudo update-ca-certificates
            echo 'Registry CA installed in system trust store'
        fi

        # --- Install helm if missing
        if ! command -v helm &>/dev/null; then
            echo '>>> Installing helm...'
            curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
        fi

        # --- Create Harbor projects: postgres, redis, harbor
        for proj in postgres redis harbor; do
            if ! curl -sk -u 'admin:${registry_pass}' \
                    \"https://${reg_host}/api/v2.0/projects?name=\${proj}\" | grep -q \"\\\"name\\\":\\\"\${proj}\\\"\"; then
                curl -sk -u 'admin:${registry_pass}' \
                    -X POST \"https://${reg_host}/api/v2.0/projects\" \
                    -H 'Content-Type: application/json' \
                    -d \"{\\\"project_name\\\":\\\"\${proj}\\\",\\\"public\\\":true}\" || true
                echo \"  Created Harbor project: \${proj}\"
            fi
        done

        # --- helm registry login (for chart push)
        echo '${registry_pass}' | helm registry login ${reg_host} -u admin --password-stdin >/dev/null
    "

    # --- Image uploads via skopeo container
    info "Copying images via skopeo..."

    # Build the list of images to copy. Format: src_image|dest_repo:dest_tag
    local -a images=(
        "registry.mirantis.com/harbor/harbor-core:v${msr4_version}|harbor/harbor-core:v${msr4_version}"
        "registry.mirantis.com/harbor/harbor-db:v${msr4_version}|harbor/harbor-db:v${msr4_version}"
        "registry.mirantis.com/harbor/harbor-jobservice:v${msr4_version}|harbor/harbor-jobservice:v${msr4_version}"
        "registry.mirantis.com/harbor/harbor-portal:v${msr4_version}|harbor/harbor-portal:v${msr4_version}"
        "registry.mirantis.com/harbor/harbor-registryctl:v${msr4_version}|harbor/harbor-registryctl:v${msr4_version}"
        "registry.mirantis.com/harbor/nginx-photon:v${msr4_version}|harbor/nginx-photon:v${msr4_version}"
        "registry.mirantis.com/harbor/redis-photon:v${msr4_version}|harbor/redis-photon:v${msr4_version}"
        "registry.mirantis.com/harbor/registry-photon:v${msr4_version}|harbor/registry-photon:v${msr4_version}"
    )
    if [[ "${ha}" == "true" ]]; then
        images+=(
            "ghcr.io/zalando/postgres-operator:v${msr4_postgres_version}|postgres/postgres-operator:v${msr4_postgres_version}"
            "registry.mirantis.com/msr/spilo:17-4.0-p3-20251117010013|postgres/spilo:17-4.0-p3"
            "quay.io/opstree/redis-operator:v${msr4_redis_operator_version}|redis/redis-operator:v${msr4_redis_operator_version}"
            "quay.io/opstree/redis:v8.2.2|redis/redis:v8.2.2"
        )
    fi

    local pair src dest
    for pair in "${images[@]}"; do
        src="${pair%%|*}"
        dest="${pair#*|}"
        info "  copy ${src} -> ${reg_host}/${dest}"
        ssh_node "${ssh_key}" "${bastion_ip}" "
            docker run --rm \
                --add-host '${reg_host}:${bastion_private_ip}' \
                -v /etc/docker/certs.d/${reg_host}/ca.crt:/etc/docker/certs.d/${reg_host}/ca.crt:ro \
                quay.io/skopeo/stable:v1.18.0 copy \
                    --dest-tls-verify=false \
                    --dest-creds 'admin:${registry_pass}' \
                    'docker://${src}' \
                    'docker://${reg_host}/${dest}'
        "
    done

    # --- Helm chart uploads on bastion
    info "Pulling + pushing helm charts..."

    ssh_node "${ssh_key}" "${bastion_ip}" "
        set -euo pipefail
        mkdir -p ~/msr4-charts
        cd ~/msr4-charts

        # Always: msr chart (from OCI). Chart name is 'msr', not 'harbor'.
        if [[ ! -f msr-${msr4_version}.tgz ]]; then
            echo '>>> Pulling msr-${msr4_version}.tgz from registry.mirantis.com...'
            helm pull oci://registry.mirantis.com/harbor/helm/msr --version '${msr4_version}'
        fi
        echo '>>> Pushing msr chart to ${reg_host}/harbor'
        helm push \"msr-${msr4_version}.tgz\" 'oci://${reg_host}/harbor'
    "

    if [[ "${ha}" == "true" ]]; then
        ssh_node "${ssh_key}" "${bastion_ip}" "
            set -euo pipefail
            cd ~/msr4-charts

            # postgres-operator (HTTP repo)
            helm repo add postgres-operator-charts https://opensource.zalando.com/postgres-operator/charts/postgres-operator 2>/dev/null || true
            helm repo update postgres-operator-charts
            if [[ ! -f postgres-operator-${msr4_postgres_version}.tgz ]]; then
                helm pull postgres-operator-charts/postgres-operator --version '${msr4_postgres_version}'
            fi
            echo '>>> Pushing postgres-operator chart to ${reg_host}/postgres'
            helm push \"postgres-operator-${msr4_postgres_version}.tgz\" 'oci://${reg_host}/postgres'

            # redis-operator + redis-replication (HTTP repo)
            helm repo add ot-helm https://ot-container-kit.github.io/helm-charts 2>/dev/null || true
            helm repo update ot-helm
            if [[ ! -f redis-operator-${msr4_redis_operator_version}.tgz ]]; then
                helm pull ot-helm/redis-operator --version '${msr4_redis_operator_version}'
            fi
            if [[ ! -f redis-replication-${msr4_redis_replication_version}.tgz ]]; then
                helm pull ot-helm/redis-replication --version '${msr4_redis_replication_version}'
            fi
            echo '>>> Pushing redis-operator + redis-replication charts to ${reg_host}/redis'
            helm push \"redis-operator-${msr4_redis_operator_version}.tgz\" 'oci://${reg_host}/redis'
            helm push \"redis-replication-${msr4_redis_replication_version}.tgz\" 'oci://${reg_host}/redis'
        "
    fi

    success "MSR4 artifacts uploaded to ${reg_host}"
}

# Pretty-printed MSR4 deploy summary.
# Usage: print_msr4_summary <online|airgap> <fqdn>
print_msr4_summary() {
    local mode="$1" fqdn="$2"
    local output
    output="$(tf_output 2>/dev/null)" || return

    local creds_file admin_pass
    creds_file="$(msr4_credentials_file)"
    admin_pass="$(grep '^password=' "${creds_file}" 2>/dev/null | cut -d= -f2 || true)"
    [[ -n "${admin_pass}" ]] || admin_pass="(see $(basename "${creds_file}"))"

    local W=80
    local SEP; SEP="$(printf '═%.0s' $(seq 1 ${W}))"
    bline() {
        # Truncate overlong lines rather than overrun the frame
        local t="$1"
        if [[ ${#t} -gt ${W} ]]; then
            t="${t:0:$((W - 1))}…"
        fi
        printf "║%-${W}s║\n" "${t}"
    }
    cline() {
        local t="$1" lp rp
        lp=$(( (W - ${#t}) / 2 ))
        rp=$(( W - ${#t} - lp ))
        printf "║%*s%s%*s║\n" $lp "" "$t" $rp ""
    }
    sep() { printf "╠%s╣\n" "${SEP}"; }

    local ha_str="Simple (replicas=1)"
    [[ "${msr4_replicas}" -ge 2 ]] && ha_str="HA (replicas=${msr4_replicas})"

    local ctrl_pub_dns=""
    ctrl_pub_dns="$(echo "${output}" | jq -r '.controller_public_dns.value[0]? // empty' 2>/dev/null)"

    echo ""
    printf "╔%s╗\n" "${SEP}"
    cline "MSR4 (Harbor) -- Deployment Complete"
    sep
    bline "$(printf '  %-14s %s' 'Version'   "${msr4_version}")"
    bline "$(printf '  %-14s %s' 'Mode'      "${ha_str}")"
    bline "$(printf '  %-14s %s' 'Namespace' "msr")"
    bline "$(printf '  %-14s %s' 'TLS CN'    "${fqdn}")"
    sep
    bline "  Access"
    if [[ "${mode}" == "airgap" ]]; then
        bline "    SSH tunnel:  t tunnel msr4"
        bline "    URL:         https://${fqdn}:8444"
        bline "                 https://localhost:8444   (TLS validates via 127.0.0.1 SAN)"
        bline "    /etc/hosts:  127.0.0.1  ${fqdn}"
    else
        bline "    URL:         https://${fqdn}:33443"
        if [[ -n "${ctrl_pub_dns}" ]]; then
            bline "                 https://${ctrl_pub_dns}:33443"
        fi
        bline "    /etc/hosts:  <node-public-ip>  ${fqdn}"
        bline "    (cert SANs cover all node IPs + public DNS names)"
    fi
    sep
    bline "  Credentials"
    bline "    user: admin"
    bline "    pass: ${admin_pass}"
    bline "    file: $(basename "${creds_file}")"
    printf "╚%s╝\n" "${SEP}"
    echo ""
}

# Online MSR4 deploy: runs kubectl/helm locally against the public NLB.
cmd_deploy_msr4() {
    load_config
    [[ "${msr4_enabled}" == "true" ]] || die "msr4_enabled is not true in config"
    msr4_preflight_ha_nodes

    ensure_mkectl

    local kc="${KUBECONFIG}"
    [[ -f "${kc}" ]] || die "kubeconfig not found at ${kc}. Deploy the cluster first."

    local output
    output="$(tf_output 2>/dev/null)" || die "Could not read terraform output. Has terraform been applied?"

    local bastion_ip=""
    bastion_ip="$(echo "${output}" | jq -r '.bastion_public_ip.value // empty' 2>/dev/null)"
    [[ -z "${bastion_ip}" || "${bastion_ip}" == "null" ]] || \
        die "This is an airgap cluster — use 't deploy msr4 airgap' instead."

    info "Preflight: verify nfs-client StorageClass..."
    kubectl get sc nfs-client >/dev/null 2>&1 \
        || die "StorageClass 'nfs-client' not found. Set nfs_enabled=true and run 't deploy nfs' first."

    local fqdn="msr.${cluster_name}.local"

    # Cert SANs: public IPs + public EC2 DNS names of every node. Both
    # https://<ip>:33443 AND https://ec2-...amazonaws.com:33443 validate.
    local -a sans=()
    while IFS= read -r _entry; do
        [[ -n "${_entry}" ]] && sans+=("IP:${_entry}")
    done < <(echo "${output}" | jq -r '.controller_ips.value[], .worker_ips.value[]' 2>/dev/null)
    while IFS= read -r _entry; do
        [[ -n "${_entry}" ]] && sans+=("DNS:${_entry}")
    done < <(echo "${output}" | jq -r '.controller_public_dns.value[]? // empty, .worker_public_dns.value[]? // empty' 2>/dev/null)

    fetch_current_mke4_yaml online
    create_msr4_namespace online
    generate_msr4_tls_cert "${fqdn}" "${sans[@]}"
    create_msr4_tls_secret online
    apply_msr4_k8s_resources online ""

    # HA path: Round 1 does postgres + redis together (option B — single mkectl apply),
    # then Round 2 (deploy_msr4_service) does msr. Simple path skips Round 1.
    if [[ "${msr4_replicas}" -ge 2 ]]; then
        deploy_msr4_ha_backends online "ghcr.io" "quay.io/opstree"
    fi

    deploy_msr4_service online "${fqdn}" "registry.mirantis.com"

    print_msr4_summary online "${fqdn}"
}

# Airgap MSR4 deploy: uploads images+charts to bastion Harbor, runs
# kubectl/mkectl on bastion (NLB is internal).
cmd_deploy_msr4_airgap() {
    load_config
    [[ "${msr4_enabled}" == "true" ]] || die "msr4_enabled is not true in config"
    msr4_preflight_ha_nodes

    local output ssh_key bastion_ip
    output="$(tf_output 2>/dev/null)" || die "Could not read terraform output. Has terraform been applied?"
    ssh_key="$(echo "${output}" | jq -r '.ssh_key_path.value')"
    bastion_ip="$(echo "${output}" | jq -r '.bastion_public_ip.value // empty' 2>/dev/null)"

    [[ -n "${bastion_ip}" && "${bastion_ip}" != "null" ]] \
        || die "No bastion found — did you mean 't deploy msr4' (online)?"

    info "Preflight: kubeconfig + nfs-client on bastion..."
    ssh_node "${ssh_key}" "${bastion_ip}" "
        set -e
        [[ -f ~/.mke/mke.kubeconf ]] || { echo 'mke.kubeconf not on bastion'; exit 1; }
        export KUBECONFIG=~/.mke/mke.kubeconf
        kubectl get sc nfs-client >/dev/null || { echo 'nfs-client StorageClass missing'; exit 1; }
    " || die "Airgap preflight failed. Ensure cluster + NFS are deployed first."

    local fqdn="msr.${cluster_name}.local"

    # Airgap SANs: private IPs + private EC2 DNS (reachable from bastion)
    # + 127.0.0.1 so 't tunnel msr4 -> https://127.0.0.1:8444' validates too.
    local -a sans=("IP:127.0.0.1")
    while IFS= read -r _entry; do
        [[ -n "${_entry}" ]] && sans+=("IP:${_entry}")
    done < <(echo "${output}" | jq -r '.controller_private_ips.value[], .worker_private_ips.value[]' 2>/dev/null)
    while IFS= read -r _entry; do
        [[ -n "${_entry}" ]] && sans+=("DNS:${_entry}")
    done < <(echo "${output}" | jq -r '.controller_private_dns.value[]? // empty, .worker_private_dns.value[]? // empty' 2>/dev/null)

    upload_msr4_artifacts
    fetch_current_mke4_yaml airgap
    generate_msr4_tls_cert "${fqdn}" "${sans[@]}"
    create_msr4_namespace airgap
    create_msr4_tls_secret airgap
    apply_msr4_k8s_resources airgap "${registry_hostname}"

    # HA path: Round 1 does postgres + redis together (option B — single mkectl apply),
    # then Round 2 (deploy_msr4_service) does msr. Simple path skips Round 1.
    if [[ "${msr4_replicas}" -ge 2 ]]; then
        deploy_msr4_ha_backends airgap "${registry_hostname}" "${registry_hostname}"
    fi

    deploy_msr4_service airgap "${fqdn}" "${registry_hostname}"

    print_msr4_summary airgap "${fqdn}"
}

cmd_status() {
    local kc="${KUBECONFIG}"
    if [[ ! -f "${kc}" ]]; then
        die "Kubeconfig not found at ${kc}. Has the cluster been deployed?"
    fi
    info "Cluster node status:"
    kubectl --kubeconfig="${kc}" get nodes -o wide
}

cmd_show_nodes() {
    load_config
    local output
    output="$(tf_output 2>/dev/null)" || die "Could not read terraform output. Has terraform been applied?"

    local lb_dns ssh_key
    lb_dns="$(echo "${output}" | jq -r '.lb_dns_name.value' 2>/dev/null || echo "(unknown)")"
    ssh_key="$(echo "${output}" | jq -r '.ssh_key_path.value' 2>/dev/null || echo "terraform/aws_private.pem")"

    # Detect airgap mode
    local bastion_pub_ip bastion_priv_ip
    bastion_pub_ip="$(echo "${output}" | jq -r '.bastion_public_ip.value // empty' 2>/dev/null)"
    bastion_priv_ip="$(echo "${output}" | jq -r '.bastion_private_ip.value // empty' 2>/dev/null)"
    local is_airgap=false
    [[ -n "${bastion_pub_ip}" && "${bastion_pub_ip}" != "null" && "${bastion_pub_ip}" != "" ]] && is_airgap=true

    if [[ "${is_airgap}" == "true" ]]; then
        echo -e "\n${BOLD}Bastion / Registry:${RESET}"
        echo "  ${bastion_pub_ip} (public)   ssh -i ${ssh_key} ubuntu@${bastion_pub_ip}"
        echo "  ${bastion_priv_ip} (private)  registry: https://${registry_hostname}/mke"

        local ctrl_ips wkr_ips
        ctrl_ips="$(echo "${output}" | jq -r '.controller_private_ips.value[]' 2>/dev/null || echo "(none)")"
        wkr_ips="$(echo "${output}" | jq -r '.worker_private_ips.value[]' 2>/dev/null || echo "(none)")"

        echo -e "\n${BOLD}Controllers (private):${RESET}"
        echo "${ctrl_ips}" | while read -r ip; do
            echo "  ${ip}   t connect m<N>  (via bastion ProxyJump)"
        done

        echo -e "\n${BOLD}Workers (private):${RESET}"
        echo "${wkr_ips}" | while read -r ip; do
            echo "  ${ip}   t connect w<N>  (via bastion ProxyJump)"
        done
    else
        local controller_ips worker_ips
        controller_ips="$(echo "${output}" | jq -r '.controller_ips.value[]' 2>/dev/null || echo "(none)")"
        worker_ips="$(echo "${output}" | jq -r '.worker_ips.value[]' 2>/dev/null || echo "(none)")"

        echo -e "\n${BOLD}Controllers:${RESET}"
        echo "${controller_ips}" | while read -r ip; do
            echo "  ${ip}   ssh -i ${ssh_key} $(node_ssh_user)@${ip}"
        done

        echo -e "\n${BOLD}Workers:${RESET}"
        echo "${worker_ips}" | while read -r ip; do
            echo "  ${ip}   ssh -i ${ssh_key} $(node_ssh_user)@${ip}"
        done
    fi

    # NFS server
    local nfs_priv_ip nfs_pub_ip
    nfs_priv_ip="$(echo "${output}" | jq -r '.nfs_server_private_ip.value // empty' 2>/dev/null)"
    nfs_pub_ip="$(echo "${output}" | jq -r '.nfs_server_public_ip.value // empty' 2>/dev/null)"
    if [[ -n "${nfs_priv_ip}" && "${nfs_priv_ip}" != "" ]]; then
        echo -e "\n${BOLD}NFS Server:${RESET}"
        if [[ "${is_airgap}" == "true" ]]; then
            echo "  ${nfs_priv_ip} (private)  t connect nfs  (via bastion ProxyJump)"
        else
            echo "  ${nfs_pub_ip} (public)   t connect nfs"
            echo "  ${nfs_priv_ip} (private)"
        fi
    fi

    echo -e "\n${BOLD}MKE4k Load Balancer:${RESET}"
    echo "  https://${lb_dns}"

    local mke3_lb_dns
    mke3_lb_dns="$(echo "${output}" | jq -r '.mke3_lb_dns_name.value' 2>/dev/null || echo "")"
    if [[ -n "${mke3_lb_dns}" ]]; then
        echo -e "\n${BOLD}MKE3 Load Balancer:${RESET}"
        echo "  https://${mke3_lb_dns}"
    fi
    echo ""
}

# Reprint the deploy summary box on demand (e.g. after 't deploy nfs' finished
# a lab that failed mid-deploy, or just to look up credentials/URLs again).
# _T_* timers are all 0 outside a live deploy, so the Timing section is
# skipped (each print_* function only renders it when _T_TERRAFORM > 0).
cmd_show_summary() {
    load_config
    local output
    output="$(tf_output 2>/dev/null)" || die "Could not read terraform output. Has terraform been applied?"

    local bastion_ip mke3_lb_dns
    bastion_ip="$(echo "${output}" | jq -r '.bastion_public_ip.value // empty' 2>/dev/null)"
    mke3_lb_dns="$(echo "${output}" | jq -r '.mke3_lb_dns_name.value // empty' 2>/dev/null)"
    local is_airgap=false is_mke3=false
    [[ -n "${bastion_ip}" ]] && is_airgap=true
    [[ -n "${mke3_lb_dns}" ]] && is_mke3=true

    if [[ "${is_mke3}" == "true" && "${is_airgap}" == "true" ]]; then
        print_mke3_airgap_deploy_summary
    elif [[ "${is_mke3}" == "true" ]]; then
        print_mke3_deploy_summary
    elif [[ "${is_airgap}" == "true" ]]; then
        print_airgap_deploy_summary
    else
        print_deploy_summary
    fi
}

# ---------------------------------------------------------------------------
# Tunnel — SSH port-forward for airgap UIs
# ---------------------------------------------------------------------------
cmd_tunnel() {
    local target="${1:-}"
    load_config
    local output
    output="$(tf_output 2>/dev/null)" || die "Could not read terraform output. Has terraform been applied?"

    local ssh_key bastion_pub_ip bastion_priv_ip lb_dns mke3_lb_dns
    ssh_key="$(echo "${output}" | jq -r '.ssh_key_path.value')"
    bastion_pub_ip="$(echo "${output}" | jq -r '.bastion_public_ip.value // empty' 2>/dev/null)"
    bastion_priv_ip="$(echo "${output}" | jq -r '.bastion_private_ip.value // empty' 2>/dev/null)"
    lb_dns="$(echo "${output}" | jq -r '.lb_dns_name.value' 2>/dev/null)"
    mke3_lb_dns="$(echo "${output}" | jq -r '.mke3_lb_dns_name.value // empty' 2>/dev/null)"

    [[ -n "${bastion_pub_ip}" && "${bastion_pub_ip}" != "null" ]] || \
        die "Tunnel requires an airgap deployment with a bastion host."

    case "${target}" in
        dashboard)
            info "Tunnelling MKE4k Dashboard → https://localhost:3000"
            info "  (via bastion ${bastion_pub_ip} → NLB ${lb_dns}:443)"
            info "  Press Ctrl-C to stop."
            ssh -o StrictHostKeyChecking=no -i "${ssh_key}" \
                -L "0.0.0.0:3000:${lb_dns}:443" -N "ubuntu@${bastion_pub_ip}"
            ;;
        mke3)
            [[ -n "${mke3_lb_dns}" && "${mke3_lb_dns}" != "null" ]] || \
                die "MKE3 NLB not found. Was terraform applied with mke3_enabled=true?"
            info "Tunnelling MKE3 Dashboard → https://localhost:3000"
            info "  (via bastion ${bastion_pub_ip} → MKE3 NLB ${mke3_lb_dns}:443)"
            info "  Press Ctrl-C to stop."
            ssh -o StrictHostKeyChecking=no -i "${ssh_key}" \
                -L "0.0.0.0:3000:${mke3_lb_dns}:443" -N "ubuntu@${bastion_pub_ip}"
            ;;
        registry)
            info "Harbor Registry is publicly accessible — no tunnel needed."
            info "  Open: https://${bastion_pub_ip}"
            ;;
        msr4)
            local ctrl_priv_ip
            ctrl_priv_ip="$(echo "${output}" | jq -r '.controller_private_ips.value[0] // empty' 2>/dev/null)"
            [[ -n "${ctrl_priv_ip}" && "${ctrl_priv_ip}" != "null" ]] \
                || die "No controller private IP found. Is this an airgap cluster?"
            info "Tunnelling MSR4 → https://localhost:8444"
            info "  (via bastion ${bastion_pub_ip} → controller ${ctrl_priv_ip}:33443)"
            info "  Remember: add '127.0.0.1 msr.${cluster_name}.local' to /etc/hosts for TLS to validate."
            info "  Press Ctrl-C to stop."
            ssh -o StrictHostKeyChecking=no -i "${ssh_key}" \
                -L "0.0.0.0:8444:${ctrl_priv_ip}:33443" -N "ubuntu@${bastion_pub_ip}"
            ;;
        k0rdent-ui)
            local ctrl_priv_ip
            ctrl_priv_ip="$(echo "${output}" | jq -r '.controller_private_ips.value[0] // empty' 2>/dev/null)"
            [[ -n "${ctrl_priv_ip}" && "${ctrl_priv_ip}" != "null" ]] \
                || die "No controller private IP found. Is this an airgap cluster?"
            info "Tunnelling k0rdent UI → https://localhost:${k0rdent_ui_lb_port}"
            info "  (via bastion ${bastion_pub_ip} → controller ${ctrl_priv_ip}:${k0rdent_ui_nodeport})"
            info "  Press Ctrl-C to stop."
            ssh -o StrictHostKeyChecking=no -i "${ssh_key}" \
                -L "0.0.0.0:${k0rdent_ui_lb_port}:${ctrl_priv_ip}:${k0rdent_ui_nodeport}" -N "ubuntu@${bastion_pub_ip}"
            ;;
        grafana)
            local ctrl_priv_ip
            ctrl_priv_ip="$(echo "${output}" | jq -r '.controller_private_ips.value[0] // empty' 2>/dev/null)"
            [[ -n "${ctrl_priv_ip}" && "${ctrl_priv_ip}" != "null" ]] \
                || die "No controller private IP found. Is this an airgap cluster?"
            info "Tunnelling KOF Grafana → https://localhost:${kof_grafana_lb_port}"
            info "  (via bastion ${bastion_pub_ip} → controller ${ctrl_priv_ip}:${kof_grafana_nodeport})"
            info "  Press Ctrl-C to stop."
            ssh -o StrictHostKeyChecking=no -i "${ssh_key}" \
                -L "0.0.0.0:${kof_grafana_lb_port}:${ctrl_priv_ip}:${kof_grafana_nodeport}" -N "ubuntu@${bastion_pub_ip}"
            ;;
        "")
            echo ""
            echo -e "${BOLD}Available tunnels:${RESET}"
            echo ""
            echo "  t tunnel dashboard    MKE4k Dashboard → https://localhost:3000"
            echo "  t tunnel mke3         MKE3 Dashboard  → https://localhost:3000"
            echo "  t tunnel msr4         MSR4 Harbor UI  → https://localhost:8444"
            echo "  t tunnel k0rdent-ui   k0rdent UI      → https://localhost:${k0rdent_ui_lb_port}"
            echo "  t tunnel grafana      KOF Grafana     → https://localhost:${kof_grafana_lb_port}"
            echo ""
            echo -e "${BOLD}Harbor Registry (no tunnel needed — publicly accessible):${RESET}"
            echo "  https://${bastion_pub_ip}"
            echo ""
            echo -e "${BOLD}Or run tunnels manually:${RESET}"
            echo ""
            echo "  # MKE4k Dashboard (via NLB)"
            echo "  ssh -i ${ssh_key} -L 0.0.0.0:3000:${lb_dns}:443 -N ubuntu@${bastion_pub_ip}"
            echo ""
            if [[ -n "${mke3_lb_dns}" && "${mke3_lb_dns}" != "null" ]]; then
                echo "  # MKE3 Dashboard (via MKE3 NLB)"
                echo "  ssh -i ${ssh_key} -L 0.0.0.0:3000:${mke3_lb_dns}:443 -N ubuntu@${bastion_pub_ip}"
                echo ""
            fi
            local ctrl_priv_ip
            ctrl_priv_ip="$(echo "${output}" | jq -r '.controller_private_ips.value[0] // empty' 2>/dev/null)"
            if [[ -n "${ctrl_priv_ip}" && "${ctrl_priv_ip}" != "null" ]]; then
                echo "  # MSR4 Harbor (via controller NodePort)"
                echo "  ssh -i ${ssh_key} -L 0.0.0.0:8444:${ctrl_priv_ip}:33443 -N ubuntu@${bastion_pub_ip}"
                echo ""
                if [[ "${k0rdent_ui_enabled:-false}" == "true" ]]; then
                    echo "  # k0rdent UI (via controller NodePort)"
                    echo "  ssh -i ${ssh_key} -L 0.0.0.0:${k0rdent_ui_lb_port}:${ctrl_priv_ip}:${k0rdent_ui_nodeport} -N ubuntu@${bastion_pub_ip}"
                    echo ""
                fi
                if [[ "${kof_enabled:-false}" == "true" ]]; then
                    echo "  # KOF Grafana (via controller NodePort)"
                    echo "  ssh -i ${ssh_key} -L 0.0.0.0:${kof_grafana_lb_port}:${ctrl_priv_ip}:${kof_grafana_nodeport} -N ubuntu@${bastion_pub_ip}"
                    echo ""
                fi
            fi
            echo "  # Kubernetes API (for local kubectl)"
            echo "  ssh -i ${ssh_key} -L 0.0.0.0:6443:${lb_dns}:6443 -N ubuntu@${bastion_pub_ip}"
            echo ""
            if [[ -t 0 ]]; then
                echo -e "${CYAN}Note: inside Docker, start with -p 3000:3000 -p 8443:8443 -p 8444:8444 -p 8445:8445${RESET}"
            fi
            ;;
        *)
            die "Unknown tunnel target: ${target}. Try: dashboard, mke3, msr4, k0rdent-ui, grafana, registry"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Client bundle
# ---------------------------------------------------------------------------

cmd_gen_client_bundle() {
    load_config

    local output ssh_key bastion_ip
    output="$(tf_output)"
    ssh_key="$(echo "${output}" | jq -r '.ssh_key_path.value')"

    # Detect airgap
    bastion_ip="$(echo "${output}" | jq -r '.bastion_public_ip.value // empty' 2>/dev/null)"
    local is_airgap=false
    [[ -n "${bastion_ip}" && "${bastion_ip}" != "null" && "${bastion_ip}" != "" ]] && is_airgap=true

    # MKE4k — just print kubeconfig path
    if [[ "${1:-mke3}" != "mke3" ]]; then
        info "MKE4k kubeconfig is at: ${HOME}/.mke/mke.kubeconf"
        info "Usage: export KUBECONFIG=${HOME}/.mke/mke.kubeconf"
        return 0
    fi

    # MKE3 — generate client bundle
    if [[ "${is_airgap}" == "true" ]]; then
        # Airgap: run on bastion
        info "Generating MKE3 client bundle on bastion (airgap)..."
        ssh_node "${ssh_key}" "${bastion_ip}" "launchpad client-config -a -c ~/launchpad.yaml"

        # Find the bundle directory on bastion
        local bundle_dir
        bundle_dir="$(ssh_node "${ssh_key}" "${bastion_ip}" "ls -d /home/ubuntu/.mirantis-launchpad/cluster/*/bundle/admin 2>/dev/null | head -1")"
        [[ -n "${bundle_dir}" ]] || die "Client bundle not found on bastion."

        # Source env.sh on bastion and print KUBECONFIG info
        info "Client bundle downloaded to bastion: ${bundle_dir}"
        info "To use it, SSH to bastion and run:"
        echo ""
        echo "  t connect bastion"
        echo "  cd ${bundle_dir}"
        echo "  source env.sh"
        echo "  kubectl get nodes"
        echo ""
    else
        # Online: run locally
        local bundle_dir
        bundle_dir="$(ensure_mke3_client_bundle)"

        success "Client bundle downloaded to: ${bundle_dir}"
        echo ""
        echo "  To activate, run:"
        echo ""
        echo "    cd ${bundle_dir} && source env.sh"
        echo ""
    fi
}

# ---------------------------------------------------------------------------
# t config — read and update the configuration of the RUNNING cluster
# ---------------------------------------------------------------------------
# mke4 (default): `mkectl config get` / `mkectl apply -f`, file terraform/mke4.yaml
# mke3:           GET/PUT /api/ucp/config-toml, file terraform/mke3-config.toml
# Both auto-detect airgap and run through the bastion when needed.

# The file a given variant reads and writes.
config_target_file() {
    case "${1}" in
        mke3) mke3_config_file ;;
        *)    printf '%s\n' "${TERRAFORM_DIR}/mke4.yaml" ;;
    esac
}

# Suffix appended to the hint commands printed back to the user ("" for mke4).
_config_hint_suffix() {
    [[ "${1}" == "mke3" ]] && printf ' mke3\n' || printf '\n'
}

cmd_config_get() {
    local variant="${1:-mke4}"
    load_config

    local mode target suffix
    mode="$(detect_deploy_mode)"
    target="$(config_target_file "${variant}")"
    suffix="$(_config_hint_suffix "${variant}")"

    if [[ "${variant}" == "mke3" ]]; then
        mke3_config_get "${mode}"
        success "Wrote ${target} ($(wc -l < "${target}") lines)"
    else
        [[ "${mode}" == "airgap" ]] || ensure_mkectl
        fetch_current_mke4_yaml "${mode}"
        warn "This is the same file 't deploy cluster' generates — it will be regenerated on the next deploy."
    fi

    echo ""
    echo "  Edit it, then push it back with:"
    echo -e "    ${CYAN}t config apply${suffix}${RESET}"
    echo "  Or do both in one step:"
    echo -e "    ${CYAN}t config edit${suffix}${RESET}"
    echo ""
}

# Shared tail of `apply` and `edit`: back up, confirm, push.
# Usage: _config_push <variant> <mode> <target>
_config_push() {
    local variant="${1}" mode="${2}" target="${3}"

    [[ -e /dev/tty ]] \
        || die "Applying a config change needs an interactive terminal to confirm."

    warn "Applying a config change restarts MKE components — expect a brief API interruption."
    local answer
    read -r -p "$(echo -e "  ${BOLD}Apply ${target} to the running cluster?${RESET} [y/N] ")" answer < /dev/tty
    case "${answer}" in
        [yY]|[yY][eE][sS]) ;;
        *) info "Skipping — nothing was applied."; return 0 ;;
    esac

    # For MKE3 the PUT is a raw API call with no server-side history, so grab a
    # fresh copy of the *running* config first — that is the rollback point.
    if [[ "${variant}" == "mke3" ]]; then
        info "Backing up the running config to $(basename "${target}").bak..."
        mke3_config_get "${mode}" "${target}.bak"
    else
        cp "${target}" "${target}.bak"
    fi

    if [[ "${variant}" == "mke3" ]]; then
        mke3_config_apply "${mode}" "${target}"
    else
        [[ "${mode}" == "airgap" ]] || ensure_mkectl
        mkectl_apply_mode "${mode}"
    fi

    success "Config applied. Previous version kept at $(basename "${target}").bak"
}

cmd_config_apply() {
    local variant="${1:-mke4}"
    load_config

    local mode target suffix
    mode="$(detect_deploy_mode)"
    target="$(config_target_file "${variant}")"
    suffix="$(_config_hint_suffix "${variant}")"

    [[ -s "${target}" ]] || die "${target} not found or empty. Run 't config get${suffix}' first."

    _config_push "${variant}" "${mode}" "${target}"
}

cmd_config_edit() {
    local variant="${1:-mke4}"
    load_config

    [[ -t 0 ]] || die "'t config edit' needs an interactive terminal. Use 't config get' + 't config apply' instead."

    local mode target editor orig
    mode="$(detect_deploy_mode)"
    target="$(config_target_file "${variant}")"
    editor="${EDITOR:-vi}"
    command -v "${editor}" &>/dev/null || die "Editor '${editor}' not found. Set \$EDITOR."

    # `|| true`: a bare `[[ ]] && cmd` that evaluates false would trip set -e
    [[ -f "${target}" ]] && warn "Replacing ${target} with a fresh copy from the cluster." || true

    if [[ "${variant}" == "mke3" ]]; then
        mke3_config_get "${mode}"
    else
        [[ "${mode}" == "airgap" ]] || ensure_mkectl
        fetch_current_mke4_yaml "${mode}"
    fi

    orig="$(mktemp)"
    cp "${target}" "${orig}"

    info "Opening ${target} in ${editor}..."
    "${editor}" "${target}"

    if cmp -s "${target}" "${orig}"; then
        rm -f "${orig}"
        info "No changes — nothing to apply."
        return 0
    fi
    rm -f "${orig}"

    _config_push "${variant}" "${mode}" "${target}"
}

usage() {
    echo ""
    echo -e "${BOLD}mke4k-lab — t CLI${RESET}"
    echo ""
    echo "Usage: t <command> [subcommand] [mke4|mke3|airgap|mke3-airgap]"
    echo ""
    echo "Commands:"
    echo "  deploy lab [mke4]           Provision instances + install MKE4k (default)"
    echo "  deploy lab mke3             Provision instances + install MKE3 (both NLBs)"
    echo "  deploy lab airgap           Airgap lab: bastion + registry + MKE4k"
    echo "  deploy lab mke3-airgap      Airgap lab: bastion + registry + proxy + MKE3"
    echo "  deploy instances            Terraform only (MKE4k)"
    echo "  deploy instances mke3       Terraform only + MKE3 NLB"
    echo "  deploy instances airgap     Terraform only (bastion + private subnet)"
    echo "  deploy instances mke3-airgap  Terraform only (MKE3 + bastion + private subnet)"
    echo "  deploy cluster              Install MKE4k (mkectl apply)"
    echo "  deploy cluster mke3         Install MKE3 (launchpad apply)"
    echo "  deploy cluster airgap       Install MKE4k from bastion (airgap)"
    echo "  deploy cluster mke3-airgap  Install MKE3 from bastion (airgap + proxy)"
    echo "  deploy registry             Setup MSR4 + upload MKE4k bundle"
    echo "  deploy registry mke3        Setup MSR4 + upload MKE3 images"
    echo "  deploy nfs [mke3]           Setup NFS server + provisioner (cluster must exist)"
    echo "  deploy msr4                 Deploy MSR4 (Harbor) on existing cluster"
    echo "  deploy msr4 airgap          Deploy MSR4 via bastion Harbor registry"
    echo "  deploy kof [full|lean]      Deploy KOF observability/FinOps (self-monitoring; default kof_mode)"
    echo "  deploy kof [full|lean] airgap  Deploy KOF from the bastion (charts/images from the internal registry)"
    echo "  deploy k0rdent-ui           Rotate the k0rdent UI password + publish it via Envoy gateway"
    echo "  deploy child-cluster        MKE4k child cluster via k0rdent/CAPI on AWS (online MKE4k; child_* in config)"
    echo "  destroy cluster             Uninstall MKE4k (mkectl reset)"
    echo "  destroy cluster mke3        Uninstall MKE3 (launchpad reset)"
    echo "  destroy cluster airgap      Uninstall MKE4k from bastion"
    echo "  destroy cluster mke3-airgap Uninstall MKE3 from bastion"
    echo "  destroy kof                 Uninstall KOF (helm uninstall + delete ns kof)"
    echo "  destroy k0rdent-ui          Remove the k0rdent UI gateway resources"
    echo "  destroy child-cluster       Delete the child cluster (CAPA removes its AWS resources)"
    echo "  rotate child-creds          Push freshly exported AWS credentials into the child's CAPA identity"
    echo "  destroy lab                 Delete any child cluster, then all AWS infrastructure (terraform destroy)"
    echo "  expiry [<days>|off|show]    Show/change/disable auto-expiry (re-arms to now+<days>; targeted apply)"
    echo "  status                      Show cluster node status (kubectl get nodes)"
    echo "  status child                Show child cluster status + nodes"
    echo "  show nodes                  Print controller/worker IPs and load balancer DNS"
    echo "  show summary                Reprint the deploy summary box (credentials, URLs, IPs)"
    echo "  connect bastion             SSH to bastion/registry host (airgap)"
    echo "  connect nfs                 SSH to NFS server (when nfs_enabled=true)"
    echo "  connect <node>              SSH into a node (m1/m2/m3, w1/w2/w3, or raw IP)"
    echo "  connect <node> cmd          Run a single command on a node and return"
    echo "  connect m1-child|w1-child   SSH into a child cluster node via its bastion (child_ssh_enabled=true)"
    echo "  gen client-bundle [mke3]    Download MKE3 client bundle (default)"
    echo "  gen client-bundle mke4      Show MKE4k kubeconfig path"
    echo "  config get [mke4|mke3]      Pull the running cluster config to a local file"
    echo "  config apply [mke4|mke3]    Push the edited config file back to the cluster"
    echo "  config edit [mke4|mke3]     Pull → \$EDITOR → push (skipped if unchanged)"
    echo "  tunnel                      Show available SSH tunnels for airgap UIs"
    echo "  tunnel dashboard            MKE4k Dashboard → https://localhost:3000"
    echo "  tunnel mke3                 MKE3 Dashboard  → https://localhost:3000"
    echo "  tunnel msr4                 MSR4 Harbor UI  → https://localhost:8444"
    echo "  tunnel k0rdent-ui           k0rdent UI      → https://localhost:8445"
    echo "  tunnel grafana              KOF Grafana     → https://localhost:8443"
    echo ""
    echo "Prerequisites:"
    echo "  - AWS credentials exported (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY)"
    echo "  - terraform, mkectl, kubectl, jq in PATH"
    echo "  - Edit 'config' before deploying"
    echo ""
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
COMMAND="${1:-}"
SUBCOMMAND="${2:-}"

case "${COMMAND}" in
    deploy)
        case "${SUBCOMMAND}" in
            lab)
                _T_ASK_NAME=true
                case "${3:-mke4}" in
                    mke4)        cmd_deploy_lab_mke4 ;;
                    mke3)        cmd_deploy_lab_mke3 ;;
                    airgap)      cmd_deploy_lab_airgap ;;
                    mke3-airgap) cmd_deploy_lab_mke3_airgap ;;
                    *)           die "Unknown variant: t deploy lab ${3}. Try: mke4, mke3, airgap, mke3-airgap" ;;
                esac
                ;;
            instances)
                _T_ASK_NAME=true
                case "${3:-mke4}" in
                    mke4)        cmd_deploy_instances ;;
                    mke3)        cmd_deploy_instances_mke3 ;;
                    airgap)      cmd_deploy_instances_airgap ;;
                    mke3-airgap) cmd_deploy_instances_mke3_airgap ;;
                    *)           die "Unknown variant: t deploy instances ${3}. Try: mke4, mke3, airgap, mke3-airgap" ;;
                esac
                ;;
            cluster)
                case "${3:-mke4}" in
                    mke4)        cmd_deploy_cluster ;;
                    mke3)        cmd_deploy_cluster_mke3 ;;
                    airgap)      cmd_deploy_cluster_airgap ;;
                    mke3-airgap) cmd_deploy_cluster_mke3_airgap ;;
                    *)           die "Unknown variant: t deploy cluster ${3}. Try: mke4, mke3, airgap, mke3-airgap" ;;
                esac
                ;;
            registry)
                case "${3:-mke4}" in
                    mke4|"")     cmd_deploy_registry ;;
                    mke3)        cmd_deploy_registry_mke3 ;;
                    *)           die "Unknown variant: t deploy registry ${3}. Try: mke4, mke3" ;;
                esac
                ;;
            nfs)
                case "${3:-mke4}" in
                    mke4|"") cmd_deploy_nfs ;;
                    mke3)    cmd_deploy_nfs mke3 ;;
                    *)       die "Unknown variant: t deploy nfs ${3}. Try: mke4, mke3" ;;
                esac
                ;;
            msr4)
                case "${3:-}" in
                    "")      cmd_deploy_msr4 ;;
                    airgap)  cmd_deploy_msr4_airgap ;;
                    *)       die "Unknown variant: t deploy msr4 ${3}. Try: (empty), airgap" ;;
                esac
                ;;
            kof)
                # t deploy kof [full|lean] [airgap]  |  t deploy kof airgap
                case "${3:-}" in
                    airgap)  cmd_deploy_kof "" airgap ;;
                    ""|full|lean)
                        case "${4:-}" in
                            ""|airgap) cmd_deploy_kof "${3:-}" "${4:-}" ;;
                            *)         die "Unknown variant: t deploy kof ${3} ${4}. Try: t deploy kof [full|lean] [airgap]" ;;
                        esac
                        ;;
                    *)       die "Unknown variant: t deploy kof ${3}. Try: t deploy kof [full|lean] [airgap]" ;;
                esac
                ;;
            k0rdent-ui) cmd_deploy_k0rdent_ui ;;
            child-cluster) cmd_deploy_child_cluster ;;
            *)         die "Unknown subcommand: t deploy ${SUBCOMMAND}. Try: lab, instances, cluster, registry, nfs, msr4, kof, k0rdent-ui, child-cluster" ;;
        esac
        ;;
    destroy)
        case "${SUBCOMMAND}" in
            lab)     cmd_destroy_lab ;;
            cluster)
                case "${3:-mke4}" in
                    mke4)        cmd_destroy_cluster ;;
                    mke3)        cmd_destroy_cluster_mke3 ;;
                    airgap)      cmd_destroy_cluster_airgap ;;
                    mke3-airgap) cmd_destroy_cluster_mke3_airgap ;;
                    *)           die "Unknown variant: t destroy cluster ${3}. Try: mke4, mke3, airgap, mke3-airgap" ;;
                esac
                ;;
            kof)     cmd_destroy_kof ;;
            k0rdent-ui) cmd_destroy_k0rdent_ui ;;
            child-cluster) cmd_destroy_child_cluster ;;
            *)       die "Unknown subcommand: t destroy ${SUBCOMMAND}. Try: lab, cluster, kof, k0rdent-ui, child-cluster" ;;
        esac
        ;;
    status)
        case "${SUBCOMMAND}" in
            "")    cmd_status ;;
            child) cmd_status_child ;;
            *)     die "Unknown subcommand: t status ${SUBCOMMAND}. Try: (empty), child" ;;
        esac
        ;;
    expiry)    cmd_expiry "${SUBCOMMAND}" ;;
    show)
        case "${SUBCOMMAND}" in
            nodes)   cmd_show_nodes ;;
            summary) cmd_show_summary ;;
            *)       die "Unknown subcommand: t show ${SUBCOMMAND}. Try: nodes, summary" ;;
        esac
        ;;
    connect) cmd_connect "${SUBCOMMAND}" "${3:-}" ;;
    rotate)
        case "${SUBCOMMAND}" in
            child-creds) cmd_rotate_child_creds ;;
            *)           die "Unknown subcommand: t rotate ${SUBCOMMAND}. Try: child-creds" ;;
        esac
        ;;
    gen)
        case "${SUBCOMMAND}" in
            client-bundle) cmd_gen_client_bundle "${3:-mke3}" ;;
            *)             die "Unknown subcommand: t gen ${SUBCOMMAND}. Try: client-bundle" ;;
        esac
        ;;
    config)
        case "${SUBCOMMAND}" in
            get|apply|edit)
                case "${3:-mke4}" in
                    mke4|mke3) "cmd_config_${SUBCOMMAND}" "${3:-mke4}" ;;
                    *)         die "Unknown variant: t config ${SUBCOMMAND} ${3}. Try: mke4, mke3" ;;
                esac
                ;;
            *) die "Unknown subcommand: t config ${SUBCOMMAND}. Try: get, apply, edit" ;;
        esac
        ;;
    tunnel)  cmd_tunnel "${SUBCOMMAND}" ;;
    help|--help|-h|"") usage ;;
    *) die "Unknown command: ${COMMAND}. Run 't help' for usage." ;;
esac
