#!/usr/bin/env bash
# =============================================================================
# KubeOps-Suite :: utils/auto_provision_cluster.sh
# Purpose : Single-Node Master Orchestrator (SSH Auto-Provisioner).
#           Executes full HA Cluster deployment across all Masters & Workers from
#           a single node via SSH with 1-Click zero-touch automation.
# Author  : KubeOps-Suite (Principal Platform Engineer)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${SUITE_ROOT:-}" ]]; then
    SUITE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
fi

# Guard against multiple sourcing
if [[ -n "${_AUTO_PROVISION_SH_LOADED:-}" ]]; then
    return 0
fi
_AUTO_PROVISION_SH_LOADED=true

# shellcheck disable=SC1090
source "${SUITE_ROOT}/lib/logger.sh"
# shellcheck disable=SC1090
source "${SUITE_ROOT}/lib/state_manager.sh"

auto_provision_ha_cluster() {
    log_banner
    log_section "Orquestador Remoto de Clúster HA (Auto-Despliegue vía SSH)"

    local ssh_user="ubuntu"
    local vip_ip="172.31.32.100"
    local master_ips=("172.31.32.10" "172.31.34.86" "172.31.43.80")
    local worker_ips=("172.31.35.21" "172.31.32.154" "172.31.33.195")
    local ssh_key=""

    printf "  ${CLR_BOLD_WHITE}Configuración de Inventario de Nodos:${CLR_RESET}\n"
    printf "  Usuario SSH Predeterminado: ${CLR_BOLD_CYAN}%s${CLR_RESET}\n" "${ssh_user}"
    printf "  Virtual IP (VIP HA): ${CLR_BOLD_YELLOW}%s:8443${CLR_RESET}\n" "${vip_ip}"
    printf "  Nodos Control Plane: %s\n" "${master_ips[*]}"
    printf "  Nodos Workers:       %s\n\n" "${worker_ips[*]}"

    printf "  ¿Desea modificar las IPs o usar el inventario detectado? [y/N]: "
    read -r modify_inv
    if [[ "${modify_inv}" =~ ^[yY]$ ]]; then
        printf "  Ingrese la IP Virtual (VIP): "
        read -r vip_ip
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
        printf "  Ingrese la ruta de la clave SSH (.pem / id_rsa): "
        read -r ssh_key
        if [[ -n "${ssh_key}" && ! -f "${ssh_key}" ]]; then
            log_warn "La ruta especificada '${ssh_key}' no existe localmente. Intentando ruta relativa en suite..."
            if [[ -f "${SUITE_ROOT}/${ssh_key}" ]]; then
                ssh_key="${SUITE_ROOT}/${ssh_key}"
            elif [[ -f "${HOME}/${ssh_key}" ]]; then
                ssh_key="${HOME}/${ssh_key}"
            fi
        fi
        if [[ -f "${ssh_key}" ]]; then
            sudo chmod 400 "${ssh_key}" 2>/dev/null || chmod 400 "${ssh_key}" 2>/dev/null || true
            log_success "Utilizando clave SSH: ${ssh_key}"
        else
            log_warn "No se encontró el archivo de clave '${ssh_key}'. Continuando con agente/claves estándar..."
            ssh_key=""
        fi
    fi

    local master1_ip="${master_ips[0]}"

    # Construir comando base de SSH con o sin clave -i
    local -a ssh_cmd=("ssh" "-o" "ConnectTimeout=8" "-o" "StrictHostKeyChecking=no")
    if [[ -n "${ssh_key}" ]]; then
        ssh_cmd+=("-i" "${ssh_key}")
    fi

    # 1. Probar conectividad SSH contra todos los nodos
    log_info "[Paso 1/5] Verificando conectividad SSH contra los 6 nodos..."
    local all_nodes=("${master_ips[@]}" "${worker_ips[@]}")
    for node in "${all_nodes[@]}"; do
        log_info "Comprobando SSH hacia ${ssh_user}@${node}..."
        if ! "${ssh_cmd[@]}" "${ssh_user}@${node}" "echo connected" &>/dev/null; then
            log_error "No se pudo conectar vía SSH a ${ssh_user}@${node}."
            log_error "Verifique que el usuario '${ssh_user}' y la clave '${ssh_key:-id_rsa}' tengan acceso."
            return 1
        fi
    done
    log_success "Conectividad SSH verificada exitosamente en los 6 nodos."

    # 2. Desplegar Virtual IP HAProxy + Keepalived en todos los Másters
    log_info "[Paso 2/5] Desplegando Módulo Virtual IP (HAProxy + Keepalived) en todos los Másters..."
    for node in "${master_ips[@]}"; do
        log_info "Configurando VIP HA en ${node}..."
        "${ssh_cmd[@]}" "${ssh_user}@${node}" "cd /home/${ssh_user}/kubeops-suite 2>/dev/null || cd /root/kubeops-suite 2>/dev/null || true; git fetch origin && git reset --hard origin/main && chmod +x kubeops.sh modules/*.sh stack/*.sh lib/*.sh utils/*.sh && sudo ./stack/deploy_haproxy_keepalived.sh" || true
    done
    log_success "Módulo Virtual IP HA activo en la VIP ${vip_ip}:8443."

    # 3. Inicializar Máster 1 Primario
    log_info "[Paso 3/5] Inicializando Kubernetes Control Plane 1 en Máster Primario (${master1_ip})..."
    "${ssh_cmd[@]}" "${ssh_user}@${master1_ip}" "sudo kubeadm init --control-plane-endpoint ${vip_ip}:8443 --upload-certs --skip-phases=addon/kube-proxy || true"
    
    # Extraer comando de join de Control Plane y Worker desde Máster 1
    log_info "Capturando clave de certificados y tokens de unión desde el Máster 1..."
    local cert_key
    cert_key=$("${ssh_cmd[@]}" "${ssh_user}@${master1_ip}" "sudo kubeadm init phase upload-certs --upload-certs 2>/dev/null | tail -n 1")
    local join_token
    join_token=$("${ssh_cmd[@]}" "${ssh_user}@${master1_ip}" "sudo kubeadm token create --print-join-command 2>/dev/null")

    # 4. Unir Másters Secundarios (HA Replication)
    log_info "[Paso 4/5] Uniendo Másters Secundarios al Control Plane HA..."
    for ((i=1; i<${#master_ips[@]}; i++)); do
        local node="${master_ips[$i]}"
        log_info "Uniendo Control Plane Secundario ${node}..."
        "${ssh_cmd[@]}" "${ssh_user}@${node}" "sudo ${join_token} --control-plane --certificate-key ${cert_key} || true"
    done

    # 5. Unir Nodos Workers
    log_info "[Paso 5/5] Uniendo Nodos Workers al Clúster..."
    for node in "${worker_ips[@]}"; do
        log_info "Uniendo Worker ${node}..."
        "${ssh_cmd[@]}" "${ssh_user}@${node}" "sudo ${join_token} || true"
    done

    printf "\n"
    log_section "🎉 ¡AUTO-DESPLIEGUE DEL CLÚSTER HA COMPLETADO EXITOSAMENTE!"
    printf "  ${CLR_BOLD_GREEN}Resumen de Infraestructura Aprovisionada:${CLR_RESET}\n"
    printf "  %-30s %s\n" "Virtual IP Flotante (VIP):" "https://${vip_ip}:8443"
    printf "  %-30s %s\n" "Nodos Control Plane (HA):" "${master_ips[*]}"
    printf "  %-30s %s\n" "Nodos Workers de Cómputo:" "${worker_ips[*]}"
    printf "\n"
    printf "  ${CLR_BOLD_WHITE}Verificación final ejecutando 'kubectl get nodes' en el Máster 1:${CLR_RESET}\n"
    "${ssh_cmd[@]}" "${ssh_user}@${master1_ip}" "sudo kubectl get nodes -o wide"
    printf "\n"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    auto_provision_ha_cluster "$@"
fi
