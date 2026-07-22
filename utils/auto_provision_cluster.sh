#!/usr/bin/env bash
# =============================================================================
# KubeOps-Suite :: utils/auto_provision_cluster.sh
# Purpose : Single-Node SSH Orchestrator for full HA Cluster provisioning.
#           Phase 0: Clone/sync kubeops-suite on all remote nodes
#           Phase 1: Install prerequisites (containerd, kubelet, kubeadm, kubectl)
#           Phase 2: Deploy HAProxy + Keepalived VIP
#           Phase 3: Init Control Plane 1 (kubeadm init)
#           Phase 4: Join CP 2 & 3 (HA replication)
#           Phase 5: Join Workers
# Author  : KubeOps-Suite (Principal Platform Engineer)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${SUITE_ROOT:-}" ]]; then
    SUITE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
fi

if [[ -n "${_AUTO_PROVISION_SH_LOADED:-}" ]]; then
    return 0
fi
_AUTO_PROVISION_SH_LOADED=true

# shellcheck disable=SC1090
source "${SUITE_ROOT}/lib/logger.sh"
# shellcheck disable=SC1090
source "${SUITE_ROOT}/lib/state_manager.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_ssh() {
    ssh "${SSH_OPTS[@]}" "$@"
}

_ssh_sudo() {
    local node="${1}"; shift
    _ssh "${SSH_USER}@${node}" "sudo bash -s" <<< "${*}"
}

_remote_exec() {
    local node="${1}"; shift
    _ssh "${SSH_USER}@${node}" "$@"
}

# Run a block of commands on a remote node as root via heredoc
_remote_script() {
    local node="${1}"
    shift
    # $@ is ignored; caller passes heredoc via stdin pipe
    _ssh "${SSH_USER}@${node}" "sudo bash -euo pipefail"
}

# ---------------------------------------------------------------------------
# Phase 0: Ensure kubeops-suite exists on every remote node
# ---------------------------------------------------------------------------
_phase0_sync_repo() {
    local node="${1}"
    log_info "  [${node}] Sincronizando kubeops-suite..."
    _ssh "${SSH_USER}@${node}" bash -s <<'REMOTE'
set -euo pipefail
REPO_URL="https://github.com/lilkross1402/Suite-Devops-K8s.git"
REPO_DIR="${HOME}/kubeops-suite"
if [[ -d "${REPO_DIR}/.git" ]]; then
    cd "${REPO_DIR}"
    git fetch origin && git reset --hard origin/main
else
    rm -rf "${REPO_DIR}"
    git clone "${REPO_URL}" "${REPO_DIR}"
fi
chmod +x "${REPO_DIR}/kubeops.sh" \
         "${REPO_DIR}/modules/"*.sh \
         "${REPO_DIR}/stack/"*.sh \
         "${REPO_DIR}/lib/"*.sh \
         "${REPO_DIR}/utils/"*.sh 2>/dev/null || true
echo "SYNC_OK"
REMOTE
}

