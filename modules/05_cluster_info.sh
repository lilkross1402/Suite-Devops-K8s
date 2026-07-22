#!/usr/bin/env bash
# =============================================================================
# KubeOps-Suite :: modules/05_cluster_info.sh
# Purpose : Display comprehensive cluster status including nodes, pods,
#           resource usage, join commands, and health summary.
# Author  : KubeOps-Suite (Principal Platform Engineer)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${SUITE_ROOT}/lib/logger.sh"
source "${SUITE_ROOT}/lib/network_check.sh"
source "${SUITE_ROOT}/lib/state_manager.sh"

_print_separator() {
    printf "${CLR_DIM}%.0s─${CLR_RESET}" {1..70}
    echo ""
}

_auto_repair_rebooted_nodes() {
    local kubeconfig="${HOME}/.kube/config"
    [[ ! -f "${kubeconfig}" ]] && kubeconfig="/etc/kubernetes/admin.conf"

    # Desactivar SWAP de forma inmediata y permanente (causa raíz del fallo de kubelet tras reinicio)
    sudo swapoff -a 2>/dev/null || true
    sudo sed -i '/swap/d' /etc/fstab 2>/dev/null || true

    # Ajustar endpoint local directo 127.0.0.1:6443 en el Control Plane
    sudo sed -i 's|server: https://.*:8443|server: https://127.0.0.1:6443|g' /etc/kubernetes/kubelet.conf /etc/kubernetes/admin.conf /root/.kube/config "${HOME}/.kube/config" 2>/dev/null || true

    if command -v kubectl &>/dev/null && [[ -f "${kubeconfig}" ]]; then
        local not_ready_nodes
        not_ready_nodes=$(kubectl get nodes --kubeconfig="${kubeconfig}" 2>/dev/null | grep -i "NotReady" | awk '{print $1}' || echo "")
        if [[ -n "${not_ready_nodes}" ]]; then
            log_info "Detectado nodo en estado NotReady. Restableciendo kubelet..."
            sudo systemctl restart kubelet 2>/dev/null || true
            sleep 2
        fi
    fi
}

_show_nodes() {
    local kubeconfig="${HOME}/.kube/config"
    if [[ ! -f "${kubeconfig}" ]]; then
        kubeconfig="/etc/kubernetes/admin.conf"
    fi

    _auto_repair_rebooted_nodes

    log_section "Nodos del Clúster"
    if command -v kubectl &>/dev/null && [[ -f "${kubeconfig}" ]]; then
        kubectl get nodes -o wide --kubeconfig="${kubeconfig}" 2>/dev/null || \
            log_warn "kubectl get nodes falló — verifique kubeconfig"
    else
        log_warn "kubectl no disponible o kubeconfig no encontrado"
        log_info "Nodos registrados en el archivo de estado:"
        state_show
    fi
}

_show_pods() {
    local kubeconfig="${HOME}/.kube/config"
    [[ ! -f "${kubeconfig}" ]] && kubeconfig="/etc/kubernetes/admin.conf"

    log_section "Pods del Sistema (kube-system)"
    if command -v kubectl &>/dev/null && [[ -f "${kubeconfig}" ]]; then
        kubectl get pods -n kube-system --kubeconfig="${kubeconfig}" 2>/dev/null || true
    fi
}

_show_resources() {
    local kubeconfig="${HOME}/.kube/config"
    [[ ! -f "${kubeconfig}" ]] && kubeconfig="/etc/kubernetes/admin.conf"

    log_section "Uso de Recursos"
    if command -v kubectl &>/dev/null && [[ -f "${kubeconfig}" ]]; then
        kubectl top nodes --kubeconfig="${kubeconfig}" 2>/dev/null || \
            log_warn "metrics-server no instalado aún (kubectl top requiere metrics-server)"
    fi
}

