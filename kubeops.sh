#!/usr/bin/env bash
# =============================================================================
# KubeOps-Suite :: kubeops.sh
# Purpose : Main interactive CLI entry point for the KubeOps-Suite automation
#           platform. Provides a fully interactive terminal menu to provision
#           and manage Kubernetes clusters in Online and Air-Gapped environments.
#
# Usage   : sudo ./kubeops.sh [--debug] [--no-color] [--state-file FILE]
#           sudo ./kubeops.sh --run <module>   # Non-interactive mode
#
# Author  : KubeOps-Suite (Principal Platform Engineer)
# Version : 1.0.0
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve the suite root directory (handles symlinks)
# ---------------------------------------------------------------------------
SUITE_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
readonly SUITE_ROOT

# ---------------------------------------------------------------------------
# Source core libraries (order matters: logger first)
# ---------------------------------------------------------------------------
_source_lib() {
    local lib="${SUITE_ROOT}/lib/${1}"
    if [[ ! -f "${lib}" ]]; then
        echo "[ERROR] Required library not found: ${lib}" >&2
        exit 1
    fi
    # shellcheck disable=SC1090
    source "${lib}"
}

_source_lib "logger.sh"
_source_lib "os_detect.sh"
_source_lib "network_check.sh"
_source_lib "state_manager.sh"

# ---------------------------------------------------------------------------
# Global constants
# ---------------------------------------------------------------------------
readonly KUBEOPS_VERSION="1.0.0"
readonly KUBEOPS_MIN_BASH_VERSION=4

# ---------------------------------------------------------------------------
# Parse CLI arguments
# ---------------------------------------------------------------------------
_parse_args() {
    while [[ $# -gt 0 ]]; do
        case "${1}" in
            --debug)
                export KUBEOPS_LOG_LEVEL="DEBUG"
                shift ;;
            --no-color)
                export KUBEOPS_NO_COLOR="true"
                shift ;;
            --state-file)
                export KUBEOPS_STATE_FILE="${2}"
                shift 2 ;;
            --run)
                KUBEOPS_DIRECT_RUN="${2}"
                shift 2 ;;
            --offline)
                # Force Air-Gap mode — skip internet probe, prompt for Nexus
                export KUBEOPS_NETWORK_MODE="airgap"
                export KUBEOPS_FORCE_OFFLINE="true"
                shift ;;
            --help|-h)
                _print_help
                exit 0 ;;
            --version|-v)
                echo "KubeOps-Suite v${KUBEOPS_VERSION}"
                exit 0 ;;
            *)
                log_warn "Unknown argument: ${1}"
                shift ;;
        esac
    done
}

_print_help() {
    cat <<EOF
KubeOps-Suite v${KUBEOPS_VERSION} — Kubernetes Provisioning & Management CLI

USAGE:
  sudo ./kubeops.sh [OPTIONS]
  sudo ./kubeops.sh --run <module>

OPTIONS:
  --debug              Enable debug logging
  --no-color           Disable ANSI color output
  --state-file FILE    Use a custom state file path
  --run MODULE         Run a module directly (non-interactive):
                         registry, containerd, master, worker, info,
                         monitoring, kong, redis
  --version            Show version
  --help               Show this help

MODULES:
  registry             Provision local container registry (Air-Gap)
  containerd           Install/configure containerd runtime
  master               Initialize Kubernetes master (control plane)
  worker               Join a worker node to the cluster
  info                 Show cluster status and join commands
  monitoring           Deploy Prometheus + Grafana stack
  kong                 Deploy Kong API Gateway
  redis                Deploy Redis

ENVIRONMENT VARIABLES:
  KUBEOPS_LOG_LEVEL    Log verbosity: DEBUG | INFO | WARN | ERROR (default: INFO)
  KUBEOPS_NO_COLOR     Disable colors: true | false
  KUBEOPS_STATE_FILE   Path to state JSON file (default: ~/.kubeops/cluster-state.json)
  K8S_VERSION          Kubernetes version to install (default: 1.29)
  K8S_VERSION_FULL     Full version string (default: 1.29.3)
  POD_CIDR             Pod network CIDR (default: 10.244.0.0/16)
  CNI_PLUGIN           CNI plugin: cilium | calico | flannel (default: cilium)
  K8S_JOIN_TOKEN       Override join token (worker mode)
  K8S_CA_HASH          Override CA hash (worker mode)
  K8S_CONTROL_PLANE    Override control plane IP (worker mode)

EXAMPLES:
  sudo ./kubeops.sh                          # Interactive menu
  sudo ./kubeops.sh --run master             # Direct master init
  sudo ./kubeops.sh --run worker             # Direct worker join
  sudo ./kubeops.sh --debug --run info       # Debug cluster info
  KUBEOPS_STATE_FILE=/tmp/my.json ./kubeops.sh --run info

EOF
}

