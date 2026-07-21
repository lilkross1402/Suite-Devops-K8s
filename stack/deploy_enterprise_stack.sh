#!/usr/bin/env bash
# =============================================================================
# KubeOps-Suite :: stack/deploy_enterprise_stack.sh
# Purpose : Interactive launcher & installer for Enterprise Platform Extensions:
#           CLI Tools (Stern, K9s), Cert-Manager, Istio, Kiali, and Longhorn.
# Author  : KubeOps-Suite (Principal Platform Engineer)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${SUITE_ROOT:-}" ]]; then
    SUITE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
fi

# Guard against multiple sourcing
if [[ -n "${_ENTERPRISE_STACK_SH_LOADED:-}" ]]; then
    return 0
fi
_ENTERPRISE_STACK_SH_LOADED=true

# shellcheck disable=SC1090
source "${SUITE_ROOT}/lib/logger.sh"
# shellcheck disable=SC1090
source "${SUITE_ROOT}/stack/deploy_certmanager.sh"
# shellcheck disable=SC1090
source "${SUITE_ROOT}/stack/deploy_istio_kiali.sh"
# shellcheck disable=SC1090
source "${SUITE_ROOT}/stack/deploy_longhorn.sh"
# shellcheck disable=SC1090
source "${SUITE_ROOT}/utils/install_cli_tools.sh"

deploy_all_enterprise_stack() {
    log_banner
    log_section "Despliegue del STACK ENTERPRISE COMPLETO (Todas las Herramientas)"

    log_info "[1/4] Instalando Herramientas CLI (Stern + K9s + Kubectl-neat)..."
    install_cli_tools || true

    log_info "[2/4] Desplegando Cert-Manager (Automatización SSL/TLS)..."
    deploy_certmanager || true

    log_info "[3/4] Desplegando Istio Service Mesh & Kiali Dashboard..."
    deploy_istio_kiali || true

    log_info "[4/4] Desplegando Longhorn (Almacenamiento Persistente Distribuido)..."
    deploy_longhorn || true

    log_success "¡STACK ENTERPRISE COMPLETO DESPLEGADO EXITOSAMENTE!"
}

show_enterprise_menu() {
    while true; do
        log_banner
        log_section "🚀  CATÁLOGO DE EXTENSIONES ENTERPRISE DE PLATAFORMA"

        printf "  %-5s %-4s %-32s %s\n" "[1]" "🛠️ " "Herramientas CLI (Stern, K9s, Neat)" "Stern, K9s y Kubectl-neat"
        printf "  %-5s %-4s %-32s %s\n" "[2]" "🔒" "Cert-Manager (SSL/TLS Automation)" "Automatización de certificados SSL/TLS"
        printf "  %-5s %-4s %-32s %s\n" "[3]" "🕸️ " "Istio Service Mesh & Kiali" "Malla de servicios mTLS y mapa topológico"
        printf "  %-5s %-4s %-32s %s\n" "[4]" "💾" "Longhorn (Storage Distribuido)" "Almacenamiento de bloques persistente"
        printf "  %-5s %-4s %-32s %s\n" "[A]" "⚡" "INSTALAR STACK ENTERPRISE COMPLETO" "Instalar todas las herramientas de una sola vez"
        printf "  %-5s %-4s %-32s %s\n" "[Q]" "🚪" "Volver al Menú Principal" "Retornar al menú principal de KubeOps"

        printf "\n  ${CLR_BOLD_WHITE}Seleccione una opción${CLR_RESET} › "
        read -r choice

        case "${choice}" in
            1) clear; install_cli_tools; pause ;;
            2) clear; deploy_certmanager; pause ;;
            3) clear; deploy_istio_kiali; pause ;;
            4) clear; deploy_longhorn; pause ;;
            [aA]) clear; deploy_all_enterprise_stack; pause ;;
            [qQ]) break ;;
            *) printf "\n  Opción inválida: '%s'\n" "${choice}"; sleep 1 ;;
        esac
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    show_enterprise_menu "$@"
fi
