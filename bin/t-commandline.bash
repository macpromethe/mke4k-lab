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

# ---------------------------------------------------------------------------
# Source config and write terraform.tfvars
# ---------------------------------------------------------------------------
load_config() {
    [[ -f "${CONFIG_FILE}" ]] || die "config file not found at ${CONFIG_FILE}"
    # shellcheck source=/dev/null
    source "${CONFIG_FILE}"

    # Auto-generate a unique suffix when cluster_name is the bare default.
    # This prevents resource collisions when multiple people deploy simultaneously.
    # The suffix is persisted in .cluster-id so it stays consistent across commands.
    if [[ "${cluster_name}" == "mke4k-lab" ]]; then
        local id_file="${PROJECT_ROOT}/.cluster-id"
        if [[ ! -f "${id_file}" ]]; then
            local suffix
            suffix="$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 4)"
            echo "${suffix}" > "${id_file}"
            info "Generated cluster ID: mke4k-lab-${suffix} (saved to .cluster-id)"
        fi
        cluster_name="mke4k-lab-$(cat "${id_file}")"
    fi

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

    # Airgap defaults
    airgap_registry_flavor="${airgap_registry_flavor:-t3.xlarge}"
    airgap_registry_disk_gb="${airgap_registry_disk_gb:-100}"
    airgap_msr_version="${airgap_msr_version:-v4.13.3}"
    registry_hostname="registry.${cluster_name}.local"

    # NFS defaults
    nfs_enabled="${nfs_enabled:-false}"
    nfs_flavor="${nfs_flavor:-t3.small}"
    nfs_disk_gb="${nfs_disk_gb:-50}"
    nfs_export_path="${nfs_export_path:-/srv/nfs/data}"

    # MSR4 defaults
    msr4_enabled="${msr4_enabled:-false}"
    msr4_version="${msr4_version:-4.13.3}"
    msr4_replicas="${msr4_replicas:-1}"
    msr4_postgres_version="${msr4_postgres_version:-1.15.1}"
    msr4_redis_operator_version="${msr4_redis_operator_version:-0.24.0}"
    msr4_redis_replication_version="${msr4_redis_replication_version:-0.16.13}"
    msr4_storage_size="${msr4_storage_size:-10Gi}"
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

write_tfvars() {
    local mke3_enabled="${1:-false}"
    local airgap_enabled="${2:-false}"
    # CCM requires internet access to AWS APIs — force off in airgap mode
    local effective_ccm="${ccm_enabled}"
    [[ "${airgap_enabled}" == "true" ]] && effective_ccm=false
    cat > "${TERRAFORM_DIR}/terraform.tfvars" <<EOF
cluster_name             = "${cluster_name}"
controller_count         = ${controller_count}
worker_count             = ${worker_count}
cluster_flavor           = "${cluster_flavor}"
region                   = "${region}"
mke4k_version            = "${mke4k_version}"
os_distro                = "${os_distro}"
ccm_enabled              = ${effective_ccm}
mke3_enabled             = ${mke3_enabled}
airgap_enabled           = ${airgap_enabled}
airgap_registry_flavor   = "${airgap_registry_flavor}"
airgap_registry_disk_gb  = ${airgap_registry_disk_gb}
nfs_enabled              = ${nfs_enabled}
nfs_flavor               = "${nfs_flavor}"
nfs_disk_gb              = ${nfs_disk_gb}
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
# SSH helpers (used for airgap bastion and general remote commands)
# ---------------------------------------------------------------------------

# Run a command on a remote host via SSH
ssh_node() {
    local ssh_key="${1}" ip="${2}"
    shift 2
    ssh -q -o StrictHostKeyChecking=no -o ConnectTimeout=10 -i "${ssh_key}" "ubuntu@${ip}" "$@"
}

# Run a command on a remote host via SSH through bastion (ProxyJump)
ssh_node_via_bastion() {
    local ssh_key="${1}" bastion_ip="${2}" ip="${3}"
    shift 3
    ssh -q -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        -i "${ssh_key}" \
        -o "ProxyCommand=ssh -q -o StrictHostKeyChecking=no -i ${ssh_key} -W %h:%p ubuntu@${bastion_ip}" \
        "ubuntu@${ip}" "$@"
}

# Wait for SSH to become available
wait_for_ssh() {
    local ssh_key="${1}" ip="${2}" label="${3:-host}" max_wait=180
    info "Waiting for ${label} SSH (${ip})..."
    for (( i=0; i<max_wait; i+=5 )); do
        if ssh_node "${ssh_key}" "${ip}" "true" 2>/dev/null; then
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

    # Determine apt suite from os_distro (ubuntu-22.04 → jammy, ubuntu-24.04 → noble)
    local apt_suite
    case "${os_distro}" in
        ubuntu-22.04) apt_suite="jammy"  ;;
        ubuntu-24.04) apt_suite="noble"  ;;
        *)            die "Unsupported os_distro for MCR install: ${os_distro}" ;;
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
# Airgap — configure DNS on cluster nodes (point systemd-resolved at bastion)
# ---------------------------------------------------------------------------
# bind9 runs on the bastion and resolves the registry hostname.
# Each cluster node's systemd-resolved is configured to use the bastion
# as its DNS server. This means both containerd (on the node) and CoreDNS
# (which forwards to the node's upstream resolver) can resolve the hostname.
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
    done

    success "DNS configured on all cluster nodes."
}