# ---------------------------------------------------------------------------
# Compatibility checks
# ---------------------------------------------------------------------------
_check_bash_version() {
    if [[ "${BASH_VERSINFO[0]}" -lt "${KUBEOPS_MIN_BASH_VERSION}" ]]; then
        echo "[ERROR] Bash ${KUBEOPS_MIN_BASH_VERSION}+ required. Current: ${BASH_VERSION}" >&2
        exit 1
    fi
}

_check_dependencies() {
    local missing=()
    for cmd in jq curl; do
        if ! command -v "${cmd}" &>/dev/null; then
            missing+=("${cmd}")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_warn "Missing recommended tools: ${missing[*]}"
        log_warn "Some features may not work correctly."
        log_warn "Install with: apt-get install -y ${missing[*]}  OR  dnf install -y ${missing[*]}"
    fi
}

# ---------------------------------------------------------------------------
# Nexus Air-Gap prompt  (additive — runs only if offline mode detected)
# ---------------------------------------------------------------------------

_prompt_nexus_if_needed() {
    # Determine if we're in air-gap mode (forced or auto-detected)
    local is_airgap=false
    if [[ "${KUBEOPS_FORCE_OFFLINE:-false}" == "true" || \
          "${KUBEOPS_NETWORK_MODE:-}"       == "airgap" ]]; then
        is_airgap=true
    fi

    [[ "${is_airgap}" == "true" ]] || return 0  # Nothing to do in online mode

    # Check if Nexus is already configured in state — skip prompt if so
    if state_nexus_configured 2>/dev/null; then
        local existing
        existing=$(state_get_nexus 2>/dev/null || echo "")
        if [[ -n "${existing}" ]]; then
            export NEXUS_REGISTRY="${existing}"
            log_info "Nexus registry loaded from state: ${CLR_BOLD_CYAN}${NEXUS_REGISTRY}${CLR_RESET}"
            return 0
        fi
    fi

    # Interactive prompt
    printf "\n"
    printf "  ${CLR_BOLD_YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CLR_RESET}\n"
    printf "  ${CLR_BOLD_YELLOW}  ⚠  Modo OFFLINE / AIR-GAP detectado${CLR_RESET}\n"
    printf "  ${CLR_BOLD_YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CLR_RESET}\n"
    printf "\n"
    printf "  Las imágenes de contenedores se deben servir desde un registro local.\n"
    printf "  Se admite Sonatype Nexus 3 (docker-hosted en puerto 5000) o cualquier\n"
    printf "  registro compatible (Docker Registry v2, Harbor, Artifactory).\n"
    printf "\n"
    printf "  Ejemplo: ${CLR_BOLD_CYAN}192.168.1.50:5000${CLR_RESET}   o   ${CLR_BOLD_CYAN}nexus.corp.local:5000${CLR_RESET}\n"
    printf "\n"

    local nexus_input=""
    while true; do
        printf "  ${CLR_BOLD_WHITE}Ingrese IP:Puerto del registro Nexus/Docker › ${CLR_RESET}"
        read -r nexus_input

        # Validate format: must contain a colon and a numeric port
        if [[ -z "${nexus_input}" ]]; then
            printf "  ${CLR_BOLD_YELLOW}[ SKIP ]${CLR_RESET} Omitiendo configuración de Nexus.\n"
            printf "           Las imágenes deberán estar disponibles localmente (cri-load).\n\n"
            return 0
        fi

        if [[ ! "${nexus_input}" =~ ^[^:]+:[0-9]{1,5}$ ]]; then
            printf "  ${CLR_BOLD_RED}Formato inválido.${CLR_RESET} Use HOST:PUERTO (ej: 192.168.1.50:5000)\n"
            continue
        fi

        local port="${nexus_input##*:}"
        if [[ "${port}" -lt 1 || "${port}" -gt 65535 ]]; then
            printf "  ${CLR_BOLD_RED}Puerto inválido${CLR_RESET} (debe estar entre 1 y 65535)\n"
            continue
        fi

        break
    done

    # Persist to state and export for the current session
    if ( state_save_nexus "${nexus_input}" ); then
        printf "\n  ${CLR_BOLD_GREEN}[  OK  ]${CLR_RESET} Nexus configurado → ${CLR_BOLD_CYAN}http://${nexus_input}${CLR_RESET}\n"
        printf "  ${CLR_DIM}Las opciones [2] [3] [5] usarán este registro automáticamente.${CLR_RESET}\n\n"
    else
        log_warn "No se pudo guardar el registro Nexus en el state — se usará solo en esta sesión"
        export NEXUS_REGISTRY="${nexus_input}"
    fi
}

