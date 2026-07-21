#!/usr/bin/env bash
# =============================================================================
# KubeOps-Suite :: utils/setup_nexus_repository.sh
# Purpose : Provision Sonatype Nexus 3 Docker Registry and automatically pre-load
#           ALL required Kubernetes, CNI, Observability, Kong and Redis images
#           for 100% offline Air-Gapped cluster deployments.
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
# Complete Image Inventory for Air-Gapped Deployments
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

    # --- Observability Stack ---
    "prom/prometheus:v2.51.0"
    "grafana/grafana:10.4.0"
    "prom/alertmanager:v0.27.0"

    # --- API Gateway & Cache ---
    "kong:3.6"
    "redis:7.2"
)

# Function to check or install container tool (docker or nerdctl/crictl)
_ensure_container_engine() {
    log_info "Verificando motor de contenedores en el servidor Nexus..."
    if command -v docker &>/dev/null; then
        log_success "Motor de contenedores Docker detectado."
        return 0
    fi

    log_info "Actualizando índices de paquetes del sistema..."
    os_update_pkg || true

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
    printf "  IP Detectada de este Servidor: ${CLR_BOLD_CYAN}%s${CLR_RESET}\n" "${primary_ip}"

    local nexus_port="8081"
    local docker_port="8082"

    _ensure_container_engine

    # 1. Desplegar contenedor Sonatype Nexus 3
    log_info "Iniciando Sonatype Nexus Repository Manager 3..."
    if sudo docker ps -a --format '{{.Names}}' | grep -q "^nexus$"; then
        log_info "El contenedor 'nexus' ya existe. Asegurando ejecución..."
        sudo docker start nexus 2>/dev/null || true
    else
        sudo docker run -d \
            --name nexus \
            --restart always \
            -p "${nexus_port}:8081" \
            -p "${docker_port}:${docker_port}" \
            -v nexus-data:/nexus-data \
            sonatype/nexus3:latest
        log_success "Contenedor Nexus 3 iniciado en puertos http://${primary_ip}:${nexus_port} y registro:${docker_port}"
    fi

    # 2. Esperar arranque de Nexus
    log_info "Esperando inicialización de Nexus (esto puede tomar 30-60 segundos)..."
    local attempt=0
    local max_attempts=30
    while [[ ${attempt} -lt ${max_attempts} ]]; do
        if sudo docker exec nexus test -f /nexus-data/admin.password 2>/dev/null; then
            break
        fi
        sleep 3
        attempt=$((attempt + 1))
    done

    local admin_pass="admin"
    if sudo docker exec nexus test -f /nexus-data/admin.password 2>/dev/null; then
        admin_pass=$(sudo docker exec nexus cat /nexus-data/admin.password 2>/dev/null || echo "admin")
    fi

    log_success "Nexus 3 listo. Contraseña inicial de admin: ${CLR_BOLD_YELLOW}${admin_pass}${CLR_RESET}"

    # 3. Configurar Insecure Registry en Docker local para Push
    log_info "Configurando daemon de Docker local para permitir http://${primary_ip}:${docker_port}..."
    sudo mkdir -p /etc/docker
    local daemon_json="/etc/docker/daemon.json"
    if [[ ! -f "${daemon_json}" ]]; then
        echo "{\"insecure-registries\": [\"${primary_ip}:${docker_port}\", \"localhost:${docker_port}\"]}" | sudo tee "${daemon_json}" > /dev/null
    else
        if ! grep -q "${docker_port}" "${daemon_json}"; then
            echo "{\"insecure-registries\": [\"${primary_ip}:${docker_port}\", \"localhost:${docker_port}\"]}" | sudo tee "${daemon_json}" > /dev/null
        fi
    fi
    sudo systemctl reload docker 2>/dev/null || sudo systemctl restart docker 2>/dev/null || true

    # 4. Descargar y Subir (Mirroring) todas las imágenes
    log_section "Descarga y Mirroring de Imágenes (Online → Nexus)"

    if ! net_is_online; then
        log_warn "El servidor Nexus no tiene acceso a Internet actualmente."
        log_warn "Asegúrese de ejecutar este script cuando tenga conexión para poblar el repositorio."
    else
        log_info "Descargando e inyectando ${#REQUIRED_IMAGES[@]} imágenes requeridas..."
        local target_registry="${primary_ip}:${docker_port}"

        for img in "${REQUIRED_IMAGES[@]}"; do
            log_info "Procesando imagen: ${img}..."
            if sudo docker pull "${img}"; then
                # Strip prefix for local repo tagging (e.g. registry.k8s.io/kube-apiserver:v1.29.15 -> target/kube-apiserver:v1.29.15)
                local img_name
                img_name=$(echo "${img}" | sed -E 's|^[^/]+/||')
                local tagged_img="${target_registry}/${img_name}"

                sudo docker tag "${img}" "${tagged_img}"
                log_info "Pushing ${tagged_img} a Nexus..."
                sudo docker push "${tagged_img}" 2>/dev/null || {
                    log_warn "Push desatendido falló. Permita acceso anónimo o inicie sesión con 'docker login ${target_registry}'."
                }
            else
                log_error "Falló la descarga de ${img}."
            fi
        done
        log_success "¡Mirroring de imágenes completado!"
    fi

    # 5. Guardar estado del Registro en KubeOps-Suite
    local registry_url="${primary_ip}:${docker_port}"
    state_set ".registry.url" "${registry_url}"
    state_set ".registry.type" "nexus"
    state_set ".registry.mode" "mirror"

    printf "\n"
    log_section "📋 Instrucciones para Despliegue Air-Gapped (Sin Internet)"
    printf "  ${CLR_BOLD_GREEN}Servidor Nexus Aprovisionado Exitosamente:${CLR_RESET}\n"
    printf "  %-30s %s\n" "Interfaz Web Nexus:" "http://${primary_ip}:${nexus_port}"
    printf "  %-30s %s\n" "Registro Docker Hosted:" "${registry_url}"
    printf "  %-30s %s\n" "Usuario predeterminado:" "admin"
    printf "  %-30s %s\n" "Contraseña inicial:" "${admin_pass}"
    printf "\n"
    printf "  ${CLR_BOLD_WHITE}Cómo usar en los Másters y Workers desconectados:${CLR_RESET}\n"
    printf "  En KubeOps-Suite (Opción 3/4/5), seleccione Modo ${CLR_BOLD_YELLOW}AIR-GAPPED${CLR_RESET} e ingrese:\n"
    printf "  ${CLR_BOLD_CYAN}%s${CLR_RESET}\n\n" "${registry_url}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    setup_nexus_server "$@"
fi
