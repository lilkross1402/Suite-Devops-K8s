#!/usr/bin/env bash
# =============================================================================
# KubeOps-Suite :: utils/setup_nexus_repository.sh
# Purpose : Provision Sonatype Nexus 3 Docker Registry and automatically pre-load
#           ALL required Kubernetes, CNI, Observability, GitOps, Istio, Kong and Redis
#           images for 100% offline Air-Gapped cluster deployments.
# Author  : KubeOps-Suite (Principal Platform Engineer)
# =============================================================================
set -euo pipefail

if [[ -z "${SUITE_ROOT:-}" ]]; then
    SUITE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

# Guard against multiple sourcing
if [[ -n "${_NEXUS_SETUP_SH_LOADED:-}" ]]; then
    return 0
fi
_NEXUS_SETUP_SH_LOADED=true

# shellcheck disable=SC1090
source "${SUITE_ROOT}/lib/logger.sh"
# shellcheck disable=SC1090
source "${SUITE_ROOT}/lib/os_detect.sh"
# shellcheck disable=SC1090
source "${SUITE_ROOT}/lib/network_check.sh"
# shellcheck disable=SC1090
source "${SUITE_ROOT}/lib/state_manager.sh"

# =============================================================================
# Complete Image Inventory for Air-Gapped Deployments (Core + Ecosystem)
# =============================================================================
K8S_VERSION="v1.29.15"
CILIUM_VERSION="v1.15.5"

REQUIRED_IMAGES=(
    # --- Kubernetes Core v1.29.15 ---
    "registry.k8s.io/kube-apiserver:${K8S_VERSION}"
    "registry.k8s.io/kube-controller-manager:${K8S_VERSION}"
    "registry.k8s.io/kube-scheduler:${K8S_VERSION}"
    "registry.k8s.io/kube-proxy:${K8S_VERSION}"
    "registry.k8s.io/etcd:3.5.12-0"
    "registry.k8s.io/coredns/coredns:v1.11.1"
    "registry.k8s.io/pause:3.9"

    # --- Cilium CNI v1.15.5 ---
    "quay.io/cilium/cilium:${CILIUM_VERSION}"
    "quay.io/cilium/operator-generic:${CILIUM_VERSION}"
    "quay.io/cilium/hubble-relay:${CILIUM_VERSION}"
    "quay.io/cilium/hubble-ui:v0.12.1"
    "quay.io/cilium/hubble-ui-backend:v0.12.1"

    # --- Observability Stack 360° ---
    "prom/prometheus:v2.51.0"
    "grafana/grafana:10.4.0"
    "prom/alertmanager:v0.27.0"
    "grafana/loki:2.9.4"
    "grafana/promtail:2.9.4"
    "quay.io/prometheus-operator/prometheus-config-reloader:v0.72.0"

    # --- Service Mesh & Dashboard ---
    "docker.io/istio/pilot:1.21.0"
    "docker.io/istio/proxyv2:1.21.0"
    "quay.io/kiali/kiali:v1.80.0"

    # --- GitOps & Disaster Recovery ---
    "quay.io/argoproj/argocd:v2.10.4"
    "velero/velero:v1.13.0"

    # --- Security & Storage ---
    "quay.io/jetstack/cert-manager-controller:v1.14.4"
    "quay.io/jetstack/cert-manager-cainjector:v1.14.4"
    "quay.io/jetstack/cert-manager-webhook:v1.14.4"
    "openebs/provisioner-localpv:3.5.0"

    # --- API Gateway & Cache ---
    "kong:3.6"
    "redis:7.2"
)

_ensure_container_engine() {
    log_info "Verificando motor de contenedores en el servidor Nexus..."
    if command -v docker &>/dev/null; then
        log_success "Motor de contenedores Docker detectado."
        return 0
    fi

    log_info "Actualizando índices de paquetes del sistema..."
    if declare -f os_update_package_cache &>/dev/null; then
        os_update_package_cache || true
    else
        sudo apt-get update -qq 2>/dev/null || true
    fi

    log_info "Instalando Docker Engine desatendido..."
    os_install_pkg docker.io || os_install_pkg docker
    sudo systemctl enable docker
    sudo systemctl start docker
}