# ---------------------------------------------------------------------------
# Module runner
# ---------------------------------------------------------------------------
_run_module() {
    local module="${1}"
    local script=""

    case "${module}" in
        1|registry)       script="${SUITE_ROOT}/modules/01_registry.sh" ;;
        2|containerd)     script="${SUITE_ROOT}/modules/02_containerd.sh" ;;
        3|master)         script="${SUITE_ROOT}/modules/03_k8s_master.sh" ;;
        4|worker)         script="${SUITE_ROOT}/modules/04_k8s_worker.sh" ;;
        5|info)           script="${SUITE_ROOT}/modules/05_cluster_info.sh" ;;
        6|monitoring)     script="${SUITE_ROOT}/stack/deploy_monitoring.sh" ;;
        7|kong)           script="${SUITE_ROOT}/stack/deploy_kong.sh" ;;
        8|redis)          script="${SUITE_ROOT}/stack/deploy_redis.sh" ;;
        *)
            log_error "Unknown module: ${module}"
            return 1
            ;;
    esac

    if [[ ! -f "${script}" ]]; then
        log_error "Module script not found: ${script}"
        log_error "Ensure the full suite is installed correctly."
        pause
        return 1
    fi

    if [[ ! -x "${script}" ]]; then
        log_warn "Making script executable: ${script}"
        chmod +x "${script}"
    fi

    log_debug "Running module: ${script}"
    bash "${script}"
    return $?
}

# ---------------------------------------------------------------------------
# Main Menu UI
# ---------------------------------------------------------------------------

