#!/usr/bin/env bash
# =============================================================================
# KubeOps-Suite :: lib/network_check.sh
# Purpose : Detect internet connectivity and classify the environment as
#           ONLINE or AIR-GAPPED. Also provides helpers for reachability
#           checks against local registries and cluster endpoints.
# Author  : KubeOps-Suite (Principal Platform Engineer)
# =============================================================================
if [[ -n "${_NETWORK_CHECK_SH_LOADED:-}" ]]; then
    return 0
fi
_NETWORK_CHECK_SH_LOADED=true

# Ensure logger is available
if ! declare -f log_info &>/dev/null; then
    # shellcheck source=lib/logger.sh
    source "$(dirname "${BASH_SOURCE[0]}")/logger.sh"
fi

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
readonly NET_PROBE_HOSTS=(
    "8.8.8.8"       # Google DNS
    "1.1.1.1"       # Cloudflare DNS
    "208.67.222.222" # OpenDNS
)
readonly NET_PROBE_TIMEOUT=3   # seconds per probe
readonly NET_PROBE_PORT=53     # DNS port for TCP probe

# Global state: KUBEOPS_NETWORK_MODE is set by net_detect_mode()
# Values: "online" | "airgap"
KUBEOPS_NETWORK_MODE="${KUBEOPS_NETWORK_MODE:-}"

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# _probe_tcp HOST PORT TIMEOUT: returns 0 if TCP connection succeeds
_probe_tcp() {
    local host="${1}"
    local port="${2}"
    local timeout="${3:-2}"

    if command -v timeout &>/dev/null; then
        timeout "${timeout}" bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null && return 0
    fi
    if command -v nc &>/dev/null; then
        nc -z -w "${timeout}" "${host}" "${port}" 2>/dev/null && return 0
    fi
    return 1
}

# _probe_icmp HOST TIMEOUT: ICMP ping probe
_probe_icmp() {
    local host="${1}"
    local timeout="${2}"
    ping -c 1 -W "${timeout}" "${host}" &>/dev/null
    return $?
}

# ---------------------------------------------------------------------------
# Public Functions
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# SRE FIX A3: net_detect_mode con cache de sesi\u00f3n y timeout reducido.
# - Respeta KUBEOPS_FORCE_OFFLINE sin lanzar ning\u00fan probe (0ms de bloqueo).
# - Cachea el resultado en _NET_MODE_CACHED para evitar re-detecci\u00f3n costosa.
# - Prueba DNS primero (m\u00e1s r\u00e1pido que TCP en redes con firewall de egreso).
# - Timeout reducido de 3s \u2192 2s por probe para minimizar bloqueo en air-gap.
# ---------------------------------------------------------------------------
declare -g _NET_MODE_CACHED=""

net_detect_mode() {
    # 0. Respetar override expl\u00edcito (--offline flag o variable de entorno)
    if [[ "${KUBEOPS_FORCE_OFFLINE:-false}" == "true" || \
          "${KUBEOPS_NETWORK_MODE:-}" == "airgap" ]]; then
        KUBEOPS_NETWORK_MODE="airgap"
        _NET_MODE_CACHED="airgap"
        export KUBEOPS_NETWORK_MODE
        log_info "Modo de red: ${CLR_BOLD_YELLOW}AIR-GAP${CLR_RESET} (forzado por --offline)"
        return 0
    fi

    # 1. Usar cache de sesi\u00f3n (evita re-detecci\u00f3n en cada m\u00f3dulo)
    if [[ -n "${_NET_MODE_CACHED}" ]]; then
        KUBEOPS_NETWORK_MODE="${_NET_MODE_CACHED}"
        log_debug "Modo de red (cache): ${KUBEOPS_NETWORK_MODE}"
        export KUBEOPS_NETWORK_MODE
        return 0
    fi

    log_info "Detectando modo de red..."
    local online=false
    local probe_timeout=2   # Reducido de 3s a 2s

    # 2. Prueba DNS (m\u00e1s r\u00e1pida que TCP en la mayor\u00eda de redes corporativas)
    if command -v nslookup &>/dev/null; then
        if timeout "${probe_timeout}" nslookup "pkgs.k8s.io" &>/dev/null 2>&1; then
            online=true
            log_debug "Reachable v\u00eda DNS: pkgs.k8s.io"
        fi
    fi

    # 3. Prueba TCP solo si DNS fall\u00f3 (evita doble latencia en modo online)
    if [[ "${online}" == "false" ]]; then
        for host in "${NET_PROBE_HOSTS[@]}"; do
            log_debug "Probando ${host}:${NET_PROBE_PORT} (TCP, ${probe_timeout}s)..."
            if _probe_tcp "${host}" "${NET_PROBE_PORT}" "${probe_timeout}" 2>/dev/null; then
                online=true
                log_debug "Reachable v\u00eda TCP: ${host}"
                break
            fi
        done
    fi

    if [[ "${online}" == "true" ]]; then
        _NET_MODE_CACHED="online"
        log_success "Modo de red: ${CLR_BOLD_GREEN}ONLINE${CLR_RESET}"
    else
        _NET_MODE_CACHED="airgap"
        log_warn "Modo de red: ${CLR_BOLD_YELLOW}AIR-GAPPED${CLR_RESET} \u2014 usando assets offline"
    fi

    KUBEOPS_NETWORK_MODE="${_NET_MODE_CACHED}"
    export KUBEOPS_NETWORK_MODE
    return 0
}

