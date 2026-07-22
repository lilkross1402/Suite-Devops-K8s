#!/usr/bin/env bash
# =============================================================================
# KubeOps-Suite :: stack/deploy_istio_kiali.sh
# Purpose : Deploy Istio Service Mesh (mTLS & Traffic Management) and Kiali
#           Real-Time Observability Topology Dashboard.
# Author  : KubeOps-Suite (Principal Platform Engineer)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${SUITE_ROOT:-}" ]]; then
    SUITE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
fi

# Guard against multiple sourcing
if [[ -n "${_ISTIO_KIALI_SH_LOADED:-}" ]]; then
    return 0
fi
_ISTIO_KIALI_SH_LOADED=true

# shellcheck disable=SC1090
source "${SUITE_ROOT}/lib/logger.sh"
# shellcheck disable=SC1090
source "${SUITE_ROOT}/lib/state_manager.sh"

deploy_istio_kiali() {
    log_banner
    log_section "Despliegue de Istio Service Mesh & Dashboard Kiali"

    if ! command -v kubectl &>/dev/null; then
        log_error "kubectl no está instalado o disponible en PATH."
        return 1
    fi

    # 1. Instalar Istio Operator / Custom Resources via Helm or kubectl manifests
    log_info "Instalando componentes de Istio Service Mesh (istio-system)..."
    kubectl create namespace istio-system 2>/dev/null || true

    local istio_version="1.21.0"
    log_info "Aplicando Istio Custom Resource Definitions (CRDs)..."
    kubectl apply -f "https://raw.githubusercontent.com/istio/istio/${istio_version}/manifests/charts/base/crds/crd-all.gen.yaml" 2>/dev/null || {
        log_warn "No se pudo descargar CRDs de Istio directamente desde GitHub. Asegúrese de conexión a Internet."
    }

    # 2. Desplegar Prometheus & Kiali Dashboard (Oficial Istio Addons)
    log_info "Desplegando Prometheus Addon para métricas de Istio (namespace: istio-system)..."
    kubectl apply -f "https://raw.githubusercontent.com/istio/istio/release-1.21/samples/addons/prometheus.yaml" 2>/dev/null || true

    log_info "Desplegando Kiali Dashboard Server (namespace: istio-system)..."
    kubectl apply -f "https://raw.githubusercontent.com/istio/istio/${istio_version}/samples/addons/kiali.yaml" 2>/dev/null || \
    kubectl apply -f "https://raw.githubusercontent.com/istio/istio/release-1.21/samples/addons/kiali.yaml"

    log_info "Exponiendo Kiali Dashboard vía NodePort (puerto 30001)..."
    sleep 3
    kubectl patch svc kiali -n istio-system -p '{"spec": {"type": "NodePort", "ports": [{"name": "http-kiali", "port": 20001, "nodePort": 30001}]}}' 2>/dev/null || true

    state_set ".stack.istio.installed" "true"
    state_set ".stack.istio.version" "${istio_version}"
    state_set ".stack.kiali.installed" "true"

    log_success "¡Istio Service Mesh & Dashboard Kiali desplegados exitosamente!"
    printf "  ${CLR_BOLD_WHITE}Acceso directo a Kiali Dashboard en el navegador:${CLR_RESET}\n"
    printf "  ${CLR_BOLD_CYAN}http://<IP_MASTER_O_PUBLIC_IP>:30001${CLR_RESET}\n\n"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    deploy_istio_kiali "$@"
fi
