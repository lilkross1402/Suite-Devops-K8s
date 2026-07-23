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
    # --- Kubernetes Core Multi-Version (v1.27, v1.28, v1.29, v1.30, v1.31) ---
    "registry.k8s.io/kube-apiserver:v1.27.12"
    "registry.k8s.io/kube-apiserver:v1.28.8"
    "registry.k8s.io/kube-apiserver:v1.28.15"
    "registry.k8s.io/kube-apiserver:v1.29.3"
    "registry.k8s.io/kube-apiserver:${K8S_VERSION}"
    "registry.k8s.io/kube-apiserver:v1.30.2"
    "registry.k8s.io/kube-apiserver:v1.30.10"
    "registry.k8s.io/kube-apiserver:v1.31.1"

    "registry.k8s.io/kube-controller-manager:v1.28.15"
    "registry.k8s.io/kube-controller-manager:${K8S_VERSION}"
    "registry.k8s.io/kube-controller-manager:v1.30.10"

    "registry.k8s.io/kube-scheduler:v1.28.15"
    "registry.k8s.io/kube-scheduler:${K8S_VERSION}"
    "registry.k8s.io/kube-scheduler:v1.30.10"

    "registry.k8s.io/kube-proxy:v1.28.15"
    "registry.k8s.io/kube-proxy:${K8S_VERSION}"
    "registry.k8s.io/kube-proxy:v1.30.10"

    "registry.k8s.io/etcd:3.5.9-0"
    "registry.k8s.io/etcd:3.5.10-0"
    "registry.k8s.io/etcd:3.5.12-0"
    "registry.k8s.io/etcd:3.5.14-0"

    "registry.k8s.io/coredns/coredns:v1.10.1"
    "registry.k8s.io/coredns/coredns:v1.11.1"
    "registry.k8s.io/coredns/coredns:v1.11.3"

    "registry.k8s.io/pause:3.8"
    "registry.k8s.io/pause:3.9"
    "registry.k8s.io/pause:3.10"

    # --- Cilium CNI Multi-Version ---
    "quay.io/cilium/cilium:v1.13.14"
    "quay.io/cilium/cilium:v1.14.9"
    "quay.io/cilium/cilium:${CILIUM_VERSION}"
    "quay.io/cilium/cilium:v1.16.0"
    "quay.io/cilium/operator-generic:${CILIUM_VERSION}"
    "quay.io/cilium/hubble-relay:${CILIUM_VERSION}"
    "quay.io/cilium/hubble-ui:v0.12.1"
    "quay.io/cilium/hubble-ui-backend:v0.12.1"

    # --- Observability Stack Multi-Version ---
    "prom/prometheus:v2.48.0"
    "prom/prometheus:v2.49.0"
    "prom/prometheus:v2.50.0"
    "prom/prometheus:v2.51.0"
    "prom/prometheus:v2.52.0"

    "grafana/grafana:10.2.0"
    "grafana/grafana:10.3.0"
    "grafana/grafana:10.4.0"
    "grafana/grafana:10.4.5"
    "grafana/grafana:11.0.0"

    "prom/alertmanager:v0.27.0"
    "grafana/loki:2.8.6"
    "grafana/loki:2.9.0"
    "grafana/loki:2.9.4"
    "grafana/loki:3.0.0"

    "grafana/promtail:2.8.6"
    "grafana/promtail:2.9.0"
    "grafana/promtail:2.9.4"
    "grafana/promtail:3.0.0"

    "quay.io/prometheus-operator/prometheus-config-reloader:v0.72.0"

    # --- Service Mesh Multi-Version ---
    "docker.io/istio/pilot:1.19.4"
    "docker.io/istio/pilot:1.20.3"
    "docker.io/istio/pilot:1.21.0"
    "docker.io/istio/pilot:1.22.0"

    "docker.io/istio/proxyv2:1.19.4"
    "docker.io/istio/proxyv2:1.20.3"
    "docker.io/istio/proxyv2:1.21.0"
    "docker.io/istio/proxyv2:1.22.0"

    "quay.io/kiali/kiali:v1.80.0"

    # --- GitOps & Disaster Recovery Multi-Version ---
    "quay.io/argoproj/argocd:v2.8.4"
    "quay.io/argoproj/argocd:v2.9.6"
    "quay.io/argoproj/argocd:v2.10.4"
    "quay.io/argoproj/argocd:v2.11.2"

    "velero/velero:v1.11.0"
    "velero/velero:v1.12.2"
    "velero/velero:v1.13.0"

    # --- Security & Storage Multi-Version ---
    "quay.io/jetstack/cert-manager-controller:v1.12.0"
    "quay.io/jetstack/cert-manager-controller:v1.13.3"
    "quay.io/jetstack/cert-manager-controller:v1.14.4"
    "quay.io/jetstack/cert-manager-controller:v1.15.0"
    "quay.io/jetstack/cert-manager-cainjector:v1.14.4"
    "quay.io/jetstack/cert-manager-webhook:v1.14.4"

    "rancher/local-path-provisioner:v0.0.26"
    "openebs/provisioner-localpv:3.5.0"
    "busybox:latest"

    # --- Fallback CNI Plugins ---
    "docker.io/calico/cni:v3.27.0"
    "docker.io/calico/node:v3.27.0"
    "docker.io/calico/kube-controllers:v3.27.0"
    "flannel/flannel:v0.24.2"

    # --- High Availability Load Balancers ---
    "haproxy:2.8"
    "osixia/keepalived:2.0.20"

    # --- API Gateway & Cache Multi-Version ---
    "kong:3.4"
    "kong:3.5"
    "kong:3.6"
    "kong:3.7"

    "redis:7.0"
    "redis:7.2"
    "redis:7.4"
)

