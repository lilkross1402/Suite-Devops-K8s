#!/usr/bin/env bash
# =============================================================================
# KubeOps-Suite :: stack/deploy_certmanager.sh
# Purpose : Deploy Cert-Manager for automated TLS/SSL certificate issuance
#           and renewal across Kubernetes workloads.
# Author  : KubeOps-Suite (Principal Platform Engineer)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${SUITE_ROOT:-}" ]]; then
    SUITE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
fi

# Guard against multiple sourcing
if [[ -n "${_CERT_MANAGER_SH_LOADED:-}" ]]; then
    return 0
fi
_CERT_MANAGER_SH_LOADED=true

# shellcheck disable=SC1090
source "${SUITE_ROOT}/lib/logger.sh"
# shellcheck disable=SC1090
source "${SUITE_ROOT}/lib/state_manager.sh"

deploy_certmanager() {
    log_banner
    log_section "Despliegue de Cert-Manager (Automatización de Certificados SSL/TLS)"

    if ! command -v kubectl &>/dev/null; then
        log_error "kubectl no está instalado o disponible en PATH."
        return 1
    fi

    local certmanager_ver="v1.14.4"
    log_info "Aplicando manifiestos oficiales de Cert-Manager ${certmanager_ver}..."

    if kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${certmanager_ver}/cert-manager.yaml"; then
        log_success "Manifiesto de Cert-Manager aplicado exitosamente."
    else
        log_error "No se pudo aplicar el manifiesto de Cert-Manager."
        return 1
    fi

    log_info "Esperando disponibilidad de pods de cert-manager en namespace cert-manager..."
    kubectl rollout status deployment/cert-manager -n cert-manager --timeout=120s 2>/dev/null || true
    kubectl rollout status deployment/cert-manager-webhook -n cert-manager --timeout=120s 2>/dev/null || true

    state_set ".stack.certmanager.installed" "true"
    state_set ".stack.certmanager.version" "${certmanager_ver}"

    log_success "¡Cert-Manager ${certmanager_ver} desplegado y activo exitosamente!"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    deploy_certmanager "$@"
fi
