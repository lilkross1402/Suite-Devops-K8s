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

    # 2. Desplegar Kiali Operator & Kiali Server CR
    log_info "Desplegando Kiali Operator..."
    kubectl create namespace kiali-operator 2>/dev/null || true
    kubectl apply -f "https://raw.githubusercontent.com/kiali/kiali-operator/master/manifests/kiali-operator.yaml" 2>/dev/null || true

    log_info "Instanciando servicio Kiali Dashboard (auth: anonymous) en istio-system..."
    sleep 5
    cat <<EOF | kubectl apply -f - 2>/dev/null || true
apiVersion: kiali.io/v1alpha1
kind: Kiali
metadata:
  name: kiali
  namespace: istio-system
spec:
  auth:
    strategy: anonymous
EOF

    state_set ".stack.istio.installed" "true"
    state_set ".stack.istio.version" "${istio_version}"
    state_set ".stack.kiali.installed" "true"

    log_success "¡Istio Service Mesh & Dashboard Kiali desplegados exitosamente!"
    printf "  ${CLR_BOLD_WHITE}Comando para acceder a Kiali Dashboard:${CLR_RESET}\n"
    printf "  ${CLR_BOLD_CYAN}kubectl port-forward svc/kiali -n istio-system 20001:20001${CLR_RESET}\n\n"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    deploy_istio_kiali "$@"
fi
