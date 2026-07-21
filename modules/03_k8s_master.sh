#!/usr/bin/env bash
# =============================================================================
# KubeOps-Suite :: modules/03_k8s_master.sh
# Purpose : Provision a Kubernetes Master (Control Plane) node.
#           - Detects ONLINE vs AIR-GAPPED mode dynamically
#           - Supports kubeadm + containerd (both modes)
#           - Generates and persists the join token to state manager
#           - Applies security hardening for kubeconfig
#           - Air-Gap mode: loads images from offline-assets/ tarball
# Author  : KubeOps-Suite (Principal Platform Engineer)
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve suite root and source libraries
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${SUITE_ROOT}/lib/logger.sh"
source "${SUITE_ROOT}/lib/os_detect.sh"
source "${SUITE_ROOT}/lib/network_check.sh"
source "${SUITE_ROOT}/lib/state_manager.sh"

# ---------------------------------------------------------------------------
# Configuration defaults (overridable via environment)
# ---------------------------------------------------------------------------
K8S_VERSION="${K8S_VERSION:-1.29}"
K8S_VERSION_FULL="${K8S_VERSION_FULL:-1.29.15}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
SERVICE_CIDR="${SERVICE_CIDR:-10.96.0.0/12}"
K8S_DNS_DOMAIN="${K8S_DNS_DOMAIN:-cluster.local}"
CNI_PLUGIN="${CNI_PLUGIN:-cilium}"             # cilium | calico | flannel

readonly OFFLINE_ASSETS_DIR="${SUITE_ROOT}/offline-assets"
readonly CONTAINERD_CONFIG_DIR="/etc/containerd"
readonly CRICTL_CONFIG="/etc/crictl.yaml"
readonly KUBECONFIG_PATH="/etc/kubernetes/admin.conf"
readonly KUBECONFIG_LOCAL="${HOME}/.kube/config"

# Kubernetes repository URLs
K8S_APT_KEYRING="/etc/apt/keyrings/kubernetes-apt-keyring.gpg"
K8S_APT_REPO="https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/"
K8S_RPM_REPO="https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/rpm/"

# ---------------------------------------------------------------------------
# Preflight validation
# ---------------------------------------------------------------------------

