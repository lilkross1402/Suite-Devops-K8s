#!/usr/bin/env bash
# =============================================================================
# KubeOps-Suite :: modules/02_containerd.sh
# Purpose : Standalone containerd/Docker runtime installation and configuration.
#           Can be run independently or sourced by other modules.
# Author  : KubeOps-Suite (Principal Platform Engineer)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${SUITE_ROOT}/lib/logger.sh"
source "${SUITE_ROOT}/lib/os_detect.sh"
source "${SUITE_ROOT}/lib/network_check.sh"
source "${SUITE_ROOT}/lib/state_manager.sh"

main() {
    log_banner
    log_section "Container Runtime Installation"

    os_detect
    net_detect_mode
    os_check_root

    # Source master module functions
    # shellcheck source=modules/03_k8s_master.sh
    _SOURCED_BY_WORKER=true source "${SUITE_ROOT}/modules/03_k8s_master.sh" 2>/dev/null || true

    log_info "Installing and configuring containerd..."

    if net_is_online; then
        _install_containerd_online
    else
        _install_containerd_airgap
    fi

    local version
    version=$(containerd --version 2>/dev/null | awk '{print $3}' || echo "unknown")
    state_set_runtime "containerd" "${version}"

    log_section "✅ containerd Installed"
    printf "  %-25s %s\n" "Version:" "${version}"
    printf "  %-25s %s\n" "Socket:" "/run/containerd/containerd.sock"
    printf "  %-25s %s\n" "Config:" "/etc/containerd/config.toml"
    printf "  %-25s %s\n" "Status:" "$(systemctl is-active containerd 2>/dev/null || echo 'unknown')"
    echo ""

    log_success "Container runtime ready"
    pause "Press [Enter] to return to main menu..."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