_show_join_commands() {
    log_section "Comandos de Unión (Join)"

    local token endpoint ca_hash cert_key
    endpoint=$(state_get ".join.control_plane_endpoint" 2>/dev/null || echo "")
    if [[ -z "${endpoint}" || "${endpoint}" == "null" ]]; then
        endpoint=$(net_get_primary_ip)
    fi

    # Always generate/refresh active token & cert_key directly from kubeadm if master is running
    if command -v kubeadm &>/dev/null && [[ -f /etc/kubernetes/admin.conf ]]; then
        # Ensure kube-apiserver explicitly enables anonymous-auth=true for kubeadm join discovery
        if [[ -f /etc/kubernetes/manifests/kube-apiserver.yaml ]]; then
            if ! grep -q "anonymous-auth=true" /etc/kubernetes/manifests/kube-apiserver.yaml; then
                sudo sed -i '/anonymous-auth/d' /etc/kubernetes/manifests/kube-apiserver.yaml 2>/dev/null || true
                sudo sed -i '/- --authorization-mode=Node,RBAC/a \    - --anonymous-auth=true' /etc/kubernetes/manifests/kube-apiserver.yaml 2>/dev/null || true
                sudo pkill -9 kube-apiserver 2>/dev/null || true
            fi
        fi

        sudo kubeadm init phase bootstrap-token 2>/dev/null || true
        sudo kubectl create rolebinding kubeadm:bootstrap-signer-cluster-info \
            --clusterrole=system:public-info-viewer \
            --group=system:anonymous \
            -n kube-public --kubeconfig=/etc/kubernetes/admin.conf 2>/dev/null || true

        token=$(sudo kubeadm token create --print-join-command 2>/dev/null | grep -oP '(?<=--token )\S+' | head -1 || echo "")
        if [[ -z "${token}" ]]; then
            token=$(sudo kubeadm token create 2>/dev/null | tail -1 | tr -d '[:space:]' || echo "")
        fi
        ca_hash=$(sudo openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt 2>/dev/null | \
            openssl rsa -pubin -outform der 2>/dev/null | \
            openssl dgst -sha256 -hex 2>/dev/null | awk '{print $2}' || echo "")
        cert_key=$(sudo kubeadm init phase upload-certs --upload-certs 2>/dev/null | tail -1 | tr -d '[:space:]' || echo "")

        if [[ -n "${token}" && -n "${ca_hash}" ]]; then
            state_save_join_token "${token}" "${ca_hash}" "${cert_key}"
            state_set ".join.control_plane_endpoint" "${endpoint}"
        fi
    else
        token=$(state_get ".join.token" 2>/dev/null || echo "")
        ca_hash=$(state_get ".join.ca_cert_hash" 2>/dev/null || echo "")
        cert_key=$(state_get ".join.certificate_key" 2>/dev/null || echo "")
    fi

    if [[ -n "${token}" && "${token}" != "null" && ! "${token}" =~ "INFO" ]]; then
        printf "\n  ${CLR_BOLD_WHITE}1. Para agregar un Nodo Worker (Trabajador):${CLR_RESET}\n"
        printf "  ${CLR_BOLD_YELLOW}kubeadm join %s:6443 --token %s --discovery-token-ca-cert-hash sha256:%s${CLR_RESET}\n\n" \
            "${endpoint}" "${token}" "${ca_hash}"

        if [[ -n "${cert_key}" && "${cert_key}" != "null" ]]; then
            printf "  ${CLR_BOLD_WHITE}2. Para agregar otro Nodo Máster (HA Control Plane):${CLR_RESET}\n"
            printf "  ${CLR_BOLD_CYAN}kubeadm join %s:6443 --token %s --discovery-token-ca-cert-hash sha256:%s --control-plane --certificate-key %s${CLR_RESET}\n\n" \
                "${endpoint}" "${token}" "${ca_hash}" "${cert_key}"
        fi
    else
        log_warn "Sin comandos de join almacenados — inicialice primero el clúster (Opción 3)"
    fi

    # Token validity
    printf "  ${CLR_BOLD_WHITE}Estado del Token:${CLR_RESET}\n"
    if state_is_token_valid 2>/dev/null; then
        printf "  %-28s ${CLR_BOLD_GREEN}VÁLIDO${CLR_RESET}\n" "Token Actual:"
    else
        printf "  %-28s ${CLR_BOLD_RED}EXPIRADO / REGENERANDO${CLR_RESET}\n" "Token Actual:"
        printf "\n  ${CLR_YELLOW}Generar un nuevo token en el máster con:${CLR_RESET}\n"
        printf "  ${CLR_YELLOW}kubeadm token create --print-join-command${CLR_RESET}\n"
    fi
}

main() {
    log_banner
    log_section "Información y Estado del Clúster"

    net_detect_mode
    state_show

    _show_nodes
    _show_pods
    _show_resources
    _show_join_commands

    echo ""
    log_success "Reporte de estado completado exitosamente"
    pause "Presione [Enter] para volver al menú principal..."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
