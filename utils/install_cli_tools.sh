#!/usr/bin/env bash
# =============================================================================
# KubeOps-Suite :: utils/install_cli_tools.sh
# Purpose : Install Operator CLI tools (Stern, K9s, Kubectl-neat) for instant
#           multi-pod logging, terminal UI management, and YAML cleaning.
# Author  : KubeOps-Suite (Principal Platform Engineer)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${SUITE_ROOT:-}" ]]; then
    SUITE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
fi

# Guard against multiple sourcing
if [[ -n "${_CLI_TOOLS_SH_LOADED:-}" ]]; then
    return 0
fi
_CLI_TOOLS_SH_LOADED=true

# shellcheck disable=SC1090
source "${SUITE_ROOT}/lib/logger.sh"
# shellcheck disable=SC1090
source "${SUITE_ROOT}/lib/os_detect.sh"

install_cli_tools() {
    log_banner
    log_section "Instalación de Herramientas CLI para Operadores (Stern, K9s, Kubectl-neat)"

    os_detect || true

    local arch="amd64"
    if [[ "${ARCH:-}" == "aarch64" || "${ARCH:-}" == "arm64" ]]; then
        arch="arm64"
    fi

    # 1. Instalar Stern
    log_info "Instalando Stern (Multi-pod log streaming CLI)..."
    if command -v stern &>/dev/null; then
        log_success "Stern ya está instalado."
    else
        local stern_ver="1.28.0"
        local stern_url="https://github.com/stern/stern/releases/download/v${stern_ver}/stern_${stern_ver}_linux_${arch}.tar.gz"
        log_info "Descargando Stern v${stern_ver}..."
        if curl -sSL -o /tmp/stern.tar.gz "${stern_url}"; then
            sudo tar -xzf /tmp/stern.tar.gz -C /usr/local/bin stern 2>/dev/null || sudo tar -xzf /tmp/stern.tar.gz -C /usr/bin stern 2>/dev/null
            sudo chmod +x /usr/local/bin/stern 2>/dev/null || sudo chmod +x /usr/bin/stern 2>/dev/null || true
            rm -f /tmp/stern.tar.gz
            log_success "Stern instalado exitosamente."
        else
            log_warn "No se pudo descargar Stern automáticamente. Instale binario standalone manualmente."
        fi
    fi

    # 2. Instalar K9s
    log_info "Instalando K9s (Terminal UI interactiva)..."
    if command -v k9s &>/dev/null; then
        log_success "K9s ya está instalado."
    else
        local k9s_ver="v0.32.4"
        local k9s_url="https://github.com/derailed/k9s/releases/download/${k9s_ver}/k9s_Linux_${arch}.tar.gz"
        log_info "Descargando K9s ${k9s_ver}..."
        if curl -sSL -o /tmp/k9s.tar.gz "${k9s_url}"; then
            sudo tar -xzf /tmp/k9s.tar.gz -C /usr/local/bin k9s 2>/dev/null || sudo tar -xzf /tmp/k9s.tar.gz -C /usr/bin k9s 2>/dev/null
            sudo chmod +x /usr/local/bin/k9s 2>/dev/null || sudo chmod +x /usr/bin/k9s 2>/dev/null || true
            rm -f /tmp/k9s.tar.gz
            log_success "K9s instalado exitosamente."
        else
            log_warn "No se pudo descargar K9s automáticamente."
        fi
    fi

    # 3. Instalar Kubectl-neat
    log_info "Instalando Kubectl-neat (YAML Formatter & Cleaner)..."
    if command -v kubectl-neat &>/dev/null; then
        log_success "Kubectl-neat ya está instalado."
    else
        local neat_ver="v2.0.3"
        local neat_url="https://github.com/itaysk/kubectl-neat/releases/download/${neat_ver}/kubectl-neat_linux_${arch}.tar.gz"
        log_info "Descargando Kubectl-neat ${neat_ver}..."
        if curl -sSL -o /tmp/kubectl-neat.tar.gz "${neat_url}"; then
            sudo tar -xzf /tmp/kubectl-neat.tar.gz -C /usr/local/bin kubectl-neat 2>/dev/null || sudo tar -xzf /tmp/kubectl-neat.tar.gz -C /usr/bin kubectl-neat 2>/dev/null
            sudo chmod +x /usr/local/bin/kubectl-neat 2>/dev/null || sudo chmod +x /usr/bin/kubectl-neat 2>/dev/null || true
            rm -f /tmp/kubectl-neat.tar.gz
            log_success "Kubectl-neat instalado exitosamente."
        else
            log_warn "No se pudo descargar kubectl-neat automáticamente."
        fi
    fi

    printf "\n"
    log_section "🎉 Herramientas CLI de Operador Instaladas"
    printf "  ${CLR_BOLD_GREEN}Comandos listos para usar:${CLR_RESET}\n"
    printf "  %-25s %s\n" "stern <regex>:" "Stream de logs multi-pod con colores (ej. stern -n kube-system cilium.*)"
    printf "  %-25s %s\n" "k9s:" "Interfaz TUI interactiva de consola para gestionar el clúster"
    printf "  %-25s %s\n" "kubectl neat:" "Limpia manifiestos YAML (kubectl get pod x -o yaml | kubectl neat)"
    printf "\n"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    install_cli_tools "$@"
fi
