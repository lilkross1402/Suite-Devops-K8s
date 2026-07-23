#!/usr/bin/env bash
# =============================================================================
# KubeOps-Suite :: modules/04_k8s_worker.sh
# Purpose : Join a Worker node to an existing Kubernetes cluster.
#           - Reads join credentials from state manager automatically
#           - Detects ONLINE vs AIR-GAPPED mode
#           - Configures containerd runtime and mirrors (air-gap)
#           - Loads offline container images from offline-assets/
#           - Validates token freshness before attempting join
# Author  : KubeOps-Suite (Principal Platform Engineer)
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve suite root and source libraries
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${SUITE_ROOT:-}" ]]; then
    SUITE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
fi

source "${SUITE_ROOT}/lib/logger.sh"
source "${SUITE_ROOT}/lib/os_detect.sh"
source "${SUITE_ROOT}/lib/network_check.sh"
source "${SUITE_ROOT}/lib/state_manager.sh"

# ---------------------------------------------------------------------------
# Configuration defaults
# ---------------------------------------------------------------------------
readonly K8S_VERSION="${K8S_VERSION:-1.29}"
readonly K8S_VERSION_FULL="${K8S_VERSION_FULL:-1.29.3}"
readonly OFFLINE_ASSETS_DIR="${SUITE_ROOT}/offline-assets"
readonly CONTAINERD_CONFIG_DIR="/etc/containerd"
readonly CRICTL_CONFIG="/etc/crictl.yaml"

# ---------------------------------------------------------------------------
# Preflight validation
# ---------------------------------------------------------------------------

_worker_preflight() {
    log_section "Worker Node Preflight Checks"
    local errors=0

    # Must be root
    if [[ "${EUID}" -ne 0 ]]; then
        log_error "Must run as root (or via sudo)"
        (( errors++ )) || true
    fi

    # OS detection
    os_detect || (( errors++ )) || true

    # System requirements: minimal for worker
    os_check_requirements 1024 2 10 || log_warn "System below recommended specs"

    # Network mode detection
    # Network mode detection
    net_detect_mode

    # Check for existing kubeadm installation
    if [[ -f "/etc/kubernetes/kubelet.conf" ]]; then
        log_warn "This node appears to already be part of a cluster."
        if ! confirm "Reset this node and rejoin?"; then
            log_info "Aborted by user"
            exit 0
        fi
        log_info "Running kubeadm reset..."
        sudo kubeadm reset -f 2>/dev/null || true
        sudo systemctl stop kubelet 2>/dev/null || true
        sudo rm -rf /etc/kubernetes /var/lib/kubelet /var/lib/etcd 2>/dev/null || true
        log_success "Node reset complete"
    fi

    # Disable swap
    if swapon --show 2>/dev/null | grep -q .; then
        log_warn "Swap enabled — disabling"
        os_disable_swap
    else
        log_success "Swap: disabled ✓"
    fi

    if [[ "${errors}" -gt 0 ]]; then
        log_fatal "Preflight failed with ${errors} error(s)"
    fi

    log_success "Preflight checks passed"
}

# ---------------------------------------------------------------------------
# Load Join Credentials from State or Prompt Interactively
# ---------------------------------------------------------------------------

_load_join_credentials() {
    log_info "Cargando credenciales de unión para el nodo Worker..."

    local token ca_hash control_plane
    token=$(state_get ".join.token" 2>/dev/null || echo "")
    ca_hash=$(state_get ".join.ca_cert_hash" 2>/dev/null || echo "")
    control_plane=$(state_get ".join.control_plane_endpoint" 2>/dev/null || echo "")

    if [[ -z "${control_plane}" || "${control_plane}" == "null" ]]; then
        printf "\n  ${CLR_BOLD_WHITE}Ingrese los datos del Máster Primario:${CLR_RESET}\n"
        printf "  IP del Máster Primario [ej. 172.31.32.10]: "
        read -r control_plane
    fi

    if [[ -z "${token}" || "${token}" == "null" || "${token}" =~ "INFO" ]]; then
        printf "  Token de Unión (Token): "
        read -r token
    fi

    if [[ -z "${ca_hash}" || "${ca_hash}" == "null" ]]; then
        printf "  CA Cert Hash (sha256:...): "
        read -r ca_hash
        ca_hash="${ca_hash#sha256:}"
    fi

    # Allow environment overrides
    JOIN_TOKEN="${K8S_JOIN_TOKEN:-${token}}"
    JOIN_CA_HASH="${K8S_CA_HASH:-${ca_hash}}"
    CONTROL_PLANE_ENDPOINT="${K8S_CONTROL_PLANE:-${control_plane}}"

    if [[ -z "${JOIN_TOKEN}" || -z "${JOIN_CA_HASH}" || -z "${CONTROL_PLANE_ENDPOINT}" ]]; then
        log_error "Faltan parámetros de unión para el Worker."
        return 1
    fi

    log_success "Credenciales de unión configuradas:"
    printf "  %-28s %s\n" "Control Plane Endpoint:" "${CONTROL_PLANE_ENDPOINT}:6443"
    printf "  %-28s %s...\n" "Token de Unión:" "${JOIN_TOKEN:0:10}"
    printf "  %-28s sha256:%s...\n" "CA Hash:" "${JOIN_CA_HASH:0:16}"

    # Check token validity
    if ! state_is_token_valid; then
        log_warn "Join token may be expired!"
        printf "\n  ${CLR_BOLD_YELLOW}To generate a new token, run on the MASTER node:${CLR_RESET}\n"
        printf "  ${CLR_YELLOW}kubeadm token create --print-join-command${CLR_RESET}\n\n"
        if ! confirm "Attempt join anyway with potentially expired token?"; then
            return 1
        fi
    fi

    export JOIN_TOKEN JOIN_CA_HASH CONTROL_PLANE_ENDPOINT
    return 0
}