# ---------------------------------------------------------------------------
# Phase 1: Install container runtime + kubeadm / kubelet / kubectl
# ---------------------------------------------------------------------------
_phase1_install_prereqs() {
    local node="${1}"
    local k8s_ver="${2:-1.29}"
    local k8s_ver_full="${3:-1.29.15}"
    log_info "  [${node}] Instalando prerequisitos (containerd, kubeadm v${k8s_ver_full}, kubelet, kubectl)..."
    _ssh "${SSH_USER}@${node}" sudo bash -s -- "${k8s_ver}" "${k8s_ver_full}" <<'REMOTE'
set -euo pipefail
K8S_VERSION="${1:-1.29}"
K8S_VERSION_FULL="${2:-1.29.15}"

# 1. OS Detection
OS_ID="ubuntu"
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID="${ID:-ubuntu}"
fi

# 2. Kernel modules & sysctl
cat >/etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
modprobe overlay 2>/dev/null || true
modprobe br_netfilter 2>/dev/null || true

cat >/etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system -q 2>/dev/null || true

# 3. Disable swap
swapoff -a 2>/dev/null || true
sed -i '/\sswap\s/d' /etc/fstab || true

# 4. OS Family Package & Repository Setup
case "${OS_ID}" in
    ubuntu|debian|mint|pop)
        export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
        systemctl stop unattended-upgrades 2>/dev/null || true
        pkill -f unattended-upgrade 2>/dev/null || true
        while fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock >/dev/null 2>&1; do
            sleep 2
        done

        apt-get update -qq 2>/dev/null || true
        apt-get install -y --fix-missing --no-install-recommends open-iscsi nfs-common jq curl ca-certificates apt-transport-https 2>/dev/null || true

        if ! command -v containerd &>/dev/null; then
            install -m 0755 -d /etc/apt/keyrings
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc 2>/dev/null || true
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "${VERSION_CODENAME}") stable" > /etc/apt/sources.list.d/docker.list 2>/dev/null || true
            apt-get update -qq 2>/dev/null || true
            apt-get install -y --fix-missing containerd.io || apt-get install -y containerd 2>/dev/null || true
        fi

        if ! command -v kubeadm &>/dev/null; then
            install -m 0755 -d /etc/apt/keyrings
            curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" -o /etc/apt/keyrings/kubernetes-apt-keyring.asc 2>/dev/null || true
            echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.asc] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" > /etc/apt/sources.list.d/kubernetes.list
            apt-get update -qq 2>/dev/null || true
            apt-get install -y --fix-missing kubelet kubeadm kubectl 2>/dev/null || true
            apt-mark hold kubelet kubeadm kubectl 2>/dev/null || true
        fi
        ;;

    rhel|rocky|centos|almalinux|fedora|ol)
        PKG_MGR="dnf"
        command -v dnf &>/dev/null || PKG_MGR="yum"

        setenforce 0 2>/dev/null || true
        sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config 2>/dev/null || true

        ${PKG_MGR} install -y iscsi-initiator-utils nfs-utils jq curl tar ca-certificates 2>/dev/null || true

        if ! command -v containerd &>/dev/null; then
            ${PKG_MGR} install -y containerd.io || ${PKG_MGR} install -y containerd 2>/dev/null || true
        fi

        if ! command -v kubeadm &>/dev/null; then
            cat >/etc/yum.repos.d/kubernetes.repo <<EOF
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/rpm/repodata/repomd.xml.key
EOF
            ${PKG_MGR} install -y kubelet kubeadm kubectl 2>/dev/null || true
        fi
        ;;

    *)
        apt-get update -qq 2>/dev/null || true
        apt-get install -y --fix-missing kubelet kubeadm kubectl containerd 2>/dev/null || true
        ;;
esac

# 5. Configure containerd with SystemdCgroup & enable CRI plugin
mkdir -p /etc/containerd
containerd config default | sed 's/disabled_plugins = \["cri"\]/disabled_plugins = []/g' >/etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml

cat >/etc/crictl.yaml <<EOF
runtime-endpoint: unix:///var/run/containerd/containerd.sock
image-endpoint: unix:///var/run/containerd/containerd.sock
timeout: 10
debug: false
EOF

systemctl enable --now iscsid 2>/dev/null || true
systemctl restart containerd 2>/dev/null || true
systemctl enable --now containerd 2>/dev/null || true
systemctl enable --now kubelet 2>/dev/null || true

# 6. Verification
if command -v kubeadm &>/dev/null && command -v containerd &>/dev/null; then
    echo "PREREQS_OK"
else
    echo "ERROR: Missing kubeadm or containerd after installation"
    exit 1
fi
REMOTE
}

