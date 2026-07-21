#!/usr/bin/env bash
# =============================================================================
# KubeOps-Suite :: lib/state_manager.sh
# Purpose : Persistent JSON-based state store for cluster provisioning data.
#           Saves & retrieves: Master IPs, join tokens, node roles, registry
#           endpoints, and any arbitrary key-value pairs.
# State file: ${KUBEOPS_STATE_FILE} (default: ~/.kubeops/cluster-state.json)
# Author  : KubeOps-Suite (Principal Platform Engineer)
# =============================================================================
set -euo pipefail

# Ensure logger is available
if ! declare -f log_info &>/dev/null; then
    # shellcheck source=lib/logger.sh
    source "$(dirname "${BASH_SOURCE[0]}")/logger.sh"
fi

# ---------------------------------------------------------------------------
# State file configuration
# ---------------------------------------------------------------------------
KUBEOPS_STATE_DIR="${KUBEOPS_STATE_DIR:-${HOME}/.kubeops}"
KUBEOPS_STATE_FILE="${KUBEOPS_STATE_FILE:-${KUBEOPS_STATE_DIR}/cluster-state.json}"
readonly KUBEOPS_STATE_LOCK="${KUBEOPS_STATE_DIR}/.state.lock"
readonly KUBEOPS_STATE_BACKUP_DIR="${KUBEOPS_STATE_DIR}/backups"

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# _state_lock: acquire exclusive lock for atomic writes
_state_lock() {
    if command -v flock &>/dev/null; then
        exec 200>"${KUBEOPS_STATE_LOCK}"
        flock -x 200
    fi
}

# _state_unlock: release exclusive lock
_state_unlock() {
    if command -v flock &>/dev/null; then
        flock -u 200 2>/dev/null || true
        exec 200>&- 2>/dev/null || true
    fi
}

# _ensure_jq: verifies jq is available
_ensure_jq() {
    if ! command -v jq &>/dev/null; then
        log_fatal "jq is required for state management. Install with: apt-get install -y jq  OR  dnf install -y jq"
    fi
}

# _state_ensure_dir: creates state directory with secure permissions
_state_ensure_dir() {
    if [[ ! -d "${KUBEOPS_STATE_DIR}" ]]; then
        mkdir -p "${KUBEOPS_STATE_DIR}"
        chmod 700 "${KUBEOPS_STATE_DIR}"
        log_debug "Created state directory: ${KUBEOPS_STATE_DIR}"
    fi
    if [[ ! -d "${KUBEOPS_STATE_BACKUP_DIR}" ]]; then
        mkdir -p "${KUBEOPS_STATE_BACKUP_DIR}"
        chmod 700 "${KUBEOPS_STATE_BACKUP_DIR}"
    fi
}

# _state_init: initializes the JSON state file with a skeleton structure
_state_init() {
    _state_ensure_dir
    if [[ ! -f "${KUBEOPS_STATE_FILE}" ]]; then
        log_debug "Initializing state file: ${KUBEOPS_STATE_FILE}"
        cat > "${KUBEOPS_STATE_FILE}" <<-'EOF'
{
  "kubeops": {
    "version": "1.0.0",
    "created_at": "",
    "updated_at": ""
  },
  "cluster": {
    "name": "",
    "initialized": false,
    "network_mode": "",
    "pod_cidr": "10.244.0.0/16",
    "service_cidr": "10.96.0.0/12",
    "dns_domain": "cluster.local"
  },
  "masters": [],
  "workers": [],
  "join": {
    "token": "",
    "ca_cert_hash": "",
    "control_plane_endpoint": "",
    "certificate_key": "",
    "expires_at": "",
    "kubeadm_join_worker": "",
    "kubeadm_join_master": ""
  },
  "registry": {
    "enabled": false,
    "host": "",
    "port": 5000,
    "url": ""
  },
  "runtime": {
    "type": "",
    "version": ""
  },
  "metadata": {}
}
EOF
        # Set timestamps
        local now
        now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
        _state_update_raw ".kubeops.created_at = \"${now}\" | .kubeops.updated_at = \"${now}\""
        chmod 600 "${KUBEOPS_STATE_FILE}"
        log_success "State file initialized: ${KUBEOPS_STATE_FILE}"
    fi
}