# ---------------------------------------------------------------------------
# Check API Server Reachability
# ---------------------------------------------------------------------------

_check_api_server() {
    log_info "Checking API server reachability: ${CONTROL_PLANE_ENDPOINT}:6443..."
    if ! net_check_endpoint "${CONTROL_PLANE_ENDPOINT}" "6443" "Kubernetes API Server"; then
        log_error "Cannot reach API server at ${CONTROL_PLANE_ENDPOINT}:6443"
        log_error "Ensure the master node is running and the firewall allows port 6443"
        return 1
    fi
    log_success "API server is reachable"
}

# ---------------------------------------------------------------------------
# Containerd & Runtime Setup (Worker)
# ---------------------------------------------------------------------------

_setup_containerd_worker() {
    log_step 1 4 "Installing container runtime"

    # Re-use functions from master module by sourcing it with a guard
    # to prevent its main() from running
    local master_mod="${SUITE_ROOT}/modules/03_k8s_master.sh"

    if [[ -f "${master_mod}" ]]; then
        # Source only the functions we need (not main)
        # shellcheck disable=SC1090
        _SOURCED_BY_WORKER=true source "${master_mod}" 2>/dev/null || true
    fi

    if command -v containerd &>/dev/null && systemctl is-active containerd &>/dev/null 2>&1; then
        log_info "containerd is already installed and running"
        log_info "Ensuring configuration is correct for Kubernetes..."
        _configure_containerd 2>/dev/null || true
        return 0
    fi

    # Install fresh
    if net_is_online; then
        _install_containerd_online
    else
        _install_containerd_airgap
    fi
}

_setup_k8s_worker_binaries() {
    log_step 2 4 "Installing Kubernetes node binaries"

    if command -v kubeadm &>/dev/null && command -v kubelet &>/dev/null; then
        log_info "Kubernetes binaries already installed"
        local current_version
        current_version=$(kubeadm version -o short 2>/dev/null | grep -oP 'v[\d.]+' || echo "unknown")
        log_info "kubeadm version: ${current_version}"
        sudo systemctl enable kubelet 2>/dev/null || true
        return 0
    fi

    if net_is_online; then
        log_info "Configurando repositorio oficial de Kubernetes v${K8S_VERSION} en apt..."
        sudo install -m 0755 -d /etc/apt/keyrings 2>/dev/null || true
        curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" | \
            sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg 2>/dev/null || true
        sudo chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg 2>/dev/null || true

        echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" | \
            sudo tee /etc/apt/sources.list.d/kubernetes.list > /dev/null

        log_info "Actualizando indice de paquetes e instalando kubelet, kubeadm, kubectl..."
        sudo apt-get update -qq 2>/dev/null || true
        sudo env NEEDRESTART_MODE=a DEBIAN_FRONTEND=noninteractive apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" kubelet kubeadm kubectl
        sudo apt-mark hold kubelet kubeadm kubectl 2>/dev/null || true
        sudo systemctl enable kubelet 2>/dev/null || true
        log_success "Binarios de Kubernetes instalados correctamente en el Worker."
    else
        _install_k8s_binaries_airgap
    fi
}

# ---------------------------------------------------------------------------
# Load Offline Images (Worker)
# ---------------------------------------------------------------------------

