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
KUBECONFIG="${HOME}/.mke/mke.kubeconf"

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

# ---------------------------------------------------------------------------
# Deploy phase timers
# ---------------------------------------------------------------------------
_T_DEPLOY_START=0
_T_PHASE_START=0
_T_TERRAFORM=0
_T_NLB=0
_T_MKECTL=0
_T_LAUNCHPAD=0

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

# ---------------------------------------------------------------------------
# Source config and write terraform.tfvars
# ---------------------------------------------------------------------------
load_config() {
    [[ -f "${CONFIG_FILE}" ]] || die "config file not found at ${CONFIG_FILE}"
    # shellcheck source=/dev/null
    source "${CONFIG_FILE}"

    # Validate required variables
    : "${cluster_name:?cluster_name not set in config}"
    : "${controller_count:?controller_count not set in config}"
    : "${worker_count:?worker_count not set in config}"
    : "${cluster_flavor:?cluster_flavor not set in config}"
    : "${region:?region not set in config}"
    : "${mke4k_version:?mke4k_version not set in config}"
    : "${os_distro:?os_distro not set in config}"
    # ccm_enabled defaults to true if not present in config
    ccm_enabled="${ccm_enabled:-true}"

    # MKE3 defaults (only used when deploying MKE3)
    mke3_version="${mke3_version:-3.8.2}"
    mcr_version="${mcr_version:-25.0.14}"
    mcr_channel="${mcr_channel:-stable-25.0.14}"
    mke3_admin_username="${mke3_admin_username:-admin}"
    launchpad_version="${launchpad_version:-1.5.15}"
}