# _state_update_raw JQ_EXPR: applies a raw jq mutation expression atomically
_state_update_raw() {
    local expr="${1}"
    _ensure_jq
    _state_init

    local tmp_file
    tmp_file=$(mktemp "${KUBEOPS_STATE_DIR}/.state.tmp.XXXXXX")

    _state_lock
    local now
    now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    jq "${expr} | .kubeops.updated_at = \"${now}\"" "${KUBEOPS_STATE_FILE}" > "${tmp_file}" && \
        mv -f "${tmp_file}" "${KUBEOPS_STATE_FILE}"
    chmod 600 "${KUBEOPS_STATE_FILE}"
    _state_unlock
}

# ---------------------------------------------------------------------------
# Public: Core Get/Set
# ---------------------------------------------------------------------------

# state_set KEY VALUE: sets a top-level key (dot-notation supported)
# Example: state_set ".cluster.name" "production"
state_set() {
    local key="${1}"
    local value="${2}"
    log_debug "State SET: ${key} = ${value}"
    # Determine if value is a string or JSON primitive
    if [[ "${value}" =~ ^[0-9]+$ ]] || \
       [[ "${value}" == "true" ]] || \
       [[ "${value}" == "false" ]] || \
       [[ "${value}" == "null" ]]; then
        _state_update_raw "${key} = ${value}"
    else
        # Treat as string — safely escape
        local escaped
        escaped=$(jq -n --arg v "${value}" '$v')
        _state_update_raw "${key} = ${escaped}"
    fi
}

# state_get KEY: prints the value of a key (returns empty string if not found)
state_get() {
    local key="${1}"
    _ensure_jq
    _state_init
    local result
    result=$(jq -r "${key} // empty" "${KUBEOPS_STATE_FILE}" 2>/dev/null || echo "")
    echo "${result}"
}

# state_get_or_default KEY DEFAULT: prints value or DEFAULT if key is empty
state_get_or_default() {
    local key="${1}"
    local default="${2}"
    local result
    result=$(state_get "${key}")
    echo "${result:-${default}}"
}

# state_append_array KEY VALUE: appends a JSON object to an array
state_append_array() {
    local key="${1}"
    local value="${2}"
    log_debug "State APPEND: ${key} += ${value}"
    _state_update_raw "${key} += [${value}]"
}

# state_has KEY: returns 0 if the key exists and is not null/empty
state_has() {
    local key="${1}"
    local val
    val=$(state_get "${key}")
    [[ -n "${val}" && "${val}" != "null" && "${val}" != "false" ]]
}

# ---------------------------------------------------------------------------
# Public: Domain-Specific Operations
# ---------------------------------------------------------------------------

# state_save_master IP [HOSTNAME] [ROLE]: saves master node info
state_save_master() {
    local ip="${1}"
    local hostname="${2:-}"
    local role="${3:-primary}"  # primary | ha-replica

    if [[ -z "${hostname}" ]]; then
        hostname=$(hostname -f 2>/dev/null || echo "master-${ip//./-}")
    fi

    local now
    now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    log_info "Saving master node: ${hostname} (${ip}) [${role}]"

    # Check if already exists
    local exists
    exists=$(jq --arg ip "${ip}" '.masters | map(select(.ip == $ip)) | length' \
        "${KUBEOPS_STATE_FILE}" 2>/dev/null || echo "0")

    if [[ "${exists}" -gt 0 ]]; then
        # Update existing
        _state_update_raw "
            .masters |= map(
                if .ip == \"${ip}\" then
                    .hostname = \"${hostname}\" | .role = \"${role}\" | .updated_at = \"${now}\"
                else . end
            )
        "
    else
        # Add new
        state_append_array ".masters" \
            "{\"ip\": \"${ip}\", \"hostname\": \"${hostname}\", \"role\": \"${role}\", \"added_at\": \"${now}\", \"updated_at\": \"${now}\"}"
    fi

    # Set primary control plane endpoint if this is the first master
    local current_endpoint
    current_endpoint=$(state_get ".join.control_plane_endpoint")
    if [[ -z "${current_endpoint}" || "${current_endpoint}" == "null" ]] || \
       [[ "${role}" == "primary" ]]; then
        state_set ".join.control_plane_endpoint" "${ip}"
        state_set ".cluster.initialized" "true"
    fi

    log_success "Master node saved: ${hostname} (${ip})"
}