_print_menu_header() {
    clear
    printf "${CLR_BOLD_CYAN}"
    cat << 'BANNER'
  ██╗  ██╗██╗   ██╗██████╗ ███████╗ ██████╗ ██████╗ ███████╗
  ██║ ██╔╝██║   ██║██╔══██╗██╔════╝██╔═══██╗██╔══██╗██╔════╝
  █████╔╝ ██║   ██║██████╔╝█████╗  ██║   ██║██████╔╝███████╗
  ██╔═██╗ ██║   ██║██╔══██╗██╔══╝  ██║   ██║██╔═══╝ ╚════██║
  ██║  ██╗╚██████╔╝██████╔╝███████╗╚██████╔╝██║     ███████║
  ╚═╝  ╚═╝ ╚═════╝ ╚═════╝ ╚══════╝ ╚═════╝ ╚═╝     ╚══════╝
BANNER
    printf "${CLR_RESET}"

    # Title bar
    printf "  ${CLR_BOLD_WHITE}Suite v%-8s${CLR_RESET}" "${KUBEOPS_VERSION}"
    printf "${CLR_DIM}Aprovisionamiento y Gestión de Kubernetes — Online / Air-Gapped${CLR_RESET}\n"
    printf "  ${CLR_DIM}%s${CLR_RESET}\n" "$(date '+%A, %d de %B de %Y  %H:%M:%S')"

    # System context bar
    printf "\n"
    local mode_color="${CLR_BOLD_GREEN}"
    local mode_label="● EN LÍNEA"
    if net_is_airgap 2>/dev/null; then
        mode_color="${CLR_BOLD_YELLOW}"
        mode_label="● AIR-GAPPED"
    fi

    local cluster_init="${CLR_BOLD_RED}NO INICIALIZADO"
    if state_is_cluster_initialized 2>/dev/null; then
        local master_ip
        master_ip=$(state_get ".join.control_plane_endpoint" 2>/dev/null || echo "desconocido")
        cluster_init="${CLR_BOLD_GREEN}INICIALIZADO  ${CLR_DIM}(${master_ip})${CLR_RESET}"
    fi

    # Disable pipefail locally so kubectl failure just returns 0, not N/A
    local node_count
    node_count=$(set +o pipefail; kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ') || node_count="N/A"
    [[ "${node_count}" == "0" && ! $(kubectl version --short 2>/dev/null) ]] && node_count="N/A"

    printf "  %-20s ${mode_color}%-16s${CLR_RESET}" "Red:" "${mode_label}"
    printf "  %-18s %b\n" "Clúster:" "${cluster_init}${CLR_RESET}"
    printf "  %-20s %-16s" "Servidor:" "$(hostname 2>/dev/null | cut -c1-16)"
    printf "  %-18s %s\n" "Nodos:" "${node_count}"
    printf "  %-20s %-16s" "IP Principal:" "$(net_get_primary_ip 2>/dev/null | cut -c1-16)"
    printf "  %-18s ${CLR_DIM}%s${CLR_RESET}\n" "Archivo de Estado:" "~/.kubeops/cluster-state.json"
}

_print_menu_separator() {
    printf "\n  ${CLR_BOLD_BLUE}"
    printf '%.0s─' {1..68}
    printf "${CLR_RESET}\n"
}

_print_menu_section() {
    local title="${1}"
    printf "\n  ${CLR_BOLD_WHITE}${title}${CLR_RESET}\n"
}

_print_menu_item() {
    local num="${1}"
    local icon="${2}"
    local title="${3}"
    local desc="${4}"
    local status="${5:-}"

    printf "  ${CLR_BOLD_CYAN}[%s]${CLR_RESET} %s %-35s" "${num}" "${icon}" "${title}"
    if [[ -n "${status}" ]]; then
        printf "%s" "${status}"
    else
        printf "${CLR_DIM}%s${CLR_RESET}" "${desc}"
    fi
    echo ""
}

_print_menu() {
    _print_menu_header
    _print_menu_separator

    # Infrastructure section
    _print_menu_section "  🏗  APROVISIONAMIENTO DE INFRAESTRUCTURA"

    _print_menu_item "1" "🏭" "Registro Local de Imágenes" \
        "Desplegar Docker Registry v2 (Air-Gap)"

    _print_menu_item "2" "⚙️ " "Instalar Runtime (containerd)" \
        "Instalar y configurar containerd + mirrors"

    _print_menu_item "3" "🎯" "Inicializar Nodo Máster" \
        "kubeadm init + Cilium CNI (Control Plane)"

    _print_menu_item "4" "🔀" "Agregar Nodo Máster (HA)" \
        "Unir Control Plane secundario (Alta Disponibilidad)"

    _print_menu_item "5" "💼" "Agregar Nodo Worker" \
        "Unir nodo trabajador al clúster"

    _print_menu_separator

    # Observability section
    _print_menu_section "  📊  OPERACIONES DEL CLÚSTER"

    _print_menu_item "6" "🔍" "Estado del Clúster y Tokens" \
        "Ver nodos, pods y comandos de unión"

    _print_menu_separator

    # Stack section
    _print_menu_section "  🚀  DESPLIEGUE DEL STACK DE ECOSISTEMA"

    _print_menu_item "7" "📈" "Stack de Observabilidad" \
        "Prometheus + Grafana + Alertmanager"

    _print_menu_item "8" "🦍" "API Gateway (Kong)" \
        "Kong Gateway + Ingress Controller"

    _print_menu_item "9" "🔴" "Caché Redis" \
        "Redis Standalone / Clúster vía Helm"

    _print_menu_separator

    # Utilities section
    _print_menu_section "  🔧  UTILIDADES"

    _print_menu_item "C" "🧹" "Limpieza Profunda del Sistema" \
        "Purgar k8s, containerd, docker y datos CNI"

    _print_menu_item "S" "💾" "Ver Estado del Clúster" \
        "Mostrar resumen JSON de estado"

    _print_menu_item "B" "🗂 " "Respaldo de Estado" \
        "Crear backup del archivo de estado"

    _print_menu_item "L" "📋" "Ver Registros (Logs)" \
        "Ver logs en tiempo real"

    _print_menu_item "R" "🔄" "Reiniciar Estado" \
        "Borrar estado guardado del clúster"

    _print_menu_item "Q" "🚪" "Salir" \
        "Salir de KubeOps-Suite"

    _print_menu_separator
    printf "\n  ${CLR_BOLD_WHITE}Seleccione una opción${CLR_RESET} › "
}

# ---------------------------------------------------------------------------
# Menu Action Handlers
# ---------------------------------------------------------------------------

_handle_add_ha_master() {
    log_banner
    log_section "Unir Nodo Máster Secundario (HA Control Plane)"

    # Preflight root check & OS
    os_detect || true
    net_detect_mode

    # Ensure containerd & k8s binaries installed
    if ! command -v kubeadm &>/dev/null; then
        log_info "Instalando binarios de Kubernetes en este máster secundario..."
        if net_is_online; then
            sudo install -m 0755 -d /etc/apt/keyrings 2>/dev/null || true
            curl -fsSL "https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key" | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg 2>/dev/null || true
            echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list > /dev/null
            sudo apt-get update -qq && sudo apt-get install -y kubelet kubeadm kubectl
        fi
    fi

    # Read credentials from local state if available, otherwise prompt
    local token ca_hash control_plane cert_key
    token=$(state_get ".join.token" 2>/dev/null || echo "")
    ca_hash=$(state_get ".join.ca_cert_hash" 2>/dev/null || echo "")
    control_plane=$(state_get ".join.control_plane_endpoint" 2>/dev/null || echo "")
    cert_key=$(state_get ".join.certificate_key" 2>/dev/null || echo "")

    if [[ -z "${control_plane}" || "${control_plane}" == "null" ]]; then
        printf "\n  ${CLR_BOLD_WHITE}Ingrese los datos del Máster Primario:${CLR_RESET}\n"
        printf "  IP del Máster Primario: "
        read -r control_plane
    fi

    if [[ -z "${token}" || "${token}" == "null" || "${token}" =~ "INFO" ]]; then
        printf "  Token de Unión (Token): "
        read -r token
    fi

    if [[ -z "${ca_hash}" || "${ca_hash}" == "null" ]]; then
        printf "  CA Cert Hash (sha256:...): "
        read -r ca_hash
        ca_hash="${ca_hash#sha256:}"
    fi

    if [[ -z "${cert_key}" || "${cert_key}" == "null" ]]; then
        printf "  Certificate Key (64 caracteres): "
        read -r cert_key
    fi

    if [[ -z "${control_plane}" || -z "${token}" || -z "${ca_hash}" || -z "${cert_key}" ]]; then
        log_error "Faltan parámetros requeridos para la unión del Máster HA."
        pause
        return 1
    fi

    log_info "Configurando módulos de kernel (overlay, br_netfilter) y sysctl para Kubernetes..."
    sudo modprobe overlay 2>/dev/null || true
    sudo modprobe br_netfilter 2>/dev/null || true
    sudo sysctl -w net.bridge.bridge-nf-call-iptables=1 2>/dev/null || true
    sudo sysctl -w net.bridge.bridge-nf-call-ip6tables=1 2>/dev/null || true
    sudo sysctl -w net.ipv4.ip_forward=1 2>/dev/null || true
    os_set_sysctl 2>/dev/null || true

    log_info "Verificando conectividad con el API Server (${control_plane}:6443)..."
    if ! curl -k --connect-timeout 5 "https://${control_plane}:6443/version" &>/dev/null; then
        log_warn "No se pudo conectar a https://${control_plane}:6443."
        log_warn "Asegúrese de que el Máster Primario tenga el API Server activo y que el puerto 6443/TCP esté permitido en el Security Group de AWS."
        if ! confirm "¿Desea intentar la unión de todas formas?"; then
            pause
            return 1
        fi
    else
        log_success "Conexión exitosa con el API Server (${control_plane}:6443)"
    fi

    log_info "Uniendo esta máquina como Control Plane Secundario a ${control_plane}:6443..."

    sudo fuser -k 6443/tcp 10259/tcp 10257/tcp 2379/tcp 2380/tcp 2>/dev/null || true

    log_info "Ejecutando kubeadm join directamente con la Certificate Key y Token de Control Plane..."
    if sudo kubeadm join "${control_plane}:6443" \
        --token "${token}" \
        --discovery-token-unsafe-skip-ca-verification \
        --control-plane \
        --certificate-key "${cert_key}" \
        --ignore-preflight-errors=Port-6443,Port-10259,Port-10257,FileContent--proc-sys-net-bridge-bridge-nf-call-iptables,FileContent--proc-sys-net-ipv4-ip_forward \
        --v=5; then

        log_success "¡Nodo Máster HA unido exitosamente al Control Plane!"

        # Auto-configure local resilience: update kubelet, controller-manager, scheduler & admin config to target local API server
        local local_ip
        local_ip=$(net_get_primary_ip)

        log_info "Configurando resiliencia HA automática en servicios locales de este Máster..."
        sudo sed -i "s|https://${control_plane}:6443|https://${local_ip}:6443|g" /etc/kubernetes/kubelet.conf 2>/dev/null || true
        sudo sed -i "s|https://${control_plane}:6443|https://${local_ip}:6443|g" /etc/kubernetes/controller-manager.conf 2>/dev/null || true
        sudo sed -i "s|https://${control_plane}:6443|https://${local_ip}:6443|g" /etc/kubernetes/scheduler.conf 2>/dev/null || true
        sudo sed -i "s|https://${control_plane}:6443|https://${local_ip}:6443|g" /etc/kubernetes/admin.conf 2>/dev/null || true

        sudo systemctl restart kubelet 2>/dev/null || true

        sudo mkdir -p /root/.kube
        sudo cp -f /etc/kubernetes/admin.conf /root/.kube/config 2>/dev/null || true
        sudo chmod 600 /root/.kube/config 2>/dev/null || true

        if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
            local u_home
            u_home=$(eval echo "~${SUDO_USER}")
            sudo mkdir -p "${u_home}/.kube"
            sudo cp -f /etc/kubernetes/admin.conf "${u_home}/.kube/config" 2>/dev/null || true
            sudo chown -R "${SUDO_USER}:${SUDO_USER}" "${u_home}/.kube" 2>/dev/null || true
            sudo chmod 600 "${u_home}/.kube/config" 2>/dev/null || true
        fi

        state_save_master "${local_ip}" "$(hostname)" "ha-replica"
        state_save_join_token "${token}" "${ca_hash}" "${cert_key}"
        state_set ".cluster.initialized" "true"
        state_set ".join.control_plane_endpoint" "${control_plane}"

        log_success "Servicios y kubeconfig configurados automáticamente con resiliencia HA en este Máster."
    else
        log_error "Falló la unión con kubeadm join."
    fi

    pause
}

_handle_show_logs() {
    local log_file="${KUBEOPS_LOG_DIR:-/var/log/kubeops}/kubeops-$(date +%Y%m%d).log"
    if [[ ! -f "${log_file}" ]]; then
        log_file="${HOME}/.kubeops/logs/kubeops-$(date +%Y%m%d).log"
    fi

    if [[ -f "${log_file}" ]]; then
        log_section "KubeOps Log (last 50 lines)"
        tail -50 "${log_file}"
    else
        log_warn "No log file found at: ${log_file}"
    fi
    pause
}

_handle_reset_state() {
    log_section "Reset Cluster State"
    log_warn "This will CLEAR all stored cluster data:"
    printf "  - Master IPs and join tokens\n"
    printf "  - Worker node records\n"
    printf "  - Registry configuration\n"
    printf "  - All deployment metadata\n\n"
    log_info "A backup will be created automatically before reset."

    if confirm "Confirm STATE RESET?"; then
        state_reset "false"
    else
        log_info "Reset cancelled"
    fi
    pause
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

_main_loop() {
    while true; do
        _print_menu

        local choice
        read -r choice

        case "${choice}" in
            1) _run_module "1" ;;
            2) _run_module "2" ;;
            3) _run_module "3" ;;
            4) _handle_add_ha_master ;;
            5) _run_module "4" ;;
            6) _run_module "5" ;;
            7) _run_module "6" ;;
            8) _run_module "7" ;;
            9) _run_module "8" ;;

            [cC])
                clear
                system_deep_cleanup
                pause ;;

            [sS])
                clear
                state_show
                pause ;;

            [bB])
                clear
                log_section "Backup State"
                local backup_path
                backup_path=$(state_backup)
                log_success "Backup created: ${backup_path}"
                pause ;;

            [lL])
                clear
                _handle_show_logs ;;

            [rR])
                clear
                _handle_reset_state ;;

            [qQ]|"exit"|"quit")
                clear
                log_banner
                printf "\n  ${CLR_BOLD_WHITE}Thank you for using KubeOps-Suite v%s${CLR_RESET}\n" "${KUBEOPS_VERSION}"
                printf "  ${CLR_DIM}Your cluster state is preserved at: %s${CLR_RESET}\n\n" \
                    "${KUBEOPS_STATE_FILE}"
                exit 0 ;;

            "")
                # Empty input — just redraw
                continue ;;

            *)
                printf "\n  ${CLR_BOLD_RED}Invalid option: '%s'${CLR_RESET}  — Enter a number [1-9] or [S/B/L/R/Q]\n" "${choice}"
                sleep 1.5
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Non-interactive direct-run mode
# ---------------------------------------------------------------------------
_direct_run() {
    local module="${1}"
    log_banner
    log_info "Direct run mode: ${module}"

    case "${module}" in
        registry)    _run_module "1" ;;
        containerd)  _run_module "2" ;;
        master)      _run_module "3" ;;
        worker)      _run_module "5" ;;
        info)        _run_module "6" ;;
        monitoring)  _run_module "7" ;;
        kong)        _run_module "8" ;;
        redis)       _run_module "9" ;;
        state)
            state_show
            ;;
        *)
            log_error "Unknown module: ${module}"
            log_info "Available: registry, containerd, master, worker, info, monitoring, kong, redis, state"
            exit 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Main entrypoint
