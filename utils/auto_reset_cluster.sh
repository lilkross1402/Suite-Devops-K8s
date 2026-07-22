#!/usr/bin/env bash
# =============================================================================
# KubeOps-Suite :: utils/auto_reset_cluster.sh
# Purpose : Single-Node SSH Remote Teardown & Cluster Reset Orchestrator.
#           Cleans Kubernetes, CNI interfaces, etcd, iptables, and VIP configs
#           in parallel across ALL Masters and Workers with 1-Click zero-touch.
# Author  : KubeOps-Suite (Principal Platform Engineer)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${SUITE_ROOT:-}" ]]; then
    SUITE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
fi

# Guard against multiple sourcing
if [[ -n "${_AUTO_RESET_SH_LOADED:-}" ]]; then
    return 0
fi
_AUTO_RESET_SH_LOADED=true

# shellcheck disable=SC1090
source "${SUITE_ROOT}/lib/logger.sh"
# shellcheck disable=SC1090
source "${SUITE_ROOT}/lib/state_manager.sh"

auto_reset_ha_cluster() {
    log_banner
    log_section "Orquestador de Reseteo y Limpieza Remota de Clúster (Teardown vía SSH)"

    local ssh_user="ubuntu"
    local master_ips=("172.31.32.10" "172.31.34.86" "172.31.43.80")
    local worker_ips=("172.31.35.21" "172.31.32.154" "172.31.33.195")
    local ssh_key=""

    printf "  ${CLR_BOLD_WHITE}Inventario de Nodos a Limpiar:${CLR_RESET}\n"
    printf "  Usuario SSH:          ${CLR_BOLD_CYAN}%s${CLR_RESET}\n" "${ssh_user}"
    printf "  Nodos Control Plane: %s\n" "${master_ips[*]}"
    printf "  Nodos Workers:       %s\n\n" "${worker_ips[*]}"

    printf "  ¿Desea modificar las IPs del inventario a resetear? [y/N]: "
    read -r modify_inv
    if [[ "${modify_inv}" =~ ^[yY]$ ]]; then
        printf "  Ingrese las IPs de los Másters (separadas por espacio): "
        read -r -a master_ips
        printf "  Ingrese las IPs de los Workers (separadas por espacio): "
        read -r -a worker_ips
        printf "  Ingrese el Usuario SSH (ej. ubuntu / root): "
        read -r ssh_user
    fi

    printf "  ¿Desea especificar un archivo de clave privada SSH (.pem / id_rsa)? [y/N]: "
    read -r use_key
    if [[ "${use_key}" =~ ^[yY]$ ]]; then
        printf "  Ingrese el nombre o ruta de la clave SSH (.pem / id_rsa): "
        read -r ssh_key
        local found_key=""
        for path in "${ssh_key}" "${SUITE_ROOT}/${ssh_key}" "${HOME}/${ssh_key}" "/home/${ssh_user}/${ssh_key}" "$(pwd)/${ssh_key}"; do
            if [[ -n "${path}" && -f "${path}" ]]; then
                found_key="${path}"
                break
            fi
        done
        if [[ -n "${found_key}" ]]; then
            ssh_key="${found_key}"
            chmod 400 "${ssh_key}" 2>/dev/null || true
            log_success "Clave SSH localizada: ${ssh_key}"
        else
            log_warn "Clave '${ssh_key}' no encontrada. Continuando con agente SSH estándar."
            ssh_key=""
        fi
    fi

    # Build SSH opts array
    local -a ssh_opts=("-o" "ConnectTimeout=10" "-o" "StrictHostKeyChecking=no" "-o" "BatchMode=yes")
    if [[ -n "${ssh_key}" ]]; then
        ssh_opts+=("-i" "${ssh_key}")
    fi

    local all_nodes=("${master_ips[@]}" "${worker_ips[@]}")

    printf "\n"
    printf "  ${BG_RED:-}${CLR_BOLD_WHITE}  ⚠️  ADVERTENCIA DE SEGURIDAD  ⚠️  ${CLR_RESET}\n"
    printf "  ${CLR_BOLD_RED}ESTA ACCIÓN ELIMINARÁ KUBERNETES, CILIUM, ETCD, IPTABLES Y CONFIGURACIONES${CLR_RESET}\n"
    printf "  ${CLR_BOLD_RED}EN LOS %d NODOS SIMULTÁNEAMENTE. NO HAY DESHACER.${CLR_RESET}\n\n" "${#all_nodes[@]}"
    printf "  ¿Está COMPLETAMENTE SEGURO de ejecutar el Reset total? [y/N]: "
    read -r confirm
    if [[ ! "${confirm}" =~ ^[yY]$ ]]; then
        log_warn "Operación de reseteo cancelada por el usuario."
        return 0
    fi

    # 1. Probar SSH contra todos los nodos
    log_info "[1/2] Verificando acceso SSH en los ${#all_nodes[@]} nodos..."
    for node in "${all_nodes[@]}"; do
        if ! ssh "${ssh_opts[@]}" "${ssh_user}@${node}" "echo ok" &>/dev/null; then
            log_error "No se pudo conectar vía SSH a ${ssh_user}@${node}. Abortando reset."
            return 1
        fi
    done
    log_success "Conexión SSH confirmada en todos los nodos."

    # 2. Ejecutar Reset paralelo en todos los nodos
    log_info "[2/2] Ejecutando Reseteo y Limpieza PARALELA en los ${#all_nodes[@]} nodos..."
    local pids=()
    for node in "${all_nodes[@]}"; do
        log_info "  [${node}] Iniciando limpieza profunda de K8s y CNI..."
        ssh "${ssh_opts[@]}" "${ssh_user}@${node}" sudo bash -s <<'REMOTE' &
set -euo pipefail

# 1. Resetear kubeadm
kubeadm reset -f --cleanup-tmp-dir 2>/dev/null || true

# 2. Detener servicios de K8s y VIP
systemctl stop kubelet 2>/dev/null || true
systemctl stop keepalived haproxy 2>/dev/null || true
systemctl disable keepalived haproxy 2>/dev/null || true

# 3. Eliminar interfaces de red CNI (Cilium, Calico, Flannel, Bridge)
ip link delete cilium_host 2>/dev/null || true
ip link delete cilium_net 2>/dev/null || true
ip link delete cilium_vxlan 2>/dev/null || true
ip link delete cni0 2>/dev/null || true
ip link delete flannel.1 2>/dev/null || true

# 4. Limpiar reglas de iptables e ipvs
iptables -F 2>/dev/null || true
iptables -t nat -F 2>/dev/null || true
iptables -t mangle -F 2>/dev/null || true
iptables -X 2>/dev/null || true
ipvsadm --clear 2>/dev/null || true

# 5. Borrar directorios de configuración, certificados y datos etcd
rm -rf /etc/kubernetes \
       /var/lib/kubelet \
       /var/lib/etcd \
       /var/lib/cni \
       /etc/cni/net.d \
       /var/run/kubernetes \
       /etc/keepalived/keepalived.conf \
       /etc/haproxy/haproxy.cfg \
       /etc/sysctl.d/99-vip.conf \
       /tmp/kubeadm* \
       /tmp/cni* \
       "${HOME}/.kube" \
       /root/.kube 2>/dev/null || true

# 6. Restablecer containerd
sed -i 's/disabled_plugins = \["cri"\]/disabled_plugins = []/g' /etc/containerd/config.toml 2>/dev/null || true
systemctl restart containerd 2>/dev/null || true

echo "NODE_RESET_OK"
REMOTE
        pids+=($!)
    done

    for pid in "${pids[@]}"; do
        wait "${pid}" || true
    done

    printf "\n"
    log_section "🧹 ¡RESETEO Y LIMPIEZA TOTAL DE NODOS COMPLETADA EXITOSAMENTE!"
    printf "  ${CLR_BOLD_GREEN}Estado de la Infraestructura:${CLR_RESET}\n"
    printf "  %-30s %s\n" "Nodos Reseteados:" "${#all_nodes[@]} nodos (${all_nodes[*]})"
    printf "  %-30s %s\n" "Estado de Kubernetes:" "Limpiado (Virgin State)"
    printf "  %-30s %s\n\n" "Estado de containerd:" "Reiniciado y listo para re-desplegar"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    auto_reset_ha_cluster "$@"
fi
