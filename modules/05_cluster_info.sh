#!/usr/bin/env bash
# =============================================================================
# KubeOps-Suite :: modules/05_cluster_info.sh
# Purpose : Display comprehensive cluster status including nodes, pods,
#           resource usage, join commands, and health summary.
# Author  : KubeOps-Suite (Principal Platform Engineer)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${SUITE_ROOT}/lib/logger.sh"
source "${SUITE_ROOT}/lib/network_check.sh"
source "${SUITE_ROOT}/lib/state_manager.sh"

_print_separator() {
    printf "${CLR_DIM}%.0s─${CLR_RESET}" {1..70}
    echo ""
}

_show_nodes() {
    local kubeconfig="${HOME}/.kube/config"
    if [[ ! -f "${kubeconfig}" ]]; then
        kubeconfig="/etc/kubernetes/admin.conf"
    fi

    log_section "Cluster Nodes"
    if command -v kubectl &>/dev/null && [[ -f "${kubeconfig}" ]]; then
        kubectl get nodes -o wide --kubeconfig="${kubeconfig}" 2>/dev/null || \
            log_warn "kubectl get nodes failed — check kubeconfig"
    else
        log_warn "kubectl not available or kubeconfig not found"
        log_info "State-stored nodes:"
        state_show
    fi
}

_show_pods() {
    local kubeconfig="${HOME}/.kube/config"
    [[ ! -f "${kubeconfig}" ]] && kubeconfig="/etc/kubernetes/admin.conf"

    log_section "System Pods"
    if command -v kubectl &>/dev/null && [[ -f "${kubeconfig}" ]]; then
        kubectl get pods -A --kubeconfig="${kubeconfig}" 2>/dev/null || true
    fi
}

_show_resources() {
    local kubeconfig="${HOME}/.kube/config"
    [[ ! -f "${kubeconfig}" ]] && kubeconfig="/etc/kubernetes/admin.conf"

    log_section "Resource Usage"
    if command -v kubectl &>/dev/null && [[ -f "${kubeconfig}" ]]; then
        kubectl top nodes --kubeconfig="${kubeconfig}" 2>/dev/null || \
            log_warn "metrics-server not available (kubectl top requires metrics-server)"
    fi
}

_show_join_commands() {
    log_section "Join Commands"

    local worker_join master_join
    worker_join=$(state_get ".join.kubeadm_join_worker")
    master_join=$(state_get ".join.kubeadm_join_master")

    if [[ -n "${worker_join}" && "${worker_join}" != "null" ]]; then
        printf "\n  ${CLR_BOLD_WHITE}Add a Worker Node:${CLR_RESET}\n"
        printf "  ${CLR_YELLOW}%s${CLR_RESET}\n\n" "${worker_join}"
    fi

    if [[ -n "${master_join}" && "${master_join}" != "null" ]]; then
        printf "  ${CLR_BOLD_WHITE}Add a Master (HA) Node:${CLR_RESET}\n"
        printf "  ${CLR_CYAN}%s${CLR_RESET}\n\n" "${master_join}"
    fi

    if [[ -z "${worker_join}" || "${worker_join}" == "null" ]]; then
        log_warn "No join commands stored — initialize the cluster first (Option 2)"
    fi

    # Token validity
    printf "  ${CLR_BOLD_WHITE}Token Status:${CLR_RESET}\n"
    if state_is_token_valid 2>/dev/null; then
        printf "  %-28s ${CLR_BOLD_GREEN}VALID${CLR_RESET}\n" "Current Token:"
    else
        printf "  %-28s ${CLR_BOLD_RED}EXPIRED${CLR_RESET}\n" "Current Token:"
        printf "\n  ${CLR_YELLOW}Regenerate with (on master):${CLR_RESET}\n"
        printf "  ${CLR_YELLOW}kubeadm token create --print-join-command${CLR_RESET}\n"
    fi
}

main() {
    log_banner
    log_section "Cluster Information & Status"

    net_detect_mode
    state_show

    _show_nodes
    _show_pods
    _show_resources
    _show_join_commands

    echo ""
    log_success "Status report complete"
    pause "Press [Enter] to return to main menu..."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