# net_is_online: Returns 0 if environment is ONLINE
net_is_online() {
    [[ "${KUBEOPS_NETWORK_MODE:-}" == "online" ]]
}

# net_is_airgap: Returns 0 if environment is AIR-GAPPED
net_is_airgap() {
    [[ "${KUBEOPS_NETWORK_MODE:-}" == "airgap" ]]
}

# net_check_endpoint HOST PORT [LABEL]: checks a specific endpoint
# Returns 0 if reachable, 1 otherwise
net_check_endpoint() {
    local host="${1}"
    local port="${2}"
    local label="${3:-${host}:${port}}"

    log_debug "Checking endpoint: ${label} (${host}:${port})"
    if _probe_tcp "${host}" "${port}" "${NET_PROBE_TIMEOUT}"; then
        log_success "Endpoint reachable: ${label}"
        return 0
    else
        log_warn "Endpoint unreachable: ${label}"
        return 1
    fi
}

# net_check_registry REGISTRY_HOST REGISTRY_PORT: validates local registry is up
net_check_registry() {
    local registry_host="${1:-localhost}"
    local registry_port="${2:-5000}"
    local registry_url="http://${registry_host}:${registry_port}"

    log_info "Checking local registry at ${registry_url}..."

    if command -v curl &>/dev/null; then
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" \
            --connect-timeout "${NET_PROBE_TIMEOUT}" \
            "${registry_url}/v2/" 2>/dev/null) || http_code="000"

        if [[ "${http_code}" == "200" || "${http_code}" == "401" ]]; then
            log_success "Registry is UP at ${registry_url} (HTTP ${http_code})"
            return 0
        else
            log_warn "Registry not responding properly (HTTP ${http_code})"
            return 1
        fi
    else
        # Fallback to TCP probe
        net_check_endpoint "${registry_host}" "${registry_port}" "registry"
        return $?
    fi
}

# net_wait_for_endpoint HOST PORT [TIMEOUT_SECS] [LABEL]
# Polls until endpoint is reachable or timeout expires
net_wait_for_endpoint() {
    local host="${1}"
    local port="${2}"
    local timeout="${3:-120}"
    local label="${4:-${host}:${port}}"
    local elapsed=0
    local interval=5

    log_info "Waiting for ${label} to become available (timeout: ${timeout}s)..."

    while [[ "${elapsed}" -lt "${timeout}" ]]; do
        if _probe_tcp "${host}" "${port}" 2 2>/dev/null; then
            log_success "${label} is now reachable (after ${elapsed}s)"
            return 0
        fi
        log_debug "Still waiting for ${label}... (${elapsed}s/${timeout}s)"
        sleep "${interval}"
        elapsed=$(( elapsed + interval ))
    done

    log_error "Timeout (${timeout}s) waiting for ${label}"
    return 1
}

# net_get_primary_ip: returns the primary non-loopback IPv4 address
net_get_primary_ip() {
    local ip=""

    # Method 1: ip route (most reliable on Linux)
    if command -v ip &>/dev/null; then
        ip=$(ip route get 1.1.1.1 2>/dev/null | \
             awk '/src/{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')
    fi

    # Method 2: hostname -I fallback
    if [[ -z "${ip}" ]] && command -v hostname &>/dev/null; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi

    # Method 3: ifconfig fallback
    if [[ -z "${ip}" ]] && command -v ifconfig &>/dev/null; then
        ip=$(ifconfig 2>/dev/null | \
             awk '/inet /{print $2}' | \
             grep -v '127\.0\.0\.' | head -1 | \
             sed 's/addr://')
    fi

    echo "${ip:-127.0.0.1}"
}

# net_validate_ip IP_STRING: validates an IPv4 address format
net_validate_ip() {
    local ip="${1}"
    if [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        local IFS='.'
        read -ra octets <<< "${ip}"
        for octet in "${octets[@]}"; do
            if [[ "${octet}" -gt 255 ]]; then
                return 1
            fi
        done
        return 0
    fi
    return 1
}

# net_show_status: prints a formatted connectivity report
net_show_status() {
    log_section "Network Status Report"
    printf "  %-25s %s\n" "Mode:" \
        "$(if net_is_online; then echo -e "${CLR_BOLD_GREEN}ONLINE${CLR_RESET}"; else echo -e "${CLR_BOLD_YELLOW}AIR-GAPPED${CLR_RESET}"; fi)"
    printf "  %-25s %s\n" "Primary IP:" "$(net_get_primary_ip)"

    # Check DNS resolution
    if command -v nslookup &>/dev/null || command -v dig &>/dev/null; then
        if nslookup "google.com" &>/dev/null 2>&1 || dig +short "google.com" &>/dev/null 2>&1; then
            printf "  %-25s %s\n" "DNS Resolution:" "${CLR_BOLD_GREEN}OK${CLR_RESET}"
        else
            printf "  %-25s %s\n" "DNS Resolution:" "${CLR_BOLD_RED}FAILED${CLR_RESET}"
        fi
    fi
    echo ""
}