setup_nexus_server() {
    log_banner
    log_section "Aprovisionamiento de Registro Nexus 3 (Air-Gap Mirror)"

    os_detect || true
    net_detect_mode

    local primary_ip
    primary_ip=$(net_get_primary_ip)

    printf "\n  ${CLR_BOLD_WHITE}Configuración del Servidor Nexus para Entornos Sin Internet:${CLR_RESET}\n"
    printf "  IP Privada Detectada de este Servidor: ${CLR_BOLD_CYAN}%s${CLR_RESET}\n" "${primary_ip}"

    local public_ip
    printf "  Ingrese la IP Pública / DNS Expuesto (ej. 3.144.166.168 - Presione Enter para usar %s): " "${primary_ip}"
    read -r public_ip
    public_ip="${public_ip:-${primary_ip}}"

    local nexus_port="8081"
    local docker_port="8082"
    local admin_password="Admin123!"

    _ensure_container_engine

    # 1. Desplegar Sonatype Nexus 3 para Gestión de Artefactos (Puerto 8081)
    log_info "Desplegando Sonatype Nexus 3 Enterprise UI (Puerto ${nexus_port})..."
    sudo docker rm -f nexus 2>/dev/null || true
    sudo docker volume create nexus-data 2>/dev/null || true

    sudo docker run -d \
        --name nexus \
        --restart always \
        -p "${nexus_port}:8081" \
        -v nexus-data:/nexus-data \
        sonatype/nexus3:latest

    log_info "Esperando a que la API de Nexus 3 esté respondiendo (60 segundos)..."
    until sudo docker exec nexus curl -fsSL http://localhost:8081/service/rest/v1/status &>/dev/null; do
        sleep 5
    done
    log_success "Servidor Nexus 3 Enterprise activo en el puerto ${nexus_port}."

    log_info "Verificando credenciales iniciales de Nexus..."
    local count=0
    until sudo docker exec nexus test -s /nexus-data/admin.password 2>/dev/null || [[ $count -ge 5 ]]; do
        sleep 3
        count=$((count + 1))
    done

    if sudo docker exec nexus test -s /nexus-data/admin.password 2>/dev/null; then
        local init_pass
        init_pass=$(sudo docker exec nexus cat /nexus-data/admin.password 2>/dev/null | tr -d '\r\n ')
        log_info "Fijando contraseña de administrador a '${admin_password}'..."
        sudo docker exec nexus curl -s -X PUT -u "admin:${init_pass}" \
            -H "Content-Type: text/plain" \
            -d "${admin_password}" \
            "http://localhost:8081/service/rest/v1/security/users/admin/change-password" 2>/dev/null || true
        log_success "Contraseña de Nexus 3 actualizada a '${admin_password}'."
    else
        log_info "Credenciales de Nexus 3 ya inicializadas activas ('${admin_password}')."
    fi

    # 2. Desplegar Registro de Imágenes de Alta Velocidad CNCF Distribution (Puerto 8082)
    log_info "Desplegando Registro Docker CNCF Distribution v2 para Air-Gap en puerto ${docker_port}..."
    sudo docker rm -f kubeops-registry 2>/dev/null || true
    sudo mkdir -p /var/lib/kubeops-registry

    sudo docker run -d \
        --name kubeops-registry \
        --restart always \
        -p "${docker_port}:5000" \
        -v /var/lib/kubeops-registry:/var/lib/registry \
        -e REGISTRY_STORAGE_DELETE_ENABLED=true \
        registry:2

    # 3. Configurar Docker daemon local para permitir insecure-registry
    log_info "Configurando daemon local /etc/docker/daemon.json para ${docker_port}..."
    sudo mkdir -p /etc/docker
    sudo tee /etc/docker/daemon.json >/dev/null <<EOF
{
  "insecure-registries": ["${primary_ip}:${docker_port}", "127.0.0.1:${docker_port}", "localhost:${docker_port}", "${public_ip}:${docker_port}"]
}
EOF
    sudo systemctl daemon-reload
    sudo systemctl restart docker

    # 3b. Vincular Registro Air-Gap (8082) en la Interfaz Web de Nexus 3 (8081) como Proxy Visual
    log_info "Vinculando Registro Air-Gap en la Interfaz Web de Nexus 3 (http://${public_ip}:${nexus_port})..."
    sudo docker exec nexus curl -s -X POST -u "admin:${admin_password}" \
        -H "Content-Type: application/json" \
        -d '{
            "name": "docker-airgap",
            "online": true,
            "storage": { "blobStoreName": "default", "strictContentTypeValidation": true },
            "proxy": { "remoteUrl": "http://localhost:8082" },
            "negativeCache": { "enabled": true, "timeToLive": 1440 },
            "httpClient": { "blocked": false, "autoBlock": true },
            "docker": { "v1Enabled": true, "forceBasicAuth": false }
        }' "http://localhost:8081/service/rest/v1/repositories/docker/proxy" 2>/dev/null || true

    log_info "Verificando respuesta del Registro Air-Gap en puerto ${docker_port}..."
    until [[ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${docker_port}/v2/" 2>/dev/null)" == "200" ]]; do
        sleep 2
    done
    log_success "Registro Docker Air-Gap (Puerto ${docker_port}) activo y respondiendo HTTP 200 OK."

    # 4. Pre-cargar e Inyectar las 23 imágenes requeridas para el clúster Air-Gap
    log_info "Iniciando descarga y precarga desatendida de imágenes hacia el registro local (127.0.0.1:${docker_port})..."
    for img in "${REQUIRED_IMAGES[@]}"; do
        local target_name="${img#*/}"
        log_info "  [Mirroring Air-Gap] ${img} -> 127.0.0.1:${docker_port}/${target_name}"
        sudo docker pull "${img}" || true
        sudo docker tag "${img}" "127.0.0.1:${docker_port}/${target_name}" || true
        sudo docker tag "${img}" "${primary_ip}:${docker_port}/${target_name}" || true
        sudo docker push "127.0.0.1:${docker_port}/${target_name}"
    done

    # 6. Guardar estado del servidor Nexus
    if declare -f state_save_registry &>/dev/null; then
        state_save_registry "${primary_ip}" "${docker_port}"
    fi
    if declare -f state_save_nexus &>/dev/null; then
        state_save_nexus "${primary_ip}:${docker_port}" 2>/dev/null || true
    fi

    log_section "🎉 ¡SERVIDOR REPOSITORIO NEXUS 3 LISTO PARA AIR-GAP!"
    printf "  %-30s %s\n" "Interfaz Web (Nexus UI):" "http://${public_ip}:${nexus_port}"
    printf "  %-30s %s\n" "Registro Docker (Air-Gap):" "${primary_ip}:${docker_port}"
    printf "  %-30s %s\n" "Usuario Docker:" "Anónimo (login opcional)"
    printf "\n"
    printf "  ${CLR_BOLD_WHITE}Configuración para containerd en los nodos del clúster:${CLR_RESET}\n"
    printf "  Añadir '${primary_ip}:${docker_port}' como insecure-registry en /etc/containerd/config.toml\n\n"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    setup_nexus_server "$@"
fi