# ---------------------------------------------------------------------------
# Phase 2: Deploy HAProxy + Keepalived on Masters
# ---------------------------------------------------------------------------
_phase2_deploy_vip() {
    local node="${1}"
    local vip="${2}"
    local priority="${3}"
    local m1="${4}"
    local m2="${5}"
    local m3="${6:-}"

    log_info "  [${node}] Instalando HAProxy + Keepalived (VIP=${vip}, priority=${priority})..."
    _ssh "${SSH_USER}@${node}" sudo bash -s -- "${vip}" "${priority}" "${m1}" "${m2}" "${m3}" <<'REMOTE'
set -euo pipefail
VIP="${1}"; PRIORITY="${2}"; M1="${3}"; M2="${4}"; M3="${5:-}"
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a

# ---- Wait for dpkg lock ----
systemctl stop unattended-upgrades 2>/dev/null || true
pkill -f unattended-upgrade 2>/dev/null || true
while fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock >/dev/null 2>&1; do
    sleep 2
done

# ---- net.ipv4.ip_nonlocal_bind ----
echo "net.ipv4.ip_nonlocal_bind = 1" >/etc/sysctl.d/99-vip.conf
sysctl --system -q 2>/dev/null || true

# ---- Install packages with --fix-missing ----
apt-get update -qq
apt-get install -y --fix-missing keepalived haproxy

NET_IFACE=$(ip -4 route show default | awk '{print $5}' | head -1)

# ---- HAProxy config ----
cat >/etc/haproxy/haproxy.cfg <<EOF
global
    log /dev/log local0
    maxconn 4000
    daemon
defaults
    log     global
    mode    tcp
    option  dontlognull
    timeout connect 10s
    timeout client  1m
    timeout server  1m
frontend k8s-api
    bind *:8443
    default_backend k8s-masters
backend k8s-masters
    balance roundrobin
    server master1 ${M1}:6443 check
    server master2 ${M2}:6443 check
EOF
[[ -n "${M3}" ]] && echo "    server master3 ${M3}:6443 check" >>/etc/haproxy/haproxy.cfg
systemctl enable haproxy && systemctl restart haproxy

# ---- Keepalived config ----
cat >/etc/keepalived/keepalived.conf <<EOF
global_defs {
    router_id LVS_K8S
}
vrrp_instance VI_K8S {
    state BACKUP
    interface ${NET_IFACE}
    virtual_router_id 51
    priority ${PRIORITY}
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass k8sha
    }
    virtual_ipaddress {
        ${VIP}
    }
}
EOF
systemctl enable keepalived && systemctl restart keepalived
echo "VIP_OK"
REMOTE
}

