#!/usr/bin/env bash
# =============================================================================
# KubeOps-Suite :: stack/deploy_haproxy_keepalived.sh
# Purpose : Automate HAProxy + Keepalived Virtual IP (VIP) deployment for
#           100% zero-touch automatic failover across Kubernetes Control Plane nodes.
# =============================================================================
set -euo pipefail

if [[ -z "${SUITE_ROOT:-}" ]]; then
    SUITE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

# shellcheck disable=SC1090
source "${SUITE_ROOT}/lib/logger.sh"
# shellcheck disable=SC1090
source "${SUITE_ROOT}/lib/os_detect.sh"
# shellcheck disable=SC1090
source "${SUITE_ROOT}/lib/network_check.sh"
# shellcheck disable=SC1090
source "${SUITE_ROOT}/lib/state_manager.sh"

deploy_haproxy_keepalived() {
    log_banner
    log_section "Despliegue de HAProxy + Keepalived (Virtual IP HA)"

    os_detect || true
    net_detect_mode

    local primary_ip
    primary_ip=$(net_get_primary_ip)

    local net_interface
    net_interface=$(ip -4 route show default | awk '{print $5}' | head -1 || echo "eth0")

    printf "\n  ${CLR_BOLD_WHITE}Configuración de la IP Virtual (VIP) para Alta Disponibilidad:${CLR_RESET}\n"
    printf "  Interfaz de Red Detectada: ${CLR_BOLD_CYAN}%s${CLR_RESET}\n" "${net_interface}"

    local vip_ip
    vip_ip=$(state_get ".ha.vip" 2>/dev/null || echo "")
    if [[ -z "${vip_ip}" || "${vip_ip}" == "null" ]]; then
        printf "  Ingrese la IP Virtual Flotante (VIP) para el clúster (ej. 172.31.32.100): "
        read -r vip_ip
    fi

    if [[ -z "${vip_ip}" ]]; then
        log_error "Debe proporcionar una IP Virtual válida."
        return 1
    fi

    local master1_ip master2_ip master3_ip
    master1_ip=$(state_get ".masters[0].ip" 2>/dev/null || echo "${primary_ip}")
    master2_ip=$(state_get ".masters[1].ip" 2>/dev/null || echo "")
    master3_ip=$(state_get ".masters[2].ip" 2>/dev/null || echo "")

    if [[ -z "${master2_ip}" ]]; then
        printf "  IP del Máster 2: "
        read -r master2_ip
    fi

    if [[ -z "${master3_ip}" ]]; then
        printf "  IP del Máster 3 (Opcional - Presione Enter para omitir): "
        read -r master3_ip
    fi

    log_info "Instalando paquetes keepalived y haproxy..."
    os_install_pkg keepalived haproxy

    # 1. Configurar Keepalived
    log_info "Configurando Keepalived en la interfaz ${net_interface} con VIP ${vip_ip}..."
    local priority=101
    local state="MASTER"
    if [[ "${primary_ip}" != "${master1_ip}" ]]; then
        priority=100
        state="BACKUP"
    fi

    sudo tee /etc/keepalived/keepalived.conf > /dev/null <<EOF
global_defs {
    router_id ${HOSTNAME}
    enable_script_security
    script_user root
}

vrrp_script check_haproxy {
    script "killall -0 haproxy"
    interval 2
    weight 2
}

vrrp_instance VI_1 {
    state ${state}
    interface ${net_interface}
    virtual_router_id 51
    priority ${priority}
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass KubeOpsHA2026
    }
    virtual_ipaddress {
        ${vip_ip}
    }
    track_script {
        check_haproxy
    }
}
EOF

    # Enable non-local bind so HAProxy can listen on floating VIP
    sudo sysctl -w net.ipv4.ip_nonlocal_bind=1 2>/dev/null || true
    echo "net.ipv4.ip_nonlocal_bind=1" | sudo tee /etc/sysctl.d/99-haproxy-vip.conf > /dev/null

    # 2. Configurar HAProxy
    log_info "Configurando HAProxy para balancear el puerto 8443 → API Servers (puerto 6443)..."
    sudo tee /etc/haproxy/haproxy.cfg > /dev/null <<EOF
global
    log /dev/log local0
    log /dev/log local1 notice
    chroot /var/lib/haproxy
    user haproxy
    group haproxy
    daemon

defaults
    log     global
    mode    tcp
    option  tcplog
    option  dontlognull
    timeout connect 5000ms
    timeout client  50000ms
    timeout server  50000ms

frontend k8s-api-frontend
    bind *:8443
    mode tcp
    option tcplog
    default_backend k8s-api-backend

backend k8s-api-backend
    mode tcp
    option tcp-check
    balance roundrobin
    server master1 ${master1_ip}:6443 check fall 3 rise 2
EOF

    if [[ -n "${master2_ip}" ]]; then
        echo "    server master2 ${master2_ip}:6443 check fall 3 rise 2" | sudo tee -a /etc/haproxy/haproxy.cfg > /dev/null
    fi

    if [[ -n "${master3_ip}" ]]; then
        echo "    server master3 ${master3_ip}:6443 check fall 3 rise 2" | sudo tee -a /etc/haproxy/haproxy.cfg > /dev/null
    fi

    log_info "Habilitando y reiniciando servicios keepalived y haproxy..."
    sudo systemctl enable keepalived haproxy
    sudo systemctl restart keepalived haproxy

    log_info "Actualizando certificados SSL del API Server para incluir la VIP ${vip_ip} en certSANs..."
    if command -v kubeadm &>/dev/null && [[ -f /etc/kubernetes/manifests/kube-apiserver.yaml ]]; then
        sudo rm -f /etc/kubernetes/pki/apiserver.crt /etc/kubernetes/pki/apiserver.key 2>/dev/null || true
        sudo kubeadm init phase certs apiserver --apiserver-cert-extra-sans "${vip_ip}" 2>/dev/null || true
        sudo pkill -9 kube-apiserver 2>/dev/null || true
    fi

    log_info "Actualizando kubeconfig local para apuntar a la Virtual IP https://${vip_ip}:8443..."
    sudo sed -i "s|https://.*:6443|https://${vip_ip}:8443|g" /etc/kubernetes/admin.conf 2>/dev/null || true
    sudo sed -i "s|https://.*:8443|https://${vip_ip}:8443|g" /etc/kubernetes/admin.conf 2>/dev/null || true

    sudo mkdir -p /root/.kube
    sudo cp -f /etc/kubernetes/admin.conf /root/.kube/config 2>/dev/null || true

    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        local u_home
        u_home=$(eval echo "~${SUDO_USER}")
        sudo mkdir -p "${u_home}/.kube"
        sudo cp -f /etc/kubernetes/admin.conf "${u_home}/.kube/config" 2>/dev/null || true
        sudo chown -R "${SUDO_USER}:${SUDO_USER}" "${u_home}/.kube" 2>/dev/null || true
    fi

    state_set ".ha.vip" "${vip_ip}"
    log_success "¡HAProxy + Keepalived desplegado exitosamente con VIP flotante ${vip_ip}:8443!"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    deploy_haproxy_keepalived "$@"
fi