_master_preflight() {
    log_section "Master Node Preflight Checks"
    local errors=0

    # Must be root
    if [[ "${EUID}" -ne 0 ]]; then
        log_error "Must run as root (or via sudo)"
        (( errors++ )) || true
    fi

    # OS detection
    os_detect || (( errors++ )) || true

    # System requirements: 2 CPU, 2GB RAM, 20GB disk (official minimums)
    os_check_requirements 1700 2 15 || log_warn "System below recommended specs — proceeding anyway"

    # Network mode detection
    net_detect_mode

    # Hostname resolution
    local hostname
    hostname=$(hostname -f 2>/dev/null || hostname)
    if ! getent hosts "${hostname}" &>/dev/null && ! ping -c1 -W2 "${hostname}" &>/dev/null 2>&1; then
        log_warn "Hostname '${hostname}' may not be resolvable. Ensure /etc/hosts is correct."
    fi

    # Check for existing installations (k8s, containerd, docker, CNI)
    local existing
    existing=$(system_detect_existing_installations 2>/dev/null || echo "")
    if [[ -n "${existing}" || -f "${KUBECONFIG_PATH}" ]]; then
        log_warn "Se detectaron componentes/instalaciones previas en el servidor:"
        printf "         ${CLR_BOLD_YELLOW}%s${CLR_RESET}\n\n" "${existing:-Kubernetes kubeconfig}"
        if confirm "¿Desea ejecutar la LIMPIEZA PROFUNDA (purga completa de paquetes k8s, containerd/docker, datos CNI y puertos)?"; then
            system_deep_cleanup
        else
            log_info "Procediendo con reset estándar..."
            sudo systemctl stop kubelet 2>/dev/null || true
            sudo kubeadm reset -f 2>/dev/null || true
            sudo fuser -k 6443/tcp 10259/tcp 10257/tcp 2379/tcp 2380/tcp 2>/dev/null || true
            sudo rm -rf /etc/cni/net.d /var/lib/etcd /var/lib/kubelet/* "${KUBECONFIG_LOCAL}" "${KUBECONFIG_PATH}" 2>/dev/null || true
            log_success "Reset básico completado"
        fi
    fi

    # Check swap (must be disabled for k8s)
    if swapon --show 2>/dev/null | grep -q .; then
        log_warn "Swap is enabled — disabling now"
        os_disable_swap
    else
        log_success "Swap: disabled ✓"
    fi

    if [[ "${errors}" -gt 0 ]]; then
        log_fatal "Preflight failed with ${errors} error(s). Resolve them and retry."
    fi

    log_success "Preflight checks passed"
}

# ---------------------------------------------------------------------------
# Containerd Configuration & Helpers
# ---------------------------------------------------------------------------

_configure_containerd_mirror() {
    local registry_url="${1}"
    local mirror_dir="${CONTAINERD_CONFIG_DIR}/certs.d/${registry_url}"
    sudo mkdir -p "${mirror_dir}"
    sudo tee "${mirror_dir}/hosts.toml" > /dev/null <<EOF
server = "http://${registry_url}"

[host."http://${registry_url}"]
  capabilities = ["pull", "resolve", "push"]
  skip_verify = true
EOF

    # Also add mirror for common registries in air-gap
    for base_registry in "docker.io" "registry.k8s.io" "quay.io" "gcr.io"; do
        local base_mirror_dir="${CONTAINERD_CONFIG_DIR}/certs.d/${base_registry}"
        sudo mkdir -p "${base_mirror_dir}"
        sudo tee "${base_mirror_dir}/hosts.toml" > /dev/null <<EOF
server = "https://${base_registry}"

[host."http://${registry_url}"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
EOF
    done
    log_success "Containerd mirrors configured for air-gap registry"
}

_inject_nexus_mirrors_if_configured() {
    # Load from state if not in environment
    if [[ -z "${NEXUS_REGISTRY:-}" ]]; then
        local nexus_from_state
        nexus_from_state=$(state_get ".nexus.registry" 2>/dev/null || echo "")
        if [[ -z "${nexus_from_state}" || "${nexus_from_state}" == "null" ]]; then
            log_debug "NEXUS_REGISTRY not set — skipping Nexus mirror injection"
            return 0
        fi
        export NEXUS_REGISTRY="${nexus_from_state}"
    fi

    log_info "Injecting Nexus mirrors for ${CLR_BOLD_CYAN}${NEXUS_REGISTRY}${CLR_RESET} → containerd"

    local certs_dir="${CONTAINERD_CONFIG_DIR}/certs.d"
    sudo mkdir -p "${certs_dir}"

    local -a registries=(
        "docker.io|https://registry-1.docker.io"
        "registry.k8s.io|https://registry.k8s.io"
        "quay.io|https://quay.io"
        "ghcr.io|https://ghcr.io"
        "gcr.io|https://gcr.io"
        "k8s.gcr.io|https://k8s.gcr.io"
    )

    for entry in "${registries[@]}"; do
        local reg="${entry%%|*}"
        local fallback="${entry##*|}"
        local mirror_dir="${certs_dir}/${reg}"

        sudo mkdir -p "${mirror_dir}"
        sudo tee "${mirror_dir}/hosts.toml" > /dev/null <<EOF
# KubeOps-Suite — Auto-generated Nexus mirror for ${reg}
server = "${fallback}"

[host."http://${NEXUS_REGISTRY}"]
  capabilities = ["pull", "resolve"]
  skip_verify   = true

[host."${fallback}"]
  capabilities = ["pull", "resolve"]
EOF
        log_debug "Mirror set: ${reg} → http://${NEXUS_REGISTRY} (fallback: ${fallback})"
    done

    local config_toml="${CONTAINERD_CONFIG_DIR}/config.toml"
    if [[ -f "${config_toml}" ]]; then
        sudo sed -i '/# KubeOps-Nexus-mirrors-start/,/# KubeOps-Nexus-mirrors-end/d' \
            "${config_toml}" 2>/dev/null || true

        sudo tee -a "${config_toml}" > /dev/null <<EOF

# KubeOps-Nexus-mirrors-start  (auto-generated — do not edit manually)
[plugins."io.containerd.grpc.v1.cri".registry]
  config_path = "${certs_dir}"

  [plugins."io.containerd.grpc.v1.cri".registry.mirrors]
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."docker.io"]
      endpoint = ["http://${NEXUS_REGISTRY}", "https://registry-1.docker.io"]
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."registry.k8s.io"]
      endpoint = ["http://${NEXUS_REGISTRY}", "https://registry.k8s.io"]
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."quay.io"]
      endpoint = ["http://${NEXUS_REGISTRY}", "https://quay.io"]
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."ghcr.io"]
      endpoint = ["http://${NEXUS_REGISTRY}", "https://ghcr.io"]

  [plugins."io.containerd.grpc.v1.cri".registry.configs."${NEXUS_REGISTRY}".tls]
    insecure_skip_verify = true
# KubeOps-Nexus-mirrors-end
EOF
    fi

    log_success "Nexus mirrors injected — restarting containerd"
    sudo systemctl restart containerd 2>/dev/null || \
        sudo service containerd restart 2>/dev/null || true
}

_configure_containerd() {
    log_info "Configuring containerd..."

    sudo mkdir -p "${CONTAINERD_CONFIG_DIR}"

    # Generate default config
    if command -v containerd &>/dev/null || [[ -x /usr/bin/containerd ]] || [[ -x /usr/local/bin/containerd ]]; then
        local c_bin="containerd"
        [[ -x /usr/bin/containerd ]] && c_bin="/usr/bin/containerd"
        [[ -x /usr/local/bin/containerd ]] && c_bin="/usr/local/bin/containerd"

        ${c_bin} config default | sudo tee "${CONTAINERD_CONFIG_DIR}/config.toml" > /dev/null
    else
        log_warn "containerd binary not found in PATH — writing minimal config"
        sudo tee "${CONTAINERD_CONFIG_DIR}/config.toml" > /dev/null <<'EOF'
version = 2

[plugins."io.containerd.grpc.v1.cri"]
  [plugins."io.containerd.grpc.v1.cri".containerd]
    [plugins."io.containerd.grpc.v1.cri".containerd.runtimes]
      [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
        runtime_type = "io.containerd.runc.v2"
        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
          SystemdCgroup = true
EOF
    fi

    # Enable SystemdCgroup (required for Kubernetes)
    sudo sed -i \
        's/SystemdCgroup = false/SystemdCgroup = true/' \
        "${CONTAINERD_CONFIG_DIR}/config.toml"

    # If AIR-GAP: configure mirror to local registry
    if net_is_airgap; then
        local registry_url
        registry_url=$(state_get ".registry.url" 2>/dev/null || echo "")
        if [[ -n "${registry_url}" && "${registry_url}" != "null" ]]; then
            log_info "Configuring containerd mirror → ${registry_url}"
            _configure_containerd_mirror "${registry_url}"
        fi
    fi

    # Hook: inject Nexus mirrors if NEXUS_REGISTRY is set (additive, idempotent)
    _inject_nexus_mirrors_if_configured

    # Enable and start containerd
    sudo systemctl daemon-reload
    sudo systemctl enable containerd 2>/dev/null || true
    sudo systemctl restart containerd 2>/dev/null || true
}

_install_containerd_online() {
    log_step 1 6 "Installing containerd (ONLINE mode)"
    export PATH="${PATH}:/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin"

    _ensure_containerd_binaries
    _ensure_containerd_systemd_service
    _configure_containerd
    log_success "containerd instalado y configurado correctamente (online)"
}

_install_containerd_airgap() {
    log_step 1 6 "Installing containerd (AIR-GAP mode)"

    local containerd_tar
    containerd_tar=$(find "${OFFLINE_ASSETS_DIR}" -name "containerd*.tar.gz" 2>/dev/null | head -1 || echo "")

    if [[ -z "${containerd_tar}" ]]; then
        log_fatal "No containerd tarball found in ${OFFLINE_ASSETS_DIR}/. \
Expected: containerd-<version>-linux-amd64.tar.gz"
    fi

    log_info "Installing containerd from: ${containerd_tar}"
    sudo tar -C /usr/local -xzf "${containerd_tar}"

    _ensure_containerd_systemd_service

    local runc_bin
    runc_bin=$(find "${OFFLINE_ASSETS_DIR}" -name "runc.amd64" -o -name "runc" 2>/dev/null | head -1 || echo "")
    if [[ -n "${runc_bin}" ]]; then
        sudo install -m 755 "${runc_bin}" /usr/local/sbin/runc
        sudo install -m 755 "${runc_bin}" /usr/bin/runc 2>/dev/null || true
        log_success "runc installed"
    else
        log_warn "runc binary not found in offline-assets — containerd may not start"
    fi

    local cni_tar
    cni_tar=$(find "${OFFLINE_ASSETS_DIR}" -name "cni-plugins*.tar.gz" 2>/dev/null | head -1 || echo "")
    if [[ -n "${cni_tar}" ]]; then
        sudo mkdir -p /opt/cni/bin
        sudo tar -C /opt/cni/bin -xzf "${cni_tar}"
        log_success "CNI plugins installed from tarball"
    fi

    _configure_containerd
    log_success "containerd installed (air-gap)"
}

_wait_for_apt_lock() {
    local count=0
    while sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
          sudo fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || \
          sudo fuser /var/lib/dpkg/lock >/dev/null 2>&1; do
        if [[ "${count}" -eq 0 ]]; then
            log_info "Esperando a que finalicen las actualizaciones automáticas del sistema (apt lock)..."
        fi
        sleep 3
        count=$(( count + 3 ))
        if [[ "${count}" -gt 120 ]]; then
            log_warn "Liberando candado de apt atascado..."
            sudo killall apt-get apt 2>/dev/null || true
            sudo rm -f /var/lib/apt/lists/lock /var/lib/dpkg/lock* /var/cache/apt/archives/lock 2>/dev/null || true
            sudo dpkg --configure -a 2>/dev/null || true
            break
        fi
    done
}

_ensure_containerd_binaries() {
    # If containerd is already installed and in PATH, we're good
    if command -v containerd &>/dev/null || [[ -x /usr/bin/containerd ]] || [[ -x /usr/local/bin/containerd ]]; then
        log_success "Binario containerd presente en el sistema"
        return 0
    fi

    log_info "Instalando paquete containerd..."
    local installed=false

    case "${OS_FAMILY}" in
        debian)
            export DEBIAN_FRONTEND=noninteractive
            _wait_for_apt_lock

            # Intento 1: Paquete oficial del sistema Ubuntu/Debian
            log_info "Intentando instalacion via apt (repo del sistema)..."
            sudo apt-get update -qq 2>/dev/null || true
            if sudo apt-get install -y containerd >/tmp/apt-containerd.log 2>&1; then
                installed=true
                log_success "containerd instalado exitosamente via apt"
            fi

            # Intento 2: Repo oficial de Docker si apt fallo
            if [[ "${installed}" != "true" ]]; then
                log_warn "apt nativo no instalo containerd — intentando repositorio de Docker..."
                _wait_for_apt_lock
                sudo install -m 0755 -d /etc/apt/keyrings 2>/dev/null || true
                curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" 2>/dev/null | \
                    sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null || true
                sudo chmod a+r /etc/apt/keyrings/docker.gpg 2>/dev/null || true

                if [[ -f /etc/apt/keyrings/docker.gpg && -n "${OS_CODENAME:-}" ]]; then
                    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${OS_ID} ${OS_CODENAME} stable" | \
                        sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
                    sudo apt-get update -qq 2>/dev/null || true
                    if sudo apt-get install -y containerd.io >/dev/null 2>&1; then
                        installed=true
                        log_success "containerd.io instalado via repo Docker"
                    fi
                fi
            fi
            ;;

        rhel)
            if sudo ${PKG_MANAGER} install -y containerd 2>/dev/null || sudo ${PKG_MANAGER} install -y containerd.io 2>/dev/null; then
                installed=true
                log_success "containerd instalado via ${PKG_MANAGER}"
            fi
            ;;
    esac

    # Intento 3 (Respaldo definitivo): Descarga directa del binario oficial de GitHub
    if [[ ! -x /usr/bin/containerd && ! -x /usr/local/bin/containerd ]]; then
        log_warn "Los paquetes de la distribucion no se pudieron instalar — descargando binario oficial de GitHub..."
        local c_ver="1.7.13"
        local c_url="https://github.com/containerd/containerd/releases/download/v${c_ver}/containerd-${c_ver}-linux-amd64.tar.gz"
        
        if curl -fsSL "${c_url}" -o /tmp/containerd.tar.gz; then
            sudo tar -C /usr/local -xzf /tmp/containerd.tar.gz 2>/dev/null || sudo tar -C /usr -xzf /tmp/containerd.tar.gz 2>/dev/null
            rm -f /tmp/containerd.tar.gz

            # Copiar binarios a /usr/bin/ y /usr/local/bin/ para asegurar visibilidad total
            sudo mkdir -p /usr/bin /usr/local/bin
            sudo cp -f /usr/local/bin/containerd* /usr/bin/ 2>/dev/null || true
            sudo cp -f /usr/local/bin/ctr /usr/bin/ 2>/dev/null || true
            log_success "containerd v${c_ver} instalado desde release de GitHub"
        else
            log_fatal "No se pudo descargar containerd desde GitHub ni instalar mediante paquetes."
        fi
    fi

    # Asegurar runc
    if ! command -v runc &>/dev/null && [[ ! -x /usr/bin/runc ]] && [[ ! -x /usr/local/sbin/runc ]]; then
        log_info "Instalando dependencia runc..."
        sudo apt-get install -y runc 2>/dev/null || {
            curl -fsSL "https://github.com/opencontainers/runc/releases/download/v1.1.12/runc.amd64" -o /tmp/runc 2>/dev/null && \
            sudo install -m 755 /tmp/runc /usr/bin/runc 2>/dev/null && \
            sudo install -m 755 /tmp/runc /usr/local/sbin/runc 2>/dev/null || true
        }
    fi
}

_ensure_containerd_systemd_service() {
    local service_file="/etc/systemd/system/containerd.service"
    if [[ ! -f "${service_file}" && ! -f "/lib/systemd/system/containerd.service" ]]; then
        log_info "Creando servicio systemd para containerd..."
        local exec_path="/usr/bin/containerd"
        [[ -x /usr/local/bin/containerd ]] && exec_path="/usr/local/bin/containerd"

        sudo tee "${service_file}" > /dev/null <<EOF
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network.target local-fs.target

[Service]
ExecStartPre=-/sbin/modprobe overlay
ExecStart=${exec_path}
Type=notify
Delegate=yes
KillMode=process
Restart=always
RestartSec=5
LimitNPROC=infinity
LimitCORE=infinity
LimitNOFILE=infinity
TasksMax=infinity
OOMScoreAdjust=-999

[Install]
WantedBy=multi-user.target
EOF
        sudo systemctl daemon-reload
    fi
    sudo systemctl daemon-reload
    sudo systemctl enable containerd
    sudo systemctl restart containerd

    # Configure crictl
    sudo tee "${CRICTL_CONFIG}" > /dev/null <<'EOF'
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
EOF

    log_success "containerd configured and started"
}

_configure_containerd_mirror() {
    local registry_url="${1}"
    local mirror_dir="${CONTAINERD_CONFIG_DIR}/certs.d/${registry_url}"
    sudo mkdir -p "${mirror_dir}"
    sudo tee "${mirror_dir}/hosts.toml" > /dev/null <<EOF
server = "http://${registry_url}"

[host."http://${registry_url}"]
  capabilities = ["pull", "resolve", "push"]
  skip_verify = true
EOF

    # Also add mirror for common registries in air-gap
    for base_registry in "docker.io" "registry.k8s.io" "quay.io" "gcr.io"; do
        local base_mirror_dir="${CONTAINERD_CONFIG_DIR}/certs.d/${base_registry}"
        sudo mkdir -p "${base_mirror_dir}"
        sudo tee "${base_mirror_dir}/hosts.toml" > /dev/null <<EOF
server = "https://${base_registry}"

[host."http://${registry_url}"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
EOF
    done
    log_success "Containerd mirrors configured for air-gap registry"
}

# ---------------------------------------------------------------------------
# Nexus Registry Mirror Injection (additive — called only if NEXUS_REGISTRY set)
# ---------------------------------------------------------------------------

# _inject_nexus_mirrors_if_configured: Configures containerd mirror endpoints
# to proxy docker.io, registry.k8s.io, quay.io and ghcr.io through Nexus.
# Idempotent: safe to call multiple times (overwrites existing mirror config).
# No-op if NEXUS_REGISTRY is unset or empty.
_inject_nexus_mirrors_if_configured() {
    # Load from state if not in environment
    if [[ -z "${NEXUS_REGISTRY:-}" ]]; then
        local nexus_from_state
        nexus_from_state=$(state_get ".nexus.registry" 2>/dev/null || echo "")
        if [[ -z "${nexus_from_state}" || "${nexus_from_state}" == "null" ]]; then
            log_debug "NEXUS_REGISTRY not set — skipping Nexus mirror injection"
            return 0
        fi
        export NEXUS_REGISTRY="${nexus_from_state}"
    fi

    log_info "Injecting Nexus mirrors for ${CLR_BOLD_CYAN}${NEXUS_REGISTRY}${CLR_RESET} → containerd"

    local certs_dir="${CONTAINERD_CONFIG_DIR}/certs.d"
    sudo mkdir -p "${certs_dir}"

    # Registries to proxy through Nexus
    # Format: "public_registry|fallback_server_url"
    local -a registries=(
        "docker.io|https://registry-1.docker.io"
        "registry.k8s.io|https://registry.k8s.io"
        "quay.io|https://quay.io"
        "ghcr.io|https://ghcr.io"
        "gcr.io|https://gcr.io"
        "k8s.gcr.io|https://k8s.gcr.io"
    )

    for entry in "${registries[@]}"; do
        local reg="${entry%%|*}"
        local fallback="${entry##*|}"
        local mirror_dir="${certs_dir}/${reg}"

        sudo mkdir -p "${mirror_dir}"
        sudo tee "${mirror_dir}/hosts.toml" > /dev/null <<EOF
# KubeOps-Suite — Auto-generated Nexus mirror for ${reg}
# Nexus endpoint: http://${NEXUS_REGISTRY}
server = "${fallback}"

[host."http://${NEXUS_REGISTRY}"]
  capabilities = ["pull", "resolve"]
  skip_verify   = true

[host."${fallback}"]
  capabilities = ["pull", "resolve"]
EOF
        log_debug "Mirror set: ${reg} → http://${NEXUS_REGISTRY} (fallback: ${fallback})"
    done

    # Also patch config.toml mirrors section for older containerd / crictl compatibility
    local config_toml="${CONTAINERD_CONFIG_DIR}/config.toml"
    if [[ -f "${config_toml}" ]]; then
        # Remove any existing [registry.mirrors] block we may have written before
        sudo sed -i '/# KubeOps-Nexus-mirrors-start/,/# KubeOps-Nexus-mirrors-end/d' \
            "${config_toml}" 2>/dev/null || true

        # Append updated mirrors block
        sudo tee -a "${config_toml}" > /dev/null <<EOF

# KubeOps-Nexus-mirrors-start  (auto-generated — do not edit manually)
[plugins."io.containerd.grpc.v1.cri".registry]
  config_path = "${certs_dir}"

  [plugins."io.containerd.grpc.v1.cri".registry.mirrors]
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."docker.io"]
      endpoint = ["http://${NEXUS_REGISTRY}", "https://registry-1.docker.io"]
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."registry.k8s.io"]
      endpoint = ["http://${NEXUS_REGISTRY}", "https://registry.k8s.io"]
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."quay.io"]
      endpoint = ["http://${NEXUS_REGISTRY}", "https://quay.io"]
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."ghcr.io"]
      endpoint = ["http://${NEXUS_REGISTRY}", "https://ghcr.io"]

  [plugins."io.containerd.grpc.v1.cri".registry.configs."${NEXUS_REGISTRY}".tls]
    insecure_skip_verify = true
# KubeOps-Nexus-mirrors-end
EOF
    fi

    log_success "Nexus mirrors injected — restarting containerd"
    sudo systemctl restart containerd 2>/dev/null || \
        sudo service containerd restart 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Kubernetes Binaries Installation
# ---------------------------------------------------------------------------

_install_k8s_binaries_online() {
    log_step 2 6 "Installing kubeadm, kubelet, kubectl (ONLINE mode)"

    case "${OS_FAMILY}" in
        debian)
            sudo install -m 0755 -d /etc/apt/keyrings
            if [[ ! -f "${K8S_APT_KEYRING}" ]]; then
                curl -fsSL "${K8S_APT_REPO}Release.key" | \
                    sudo gpg --dearmor -o "${K8S_APT_KEYRING}"
                sudo chmod 644 "${K8S_APT_KEYRING}"
            fi

            local k8s_list="/etc/apt/sources.list.d/kubernetes.list"
            if [[ ! -f "${k8s_list}" ]]; then
                echo "deb [signed-by=${K8S_APT_KEYRING}] ${K8S_APT_REPO} /" | \
                    sudo tee "${k8s_list}" > /dev/null
            fi

            os_update_pkg_cache
            os_install_pkg kubelet kubeadm kubectl

            # Pin versions to prevent automatic upgrades
            sudo apt-mark hold kubelet kubeadm kubectl 2>/dev/null || true
            ;;

        rhel)
            local k8s_repo_file="/etc/yum.repos.d/kubernetes.repo"
            if [[ ! -f "${k8s_repo_file}" ]]; then
                sudo tee "${k8s_repo_file}" > /dev/null <<EOF
[kubernetes]
name=Kubernetes
baseurl=${K8S_RPM_REPO}
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF
            fi
            sudo ${PKG_MANAGER} install -y \
                kubelet kubeadm kubectl \
                --disableexcludes=kubernetes

            # Pin versions
            if command -v dnf &>/dev/null; then
                sudo dnf versionlock add kubelet kubeadm kubectl 2>/dev/null || true
            fi
            ;;
    esac

    sudo systemctl enable kubelet
    log_success "Kubernetes binaries installed (online)"
}

_install_k8s_binaries_airgap() {
    log_step 2 6 "Installing kubeadm, kubelet, kubectl (AIR-GAP mode)"

    local k8s_tar
    k8s_tar=$(find "${OFFLINE_ASSETS_DIR}" -name "kubernetes-*.tar.gz" -o -name "k8s-bins-*.tar.gz" 2>/dev/null | head -1 || echo "")

    if [[ -n "${k8s_tar}" ]]; then
        log_info "Extracting Kubernetes binaries from: ${k8s_tar}"
        local tmp_dir
        tmp_dir=$(mktemp -d)
        tar -xzf "${k8s_tar}" -C "${tmp_dir}"

        for binary in kubeadm kubelet kubectl; do
            local bin_path
            bin_path=$(find "${tmp_dir}" -name "${binary}" -type f 2>/dev/null | head -1 || echo "")
            if [[ -n "${bin_path}" ]]; then
                sudo install -m 755 "${bin_path}" "/usr/local/bin/${binary}"
                log_success "Installed ${binary}"
            else
                log_warn "${binary} not found in tarball"
            fi
        done
        rm -rf "${tmp_dir}"
    else
        # Try individual binaries
        for binary in kubeadm kubelet kubectl; do
            local bin_path
            bin_path=$(find "${OFFLINE_ASSETS_DIR}" -name "${binary}" -type f 2>/dev/null | head -1 || echo "")
            if [[ -n "${bin_path}" ]]; then
                sudo install -m 755 "${bin_path}" "/usr/local/bin/${binary}"
                log_success "Installed ${binary}"
            else
                log_error "${binary} binary not found in ${OFFLINE_ASSETS_DIR}"
            fi
        done
    fi

    # Install kubelet systemd service and configuration
    _install_kubelet_service

    sudo systemctl enable kubelet
    log_success "Kubernetes binaries installed (air-gap)"
}

_install_kubelet_service() {
    local kubelet_service="/etc/systemd/system/kubelet.service"
    if [[ ! -f "${kubelet_service}" ]]; then
        sudo tee "${kubelet_service}" > /dev/null <<'EOF'
[Unit]
Description=kubelet: The Kubernetes Node Agent
Documentation=https://kubernetes.io/docs/
Wants=network-online.target
After=network-online.target

[Service]
ExecStart=/usr/local/bin/kubelet
Restart=always
StartLimitInterval=0
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    fi

    sudo mkdir -p /etc/systemd/system/kubelet.service.d
    local drop_in="/etc/systemd/system/kubelet.service.d/10-kubeadm.conf"
    if [[ ! -f "${drop_in}" ]]; then
        sudo tee "${drop_in}" > /dev/null <<'EOF'
[Service]
Environment="KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf"
Environment="KUBELET_CONFIG_ARGS=--config=/var/lib/kubelet/config.yaml"
EnvironmentFile=-/var/lib/kubelet/kubeadm-flags.env
EnvironmentFile=-/etc/default/kubelet
ExecStart=
ExecStart=/usr/local/bin/kubelet $KUBELET_KUBECONFIG_ARGS $KUBELET_CONFIG_ARGS $KUBELET_KUBEADM_ARGS $KUBELET_EXTRA_ARGS
EOF
    fi

    sudo systemctl daemon-reload
}

# ---------------------------------------------------------------------------
# Load Offline Container Images
# ---------------------------------------------------------------------------

_load_offline_images() {
    log_step 3 6 "Loading offline container images"

    local image_archives
    mapfile -t image_archives < <(find "${OFFLINE_ASSETS_DIR}" -name "*.tar" -o -name "images-*.tar.gz" 2>/dev/null | sort)

    if [[ ${#image_archives[@]} -eq 0 ]]; then
        log_warn "No image archives found in ${OFFLINE_ASSETS_DIR}"
        log_warn "Expected files: k8s-images-*.tar or individual *.tar files"
        return 0
    fi

    local total=${#image_archives[@]}
    local count=0
    for archive in "${image_archives[@]}"; do
        (( count++ )) || true
        log_progress_bar "${count}" "${total}" "Loading images"
        local archive_name
        archive_name=$(basename "${archive}")

        if [[ "${archive}" == *.tar.gz ]]; then
            log_debug "Importing gzipped archive: ${archive_name}"
            if ! sudo ctr -n k8s.io images import <(gzip -dc "${archive}") 2>/dev/null; then
                log_warn "Failed to import ${archive_name} via ctr — trying docker load"
                if command -v docker &>/dev/null; then
                    sudo docker load < "${archive}" 2>/dev/null || log_warn "docker load also failed for ${archive_name}"
                fi
            fi
        else
            log_debug "Importing archive: ${archive_name}"
            if ! sudo ctr -n k8s.io images import "${archive}" 2>/dev/null; then
                log_warn "Failed to import ${archive_name} via ctr"
            fi
        fi
    done

    echo ""  # newline after progress bar
    log_success "Offline images loaded: ${total} archive(s) processed"
}

# ---------------------------------------------------------------------------
# kubeadm init
# ---------------------------------------------------------------------------

_build_kubeadm_init_config() {
    local master_ip="${1}"
    local cluster_name="${2}"
    local config_file="/tmp/kubeops-kubeadm-init.yaml"

    local image_repo_line=""
    if net_is_airgap; then
        local registry_url
        registry_url=$(state_get ".registry.url" 2>/dev/null || echo "")
        if [[ -n "${registry_url}" && "${registry_url}" != "null" ]]; then
            image_repo_line="imageRepository: ${registry_url}"
        fi
    fi

    local endpoint="${CONTROL_PLANE_ENDPOINT:-${master_ip}:6443}"
    if [[ "${endpoint}" != *":"* ]]; then
        endpoint="${endpoint}:6443"
    fi
    local ep_ip="${endpoint%%:*}"

    sudo tee "${config_file}" > /dev/null <<EOF
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: "${master_ip}"
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
  taints:
    - effect: PreferNoSchedule
      key: node-role.kubernetes.io/control-plane
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
clusterName: "${cluster_name}"
kubernetesVersion: "v${K8S_VERSION_FULL}"
controlPlaneEndpoint: "${endpoint}"
networking:
  podSubnet: "${POD_CIDR}"
  serviceSubnet: "${SERVICE_CIDR}"
  dnsDomain: "${K8S_DNS_DOMAIN}"
apiServer:
  certSANs:
    - "127.0.0.1"
    - "${master_ip}"
    - "${ep_ip}"
  extraArgs:
    authorization-mode: Node,RBAC
    enable-admission-plugins: NodeRestriction,PodSecurity
    audit-log-path: /var/log/kubernetes/audit.log
    audit-log-maxage: "30"
    audit-log-maxbackup: "10"
    audit-log-maxsize: "100"
    tls-min-version: VersionTLS12
    anonymous-auth: "true"
controllerManager:
  extraArgs:
    bind-address: 0.0.0.0
scheduler:
  extraArgs:
    bind-address: 0.0.0.0
etcd:
  local:
    dataDir: /var/lib/etcd
${image_repo_line}
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
serverTLSBootstrap: true
protectKernelDefaults: true
makeIPTablesUtilChains: true
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
mode: iptables
EOF

    echo "${config_file}"
}

_run_kubeadm_init() {
    local master_ip="${1}"
    local cluster_name="${2}"

    log_step 4 6 "Running kubeadm init"

    local config_file
    config_file=$(_build_kubeadm_init_config "${master_ip}" "${cluster_name}")

    log_info "Pulling required Kubernetes container images (kube-apiserver, etcd, coredns)..."
    if net_is_online; then
        sudo kubeadm config images pull --config "${config_file}" || true
        log_success "Kubernetes container images pulled"
    else
        log_info "Air-gap mode — skipping image pull (using local registry/pre-loaded images)"
    fi

    log_info "Initializing Kubernetes control plane (this takes 1-2 minutes)..."
    export KUBEOPS_KUBEADM_INIT_LOG="/tmp/kubeops-kubeadm-init.log"

    # Kill any residual process listening on Kubernetes control plane ports
    sudo fuser -k 6443/tcp 10259/tcp 10257/tcp 2379/tcp 2380/tcp 2>/dev/null || true

    if ! sudo kubeadm init \
        --config "${config_file}" \
        --upload-certs \
        --ignore-preflight-errors=Port-6443,Port-10259,Port-10257,Port-10250 \
        --v=5 \
        2>&1 | tee "${KUBEOPS_KUBEADM_INIT_LOG}"; then

        log_error "kubeadm init FAILED — full log at ${KUBEOPS_KUBEADM_INIT_LOG}"
        tail -30 "${KUBEOPS_KUBEADM_INIT_LOG}" | while IFS= read -r l; do log_error "${l}"; done
        return 1
    fi

    log_success "kubeadm init completed successfully"
}

_extract_join_credentials() {
    local init_log="${1}"

    log_debug "Extracting join credentials from init output..." >&2

    # Extract token (format: xxxxxx.xxxxxxxxxxxxxxxx)
    local token
    token=$(grep -oP '(?<=--token )\S+' "${init_log}" 2>/dev/null | head -1 || echo "")

    # Extract CA cert hash (sha256:...)
    local ca_hash
    ca_hash=$(grep -oP '(?<=--discovery-token-ca-cert-hash sha256:)\S+' "${init_log}" 2>/dev/null | head -1 || echo "")

    # Extract certificate key (for HA master join)
    local cert_key
    cert_key=$(grep -oP '(?<=--certificate-key )\S+' "${init_log}" 2>/dev/null | head -1 || echo "")

    # Ensure cluster-info ConfigMap and RBAC in kube-public are properly configured
    sudo kubeadm init phase bootstrap-token 2>/dev/null || true

    if [[ -z "${token}" ]] || [[ -z "${ca_hash}" ]]; then
        token=$(sudo kubeadm token create 2>/dev/null | head -1)
        ca_hash=$(sudo openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt 2>/dev/null | \
            openssl rsa -pubin -outform der 2>/dev/null | \
            openssl dgst -sha256 -hex 2>/dev/null | \
            awk '{print $2}')
        cert_key=$(sudo kubeadm init phase upload-certs --upload-certs 2>/dev/null | \
            tail -1 | tr -d '[:space:]' || echo "")
    fi

    echo "${token}|${ca_hash}|${cert_key}"
}

# ---------------------------------------------------------------------------
# CNI Plugin deployment
# ---------------------------------------------------------------------------

_deploy_cni_online() {
    log_step 5 6 "Desplegando Plugin CNI de Red: ${CNI_PLUGIN} (ONLINE)"

    # Ensure standard CNI binaries exist in /opt/cni/bin for containerd
    sudo mkdir -p /opt/cni/bin
    if [[ ! -f /opt/cni/bin/loopback || ! -f /opt/cni/bin/bridge ]]; then
        log_info "Instalando binarios CNI estándar en /opt/cni/bin..."
        local cni_url="https://github.com/containernetworking/plugins/releases/download/v1.4.0/cni-plugins-linux-amd64-v1.4.0.tgz"
        curl -fsSL "${cni_url}" -o /tmp/cni-plugins.tgz 2>/dev/null || true
        if [[ -f /tmp/cni-plugins.tgz ]]; then
            sudo tar -xzf /tmp/cni-plugins.tgz -C /opt/cni/bin/ 2>/dev/null || true
            rm -f /tmp/cni-plugins.tgz
            log_success "Binarios CNI en /opt/cni/bin instalados"
        fi
    fi

    case "${CNI_PLUGIN}" in
        cilium)
            log_info "Desplegando Cilium CNI v1.15.5..."
            if ! command -v helm &>/dev/null; then
                log_info "Instalando Helm..."
                curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash 2>/dev/null || true
            fi

            if command -v helm &>/dev/null; then
                log_info "Desplegando Cilium vía Helm..."
                helm repo add cilium https://helm.cilium.io/ 2>/dev/null || true
                helm repo update cilium 2>/dev/null || true
                helm install cilium cilium/cilium --version 1.15.5 \
                    --namespace kube-system \
                    --set nodeinit.enabled=true \
                    --set ipam.mode=kubernetes \
                    --kubeconfig="${KUBECONFIG_PATH}" || true
            else
                log_info "Desplegando Calico CNI como fallback de red..."
                kubectl apply -f "https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/calico.yaml" --kubeconfig="${KUBECONFIG_PATH}"
            fi
            ;;
        calico)
            log_info "Desplegando Calico CNI v3.27.0..."
            local calico_url="https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/calico.yaml"
            kubectl apply -f "${calico_url}" --kubeconfig="${KUBECONFIG_PATH}"
            ;;
        flannel)
            log_info "Desplegando Flannel CNI..."
            local flannel_url="https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml"
            kubectl apply -f "${flannel_url}" --kubeconfig="${KUBECONFIG_PATH}"
            ;;
        *)
            log_warn "Plugin CNI desconocido '${CNI_PLUGIN}' — desplegando Calico"
            kubectl apply -f "https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/calico.yaml" --kubeconfig="${KUBECONFIG_PATH}"
            ;;
    esac

    log_success "Plugin CNI de Red desplegado: ${CNI_PLUGIN}"
}

_deploy_cni_airgap() {
    log_step 5 6 "Deploying CNI plugin: ${CNI_PLUGIN} (AIR-GAP)"

    local cni_manifest
    cni_manifest=$(find "${OFFLINE_ASSETS_DIR}" \
        -name "cilium*.yaml" -o \
        -name "calico.yaml" -o \
        -name "kube-flannel.yml" -o \
        -name "cni-*.yaml" 2>/dev/null | head -1 || echo "")

    if [[ -z "${cni_manifest}" ]]; then
        log_warn "No CNI manifest found in ${OFFLINE_ASSETS_DIR}"
        log_warn "Network plugin will NOT be installed. Nodes will remain NotReady."
        log_warn "Add cilium.yaml, calico.yaml or kube-flannel.yml to ${OFFLINE_ASSETS_DIR} and apply manually."
        return 0
    fi

    local registry_url
    registry_url=$(state_get ".registry.url" 2>/dev/null || echo "")

    if [[ -n "${registry_url}" && "${registry_url}" != "null" ]]; then
        log_info "Rewriting CNI manifest images to use local registry: ${registry_url}"
        local tmp_manifest="/tmp/cni-airgap.yaml"
        sed "s|docker.io|${registry_url}|g; s|quay.io|${registry_url}|g; s|ghcr.io|${registry_url}|g" \
            "${cni_manifest}" > "${tmp_manifest}"
        kubectl apply -f "${tmp_manifest}" --kubeconfig="${KUBECONFIG_LOCAL}"
        rm -f "${tmp_manifest}"
    else
        kubectl apply -f "${cni_manifest}" --kubeconfig="${KUBECONFIG_LOCAL}"
    fi

    log_success "CNI plugin deployed from offline manifest"
}

# ---------------------------------------------------------------------------
# Post-init setup
# ---------------------------------------------------------------------------

_setup_kubeconfig() {
    log_info "Configurando kubeconfig automáticamente para root y usuario activo..."

    # 1. Configurar para root (/root/.kube/config)
    sudo mkdir -p /root/.kube
    sudo cp -f /etc/kubernetes/admin.conf /root/.kube/config
    sudo chmod 600 /root/.kube/config

    # 2. Configurar para SUDO_USER (ej. ubuntu) si aplica
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        local user_home
        user_home=$(eval echo "~${SUDO_USER}")
        if [[ -d "${user_home}" ]]; then
            sudo mkdir -p "${user_home}/.kube"
            sudo cp -f /etc/kubernetes/admin.conf "${user_home}/.kube/config"
            sudo chown -R "${SUDO_USER}:${SUDO_USER}" "${user_home}/.kube"
            sudo chmod 600 "${user_home}/.kube/config"
            log_success "kubeconfig configurado para usuario: ${SUDO_USER} (${user_home}/.kube/config)"
        fi
    fi

    # 3. Exportar KUBECONFIG
    export KUBECONFIG="/root/.kube/config"

    # 4. Asegurar permisos RBAC públicos para cluster-info en kube-public
    sudo kubectl create rolebinding kubeadm:bootstrap-signer-cluster-info \
        --clusterrole=system:public-info-viewer \
        --group=system:anonymous \
        -n kube-public \
        --kubeconfig=/etc/kubernetes/admin.conf 2>/dev/null || true

    log_success "kubeconfig activado correctamente sin requerir pasos manuales."
}

_wait_for_control_plane() {
    log_info "Esperando a que los componentes del Control Plane y la red CNI (${CNI_PLUGIN}) estén en estado Ready..."

    local timeout=180
    local interval=5
    local elapsed=0

    while [[ "${elapsed}" -lt "${timeout}" ]]; do
        if kubectl get nodes --kubeconfig="${KUBECONFIG_PATH}" 2>/dev/null | grep -w "Ready" | grep -v "NotReady" &>/dev/null; then
            log_success "¡El nodo Máster y la red CNI están 100% Ready (${elapsed}s)!"
            return 0
        fi
        log_info "Inicializando red CNI y asignando IP a pods (${elapsed}s/${timeout}s)..."
        sleep "${interval}"
        elapsed=$(( elapsed + interval ))
    done

    log_warn "El clúster continúa inicializando pods en segundo plano."
    return 0
}

_apply_security_policies() {
    log_info "Applying baseline security policies..."

    # Label namespaces for Pod Security Standards
    for ns in default kube-system kube-public; do
        kubectl label namespace "${ns}" \
            pod-security.kubernetes.io/warn=baseline \
            pod-security.kubernetes.io/audit=baseline \
            --overwrite \
            --kubeconfig="${KUBECONFIG_LOCAL}" 2>/dev/null || true
    done

    # Create restrictive RBAC for service accounts
    kubectl apply --kubeconfig="${KUBECONFIG_LOCAL}" -f - <<'EOF' 2>/dev/null || true
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kubeops:node-reader
rules:
- apiGroups: [""]
  resources: ["nodes"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kubeops:node-reader
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: kubeops:node-reader
subjects:
- kind: Group
  name: system:authenticated
  apiGroup: rbac.authorization.k8s.io
EOF

    log_success "Security policies applied"
}

_print_cluster_summary() {
    local master_ip="${1}"
    local token="${2}"
    local ca_hash="${3}"
    local cert_key="${4}"

    log_section "🎉 Kubernetes Master Node — Provisioning Complete"

    printf "\n  ${CLR_BOLD_WHITE}Control Plane Info:${CLR_RESET}\n"
    printf "  %-30s %s\n" "API Server:"       "${CLR_BOLD_GREEN}${master_ip}:6443${CLR_RESET}"
    printf "  %-30s %s\n" "kubeconfig:"       "${CLR_CYAN}${KUBECONFIG_LOCAL}${CLR_RESET}"
    printf "  %-30s %s\n" "Mode:"             "$(if net_is_online; then echo "ONLINE"; else echo "AIR-GAPPED"; fi)"
    printf "  %-30s %s\n" "CNI Plugin:"       "${CNI_PLUGIN}"
    printf "  %-30s %s\n" "Pod CIDR:"         "${POD_CIDR}"

    printf "\n  ${CLR_BOLD_WHITE}Quick Commands:${CLR_RESET}\n"
    printf "  ${CLR_DIM}# View nodes:${CLR_RESET}\n"
    printf "  ${CLR_YELLOW}kubectl get nodes -o wide${CLR_RESET}\n\n"
    printf "  ${CLR_DIM}# View all pods:${CLR_RESET}\n"
    printf "  ${CLR_YELLOW}kubectl get pods -A${CLR_RESET}\n\n"

    printf "  ${CLR_BOLD_WHITE}Worker Join Command:${CLR_RESET}\n"
    printf "  ${CLR_BOLD_YELLOW}kubeadm join ${master_ip}:6443 \\\\\n"
    printf "    --token ${token} \\\\\n"
    printf "    --discovery-token-ca-cert-hash sha256:${ca_hash}${CLR_RESET}\n\n"

    if [[ -n "${cert_key}" ]]; then
        printf "  ${CLR_BOLD_WHITE}Master (HA) Join Command:${CLR_RESET}\n"
        printf "  ${CLR_BOLD_CYAN}kubeadm join ${master_ip}:6443 \\\\\n"
        printf "    --token ${token} \\\\\n"
        printf "    --discovery-token-ca-cert-hash sha256:${ca_hash} \\\\\n"
        printf "    --control-plane --certificate-key ${cert_key}${CLR_RESET}\n\n"
    fi
}

# ---------------------------------------------------------------------------
# Main Entrypoint
# ---------------------------------------------------------------------------

main() {
    log_banner
    log_section "Kubernetes Master Node Provisioning"

    # === 0. Preflight ===
    _master_preflight

    # === Collect Configuration ===
    local master_ip
    master_ip=$(net_get_primary_ip)
    printf "\n"
    printf "  ${CLR_BOLD_WHITE}Detected primary IP: ${CLR_BOLD_GREEN}%s${CLR_RESET}\n" "${master_ip}"
    printf "  Override IP? Leave blank to use detected IP\n"
    printf "  Master IP [%s]: " "${master_ip}"
    read -r input_ip
    if [[ -n "${input_ip}" ]]; then
        if net_validate_ip "${input_ip}"; then
            master_ip="${input_ip}"
        else
            log_error "Invalid IP: ${input_ip} — using detected: ${master_ip}"
        fi
    fi

    printf "\n  Cluster name [kubeops-cluster]: "
    read -r cluster_name
    cluster_name="${cluster_name:-kubeops-cluster}"

    # === Selección interactiva de la Versión de Kubernetes ===
    printf "\n  ${CLR_BOLD_WHITE}Seleccione la versión de Kubernetes a instalar:${CLR_RESET}\n"
    printf "  ${CLR_CYAN}[1]${CLR_RESET} v1.29 (1.29.15) — Estable (Recomendada)\n"
    printf "  ${CLR_CYAN}[2]${CLR_RESET} v1.30 (1.30.10) — Versión Reciente\n"
    printf "  ${CLR_CYAN}[3]${CLR_RESET} v1.28 (1.28.15) — Versión Legacy\n"
    printf "  ${CLR_CYAN}[4]${CLR_RESET} Personalizada (ingresar versión manualmente)\n"
    printf "  ${CLR_BOLD_WHITE}Selección [1]: ${CLR_RESET}"
    read -r v_choice
    case "${v_choice}" in
        2)
            K8S_VERSION="1.30"
            K8S_VERSION_FULL="1.30.10"
            ;;
        3)
            K8S_VERSION="1.28"
            K8S_VERSION_FULL="1.28.15"
            ;;
        4)
            printf "  Ingrese la versión exacta (ej: 1.29.3): "
            read -r custom_v
            if [[ -n "${custom_v}" ]]; then
                K8S_VERSION_FULL="${custom_v#v}"
                K8S_VERSION="$(echo "${K8S_VERSION_FULL}" | cut -d. -f1,2)"
            fi
            ;;
        *)
            K8S_VERSION="1.29"
            K8S_VERSION_FULL="1.29.15"
            ;;
    esac
    K8S_APT_REPO="https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/"
    K8S_RPM_REPO="https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/rpm/"
    log_info "Versión de Kubernetes seleccionada: v${K8S_VERSION_FULL}"

    # === Selección interactiva del Plugin CNI (Red) ===
    printf "\n  ${CLR_BOLD_WHITE}Seleccione el CNI (Plugin de Red):${CLR_RESET}\n"
    printf "  ${CLR_CYAN}[1]${CLR_RESET} Cilium v1.15 (eBPF High Performance - Recomendado)\n"
    printf "  ${CLR_CYAN}[2]${CLR_RESET} Calico v3.27 (BGP / Red Estándar)\n"
    printf "  ${CLR_CYAN}[3]${CLR_RESET} Flannel (Overlay ligero)\n"
    printf "  ${CLR_BOLD_WHITE}Selección [1]: ${CLR_RESET}"
    read -r cni_choice
    case "${cni_choice}" in
        2) CNI_PLUGIN="calico" ;;
        3) CNI_PLUGIN="flannel" ;;
        *) CNI_PLUGIN="cilium" ;;
    esac
    log_info "Plugin de Red (CNI) seleccionado: ${CNI_PLUGIN}"

    # Save initial state
    state_set_cluster_name "${cluster_name}"
    state_set_network_mode "${KUBEOPS_NETWORK_MODE}"

    # === Kernel & System config ===
    log_step 0 6 "Configuring kernel parameters"
    os_set_sysctl
    os_configure_firewall_k8s "master"

    # === 1. Install container runtime ===
    if net_is_online; then
        _install_containerd_online
    else
        _install_containerd_airgap
    fi
    state_set_runtime "containerd"

    # === 2. Install Kubernetes binaries ===
    if net_is_online; then
        _install_k8s_binaries_online
    else
        _install_k8s_binaries_airgap
    fi

    # === 3. Load offline images (air-gap only) ===
    if net_is_airgap; then
        _load_offline_images
    fi

    # === 4. Run kubeadm init ===
    _run_kubeadm_init "${master_ip}" "${cluster_name}"
    local init_log="${KUBEOPS_KUBEADM_INIT_LOG:-/tmp/kubeops-kubeadm-init.log}"

    # === Setup kubeconfig with secure permissions ===
    _setup_kubeconfig

    # === 5. Deploy CNI ===
    if net_is_online; then
        _deploy_cni_online
    else
        _deploy_cni_airgap
    fi

    # === 6. Wait for control plane ===
    log_step 6 6 "Verifying cluster health"
    _wait_for_control_plane
    _apply_security_policies

    # === Save Master & Cluster State ===
    state_save_master "${master_ip}" "$(hostname -f 2>/dev/null || hostname)" "primary"
    state_set ".cluster.initialized" "true"
    state_set ".join.control_plane_endpoint" "${master_ip}"
    state_set ".cluster.pod_cidr" "${POD_CIDR}"
    state_set ".cluster.service_cidr" "${SERVICE_CIDR}"

    # === Extract and persist join credentials ===
    local creds
    creds=$(_extract_join_credentials "${init_log}")
    local token ca_hash cert_key
    IFS='|' read -r token ca_hash cert_key <<< "${creds}"
    state_save_join_token "${token}" "${ca_hash}" "${cert_key}"

    # === Print summary ===
    _print_cluster_summary "${master_ip}" "${token}" "${ca_hash}" "${cert_key}"

    log_success "Master provisioning complete! State saved to: ${KUBEOPS_STATE_FILE}"
    pause "Press [Enter] to return to main menu..."
}

# Run only if executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