_load_worker_offline_images() {
    if net_is_airgap; then
        log_step 3 4 "Loading offline container images"
        # Look for worker-specific images or fall back to general images
        local image_archives
        mapfile -t image_archives < <(find "${OFFLINE_ASSETS_DIR}" \
            -name "worker-images-*.tar" \
            -o -name "*.tar" 2>/dev/null | sort)

        if [[ ${#image_archives[@]} -eq 0 ]]; then
            log_warn "No image archives in ${OFFLINE_ASSETS_DIR} — worker pods may fail to start"
            return 0
        fi

        local total=${#image_archives[@]}
        local count=0
        for archive in "${image_archives[@]}"; do
            (( count++ )) || true
            log_progress_bar "${count}" "${total}" "Loading images"
            if command -v ctr &>/dev/null; then
                sudo ctr -n k8s.io images import "${archive}" 2>/dev/null || \
                    log_warn "Failed to import $(basename "${archive}")"
            fi
        done
        echo ""
        log_success "Offline images loaded"
    fi
}

# ---------------------------------------------------------------------------
# kubeadm join
# ---------------------------------------------------------------------------

_run_kubeadm_join() {
    log_step 4 4 "Joining cluster as Worker node"

    local worker_ip
    worker_ip=$(net_get_primary_ip)

    log_info "Worker node IP: ${worker_ip}"
    log_info "Joining: ${CONTROL_PLANE_ENDPOINT}:6443"

    local join_log="/tmp/kubeops-kubeadm-join-$(date +%s).log"

    # Build join config
    local join_config="/tmp/kubeops-join-config.yaml"
    sudo tee "${join_config}" > /dev/null <<EOF
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: JoinConfiguration
discovery:
  bootstrapToken:
    apiServerEndpoint: "${CONTROL_PLANE_ENDPOINT}:6443"
    token: "${JOIN_TOKEN}"
    caCertHashes:
      - "sha256:${JOIN_CA_HASH}"
    unsafeSkipCAVerification: false
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
  name: "$(hostname)"
  taints: []
EOF

    log_info "Configurando módulos de kernel (overlay, br_netfilter) y sysctl para Kubernetes..."
    sudo modprobe overlay 2>/dev/null || true
    sudo modprobe br_netfilter 2>/dev/null || true
    sudo sysctl -w net.bridge.bridge-nf-call-iptables=1 2>/dev/null || true
    sudo sysctl -w net.bridge.bridge-nf-call-ip6tables=1 2>/dev/null || true
    sudo sysctl -w net.ipv4.ip_forward=1 2>/dev/null || true

    log_info "Executing kubeadm join..."
    if ! sudo kubeadm join \
        --config "${join_config}" \
        --ignore-preflight-errors=FileContent--proc-sys-net-bridge-bridge-nf-call-iptables,FileContent--proc-sys-net-ipv4-ip_forward,Port-10250 \
        --v=5 \
        2>&1 | tee "${join_log}"; then

        log_warn "Primer intento con discovery-token falló. Reintentando con --discovery-token-unsafe-skip-ca-verification..."
        if ! sudo kubeadm join "${CONTROL_PLANE_ENDPOINT}:6443" \
            --token "${JOIN_TOKEN}" \
            --discovery-token-unsafe-skip-ca-verification \
            --ignore-preflight-errors=FileContent--proc-sys-net-bridge-bridge-nf-call-iptables,FileContent--proc-sys-net-ipv4-ip_forward,Port-10250 \
            --v=5 \
            2>&1 | tee -a "${join_log}"; then
            log_error "kubeadm join FAILED — reviewing log..."
            printf "\n  ${CLR_BOLD_RED}Last 20 lines of join log:${CLR_RESET}\n"
            tail -20 "${join_log}" | while IFS= read -r l; do log_error "  ${l}"; done
            printf "\n  Full log: ${join_log}\n"
            return 1
        fi
    fi

    rm -f "${join_config}"
    log_success "Node joined the cluster successfully!"
    echo "${worker_ip}"
}

# ---------------------------------------------------------------------------
# Post-Join Configuration
# ---------------------------------------------------------------------------

_post_join_setup() {
    local worker_ip="${1}"

    log_info "Configuring kubelet..."
    sudo systemctl enable kubelet
    sudo systemctl start kubelet 2>/dev/null || true

    # Apply security kernel parameters (same as master)
    os_set_sysctl

    # Configure firewall for worker
    os_configure_firewall_k8s "worker"

    log_success "Worker node services configured"
}

_verify_node_joined() {
    local worker_ip="${1}"

    log_info "Verifying node registration..."
    log_info "NOTE: Run this on the MASTER node to confirm:"
    printf "\n  ${CLR_YELLOW}kubectl get nodes -o wide${CLR_RESET}\n\n"

    # If we have kubectl and kubeconfig access, try to verify
    local kubeconfig="${HOME}/.kube/config"
    if [[ -f "${kubeconfig}" ]]; then
        local timeout=120
        local elapsed=0
        local interval=10
        log_info "Polling for node readiness (${timeout}s timeout)..."
        while [[ "${elapsed}" -lt "${timeout}" ]]; do
            local node_status
            node_status=$(kubectl get nodes \
                --kubeconfig="${kubeconfig}" \
                --no-headers 2>/dev/null | \
                grep "$(hostname)" | awk '{print $2}' || echo "")

            if [[ "${node_status}" == "Ready" ]]; then
                log_success "Node $(hostname) is Ready!"
                return 0
            elif [[ "${node_status}" == "NotReady" ]]; then
                log_debug "Node registered but NotReady (${elapsed}s) — CNI may still be initializing"
            fi

            sleep "${interval}"
            elapsed=$(( elapsed + interval ))
        done
        log_warn "Node did not reach Ready state within ${timeout}s"
        log_warn "This is normal if CNI is still initializing on the master"
    fi

    # If a HA Virtual IP (VIP) exists in state, configure kubelet.conf to target the VIP
    local vip_ip
    vip_ip=$(state_get ".ha.vip" 2>/dev/null || echo "")
    if [[ -n "${vip_ip}" && "${vip_ip}" != "null" ]]; then
        log_info "Configurando kubelet del Worker para comunicarse vía la Virtual IP https://${vip_ip}:8443..."
        sudo sed -i "s|https://.*:6443|https://${vip_ip}:8443|g" /etc/kubernetes/kubelet.conf 2>/dev/null || true
        sudo sed -i "s|https://.*:8443|https://${vip_ip}:8443|g" /etc/kubernetes/kubelet.conf 2>/dev/null || true
        sudo systemctl restart kubelet 2>/dev/null || true
    fi
}

_print_worker_summary() {
    local worker_ip="${1}"

    log_section "🎉 Kubernetes Worker Node — Join Complete"

    printf "\n  ${CLR_BOLD_WHITE}Worker Node Info:${CLR_RESET}\n"
    printf "  %-30s %s\n" "Hostname:"         "$(hostname)"
    printf "  %-30s %s\n" "Worker IP:"        "${CLR_BOLD_GREEN}${worker_ip}${CLR_RESET}"
    printf "  %-30s %s\n" "Joined cluster at:" "${CONTROL_PLANE_ENDPOINT}:6443"
    printf "  %-30s %s\n" "Network Mode:"     "$(if net_is_online; then echo "ONLINE"; else echo "AIR-GAPPED"; fi)"

    printf "\n  ${CLR_BOLD_WHITE}Verify from Master Node:${CLR_RESET}\n"
    printf "  ${CLR_YELLOW}kubectl get nodes -o wide${CLR_RESET}\n"
    printf "  ${CLR_YELLOW}kubectl describe node %s${CLR_RESET}\n\n" "$(hostname)"

    printf "  ${CLR_DIM}Worker kubelet status:${CLR_RESET}\n"
    printf "  ${CLR_YELLOW}systemctl status kubelet${CLR_RESET}\n\n"
}

# ---------------------------------------------------------------------------
# Main Entrypoint
# ---------------------------------------------------------------------------

main() {
    log_banner
    log_section "Kubernetes Worker Node — Joining Cluster"

    # === 0. Preflight ===
    _worker_preflight

    # === Load join credentials from state ===
    if ! _load_join_credentials; then
        log_fatal "Cannot proceed without valid join credentials"
    fi

    # === Check API server is reachable ===
    _check_api_server

    # === Confirm before joining ===
    printf "\n"
    printf "  ${CLR_BOLD_WHITE}Ready to join worker node to cluster${CLR_RESET}\n"
    printf "  %-28s %s\n" "This node:"     "$(hostname) [$(net_get_primary_ip)]"
    printf "  %-28s %s\n" "Control Plane:" "${CONTROL_PLANE_ENDPOINT}:6443"
    printf "\n"
    if ! confirm "Proceed with node join?"; then
        log_info "Worker join cancelled"
        exit 0
    fi

    # === Kernel configuration ===
    os_set_sysctl

    # === 1. Setup containerd ===
    _setup_containerd_worker

    # === 2. Install K8s binaries ===
    _setup_k8s_worker_binaries

    # === 3. Load offline images (air-gap) ===
    _load_worker_offline_images

    # === 4. Join the cluster ===
    local worker_ip
    worker_ip=$(_run_kubeadm_join)

    # === Post-join ===
    _post_join_setup "${worker_ip}"

    # === Persist to state ===
    state_save_worker "${worker_ip}" "$(hostname -f 2>/dev/null || hostname)"

    # === Verify (optional if kubectl available) ===
    _verify_node_joined "${worker_ip}"

    # === Print summary ===
    _print_worker_summary "${worker_ip}"

    log_success "Worker join complete! State updated: ${KUBEOPS_STATE_FILE}"
    pause "Press [Enter] to return to main menu..."
}

# Guard to allow sourcing without running main
if [[ "${BASH_SOURCE[0]}" == "${0}" ]] && [[ "${_SOURCED_BY_WORKER:-false}" != "true" ]]; then
    main "$@"
fi