# state_save_worker IP [HOSTNAME]: saves worker node info
state_save_worker() {
    local ip="${1}"
    local hostname="${2:-}"

    if [[ -z "${hostname}" ]]; then
        hostname=$(hostname -f 2>/dev/null || echo "worker-${ip//./-}")
    fi

    local now
    now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    log_info "Saving worker node: ${hostname} (${ip})"

    local exists
    exists=$(jq --arg ip "${ip}" '.workers | map(select(.ip == $ip)) | length' \
        "${KUBEOPS_STATE_FILE}" 2>/dev/null || echo "0")

    if [[ "${exists}" -gt 0 ]]; then
        _state_update_raw "
            .workers |= map(
                if .ip == \"${ip}\" then
                    .hostname = \"${hostname}\" | .updated_at = \"${now}\"
                else . end
            )
        "
    else
        state_append_array ".workers" \
            "{\"ip\": \"${ip}\", \"hostname\": \"${hostname}\", \"added_at\": \"${now}\", \"updated_at\": \"${now}\"}"
    fi

    log_success "Worker node saved: ${hostname} (${ip})"
}

# state_save_join_token TOKEN CA_HASH [CERTIFICATE_KEY]
state_save_join_token() {
    local token="${1}"
    local ca_hash="${2}"
    local cert_key="${3:-}"

    log_info "Saving join credentials..."

    # Token expiry: kubeadm tokens expire in 24h by default
    local expires_at
    expires_at=$(date -u -d '+24 hours' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || \
                 date -u -v+24H '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || \
                 echo "")

    local control_plane_ip
    control_plane_ip=$(state_get ".join.control_plane_endpoint")

    state_set ".join.token" "${token}"
    state_set ".join.ca_cert_hash" "${ca_hash}"
    state_set ".join.expires_at" "${expires_at}"

    if [[ -n "${cert_key}" ]]; then
        state_set ".join.certificate_key" "${cert_key}"
    fi

    # Build join commands
    local worker_join="kubeadm join ${control_plane_ip}:6443 --token ${token} --discovery-token-ca-cert-hash sha256:${ca_hash}"
    local master_join="${worker_join} --control-plane --certificate-key ${cert_key}"

    state_set ".join.kubeadm_join_worker" "${worker_join}"
    if [[ -n "${cert_key}" ]]; then
        state_set ".join.kubeadm_join_master" "${master_join}"
    fi

    log_success "Join token saved (expires: ${expires_at:-unknown})"
}

# state_save_registry HOST PORT: saves local registry configuration
state_save_registry() {
    local host="${1:-localhost}"
    local port="${2:-5000}"

    log_info "Saving registry config: ${host}:${port}"
    state_set ".registry.enabled" "true"
    state_set ".registry.host" "${host}"
    state_set ".registry.port" "${port}"
    state_set ".registry.url" "${host}:${port}"
    log_success "Registry config saved: ${host}:${port}"
}

# state_get_join_command [ROLE]: returns the kubeadm join command
state_get_join_command() {
    local role="${1:-worker}"  # worker | master
    local key

    if [[ "${role}" == "master" ]]; then
        key=".join.kubeadm_join_master"
    else
        key=".join.kubeadm_join_worker"
    fi

    local cmd
    cmd=$(state_get "${key}")

    if [[ -z "${cmd}" || "${cmd}" == "null" ]]; then
        log_error "No join command found for role: ${role}. Initialize the cluster first."
        return 1
    fi

    echo "${cmd}"
}

# state_is_cluster_initialized: returns 0 if cluster has been initialized
state_is_cluster_initialized() {
    local initialized
    initialized=$(state_get ".cluster.initialized")
    [[ "${initialized}" == "true" ]]
}

# state_is_token_valid: checks if the stored join token has not expired
state_is_token_valid() {
    local expires_at
    expires_at=$(state_get ".join.expires_at")

    if [[ -z "${expires_at}" || "${expires_at}" == "null" ]]; then
        log_warn "Token expiry unknown — assuming valid"
        return 0
    fi

    local now_epoch
    now_epoch=$(date -u +%s)
    local exp_epoch
    exp_epoch=$(date -u -d "${expires_at}" +%s 2>/dev/null || \
                date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "${expires_at}" +%s 2>/dev/null || \
                echo "0")

    if [[ "${now_epoch}" -gt "${exp_epoch}" ]]; then
        log_warn "Join token has EXPIRED (at ${expires_at}). Generate a new token with: kubeadm token create --print-join-command"
        return 1
    fi

    local remaining=$(( (exp_epoch - now_epoch) / 3600 ))
    log_debug "Join token valid for ~${remaining}h more"
    return 0
}

# ---------------------------------------------------------------------------
# Public: Backup & Restore
# ---------------------------------------------------------------------------

# state_backup: creates a timestamped backup of the state file
state_backup() {
    _state_ensure_dir
    if [[ ! -f "${KUBEOPS_STATE_FILE}" ]]; then
        log_warn "No state file to backup"
        return 0
    fi
    local backup_file="${KUBEOPS_STATE_BACKUP_DIR}/cluster-state-$(date +%Y%m%d_%H%M%S).json"
    cp "${KUBEOPS_STATE_FILE}" "${backup_file}"
    chmod 600 "${backup_file}"
    log_success "State backed up: ${backup_file}"
    echo "${backup_file}"
}

# state_restore BACKUP_FILE: restores state from a backup
state_restore() {
    local backup="${1}"
    if [[ ! -f "${backup}" ]]; then
        log_error "Backup file not found: ${backup}"
        return 1
    fi
    # Validate JSON
    if ! jq empty "${backup}" 2>/dev/null; then
        log_error "Invalid JSON in backup file: ${backup}"
        return 1
    fi
    state_backup  # backup current before restoring
    cp "${backup}" "${KUBEOPS_STATE_FILE}"
    chmod 600 "${KUBEOPS_STATE_FILE}"
    log_success "State restored from: ${backup}"
}

# state_reset: clears the state file (with confirmation)
state_reset() {
    local force="${1:-false}"
    if [[ "${force}" != "true" ]]; then
        log_warn "This will PERMANENTLY delete all cluster state data!"
        if ! confirm "Are you sure you want to reset state?"; then
            log_info "State reset cancelled"
            return 0
        fi
    fi
    state_backup 2>/dev/null || true
    rm -f "${KUBEOPS_STATE_FILE}"
    log_success "State reset complete"
}

# ---------------------------------------------------------------------------
# Public: Display
# ---------------------------------------------------------------------------

# state_show: prints a human-readable cluster state summary
state_show() {
    _ensure_jq
    _state_init

    log_section "Cluster State Summary"

    local cluster_name initialized network_mode
    cluster_name=$(state_get ".cluster.name")
    initialized=$(state_get ".cluster.initialized")
    network_mode=$(state_get ".cluster.network_mode")

    printf "\n  ${CLR_BOLD_WHITE}Cluster${CLR_RESET}\n"
    printf "  %-28s %s\n" "Name:"        "${cluster_name:-<not set>}"
    printf "  %-28s %s\n" "Initialized:" \
        "$(if [[ "${initialized}" == "true" ]]; then echo "${CLR_BOLD_GREEN}YES${CLR_RESET}"; else echo "${CLR_BOLD_RED}NO${CLR_RESET}"; fi)"
    printf "  %-28s %s\n" "Network Mode:" "${network_mode:-<not set>}"
    printf "  %-28s %s\n" "Pod CIDR:"    "$(state_get ".cluster.pod_cidr")"
    printf "  %-28s %s\n" "Service CIDR:" "$(state_get ".cluster.service_cidr")"

    printf "\n  ${CLR_BOLD_WHITE}Masters${CLR_RESET}\n"
    local masters
    masters=$(jq -r '.masters[] | "  \(.role | ascii_upcase)  \(.hostname)  [\(.ip)]  added: \(.added_at)"' \
        "${KUBEOPS_STATE_FILE}" 2>/dev/null || echo "  (none)")
    if [[ -z "${masters}" ]]; then
        printf "  %s\n" "(none registered)"
    else
        while IFS= read -r line; do
            printf "  ${CLR_GREEN}●${CLR_RESET} %s\n" "${line}"
        done <<< "${masters}"
    fi

    printf "\n  ${CLR_BOLD_WHITE}Workers${CLR_RESET}\n"
    local workers
    workers=$(jq -r '.workers[] | "  \(.hostname)  [\(.ip)]  added: \(.added_at)"' \
        "${KUBEOPS_STATE_FILE}" 2>/dev/null || echo "")
    if [[ -z "${workers}" ]]; then
        printf "  %s\n" "(none registered)"
    else
        while IFS= read -r line; do
            printf "  ${CLR_CYAN}●${CLR_RESET} %s\n" "${line}"
        done <<< "${workers}"
    fi

    printf "\n  ${CLR_BOLD_WHITE}Join Credentials${CLR_RESET}\n"
    local token endpoint ca_hash expires_at
    token=$(state_get ".join.token")
    endpoint=$(state_get ".join.control_plane_endpoint")
    ca_hash=$(state_get ".join.ca_cert_hash")
    expires_at=$(state_get ".join.expires_at")

    if [[ -n "${token}" && "${token}" != "null" ]]; then
        # Mask middle of token for security in display
        local masked_token="${token:0:6}...${token: -6}"
        printf "  %-28s %s\n" "Control Plane:" "${endpoint:-N/A}:6443"
        printf "  %-28s %s\n" "Token:" "${masked_token}"
        printf "  %-28s sha256:%s\n" "CA Hash:" "${ca_hash:0:16}..."
        printf "  %-28s %s\n" "Expires:" "${expires_at:-unknown}"
        if state_is_token_valid 2>/dev/null; then
            printf "  %-28s %s\n" "Status:" "${CLR_BOLD_GREEN}VALID${CLR_RESET}"
        else
            printf "  %-28s %s\n" "Status:" "${CLR_BOLD_RED}EXPIRED${CLR_RESET}"
        fi
    else
        printf "  %s\n" "(no join credentials stored)"
    fi

    printf "\n  ${CLR_BOLD_WHITE}Registry${CLR_RESET}\n"
    local reg_enabled reg_url
    reg_enabled=$(state_get ".registry.enabled")
    reg_url=$(state_get ".registry.url")
    if [[ "${reg_enabled}" == "true" ]]; then
        printf "  %-28s %s\n" "Registry URL:" "${CLR_BOLD_GREEN}${reg_url}${CLR_RESET}"
    else
        printf "  %s\n" "(no local registry configured)"
    fi

    printf "\n  ${CLR_BOLD_WHITE}Join Commands${CLR_RESET}\n"
    local join_worker
    join_worker=$(state_get ".join.kubeadm_join_worker")
    if [[ -n "${join_worker}" && "${join_worker}" != "null" ]]; then
        printf "\n  ${CLR_DIM}# Add a Worker node:${CLR_RESET}\n"
        printf "  ${CLR_YELLOW}%s${CLR_RESET}\n" "${join_worker}"
        local join_master
        join_master=$(state_get ".join.kubeadm_join_master")
        if [[ -n "${join_master}" && "${join_master}" != "null" ]]; then
            printf "\n  ${CLR_DIM}# Add a Master (HA) node:${CLR_RESET}\n"
            printf "  ${CLR_YELLOW}%s${CLR_RESET}\n" "${join_master}"
        fi
    else
        printf "  %s\n" "(cluster not initialized — run Option 2 first)"
    fi

    printf "\n  ${CLR_DIM}State file: ${KUBEOPS_STATE_FILE}${CLR_RESET}\n"
    printf "  ${CLR_DIM}Last updated: $(state_get ".kubeops.updated_at")${CLR_RESET}\n\n"
}

# state_export_kubeconfig: exports the kubeconfig path hint
state_export_kubeconfig_path() {
    local master_ip
    master_ip=$(state_get ".join.control_plane_endpoint")
    if [[ -z "${master_ip}" || "${master_ip}" == "null" ]]; then
        echo ""
        return 1
    fi
    echo "/etc/kubernetes/admin.conf"
}

# state_set_runtime RUNTIME_TYPE VERSION
state_set_runtime() {
    local runtime_type="${1}"
    local version="${2:-}"
    state_set ".runtime.type" "${runtime_type}"
    if [[ -n "${version}" ]]; then
        state_set ".runtime.version" "${version}"
    fi
}

# state_set_cluster_name NAME
state_set_cluster_name() {
    state_set ".cluster.name" "${1}"
}

# state_set_network_mode MODE (online|airgap)
state_set_network_mode() {
    state_set ".cluster.network_mode" "${1}"
}

# state_set_meta KEY VALUE: stores arbitrary metadata
state_set_meta() {
    local key="${1}"
    local value="${2}"
    state_set ".metadata.${key}" "${value}"
}

# state_get_meta KEY
state_get_meta() {
    state_get ".metadata.${1}"
}

# ===========================================================================
# Nexus Registry State (Air-Gap support)
# ===========================================================================

# state_save_nexus REGISTRY_URL: persists Nexus registry endpoint
# REGISTRY_URL format: "192.168.1.50:5000"
state_save_nexus() {
    local registry="${1}"
    local host="${registry%%:*}"
    local port="${registry##*:}"

    # Ensure nexus object exists in state
    _state_update_raw \
        ".nexus = (.nexus // {}) |
         .nexus.enabled = true |
         .nexus.registry = \"${registry}\" |
         .nexus.host = \"${host}\" |
         .nexus.port = ${port} |
         .nexus.ui_url = \"http://${host}:8081\" |
         .nexus.docker_url = \"http://${registry}\""

    # Export to current session so other modules can read it immediately
    export NEXUS_REGISTRY="${registry}"
    log_success "Nexus registry saved: ${CLR_BOLD_CYAN}${registry}${CLR_RESET}"
}

# state_get_nexus: returns the saved Nexus registry URL (host:port)
state_get_nexus() {
    local val
    val=$(state_get ".nexus.registry" 2>/dev/null || echo "")
    if [[ -z "${val}" || "${val}" == "null" ]]; then
        echo ""
    else
        echo "${val}"
    fi
}

# state_nexus_configured: returns 0 if Nexus is configured, 1 otherwise
state_nexus_configured() {
    local val
    val=$(state_get ".nexus.enabled" 2>/dev/null || echo "false")
    [[ "${val}" == "true" ]]
}

# state_load_nexus_env: exports NEXUS_REGISTRY from state into current shell
# Call this at the start of any module that needs Nexus awareness
state_load_nexus_env() {
    local saved
    saved=$(state_get_nexus 2>/dev/null || echo "")
    if [[ -n "${saved}" ]]; then
        export NEXUS_REGISTRY="${saved}"
        log_debug "Nexus registry loaded from state: ${NEXUS_REGISTRY}"
    fi
}