# ---------------------------------------------------------------------------

# _bootstrap_deps: installs jq and curl if missing (required before state_init)
_bootstrap_deps() {
    local missing=()
    command -v jq   &>/dev/null || missing+=("jq")
    command -v curl &>/dev/null || missing+=("curl")

    if [[ ${#missing[@]} -eq 0 ]]; then
        return 0
    fi

    printf "${CLR_BOLD_YELLOW}[SETUP ]${CLR_RESET} Installing missing dependencies: %s\n" "${missing[*]}"

    # Detect package manager without full os_detect (which needs logger)
    if command -v apt-get &>/dev/null; then
        apt-get update -qq 2>/dev/null || true
        apt-get install -y --no-install-recommends "${missing[@]}" 2>/dev/null
    elif command -v dnf &>/dev/null; then
        dnf install -y "${missing[@]}" 2>/dev/null
    elif command -v yum &>/dev/null; then
        yum install -y "${missing[@]}" 2>/dev/null
    else
        printf "${CLR_BOLD_RED}[ERROR ]${CLR_RESET} Cannot install %s — no supported package manager found.\n" "${missing[*]}" >&2
        printf "  Install manually: apt-get install -y jq curl\n" >&2
        exit 1
    fi

    # Verify install succeeded
    for pkg in "${missing[@]}"; do
        if ! command -v "${pkg}" &>/dev/null; then
            printf "${CLR_BOLD_RED}[ERROR ]${CLR_RESET} Failed to install '%s'. Install manually and retry.\n" "${pkg}" >&2
            exit 1
        fi
    done

    printf "${CLR_BOLD_GREEN}[  OK  ]${CLR_RESET} Dependencies installed: %s\n" "${missing[*]}"
}

main() {
    # Verify bash version
    _check_bash_version

    # Print a startup marker so user knows the script launched
    printf "${CLR_BOLD_CYAN}[KubeOps]${CLR_RESET} v${KUBEOPS_VERSION} starting...\n"

    # Parse arguments
    KUBEOPS_DIRECT_RUN=""
    _parse_args "$@"

    # Ensure jq + curl are available BEFORE anything that depends on them
    # Run as root only (state_init requires jq)
    if [[ "${EUID}" -eq 0 ]]; then
        _bootstrap_deps
    else
        _check_dependencies
    fi

    # Initialize state file — run in subshell so that any exit() inside
    # (e.g. from log_fatal) does not kill the parent process silently.
    if ! ( _state_init ); then
        printf "${CLR_BOLD_YELLOW}[ WARN ]${CLR_RESET} State file init failed — continuing without persistent state.\n" >&2
    fi

    # Pre-detect network mode (cached for session)
    if ! ( net_detect_mode ); then
        printf "${CLR_BOLD_YELLOW}[ WARN ]${CLR_RESET} Network detection failed — defaulting to ONLINE mode.\n" >&2
        export KUBEOPS_NETWORK_MODE="online"
    fi

    # Load Nexus registry from state (if already configured from a previous run)
    ( state_load_nexus_env ) 2>/dev/null || true

    # If offline/air-gap mode: prompt for Nexus registry (interactive only)
    if [[ -t 0 ]]; then
        _prompt_nexus_if_needed
    fi

    # Direct run mode (non-interactive)
    if [[ -n "${KUBEOPS_DIRECT_RUN:-}" ]]; then
        _direct_run "${KUBEOPS_DIRECT_RUN}"
        exit $?
    fi

    # Interactive mode — check TTY
    if [[ ! -t 0 ]]; then
        log_error "No interactive terminal detected."
        log_error "For non-interactive use: ./kubeops.sh --run <module>"
        log_error "For help: ./kubeops.sh --help"
        exit 1
    fi

    # Start main menu loop
    _main_loop
}

# Trap for clean exit
trap 'echo -e "\n\n  ${CLR_BOLD_YELLOW}Interrupted. State preserved at: ${KUBEOPS_STATE_FILE:-~/.kubeops/cluster-state.json}${CLR_RESET}\n"; exit 130' INT TERM

main "$@"