_ensure_container_engine() {
    log_info "Verificando motor de contenedores en el servidor Nexus..."
    if ! command -v docker &>/dev/null; then
        log_info "Instalando Docker Engine desatendido..."
        os_install_pkg docker.io || os_install_pkg docker || sudo apt-get install -y docker.io 2>/dev/null || true
    fi

    log_info "Asegurando servicio Docker activo..."
    sudo systemctl enable docker 2>/dev/null || true
    sudo systemctl start docker 2>/dev/null || true

    if ! sudo docker info &>/dev/null; then
        log_warn "Docker daemon inactivo — reiniciando servicio docker.service..."
        sudo systemctl restart docker 2>/dev/null || true
        sleep 3
    fi
    log_success "Motor de contenedores Docker activo y respondiendo."
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

    # 1. Desplegar Sonatype Nexus 3 para Gestión de Artefactos (Puertos 8081 UI + 8082 Docker)
    log_info "Desplegando Sonatype Nexus 3 Enterprise UI (Puerto ${nexus_port}) y Docker Connector (Puerto ${docker_port})..."
    sudo docker rm -f nexus kubeops-registry 2>/dev/null || true
    sudo fuser -k 8081/tcp 8082/tcp 2>/dev/null || true
    sudo docker volume create nexus-data 2>/dev/null || true

    sudo docker run -d \
        --name nexus \
        --restart always \
        -p "${nexus_port}:8081" \
        -p "${docker_port}:8082" \
        -v nexus-data:/nexus-data \
        sonatype/nexus3:latest

    log_info "Esperando a que la API de Nexus 3 esté respondiendo (esto toma 60-90 segundos)..."
    until sudo docker exec nexus curl -fsSL http://localhost:8081/service/rest/v1/status &>/dev/null; do
        sleep 5
    done
    log_success "Servidor Nexus 3 Enterprise activo en el puerto ${nexus_port}."

    log_info "Verificando credenciales iniciales de Nexus..."
    local count=0
    until sudo docker exec nexus test -s /nexus-data/admin.password 2>/dev/null || [[ $count -ge 10 ]]; do
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

    # 2. Habilitar Realms de Seguridad para Docker en Nexus
    log_info "Habilitando Realm 'Docker Bearer Token' y Acceso Anónimo en Nexus 3..."
    sudo docker exec nexus curl -s -X PUT -u "admin:${admin_password}" \
        -H "Content-Type: application/json" \
        -d '["NexusAuthenticatingRealm", "NexusAuthorizingRealm", "DockerToken"]' \
        "http://localhost:8081/service/rest/v1/security/realms/active" 2>/dev/null || true

    sudo docker exec nexus curl -s -X PUT -u "admin:${admin_password}" \
        -H "Content-Type: application/json" \
        -d '{"enabled": true, "anonymousRole": "nx-anonymous"}' \
        "http://localhost:8081/service/rest/v1/security/anonymous" 2>/dev/null || true

    # 3. Crear Repositorio Nativo 'docker-hosted' en Nexus en puerto 8082
    log_info "Creando Repositorio 'docker-hosted' en Nexus 3 (Puerto HTTP ${docker_port})..."
    sudo docker exec nexus curl -s -X POST -u "admin:${admin_password}" \
        -H "Content-Type: application/json" \
        -d "{
            \"name\": \"docker-hosted\",
            \"online\": true,
            \"storage\": {
                \"blobStoreName\": \"default\",
                \"strictContentTypeValidation\": true,
                \"writePolicy\": \"ALLOW\"
            },
            \"docker\": {
                \"v1Enabled\": false,
                \"forceBasicAuth\": false,
                \"httpPort\": ${docker_port}
            }
        }" "http://localhost:8081/service/rest/v1/repositories/docker/hosted" 2>/dev/null || true

    # 3b. Crear Repositorio Nativo 'raw-hosted' en Nexus para Binarios y Paquetes Air-Gap
    log_info "Creando Repositorio 'raw-hosted' en Nexus 3 para binarios y librerías Air-Gap..."
    sudo docker exec nexus curl -s -X POST -u "admin:${admin_password}" \
        -H "Content-Type: application/json" \
        -d '{
            "name": "raw-hosted",
            "online": true,
            "storage": {
                "blobStoreName": "default",
                "strictContentTypeValidation": true,
                "writePolicy": "ALLOW"
            }
        }' "http://localhost:8081/service/rest/v1/repositories/raw/hosted" 2>/dev/null || true

    # 4. Configurar Docker daemon local para permitir insecure-registry
    log_info "Configurando daemon local /etc/docker/daemon.json para puerto ${docker_port}..."
    sudo mkdir -p /etc/docker
    sudo tee /etc/docker/daemon.json >/dev/null <<EOF
{
  "insecure-registries": ["${primary_ip}:${docker_port}", "127.0.0.1:${docker_port}", "localhost:${docker_port}", "${public_ip}:${docker_port}"]
}
EOF
    sudo systemctl daemon-reload
    sudo systemctl restart docker 2>/dev/null || true
    sleep 4

    log_info "Esperando disponibilidad del conector Docker de Nexus en 127.0.0.1:${docker_port}..."
    local port_ready=0
    for i in $(seq 1 15); do
        if sudo docker login "127.0.0.1:${docker_port}" -u admin -p "${admin_password}" &>/dev/null; then
            port_ready=1
            break
        fi
        sleep 3
    done

    if [[ "${port_ready}" -eq 1 ]]; then
        log_success "Autenticado exitosamente en Nexus 3 Docker Registry (127.0.0.1:${docker_port})."
    else
        log_warn "Conector 8082 aún inicializando — reintentando login directo..."
        sudo docker login "127.0.0.1:${docker_port}" -u admin -p "${admin_password}" || true
    fi

    # 5. Pre-cargar e Inyectar las imágenes requeridas directamente en Nexus 3
    log_info "Cargando e inyectando imágenes en la Consola Web de Nexus 3 (127.0.0.1:${docker_port})..."
    for img in "${REQUIRED_IMAGES[@]}"; do
        local target_name="${img#*/}"
        log_info "  [Inyectando a Nexus 3 UI] ${img} -> 127.0.0.1:${docker_port}/${target_name}"
        sudo docker pull "${img}" || true
        sudo docker tag "${img}" "127.0.0.1:${docker_port}/${target_name}" || true
        sudo docker push "127.0.0.1:${docker_port}/${target_name}"
    done

