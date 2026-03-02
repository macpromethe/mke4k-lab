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
_T_REGISTRY=0
_T_BUNDLE=0

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

        echo '>>> Generating TLS cert (SAN=DNS:${reg_host},IP:${bastion_private_ip})...'
        mkdir -p ~/msr/certs
        openssl req -x509 -nodes -days 3650 -newkey rsa:4096 \
            -keyout ~/msr/certs/server.key \
            -out ~/msr/certs/server.crt \
            -subj '/CN=${reg_host}' \
            -addext 'subjectAltName=DNS:${reg_host},IP:${bastion_private_ip}'

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
        sudo cp ~/msr/certs/server.crt /etc/docker/certs.d/${reg_host}/ca.crt
        sudo cp ~/msr/certs/server.crt /etc/docker/certs.d/${bastion_private_ip}/ca.crt

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
        "ubuntu@${bastion_ip}:~/msr/certs/server.crt" "${cert_file}"
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
# Airgap — download MKE4k bundle + upload images to Harbor
# ---------------------------------------------------------------------------
upload_mke4k_bundle() {
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

    info "Downloading + uploading MKE4k bundle to registry..."
    ssh_node "${ssh_key}" "${bastion_ip}" "
        set -euo pipefail

        BUNDLE_DIR=~/bundles
        REGISTRY='${registry_hostname}'

        # Download bundle if not already present
        if [[ -z \"\$(find \${BUNDLE_DIR} -name '*.tar' -type f 2>/dev/null | head -1)\" ]]; then
            echo '>>> Downloading MKE4k bundle...'
            mkdir -p \"\${BUNDLE_DIR}\"
            cd /tmp
            curl -fsSL '${bundle_url}' -o bundle.tar.gz
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
        if command -v mkectl &>/dev/null; then
            got=\$(mkectl version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
            [[ \"\${got}\" == '${want}' ]] && { echo 'mkectl ${want} already installed'; }
        fi
        if ! command -v mkectl &>/dev/null; then
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

        yq e -i '.spec.registries.imageRegistry.caData = strenv(CERT_DATA)' "${mke4_yaml}"
        yq e -i '.spec.registries.chartRegistry.caData = strenv(CERT_DATA)' "${mke4_yaml}"
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

    local total=$(( _T_TERRAFORM + _T_REGISTRY + _T_BUNDLE + _T_NLB + _T_MKECTL ))

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
    echo -e "  ${BOLD}NLB:${RESET}       ${lb_dns}"
    echo -e "  ${BOLD}SSH:${RESET}       t connect bastion      (direct)"
    echo -e "             t connect m1           (via bastion ProxyJump)"
    echo -e "  ${BOLD}Tunnels:${RESET}   t tunnel dashboard     → https://localhost:3000"
    echo -e "             t tunnel registry      → https://localhost:8443"
    echo -e "             t tunnel               (show all + manual commands)"
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

    upload_mke4k_bundle        # Download bundle on bastion + upload to Harbor
    timer_phase_end _T_BUNDLE

    setup_node_dns             # Point each node's systemd-resolved at bastion

    local output ssh_key bastion_ip
    output="$(tf_output)"
    ssh_key="$(echo "${output}" | jq -r '.ssh_key_path.value')"
    bastion_ip="$(echo "${output}" | jq -r '.bastion_public_ip.value')"

    ensure_mkectl_on_bastion "${ssh_key}" "${bastion_ip}"
    wait_for_lb
    timer_phase_end _T_NLB

    generate_mke4_yaml true    # airgap=true — uses hostname, caData
    mkectl_apply_on_bastion    # SCP mke4.yaml to bastion, run mkectl there
    timer_phase_end _T_MKECTL

    print_airgap_deploy_summary
    export KUBECONFIG=/root/.mke/mke.kubeconf
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
    upload_mke4k_bundle
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
# Tunnel — SSH port-forward for airgap UIs
# ---------------------------------------------------------------------------
cmd_tunnel() {
    local target="${1:-}"
    load_config
    local output
    output="$(tf_output 2>/dev/null)" || die "Could not read terraform output. Has terraform been applied?"

    local ssh_key bastion_pub_ip bastion_priv_ip lb_dns
    ssh_key="$(echo "${output}" | jq -r '.ssh_key_path.value')"
    bastion_pub_ip="$(echo "${output}" | jq -r '.bastion_public_ip.value // empty' 2>/dev/null)"
    bastion_priv_ip="$(echo "${output}" | jq -r '.bastion_private_ip.value // empty' 2>/dev/null)"
    lb_dns="$(echo "${output}" | jq -r '.lb_dns_name.value' 2>/dev/null)"

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
        registry)
            info "Tunnelling Harbor Registry UI → https://localhost:8443"
            info "  (via bastion ${bastion_pub_ip} → localhost:443)"
            info "  Press Ctrl-C to stop."
            ssh -o StrictHostKeyChecking=no -i "${ssh_key}" \
                -L "0.0.0.0:8443:localhost:443" -N "ubuntu@${bastion_pub_ip}"
            ;;
        "")
            echo ""
            echo -e "${BOLD}Available tunnels:${RESET}"
            echo ""
            echo "  t tunnel dashboard    MKE4k Dashboard → https://localhost:3000"
            echo "  t tunnel registry     Harbor Registry  → https://localhost:8443"
            echo ""
            echo -e "${BOLD}Or run manually:${RESET}"
            echo ""
            echo "  # MKE4k Dashboard (via NLB)"
            echo "  ssh -i ${ssh_key} -L 0.0.0.0:3000:${lb_dns}:443 -N ubuntu@${bastion_pub_ip}"
            echo ""
            echo "  # Harbor Registry UI"
            echo "  ssh -i ${ssh_key} -L 0.0.0.0:8443:localhost:443 -N ubuntu@${bastion_pub_ip}"
            echo ""
            echo "  # Kubernetes API (for local kubectl)"
            echo "  ssh -i ${ssh_key} -L 0.0.0.0:6443:${lb_dns}:6443 -N ubuntu@${bastion_pub_ip}"
            echo ""
            if [[ -t 0 ]]; then
                echo -e "${CYAN}Note: If running inside Docker, start with -p 3000:3000 -p 8443:8443${RESET}"
            fi
            ;;
        *)
            die "Unknown tunnel target: ${target}. Try: dashboard, registry"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF

${BOLD}mke4k-lab — t CLI${RESET}

Usage: t <command> [subcommand] [mke4|mke3|airgap]

Commands:
  deploy lab [mke4]       Provision instances + install MKE4k (default)
  deploy lab mke3         Provision instances + install MKE3 (both NLBs created)
  deploy lab airgap       Provision airgap lab: bastion + registry + MKE4k
  deploy instances        Provision EC2 instances and NLBs only (terraform apply)
  deploy instances mke3   Provision with MKE3 NLB enabled
  deploy instances airgap Provision bastion + private-subnet nodes (terraform only)
  deploy cluster          Install MKE4k on existing instances (mkectl apply)
  deploy cluster mke3     Install MKE3 on existing instances (launchpad apply)
  deploy cluster airgap   Install MKE4k from bastion (airgap, mkectl on bastion)
  deploy registry         Setup MSR4 on bastion + upload MKE4k bundle
  destroy cluster         Uninstall MKE4k from nodes (mkectl reset --force)
  destroy cluster mke3    Uninstall MKE3 from nodes (launchpad reset --force)
  destroy cluster airgap  Uninstall MKE4k from bastion (mkectl reset --force)
  destroy lab             Destroy all AWS infrastructure (terraform destroy)
  status                  Show cluster node status (kubectl get nodes)
  show nodes              Print controller/worker IPs and load balancer DNS
  connect bastion         SSH to bastion/registry host (airgap)
  connect <node>          SSH into a node (m1/m2/m3, w1/w2/w3, or raw IP)
  connect <node> cmd      Run a single command on a node and return
  tunnel                  Show available SSH tunnels for airgap UIs
  tunnel dashboard        Port-forward MKE4k Dashboard → https://localhost:3000
  tunnel registry         Port-forward Harbor Registry → https://localhost:8443

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
                    mke4)   cmd_deploy_lab_mke4 ;;
                    mke3)   cmd_deploy_lab_mke3 ;;
                    airgap) cmd_deploy_lab_airgap ;;
                    *)      die "Unknown variant: t deploy lab ${3}. Try: mke4, mke3, airgap" ;;
                esac
                ;;
            instances)
                case "${3:-mke4}" in
                    mke4)   cmd_deploy_instances ;;
                    mke3)   cmd_deploy_instances_mke3 ;;
                    airgap) cmd_deploy_instances_airgap ;;
                    *)      die "Unknown variant: t deploy instances ${3}. Try: mke4, mke3, airgap" ;;
                esac
                ;;
            cluster)
                case "${3:-mke4}" in
                    mke4)   cmd_deploy_cluster ;;
                    mke3)   cmd_deploy_cluster_mke3 ;;
                    airgap) cmd_deploy_cluster_airgap ;;
                    *)      die "Unknown variant: t deploy cluster ${3}. Try: mke4, mke3, airgap" ;;
                esac
                ;;
            registry)  cmd_deploy_registry ;;
            *)         die "Unknown subcommand: t deploy ${SUBCOMMAND}. Try: lab, instances, cluster, registry" ;;
        esac
        ;;
    destroy)
        case "${SUBCOMMAND}" in
            lab)     cmd_destroy_lab ;;
            cluster)
                case "${3:-mke4}" in
                    mke4)   cmd_destroy_cluster ;;
                    mke3)   cmd_destroy_cluster_mke3 ;;
                    airgap) cmd_destroy_cluster_airgap ;;
                    *)      die "Unknown variant: t destroy cluster ${3}. Try: mke4, mke3, airgap" ;;
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
    tunnel)  cmd_tunnel "${SUBCOMMAND}" ;;
    help|--help|-h|"") usage ;;
    *) die "Unknown command: ${COMMAND}. Run 't help' for usage." ;;
esac