write_tfvars() {
    local mke3_enabled="${1:-false}"
    cat > "${TERRAFORM_DIR}/terraform.tfvars" <<EOF
cluster_name     = "${cluster_name}"
controller_count = ${controller_count}
worker_count     = ${worker_count}
cluster_flavor   = "${cluster_flavor}"
region           = "${region}"
mke4k_version    = "${mke4k_version}"
os_distro        = "${os_distro}"
ccm_enabled      = ${ccm_enabled}
mke3_enabled     = ${mke3_enabled}
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
# mke4.yaml generation — mkectl init provides the schema, we patch values in
# ---------------------------------------------------------------------------
generate_mke4_yaml() {
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

    # Build hosts JSON array with jq, then patch the YAML with yq
    local hosts_json
    hosts_json="$(echo "${output}" | jq -c \
        --arg key "${ssh_key}" \
        --arg crole "${ctrl_role}" \
        '[
            (.controller_ips.value[] | {
                ssh: { address: ., user: "ubuntu", keyPath: $key },
                role: $crole
            }),
            (.worker_ips.value[] | {
                ssh: { address: ., user: "ubuntu", keyPath: $key },
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
    ensure_launchpad

    local launchpad_yaml="${TERRAFORM_DIR}/launchpad.yaml"
    local creds_file="${TERRAFORM_DIR}/mke3_credentials.txt"
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

    # Build hosts JSON array with jq
    local hosts_json
    hosts_json="$(echo "${output}" | jq -c \
        --arg key "${ssh_key}" \
        '[
            (.controller_ips.value[] | {
                role: "manager",
                ssh: { address: ., user: "ubuntu", keyPath: $key }
            }),
            (.worker_ips.value[] | {
                role: "worker",
                ssh: { address: ., user: "ubuntu", keyPath: $key }
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

    success "launchpad.yaml written to ${launchpad_yaml}"

    # Generate nodes.yaml for mkectl upgrade (all nodes, no role field)
    generate_nodes_yaml "${output}" "${ssh_key}"
}

generate_nodes_yaml() {
    local output="${1}"
    local ssh_key="${2}"
    local nodes_yaml="${TERRAFORM_DIR}/nodes.yaml"

    local nodes_json
    nodes_json="$(echo "${output}" | jq -c \
        --arg key "${ssh_key}" \
        '[
            (.controller_ips.value[], .worker_ips.value[]) |
            { address: ., port: 22, user: "ubuntu", keyPath: $key }
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
    read -r -p "$(echo -e "  ${BOLD}Download mkectl now to prepare for MKE3 → MKE4k upgrade?${RESET} [y/N] ")" answer
    case "${answer}" in
        [yY]|[yY][eE][sS])
            local ver_input
            read -r -p "  MKE4k version [${mke4k_version}]: " ver_input
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
# resolve_node <name> → prints the public IP for the node
# Accepted names:
#   controller-0, controller-1, …   (or c0, c1, …)
#   worker-0,     worker-1,     …   (or w0, w1, …)
#   any raw IP / hostname            (passed through as-is)
resolve_node() {
    local name="${1}"
    local output
    output="$(tf_output 2>/dev/null)" \
        || die "Could not read terraform output. Has terraform been applied?"

    # m1, m2, m3 → controller index 0, 1, 2 (1-based → 0-based)
    # w1, w2, w3 → worker index 0, 1, 2
    local ip=""
    if [[ "${name}" =~ ^m([0-9]+)$ ]]; then
        local idx=$(( BASH_REMATCH[1] - 1 ))
        ip="$(echo "${output}" | jq -r ".controller_ips.value[${idx}]" 2>/dev/null)"
    elif [[ "${name}" =~ ^w([0-9]+)$ ]]; then
        local idx=$(( BASH_REMATCH[1] - 1 ))
        ip="$(echo "${output}" | jq -r ".worker_ips.value[${idx}]" 2>/dev/null)"
    else
        # Treat as a raw IP / hostname
        ip="${name}"
    fi

    [[ -z "${ip}" || "${ip}" == "null" ]] \
        && die "Could not resolve node '${name}'. Use m1/m2/m3 (controllers) or w1/w2/w3 (workers), or a raw IP."
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
  m1, m2, m3, …   controllers (managers)
  w1, w2, w3, …   workers
  <ip>             any raw IP or hostname

${BOLD}Examples:${RESET}
  t connect m1                     interactive SSH into controller-1
  t connect w1                     interactive SSH into worker-1
  t connect m1 "docker ps"         run a single command and return
  t connect 1.2.3.4                SSH to a raw IP
EOF
        return 0
    fi

    local ssh_key="${TERRAFORM_DIR}/aws_private.pem"
    [[ -f "${ssh_key}" ]] \
        || die "SSH key not found at ${ssh_key}. Has terraform been applied?"

    local ip
    ip="$(resolve_node "${target}")"

    local ssh_opts=(-q -i "${ssh_key}" -o StrictHostKeyChecking=no -o BatchMode=no -l ubuntu)

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

    local total=$(( _T_TERRAFORM + _T_NLB + _T_MKECTL ))
    local ccm_str="CCM disabled"
    [[ "${ccm_enabled:-false}" == "true" ]] && ccm_str="CCM enabled"

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
    sep
    bline "  Timing"
    bline "$(printf '    %-22s %s' 'Terraform'     "$(fmt_duration ${_T_TERRAFORM})")"
    bline "$(printf '    %-22s %s' 'NLB stabilise' "$(fmt_duration ${_T_NLB})")"
    bline "$(printf '    %-22s %s' 'MKE4k install' "$(fmt_duration ${_T_MKECTL})")"
    bline "    ${HDIV}"
    bline "$(printf '    %-22s %s' 'Total'         "$(fmt_duration ${total})")"
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
    local lb_remaining="${lb_dns}"
    while [[ ${#lb_remaining} -gt ${lb_chunk_w} ]]; do
        bline "    ${lb_remaining:0:${lb_chunk_w}}"
        lb_remaining="${lb_remaining:${lb_chunk_w}}"
    done
    bline "    ${lb_remaining}"
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
    local creds_file="${TERRAFORM_DIR}/mke3_credentials.txt"
    local admin_user admin_pass
    admin_user="$(grep '^username=' "${creds_file}" 2>/dev/null | cut -d= -f2 || echo "${mke3_admin_username}")"
    admin_pass="$(grep '^password=' "${creds_file}" 2>/dev/null | cut -d= -f2 || echo "(see ${creds_file})")"

    local nodes_yaml="${TERRAFORM_DIR}/nodes.yaml"

    local total=$(( _T_TERRAFORM + _T_NLB + _T_LAUNCHPAD ))

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
    sep
    bline "  Timing"
    bline "$(printf '    %-22s %s' 'Terraform'       "$(fmt_duration ${_T_TERRAFORM})")"
    bline "$(printf '    %-22s %s' 'NLB stabilise'   "$(fmt_duration ${_T_NLB})")"
    bline "$(printf '    %-22s %s' 'MKE3 install'    "$(fmt_duration ${_T_LAUNCHPAD})")"
    bline "    ${HDIV}"
    bline "$(printf '    %-22s %s' 'Total'           "$(fmt_duration ${total})")"
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
# Commands
# ---------------------------------------------------------------------------
cmd_deploy_lab_mke4() {
    load_config
    write_tfvars false
    timer_deploy_start
    tf_init
    tf_apply
    timer_phase_end _T_TERRAFORM
    wait_for_lb
    timer_phase_end _T_NLB
    generate_mke4_yaml
    mkectl_apply
    timer_phase_end _T_MKECTL
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
    wait_for_lb
    timer_phase_end _T_NLB
    generate_launchpad_yaml
    launchpad_apply
    timer_phase_end _T_LAUNCHPAD
    print_mke3_deploy_summary
    prompt_mkectl_for_upgrade
}

cmd_deploy_instances() {
    load_config
    write_tfvars false
    tf_init
    tf_apply
    generate_mke4_yaml
    success "Instances deployed. Run 't deploy cluster' to install MKE4k."
}

cmd_deploy_instances_mke3() {
    load_config
    write_tfvars true
    tf_init
    tf_apply
    generate_launchpad_yaml
    success "Instances deployed. Run 't deploy cluster mke3' to install MKE3."
}

cmd_deploy_cluster() {
    load_config
    mkectl_apply
}

cmd_deploy_cluster_mke3() {
    load_config
    generate_launchpad_yaml
    launchpad_apply
}

cmd_destroy_cluster() {
    load_config
    mkectl_reset
}

cmd_destroy_cluster_mke3() {
    load_config
    launchpad_reset
}

cmd_destroy_lab() {
    load_config
    write_tfvars
    tf_destroy
    success "Lab destroyed."
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
    local output
    output="$(tf_output 2>/dev/null)" || die "Could not read terraform output. Has terraform been applied?"

    local controller_ips worker_ips lb_dns
    controller_ips="$(echo "${output}" | jq -r '.controller_ips.value[]' 2>/dev/null || echo "(none)")"
    worker_ips="$(echo "${output}" | jq -r '.worker_ips.value[]' 2>/dev/null || echo "(none)")"
    lb_dns="$(echo "${output}" | jq -r '.lb_dns_name.value' 2>/dev/null || echo "(unknown)")"
    local ssh_key
    ssh_key="$(echo "${output}" | jq -r '.ssh_key_path.value' 2>/dev/null || echo "terraform/aws_private.pem")"

    echo -e "\n${BOLD}Controllers:${RESET}"
    echo "${controller_ips}" | while read -r ip; do
        echo "  ${ip}   ssh -i ${ssh_key} ubuntu@${ip}"
    done

    echo -e "\n${BOLD}Workers:${RESET}"
    echo "${worker_ips}" | while read -r ip; do
        echo "  ${ip}   ssh -i ${ssh_key} ubuntu@${ip}"
    done

    echo -e "\n${BOLD}MKE4k Load Balancer:${RESET}"
    echo "  ${lb_dns}"

    local mke3_lb_dns
    mke3_lb_dns="$(echo "${output}" | jq -r '.mke3_lb_dns_name.value' 2>/dev/null || echo "")"
    if [[ -n "${mke3_lb_dns}" ]]; then
        echo -e "\n${BOLD}MKE3 Load Balancer:${RESET}"
        echo "  ${mke3_lb_dns}"
    fi
    echo ""
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF

${BOLD}mke4k-lab — t CLI${RESET}

Usage: t <command> [subcommand] [mke3|mke4]

Commands:
  deploy lab [mke4]   Provision instances + install MKE4k (default)
  deploy lab mke3     Provision instances + install MKE3 (both NLBs created)
  deploy instances    Provision EC2 instances and NLBs only (terraform apply)
  deploy instances mke3  Provision with MKE3 NLB enabled
  deploy cluster      Install MKE4k on existing instances (mkectl apply)
  deploy cluster mke3 Install MKE3 on existing instances (launchpad apply)
  destroy cluster     Uninstall MKE4k from nodes (mkectl reset --force)
  destroy cluster mke3  Uninstall MKE3 from nodes (launchpad reset --force)
  destroy lab         Destroy all AWS infrastructure (terraform destroy)
  status              Show cluster node status (kubectl get nodes)
  show nodes          Print controller/worker IPs and load balancer DNS
  connect <node>      SSH into a node (m1/m2/m3 controllers, w1/w2/w3 workers, or raw IP)
  connect <node> cmd  Run a single command on a node and return

Prerequisites:
  - AWS credentials exported (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY)
  - terraform, mkectl, kubectl, jq in PATH
  - Edit 'config' before deploying

EOF
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
                case "${3:-mke4}" in
                    mke4) cmd_deploy_lab_mke4 ;;
                    mke3) cmd_deploy_lab_mke3 ;;
                    *)    die "Unknown variant: t deploy lab ${3}. Try: mke4, mke3" ;;
                esac
                ;;
            instances)
                case "${3:-mke4}" in
                    mke4) cmd_deploy_instances ;;
                    mke3) cmd_deploy_instances_mke3 ;;
                    *)    die "Unknown variant: t deploy instances ${3}. Try: mke4, mke3" ;;
                esac
                ;;
            cluster)
                case "${3:-mke4}" in
                    mke4) cmd_deploy_cluster ;;
                    mke3) cmd_deploy_cluster_mke3 ;;
                    *)    die "Unknown variant: t deploy cluster ${3}. Try: mke4, mke3" ;;
                esac
                ;;
            *)         die "Unknown subcommand: t deploy ${SUBCOMMAND}. Try: lab, instances, cluster" ;;
        esac
        ;;
    destroy)
        case "${SUBCOMMAND}" in
            lab)     cmd_destroy_lab ;;
            cluster)
                case "${3:-mke4}" in
                    mke4) cmd_destroy_cluster ;;
                    mke3) cmd_destroy_cluster_mke3 ;;
                    *)    die "Unknown variant: t destroy cluster ${3}. Try: mke4, mke3" ;;
                esac
                ;;
            *)       die "Unknown subcommand: t destroy ${SUBCOMMAND}. Try: lab, cluster" ;;
        esac
        ;;
    status)    cmd_status ;;
    show)
        case "${SUBCOMMAND}" in
            nodes) cmd_show_nodes ;;
            *)     die "Unknown subcommand: t show ${SUBCOMMAND}. Try: nodes" ;;
        esac
        ;;
    connect) cmd_connect "${SUBCOMMAND}" "${3:-}" ;;
    help|--help|-h|"") usage ;;
    *) die "Unknown command: ${COMMAND}. Run 't help' for usage." ;;
esac
