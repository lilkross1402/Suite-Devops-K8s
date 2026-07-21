#!/usr/bin/env bash
# =============================================================================
# KubeOps-Suite :: stack/deploy_longhorn.sh
# Purpose : Deploy Longhorn Persistent Distributed Storage for Kubernetes.
# Author  : KubeOps-Suite (Principal Platform Engineer)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${SUITE_ROOT:-}" ]]; then
    SUITE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
fi

# Guard against multiple sourcing
if [[ -n "${_LONGHORN_SH_LOADED:-}" ]]; then
    return 0
fi
_LONGHORN_SH_LOADED=true

# shellcheck disable=SC1090
source "${SUITE_ROOT}/lib/logger.sh"
# shellcheck disable=SC1090
source "${SUITE_ROOT}/lib/state_manager.sh"

deploy_longhorn() {
    log_banner
    log_section "Despliegue de Longhorn (Almacenamiento Persistente Distribuido)"

    if ! command -v kubectl &>/dev/null; then
        log_error "kubectl no está instalado o disponible en PATH."
        return 1
    fi

    local longhorn_ver="v1.6.1"
    log_info "Aplicando manifiesto oficial de Longhorn ${longhorn_ver} (namespace: longhorn-system)..."

    if kubectl apply -f "https://raw.githubusercontent.com/longhorn/longhorn/${longhorn_ver}/deploy/longhorn.yaml"; then
        log_success "Manifiesto de Longhorn aplicado exitosamente."
    else
        log_error "No se pudo aplicar el manifiesto de Longhorn."
        return 1
    fi

    state_set ".stack.longhorn.installed" "true"
    state_set ".stack.longhorn.version" "${longhorn_ver}"

    log_success "¡Longhorn ${longhorn_ver} desplegado exitosamente!"
    printf "  ${CLR_BOLD_WHITE}Acceso a UI de Longhorn Storage Manager:${CLR_RESET}\n"
    printf "  ${CLR_BOLD_CYAN}kubectl port-forward svc/longhorn-frontend -n longhorn-system 8000:80${CLR_RESET}\n\n"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    deploy_longhorn "$@"
fi
