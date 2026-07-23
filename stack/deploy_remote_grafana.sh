#!/usr/bin/env bash
# =============================================================================
# KubeOps-Suite :: stack/deploy_remote_grafana.sh
# Purpose : Deploy Grafana on a dedicated external Monitoring Server via SSH/Docker
#           and automatically configure Data Sources to aggregate metrics & logs
#           from Kubernetes clusters (Prometheus & Loki).
# Author  : KubeOps-Suite (Principal Platform Engineer)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${SUITE_ROOT:-}" ]]; then
    SUITE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
fi

# shellcheck disable=SC1090
source "${SUITE_ROOT}/lib/logger.sh"
# shellcheck disable=SC1090
source "${SUITE_ROOT}/lib/network_check.sh"
# shellcheck disable=SC1090
source "${SUITE_ROOT}/lib/state_manager.sh"

deploy_remote_grafana_server() {
    log_banner
    log_section "Despliegue de Servidor de Monitoreo Centralizado (Grafana Dedicado)"

    local ssh_user="ubuntu"
    local target_ip=""
    local grafana_port="3000"
    local admin_password="Admin123!"
    local ssh_key=""

    local local_ip
    local_ip=$(net_get_primary_ip 2>/dev/null || echo "127.0.0.1")

    printf "\n  ${CLR_BOLD_WHITE}Configuración del Servidor Dedicado de Monitoreo:${CLR_RESET}\n\n"
    printf "  IP del Servidor de Monitoreo Externo (ej. 192.168.1.50 / 3.144.x.x): "
    read -r target_ip

    if [[ -z "${target_ip}" ]]; then
        log_error "La IP del servidor de monitoreo es obligatoria."
        return 1
    fi

    printf "  Usuario SSH [%s]: " "${ssh_user}"
    read -r user_input
    ssh_user="${user_input:-${ssh_user}}"

    printf "  Puerto HTTP para Grafana [%s]: " "${grafana_port}"
    read -r port_input
    grafana_port="${port_input:-${grafana_port}}"

    printf "  Contraseña para Admin de Grafana [%s]: " "${admin_password}"
    read -r pass_input
    admin_password="${pass_input:-${admin_password}}"

    printf "  ¿Desea especificar archivo de clave privada SSH (.pem / id_rsa)? [y/N]: "
    read -r use_key
    if [[ "${use_key}" =~ ^[yY]$ ]]; then
        printf "  Ruta de la clave SSH: "
        read -r ssh_key
    fi

    local -a ssh_opts=("-o" "ConnectTimeout=10" "-o" "StrictHostKeyChecking=no" "-o" "BatchMode=yes")
    if [[ -n "${ssh_key}" && -f "${ssh_key}" ]]; then
        ssh_opts+=("-i" "${ssh_key}")
    fi

    log_info "Verificando conexión SSH contra ${ssh_user}@${target_ip}..."
    if ! ssh "${ssh_opts[@]}" "${ssh_user}@${target_ip}" "echo ok" &>/dev/null; then
        log_error "No se pudo conectar por SSH a ${ssh_user}@${target_ip}. Verifique IP, usuario y clave SSH."
        return 1
    fi
    log_success "Conexión SSH confirmada."

    # K8s Service Endpoints
    local k8s_prometheus_url="http://${local_ip}:30090"
    local k8s_loki_url="http://${local_ip}:3100"

    printf "\n  ${CLR_BOLD_WHITE}Endpoints del Clúster Kubernetes KubeOps:${CLR_RESET}\n"
    printf "  URL de Prometheus [%s]: " "${k8s_prometheus_url}"
    read -r prom_input
    k8s_prometheus_url="${prom_input:-${k8s_prometheus_url}}"

    printf "  URL de Loki [%s]: " "${k8s_loki_url}"
    read -r loki_input
    k8s_loki_url="${loki_input:-${k8s_loki_url}}"

    log_info "Instalando y configurando Grafana Central en ${target_ip}:${grafana_port}..."

    ssh "${ssh_opts[@]}" "${ssh_user}@${target_ip}" sudo bash -s -- \
        "${grafana_port}" "${admin_password}" "${k8s_prometheus_url}" "${k8s_loki_url}" <<'REMOTE'
set -euo pipefail
PORT="${1}"; PASS="${2}"; PROM_URL="${3}"; LOKI_URL="${4}"

# 1. Install Docker if missing
if ! command -v docker &>/dev/null; then
    echo "Instalando Docker Engine..."
    apt-get update -qq 2>/dev/null || true
    apt-get install -y docker.io curl 2>/dev/null || yum install -y docker curl 2>/dev/null || dnf install -y docker curl 2>/dev/null || true
    systemctl enable --now docker 2>/dev/null || true
fi

# 2. Prepare provisioning directory
mkdir -p /etc/grafana/provisioning/datasources

cat > /etc/grafana/provisioning/datasources/k8s-cluster.yaml <<EOF
apiVersion: 1
datasources:
  - name: Prometheus-K8s
    type: prometheus
    access: proxy
    url: ${PROM_URL}
    isDefault: true
    editable: true
  - name: Loki-K8s
    type: loki
    access: proxy
    url: ${LOKI_URL}
    editable: true
EOF

# 3. Launch Grafana container
docker rm -f grafana-central 2>/dev/null || true
docker volume create grafana-central-data 2>/dev/null || true

docker run -d \
    --name grafana-central \
    --restart always \
    -p "${PORT}:3000" \
    -e "GF_SECURITY_ADMIN_PASSWORD=${PASS}" \
    -e "GF_USERS_ALLOW_SIGN_UP=false" \
    -v grafana-central-data:/var/lib/grafana \
    -v /etc/grafana/provisioning/datasources:/etc/grafana/provisioning/datasources \
    grafana/grafana:10.4.0

echo "GRAFANA_REMOTE_OK"
REMOTE

    log_section "🎉 ¡Servidor Dedicado de Monitoreo (Grafana Central) Instalado!"
    printf "  %-30s %s\n" "URL de Grafana Central:" "http://${target_ip}:${grafana_port}"
    printf "  %-30s %s\n" "Usuario Admin:" "admin"
    printf "  %-30s %s\n" "Password Admin:" "${admin_password}"
    printf "  %-30s %s\n" "Data Source Prometheus:" "${k8s_prometheus_url}"
    printf "  %-30s %s\n\n" "Data Source Loki:" "${k8s_loki_url}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    deploy_remote_grafana_server "$@"
fi