# ---------------------------------------------------------------------------
# Main orchestrator
# ---------------------------------------------------------------------------
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

    SSH_USER="${ssh_user}"

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
    SSH_OPTS=("-o" "ConnectTimeout=10" "-o" "StrictHostKeyChecking=no" "-o" "BatchMode=yes")
    if [[ -n "${ssh_key}" ]]; then
        SSH_OPTS+=("-i" "${ssh_key}")
    fi

    # ── WIZARD: Modo de Despliegue (Online vs Air-Gap) ───────────────────────
    local deploy_mode="online"
    local nexus_host=""
    local nexus_docker_port="8082"
    local prov_nexus="N"

    printf "\n"
    printf "  ══════════════════════════════════════════════════════════════\n"
    printf "  ${CLR_BOLD_WHITE}Selección de Entorno de Despliegue${CLR_RESET}\n"
    printf "  ══════════════════════════════════════════════════════════════\n\n"
    printf "  ${CLR_BOLD_WHITE}[0] Seleccione el modo de red del clúster:${CLR_RESET}\n"
    printf "  ${CLR_CYAN}[1]${CLR_RESET} ONLINE (Con acceso a Internet) ${CLR_BOLD_GREEN}(Predeterminado)${CLR_RESET}\n"
    printf "  ${CLR_CYAN}[2]${CLR_RESET} AIR-GAP (Sin Internet / Repositorio Privado Nexus 3)\n"
    printf "  ${CLR_BOLD_WHITE}Selección [1]: ${CLR_RESET}"
    read -r net_choice
    if [[ "${net_choice}" == "2" ]]; then
        deploy_mode="airgap"
        log_info "Modo AIR-GAP seleccionado (Sin Internet)."
        
        printf "  ¿Desea aprovisionar el Servidor Nexus 3 vía SSH antes de instalar el clúster? [y/N]: "
        read -r prov_nexus
        if [[ "${prov_nexus}" =~ ^[yY]$ ]]; then
            printf "  Ingrese la IP del Servidor Nexus 3 (ej. 172.31.46.152 o 3.144.166.168): "
            read -r nexus_host
        else
            printf "  Ingrese la IP/URL del Registro Docker Nexus ya activo (ej. 172.31.46.152:8082): "
            read -r nexus_host
        fi
    fi

    # ── WIZARD: Versiones y Plugin CNI ─────────────────────────────────────
    local k8s_version="1.29"
    local k8s_version_full="1.29.15"
    local cni_plugin="cilium"
    local cni_version="1.15.5"
    local pod_cidr="10.244.0.0/16"
    local service_cidr="10.96.0.0/12"

    printf "\n"
    printf "  ══════════════════════════════════════════════════════════════\n"
    printf "  ${CLR_BOLD_WHITE}Configuración de Versiones del Clúster${CLR_RESET}\n"
    printf "  ══════════════════════════════════════════════════════════════\n\n"

    # Versión de Kubernetes
    printf "  ${CLR_BOLD_WHITE}[1] Seleccione la versión de Kubernetes a instalar:${CLR_RESET}\n"
    printf "  ${CLR_CYAN}[1]${CLR_RESET} v1.29 (1.29.15) — Estable ${CLR_BOLD_GREEN}(Recomendada)${CLR_RESET}\n"
    printf "  ${CLR_CYAN}[2]${CLR_RESET} v1.30 (1.30.10) — Versión Reciente\n"
    printf "  ${CLR_CYAN}[3]${CLR_RESET} v1.28 (1.28.15) — Versión Legacy\n"
    printf "  ${CLR_CYAN}[4]${CLR_RESET} Personalizada (ingresar versión manualmente)\n"
    printf "  ${CLR_BOLD_WHITE}Selección [1]: ${CLR_RESET}"
    read -r v_choice
    case "${v_choice}" in
        2) k8s_version="1.30"; k8s_version_full="1.30.10" ;;
        3) k8s_version="1.28"; k8s_version_full="1.28.15" ;;
        4)
            printf "  Ingrese la versión exacta (ej: 1.29.15): "
            read -r custom_v
            if [[ -n "${custom_v}" ]]; then
                k8s_version_full="${custom_v#v}"
                k8s_version="$(echo "${k8s_version_full}" | cut -d. -f1,2)"
            fi
            ;;
        *) k8s_version="1.29"; k8s_version_full="1.29.15" ;;
    esac
    log_info "Versión de Kubernetes seleccionada: v${k8s_version_full}"

    # Plugin CNI
    printf "\n  ${CLR_BOLD_WHITE}[2] Seleccione el Plugin de Red (CNI):${CLR_RESET}\n"
    printf "  ${CLR_CYAN}[1]${CLR_RESET} Cilium (eBPF High-Performance) ${CLR_BOLD_GREEN}(Recomendado)${CLR_RESET}\n"
    printf "  ${CLR_CYAN}[2]${CLR_RESET} Calico (BGP / Network Policy)\n"
    printf "  ${CLR_CYAN}[3]${CLR_RESET} Flannel (Overlay ligero)\n"
    printf "  ${CLR_BOLD_WHITE}Selección [1]: ${CLR_RESET}"
    read -r cni_choice
    case "${cni_choice}" in
        2)
            cni_plugin="calico"
            printf "  Versión de Calico [3.27.4]: "
            read -r calico_v
            cni_version="${calico_v:-3.27.4}"
            ;;
        3)
            cni_plugin="flannel"
            cni_version="0.24.2"
            ;;
        *)
            cni_plugin="cilium"
            printf "  Versión de Cilium [1.15.5]: "
            read -r cilium_v
            cni_version="${cilium_v:-1.15.5}"
            ;;
    esac
    log_info "CNI seleccionado: ${cni_plugin} v${cni_version}"

    # CIDRs
    printf "\n  ${CLR_BOLD_WHITE}[3] Configuración de CIDRs de Red:${CLR_RESET}\n"
    printf "  Pod Network CIDR [%s]: " "${pod_cidr}"
    read -r pod_cidr_input
    pod_cidr="${pod_cidr_input:-${pod_cidr}}"

    printf "  Service CIDR [%s]: " "${service_cidr}"
    read -r svc_cidr_input
    service_cidr="${svc_cidr_input:-${service_cidr}}"

    log_info "Pod CIDR: ${pod_cidr} | Service CIDR: ${service_cidr}"

    # Resumen antes de continuar
    printf "\n"
    printf "  ══════════════════════════════════════════════════════════════\n"
    printf "  ${CLR_BOLD_WHITE}  RESUMEN DE CONFIGURACIÓN DEL CLÚSTER${CLR_RESET}\n"
    printf "  ══════════════════════════════════════════════════════════════\n"
    printf "  %-28s ${CLR_BOLD_GREEN}%s${CLR_RESET}\n" "Virtual IP (VIP):"         "${vip_ip}:8443"
    printf "  %-28s %s\n"                              "Control Planes:"           "${master_ips[*]}"
    printf "  %-28s %s\n"                              "Workers:"                  "${worker_ips[*]}"
    printf "  %-28s ${CLR_BOLD_CYAN}v%s${CLR_RESET}\n" "Kubernetes:"               "${k8s_version_full}"
    printf "  %-28s ${CLR_BOLD_CYAN}%s v%s${CLR_RESET}\n" "CNI Plugin:"             "${cni_plugin}" "${cni_version}"
    printf "  %-28s %s\n"                              "Pod CIDR:"                 "${pod_cidr}"
    printf "  %-28s %s\n"                              "Service CIDR:"             "${service_cidr}"
    printf "  ══════════════════════════════════════════════════════════════\n\n"
    printf "  ¿Confirmar y comenzar el despliegue completo? [y/N]: "
    read -r confirm
    if [[ ! "${confirm}" =~ ^[yY]$ ]]; then
        log_warn "Despliegue cancelado por el usuario."
        return 0
    fi


    local master1_ip="${master_ips[0]}"
    local master2_ip="${master_ips[1]:-}"
    local master3_ip="${master_ips[2]:-}"

    # ── PASO 0/6: Aprovisionar Servidor Nexus 3 (Opcional Air-Gap) ───────────
    if [[ -n "${nexus_host}" && "${prov_nexus:-}" =~ ^[yY]$ ]]; then
        log_info "[Paso 0/6] Aprovisionando Servidor Nexus 3 Air-Gap Mirror en ${nexus_host}..."
        _ssh "${ssh_user}@${nexus_host}" "cd /home/${ssh_user}/kubeops-suite 2>/dev/null || cd /root/kubeops-suite 2>/dev/null || true; git fetch origin && git reset --hard origin/main && chmod +x kubeops.sh modules/*.sh stack/*.sh lib/*.sh utils/*.sh && sudo ./utils/setup_nexus_repository.sh" || true
        log_success "Servidor Nexus 3 cargado con las imágenes del clúster en ${nexus_host}:${nexus_docker_port}."
    fi

    # ── PASO 1/6: Verificar SSH ──────────────────────────────────────────────
    log_info "[Paso 1/6] Verificando conectividad SSH contra los ${#master_ips[@]} Másters y ${#worker_ips[@]} Workers..."
    local all_nodes=("${master_ips[@]}" "${worker_ips[@]}")
    for node in "${all_nodes[@]}"; do
        log_info "  Comprobando SSH → ${ssh_user}@${node}..."
        if ! _ssh "${ssh_user}@${node}" "echo ok" &>/dev/null; then
            log_error "No se pudo conectar vía SSH a ${ssh_user}@${node}. Verifique usuario y clave."
            return 1
        fi
    done
    log_success "Conectividad SSH verificada en todos los nodos."

    # ── PASO 2/6: Sincronizar repo en todos los nodos (En paralelo) ─────────
    log_info "[Paso 2/6] Sincronizando kubeops-suite en los nodos remotos (en paralelo)..."
    local pids=()
    for node in "${all_nodes[@]}"; do
        _phase0_sync_repo "${node}" &
        pids+=($!)
    done
    for pid in "${pids[@]}"; do
        wait "${pid}" || true
    done
    log_success "kubeops-suite sincronizado en todos los nodos."

    # ── PASO 3/6: Instalar prereqs en todos los nodos (En paralelo) ─────────
    log_info "[Paso 3/6] Instalando prerequisitos K8s (containerd, kubeadm=${k8s_version_full}) en paralelo en todos los nodos..."
    pids=()
    for node in "${all_nodes[@]}"; do
        _phase1_install_prereqs "${node}" "${k8s_version}" "${k8s_version_full}" &
        pids+=($!)
    done
    for pid in "${pids[@]}"; do
        wait "${pid}" || true
    done

    # Verificación estricta de binario kubeadm en todos los nodos
    local kubeadm_missing=0
    for node in "${all_nodes[@]}"; do
        if ! _ssh "${ssh_user}@${node}" "command -v kubeadm" &>/dev/null; then
            log_error "El binario 'kubeadm' no se instaló en el nodo ${node}"
            kubeadm_missing=1
        fi
    done
    if [[ "${kubeadm_missing}" -eq 1 ]]; then
        log_fatal "Faltan binarios de K8s en algunos nodos. Abortando instalación antes del Paso 4/5."
    fi
    log_success "Prerequisitos y binarios de K8s (kubeadm/kubelet/kubectl) verificados en todos los nodos."

    # ── PASO 4/6: VIP HAProxy + Keepalived en Masters ────────────────────────
    log_info "[Paso 4/6] Desplegando Virtual IP HA (HAProxy + Keepalived) en los Másters..."
    local priorities=(102 101 100)
    for i in "${!master_ips[@]}"; do
        _phase2_deploy_vip "${master_ips[$i]}" "${vip_ip}" "${priorities[$i]}" \
            "${master1_ip}" "${master2_ip}" "${master3_ip}"
    done
    log_success "Virtual IP ${vip_ip}:8443 activa."
    sleep 5  # Esperar convergencia VRRP

    # ── PASO 5/6: kubeadm init en Máster 1 ──────────────────────────────────
    log_info "[Paso 5/6] Inicializando Control Plane Primario en ${master1_ip} (K8s v${k8s_version_full})..."
    _ssh "${ssh_user}@${master1_ip}" sudo bash -s -- "${vip_ip}" "${k8s_version_full}" "${pod_cidr}" "${service_cidr}" "${ssh_user}" <<'REMOTE'