# ---------------------------------------------------------------------------
# Airgap — Squid forward proxy on bastion (for MCR APT install on airgap nodes)
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
    local no_proxy_list="localhost,127.0.0.1,${bastion_private_ip},${reg_host}"
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
            "${cert_file}" "ubuntu@${node_ip}:/tmp/registry_ca.crt"

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
    local bundle_url="${MKE3_BUNDLE_URL:-https://packages.mirantis.com/caas/ucp_images_${mke3_version}.tar.gz}"

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

    local bundle_url="${MKE4K_BUNDLE_URL:-https://packages.mirantis.com/caas/mke_bundle_${mke4k_version}_amd64.tar.gz}"

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

        # Make sure we can reach the NFS server via bastion
        info "  Installing NFS server packages..."
        ssh_node_via_bastion "${ssh_key}" "${bastion_ip}" "${nfs_ip}" "
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

    info "Installing nfs-common on ${#all_ips[@]} cluster node(s)..."

    if [[ "${is_airgap}" == "true" ]]; then
        # Download nfs-common packages on bastion
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
            "
        done
    else
        for node_ip in "${all_ips[@]}"; do
            info "  nfs-common → ${node_ip}"
            ssh_node "${ssh_key}" "${node_ip}" "
                set -euo pipefail
                if dpkg -l nfs-common 2>/dev/null | grep -q '^ii'; then
                    echo 'nfs-common already installed'
                    exit 0
                fi
                sudo apt-get update -qq
                sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nfs-common >/dev/null 2>&1
            "
        done
    fi
    success "nfs-common installed on all cluster nodes."
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
        --arg crole "${ctrl_role}" \
        --arg ctrl_field "${ctrl_ips_field}" \
        --arg wkr_field "${wkr_ips_field}" \
        '[
            (.[$ctrl_field].value[] | {
                ssh: { address: ., user: "ubuntu", keyPath: $key },
                role: $crole
            }),
            (.[$wkr_field].value[] | {
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
        --arg ctrl_field "${ctrl_ips_field}" \
        --arg wkr_field "${wkr_ips_field}" \
        '[
            (.[$ctrl_field].value[] | {
                role: "manager",
                ssh: { address: ., user: "ubuntu", keyPath: $key }
            }),
            (.[$wkr_field].value[] | {
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
        --arg ctrl_field "${ctrl_field}" \
        --arg wkr_field "${wkr_field}" \
        '[
            (.[$ctrl_field].value[], .[$wkr_field].value[]) |
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
            local creds_file="${TERRAFORM_DIR}/mke3_credentials.txt"
            local admin_user admin_pass
            admin_user="$(grep '^username=' "${creds_file}" 2>/dev/null | cut -d= -f2 || echo "${mke3_admin_username}")"
            admin_pass="$(grep '^password=' "${creds_file}" 2>/dev/null | cut -d= -f2 || echo "(see ${creds_file})")"

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

    local ssh_key="${TERRAFORM_DIR}/aws_private.pem"
    [[ -f "${ssh_key}" ]] \
        || die "SSH key not found at ${ssh_key}. Has terraform been applied?"

    local output
    output="$(tf_output 2>/dev/null)" || die "Could not read terraform output."

    local ip
    ip="$(resolve_node "${target}" "${output}")"

    # Detect airgap mode
    local bastion_pub_ip
    bastion_pub_ip="$(echo "${output}" | jq -r '.bastion_public_ip.value // empty' 2>/dev/null)"
    local is_airgap=false
    [[ -n "${bastion_pub_ip}" && "${bastion_pub_ip}" != "null" && "${bastion_pub_ip}" != "" ]] && is_airgap=true

    local ssh_opts=(-q -i "${ssh_key}" -o StrictHostKeyChecking=no -o BatchMode=no -l ubuntu)

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
    if [[ -n "${nfs_priv_ip}" && "${nfs_priv_ip}" != "" ]]; then
        bline "$(printf '  %-12s %s' 'NFS' "${nfs_priv_ip} (${nfs_export_path})")"
    fi
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
    echo -e "  ${BOLD}NLB:${RESET}       https://${lb_dns}"
    echo -e "  ${BOLD}Registry:${RESET}  https://${bastion_pub_ip}  (Harbor, publicly accessible)"
    echo -e "  ${BOLD}SSH:${RESET}       t connect bastion      (direct)"
    echo -e "             t connect m1           (via bastion ProxyJump)"
    echo -e "  ${BOLD}Tunnels:${RESET}   t tunnel dashboard     → https://localhost:3000"
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

    local creds_file="${TERRAFORM_DIR}/mke3_credentials.txt"
    local admin_user admin_pass
    admin_user="$(grep '^username=' "${creds_file}" 2>/dev/null | cut -d= -f2 || echo "${mke3_admin_username}")"
    admin_pass="$(grep '^password=' "${creds_file}" 2>/dev/null | cut -d= -f2 || echo "(see ${creds_file})")"

    local reg_creds_file="${TERRAFORM_DIR}/registry_credentials.txt"
    local registry_pass
    registry_pass="$(grep '^password=' "${reg_creds_file}" 2>/dev/null | cut -d= -f2 || echo "(unknown)")"

    local total=$(( _T_TERRAFORM + _T_REGISTRY + _T_MKE3_IMAGES + _T_PROXY + _T_NLB + _T_LAUNCHPAD ))

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
    sep
    bline "  Timing"
    bline "$(printf '    %-22s %s' 'Terraform'       "$(fmt_duration ${_T_TERRAFORM})")"
    bline "$(printf '    %-22s %s' 'Registry setup'  "$(fmt_duration ${_T_REGISTRY})")"
    bline "$(printf '    %-22s %s' 'MKE3 images'     "$(fmt_duration ${_T_MKE3_IMAGES})")"
    bline "$(printf '    %-22s %s' 'Proxy setup'     "$(fmt_duration ${_T_PROXY})")"
    bline "$(printf '    %-22s %s' 'NLB stabilise'   "$(fmt_duration ${_T_NLB})")"
    bline "$(printf '    %-22s %s' 'launchpad apply'  "$(fmt_duration ${_T_LAUNCHPAD})")"
    bline "    ${HDIV}"
    bline "$(printf '    %-22s %s' 'Total'           "$(fmt_duration ${total})")"
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

    setup_node_dns             # Point each node's systemd-resolved at bastion

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

    setup_node_dns             # Point each node's systemd-resolved at bastion

    setup_squid_proxy          # Squid on bastion for MCR APT install
    setup_node_proxy           # APT proxy + env vars + registry CA on nodes
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
    write_tfvars
    tf_destroy
    success "Lab destroyed."
}

cmd_deploy_nfs() {
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
        deploy_nfs_provisioner_airgap
    else
        deploy_nfs_provisioner
    fi
    success "NFS setup complete."
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
    local output ssh_key bastion_ip

    info "Fetching current cluster config (mkectl config get, ${mode})..."

    if [[ "${mode}" == "airgap" ]]; then
        output="$(tf_output)"
        ssh_key="$(echo "${output}" | jq -r '.ssh_key_path.value')"
        bastion_ip="$(echo "${output}" | jq -r '.bastion_public_ip.value')"
        ssh_node "${ssh_key}" "${bastion_ip}" \
            "export KUBECONFIG=~/.mke/mke.kubeconf; mkectl config get 2>/dev/null" \
            | sed -n '/^apiVersion:/,$p' > "${mke4_yaml}"
    else
        mkectl config get 2>/dev/null | sed -n '/^apiVersion:/,$p' > "${mke4_yaml}"
    fi

    [[ -s "${mke4_yaml}" ]] || die "mkectl config get returned empty output. Is the cluster up?"
    # Sanity check
    grep -q '^apiVersion:' "${mke4_yaml}" || die "mke4.yaml missing apiVersion header — check mkectl output"
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
# Usage: msr4_mkectl_apply <online|airgap>
msr4_mkectl_apply() {
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
    msr4_mkectl_apply "${mode}"

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

    msr4_mkectl_apply "${mode}"

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
            echo "  ${ip}   ssh -i ${ssh_key} ubuntu@${ip}"
        done

        echo -e "\n${BOLD}Workers:${RESET}"
        echo "${worker_ips}" | while read -r ip; do
            echo "  ${ip}   ssh -i ${ssh_key} ubuntu@${ip}"
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
        "")
            echo ""
            echo -e "${BOLD}Available tunnels:${RESET}"
            echo ""
            echo "  t tunnel dashboard    MKE4k Dashboard → https://localhost:3000"
            echo "  t tunnel mke3         MKE3 Dashboard  → https://localhost:3000"
            echo "  t tunnel msr4         MSR4 Harbor UI  → https://localhost:8444"
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
            fi
            echo "  # Kubernetes API (for local kubectl)"
            echo "  ssh -i ${ssh_key} -L 0.0.0.0:6443:${lb_dns}:6443 -N ubuntu@${bastion_pub_ip}"
            echo ""
            if [[ -t 0 ]]; then
                echo -e "${CYAN}Note: inside Docker, start with -p 3000:3000 -p 8443:8443 -p 8444:8444${RESET}"
            fi
            ;;
        *)
            die "Unknown tunnel target: ${target}. Try: dashboard, mke3, msr4, registry"
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
    local launchpad_yaml="${TERRAFORM_DIR}/launchpad.yaml"

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
        [[ -f "${launchpad_yaml}" ]] || die "launchpad.yaml not found. Deploy MKE3 first."
        ensure_launchpad
        info "Generating MKE3 client bundle..."
        launchpad client-config -a -c "${launchpad_yaml}"

        # Find the bundle directory
        local bundle_dir
        bundle_dir="$(ls -d ${HOME}/.mirantis-launchpad/cluster/*/bundle/admin 2>/dev/null | head -1)"
        [[ -n "${bundle_dir}" ]] || die "Client bundle not found."

        success "Client bundle downloaded to: ${bundle_dir}"
        echo ""
        echo "  To activate, run:"
        echo ""
        echo "    cd ${bundle_dir} && source env.sh"
        echo ""
    fi
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
    echo "  deploy nfs                  Setup NFS server + CSI driver (cluster must exist)"
    echo "  deploy msr4                 Deploy MSR4 (Harbor) on existing cluster"
    echo "  deploy msr4 airgap          Deploy MSR4 via bastion Harbor registry"
    echo "  destroy cluster             Uninstall MKE4k (mkectl reset)"
    echo "  destroy cluster mke3        Uninstall MKE3 (launchpad reset)"
    echo "  destroy cluster airgap      Uninstall MKE4k from bastion"
    echo "  destroy cluster mke3-airgap Uninstall MKE3 from bastion"
    echo "  destroy lab                 Destroy all AWS infrastructure (terraform destroy)"
    echo "  status                      Show cluster node status (kubectl get nodes)"
    echo "  show nodes                  Print controller/worker IPs and load balancer DNS"
    echo "  connect bastion             SSH to bastion/registry host (airgap)"
    echo "  connect nfs                 SSH to NFS server (when nfs_enabled=true)"
    echo "  connect <node>              SSH into a node (m1/m2/m3, w1/w2/w3, or raw IP)"
    echo "  connect <node> cmd          Run a single command on a node and return"
    echo "  gen client-bundle [mke3]    Download MKE3 client bundle (default)"
    echo "  gen client-bundle mke4      Show MKE4k kubeconfig path"
    echo "  tunnel                      Show available SSH tunnels for airgap UIs"
    echo "  tunnel dashboard            MKE4k Dashboard → https://localhost:3000"
    echo "  tunnel mke3                 MKE3 Dashboard  → https://localhost:3000"
    echo "  tunnel msr4                 MSR4 Harbor UI  → https://localhost:8444"
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
                case "${3:-mke4}" in
                    mke4)        cmd_deploy_lab_mke4 ;;
                    mke3)        cmd_deploy_lab_mke3 ;;
                    airgap)      cmd_deploy_lab_airgap ;;
                    mke3-airgap) cmd_deploy_lab_mke3_airgap ;;
                    *)           die "Unknown variant: t deploy lab ${3}. Try: mke4, mke3, airgap, mke3-airgap" ;;
                esac
                ;;
            instances)
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
            nfs) cmd_deploy_nfs ;;
            msr4)
                case "${3:-}" in
                    "")      cmd_deploy_msr4 ;;
                    airgap)  cmd_deploy_msr4_airgap ;;
                    *)       die "Unknown variant: t deploy msr4 ${3}. Try: (empty), airgap" ;;
                esac
                ;;
            *)         die "Unknown subcommand: t deploy ${SUBCOMMAND}. Try: lab, instances, cluster, registry, nfs, msr4" ;;
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
    gen)
        case "${SUBCOMMAND}" in
            client-bundle) cmd_gen_client_bundle "${3:-mke3}" ;;
            *)             die "Unknown subcommand: t gen ${SUBCOMMAND}. Try: client-bundle" ;;
        esac
        ;;
    tunnel)  cmd_tunnel "${SUBCOMMAND}" ;;
    help|--help|-h|"") usage ;;
    *) die "Unknown command: ${COMMAND}. Run 't help' for usage." ;;
esac