_ensure_offline_binaries() {
    log_info "Verificando disponibilidad de binarios CLI (kubeadm, kubelet, kubectl, helm, cilium)..."
    mkdir -p "${SUITE_ROOT}/offline-assets"

    local k8s_ver="v1.29.15"
    local helm_ver="v3.14.2"
    local cilium_ver="v0.16.0"

    if net_is_online; then
        log_info "Descargando binarios de Kubernetes y herramientas CLI para almacenamiento offline en Nexus..."

        # kubeadm, kubelet, kubectl
        for bin in kubeadm kubelet kubectl; do
            if [[ ! -f "${SUITE_ROOT}/offline-assets/${bin}" ]]; then
                log_info "  [Download CLI] ${bin} ${k8s_ver}..."
                curl -fsSL "https://dl.k8s.io/release/${k8s_ver}/bin/linux/amd64/${bin}" -o "${SUITE_ROOT}/offline-assets/${bin}" 2>/dev/null || true
                chmod +x "${SUITE_ROOT}/offline-assets/${bin}" 2>/dev/null || true
            fi
        done

        # Helm CLI
        if [[ ! -f "${SUITE_ROOT}/offline-assets/helm" ]]; then
            log_info "  [Download CLI] helm ${helm_ver}..."
            curl -fsSL "https://get.helm.sh/helm-${helm_ver}-linux-amd64.tar.gz" -o "${SUITE_ROOT}/offline-assets/helm.tar.gz" 2>/dev/null || true
            tar -xzf "${SUITE_ROOT}/offline-assets/helm.tar.gz" -C "${SUITE_ROOT}/offline-assets" linux-amd64/helm 2>/dev/null || true
            mv "${SUITE_ROOT}/offline-assets/linux-amd64/helm" "${SUITE_ROOT}/offline-assets/helm" 2>/dev/null || true
            rm -rf "${SUITE_ROOT}/offline-assets/linux-amd64" "${SUITE_ROOT}/offline-assets/helm.tar.gz" 2>/dev/null || true
            chmod +x "${SUITE_ROOT}/offline-assets/helm" 2>/dev/null || true
        fi

        # Cilium CLI
        if [[ ! -f "${SUITE_ROOT}/offline-assets/cilium" ]]; then
            log_info "  [Download CLI] cilium ${cilium_ver}..."
            curl -fsSL "https://github.com/cilium/cilium-cli/releases/download/${cilium_ver}/cilium-linux-amd64.tar.gz" -o "${SUITE_ROOT}/offline-assets/cilium.tar.gz" 2>/dev/null || true
            tar -xzf "${SUITE_ROOT}/offline-assets/cilium.tar.gz" -C "${SUITE_ROOT}/offline-assets" cilium 2>/dev/null || true
            rm -f "${SUITE_ROOT}/offline-assets/cilium.tar.gz" 2>/dev/null || true
            chmod +x "${SUITE_ROOT}/offline-assets/cilium" 2>/dev/null || true
        fi
    fi
}

    # 5b. Subir binarios y librerías Air-Gap (kubeadm, kubelet, kubectl, helm, cilium) a Nexus raw-hosted
    _ensure_offline_binaries
    log_info "Inyectando binarios y librerías Air-Gap en Nexus 3 Raw Hosted Repository (repository/raw-hosted)..."
    if [[ -d "${SUITE_ROOT}/offline-assets" ]]; then
        find "${SUITE_ROOT}/offline-assets" -type f | while read -r asset; do
            local filename
            filename=$(basename "${asset}")
            log_info "  [Publicando a Nexus Raw] ${filename} -> http://localhost:8081/repository/raw-hosted/${filename}"
            sudo docker exec nexus curl -s -u "admin:${admin_password}" --upload-file "${asset}" "http://localhost:8081/repository/raw-hosted/${filename}" 2>/dev/null || true
        done
    fi

    # 6. Guardar estado del servidor Nexus
    if declare -f state_save_registry &>/dev/null; then
        state_save_registry "${primary_ip}" "${docker_port}"
    fi
    if declare -f state_save_nexus &>/dev/null; then
        state_save_nexus "${primary_ip}:${docker_port}" 2>/dev/null || true
    fi

    log_section "🎉 ¡SERVIDOR REPOSITORIO NEXUS 3 Y CONSOLA WEB LISTOS!"
    printf "  %-30s %s\n" "Interfaz Web (Nexus UI):" "http://${public_ip}:${nexus_port} (Browse -> docker-hosted)"
    printf "  %-30s %s\n" "Registro Docker (Air-Gap):" "${primary_ip}:${docker_port}"
    printf "  %-30s %s\n" "Usuario Admin:" "admin"
    printf "  %-30s %s\n" "Password Admin:" "${admin_password}"
    printf "\n"
    printf "  ${CLR_BOLD_WHITE}Configuración para containerd en los nodos del clúster:${CLR_RESET}\n"
    printf "  Añadir '${primary_ip}:${docker_port}' como insecure-registry en /etc/containerd/config.toml\n\n"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    setup_nexus_server "$@"
fi