set -euo pipefail
VIP="${1}"; K8S_VER="${2}"; POD_CIDR="${3}"; SVC_CIDR="${4}"; OS_USER="${5:-ubuntu}"
mkdir -p "${HOME}/.kube"

# Ensure containerd CRI plugin is active
sed -i 's/disabled_plugins = \["cri"\]/disabled_plugins = []/g' /etc/containerd/config.toml 2>/dev/null || true
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml 2>/dev/null || true
systemctl restart containerd 2>/dev/null || true
sleep 2

if [[ -f /etc/kubernetes/admin.conf ]]; then
    echo "Control plane already initialized, skipping kubeadm init."
else
    kubeadm init \
        --control-plane-endpoint "${VIP}:8443" \
        --upload-certs \
        --pod-network-cidr="${POD_CIDR}" \
        --service-cidr="${SVC_CIDR}" \
        --skip-phases=addon/kube-proxy \
        --kubernetes-version="${K8S_VER}" \
        2>&1
fi

# Setup kubeconfig for root
mkdir -p /root/.kube
cp -f /etc/kubernetes/admin.conf /root/.kube/config
chown root:root /root/.kube/config

# Setup kubeconfig for OS user
HOME_DIR=$(eval echo "~${OS_USER}")
mkdir -p "${HOME_DIR}/.kube"
cp -f /etc/kubernetes/admin.conf "${HOME_DIR}/.kube/config"
chown -R "${OS_USER}:${OS_USER}" "${HOME_DIR}/.kube" || true

echo "INIT_OK"
REMOTE
    log_success "Control Plane inicializado en ${master1_ip}."

    # Esperar a que el API Server esté listo
    log_info "  Esperando al API Server en ${master1_ip}:6443..."
    for i in $(seq 1 30); do
        if _ssh "${ssh_user}@${master1_ip}" "sudo kubectl get nodes --kubeconfig=/etc/kubernetes/admin.conf" &>/dev/null; then
            break
        fi
        sleep 5
    done

    # Instalar CNI en Máster 1
    log_info "  Instalando CNI: ${cni_plugin} v${cni_version} (Modo: ${deploy_mode})..."
    _ssh "${ssh_user}@${master1_ip}" sudo bash -s -- "${cni_plugin}" "${cni_version}" "${pod_cidr}" "${deploy_mode}" "${nexus_host}" "${nexus_docker_port}" <<'REMOTE'
set -euo pipefail
CNI_PLUGIN="${1}"; CNI_VERSION="${2}"; POD_CIDR="${3}"; MODE="${4:-online}"; NEXUS_IP="${5:-}"; NEXUS_PORT="${6:-8082}"
export KUBECONFIG=/etc/kubernetes/admin.conf

if [[ "${MODE}" == "airgap" ]]; then
    log_info "Instalando CNI ${CNI_PLUGIN} en modo AIR-GAP desde manifiestos locales..."
    OFFLINE_MANIFEST=$(find /home/${SUDO_USER:-ubuntu}/kubeops-suite/offline-assets /root/kubeops-suite/offline-assets -name "${CNI_PLUGIN}*.yaml" -o -name "calico.yaml" -o -name "kube-flannel.yml" 2>/dev/null | head -1 || echo "")
    if [[ -n "${OFFLINE_MANIFEST}" && -f "${OFFLINE_MANIFEST}" ]]; then
        if [[ -n "${NEXUS_IP}" ]]; then
            sed "s|quay.io|${NEXUS_IP}:${NEXUS_PORT}|g; s|docker.io|${NEXUS_IP}:${NEXUS_PORT}|g; s|registry.k8s.io|${NEXUS_IP}:${NEXUS_PORT}|g" \
                "${OFFLINE_MANIFEST}" > /tmp/cni-airgap.yaml
            kubectl apply -f /tmp/cni-airgap.yaml
            rm -f /tmp/cni-airgap.yaml
        else
            kubectl apply -f "${OFFLINE_MANIFEST}"
        fi
        echo "CNI_AIRGAP_OK"
        exit 0
    fi
fi

case "${CNI_PLUGIN}" in
  cilium)
    if ! command -v helm &>/dev/null; then
        curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash 2>/dev/null || true
    fi
    if command -v helm &>/dev/null; then
        helm repo add cilium https://helm.cilium.io/ 2>/dev/null || true
        helm repo update cilium 2>/dev/null || true
        CLEAN_VER="${CNI_VERSION#v}"
        helm upgrade --install cilium cilium/cilium \
            --version "${CLEAN_VER}" \
            --namespace kube-system \
            --set kubeProxyReplacement=true 2>&1 || true
    else
        kubectl apply -f "https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/calico.yaml" 2>&1 || true
    fi
    ;;
  calico)
    curl -fsSL "https://raw.githubusercontent.com/projectcalico/calico/v${CNI_VERSION}/manifests/calico.yaml" | \
        sed "s|192.168.0.0/16|${POD_CIDR}|g" | kubectl apply -f - 2>&1 || true
    ;;
  flannel)
    kubectl apply -f \
        "https://github.com/flannel-io/flannel/releases/download/v${CNI_VERSION}/kube-flannel.yml" 2>&1 || true
    ;;
esac
echo "CNI_OK"
REMOTE

    # ── Capturar join tokens ──────────────────────────────────────────────────
    log_info "  Capturando tokens de unión desde el Máster 1..."
    local cert_key join_cmd
    cert_key=$(_ssh "${ssh_user}@${master1_ip}" \
        "sudo kubeadm init phase upload-certs --upload-certs 2>/dev/null | tail -1")
    join_cmd=$(_ssh "${ssh_user}@${master1_ip}" \
        "sudo kubeadm token create --print-join-command 2>/dev/null")

    # ── PASO 6a/6: Unir Másters Secundarios ─────────────────────────────────
    log_info "[Paso 6/6] Uniendo Másters Secundarios al Control Plane HA..."
    for ((i=1; i<${#master_ips[@]}; i++)); do
        local node="${master_ips[$i]}"
        log_info "  Uniendo Control Plane ${node}..."
        _ssh "${ssh_user}@${node}" "if [[ -f /etc/kubernetes/kubelet.conf ]]; then echo 'Node already joined, skipping kubeadm join.'; else sudo ${join_cmd} --control-plane --certificate-key ${cert_key}; fi" || true
        # kubeconfig para el usuario en CPs adicionales
        _ssh "${ssh_user}@${node}" bash -s -- "${ssh_user}" <<'REMOTE'
set -euo pipefail
U="${1}"
HOME_DIR=$(eval echo "~${U}")
mkdir -p "${HOME_DIR}/.kube"
sudo cp -f /etc/kubernetes/admin.conf "${HOME_DIR}/.kube/config" || true
sudo chown -R "${U}:${U}" "${HOME_DIR}/.kube" 2>/dev/null || true
REMOTE
    done

    # ── PASO 6b/6: Unir Workers ──────────────────────────────────────────────
    log_info "  Uniendo Nodos Workers al Clúster..."
    for node in "${worker_ips[@]}"; do
        log_info "  Uniendo Worker ${node}..."
        _ssh "${ssh_user}@${node}" "if [[ -f /etc/kubernetes/kubelet.conf ]]; then echo 'Worker already joined, skipping kubeadm join.'; else sudo ${join_cmd}; fi" || true
    done

    printf "\n"
    log_section "🎉 ¡AUTO-DESPLIEGUE DEL CLÚSTER HA COMPLETADO!"
    printf "  %-30s %s\n" "Virtual IP Flotante (VIP):" "https://${vip_ip}:8443"
    printf "  %-30s %s\n" "Control Plane HA (3 nodos):" "${master_ips[*]}"
    printf "  %-30s %s\n" "Workers de Cómputo:" "${worker_ips[*]}"
    printf "\n"
    printf "  ${CLR_BOLD_WHITE}Estado del Clúster (kubectl get nodes -o wide):${CLR_RESET}\n"
    sleep 10
    _ssh "${ssh_user}@${master1_ip}" "sudo kubectl get nodes -o wide --kubeconfig=/etc/kubernetes/admin.conf" || true
    printf "\n"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    auto_provision_ha_cluster "$@"
fi
