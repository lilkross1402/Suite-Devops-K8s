#!/usr/bin/env bash
# =============================================================================
# KubeOps-Suite :: lib/logger.sh
# Purpose : Centralized logging with ANSI colors, log levels, and file output
# Author  : KubeOps-Suite (Principal Platform Engineer)
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# ANSI Color Palette
# ---------------------------------------------------------------------------
readonly CLR_RESET='\033[0m'
readonly CLR_BOLD='\033[1m'
readonly CLR_DIM='\033[2m'

readonly CLR_RED='\033[0;31m'
readonly CLR_GREEN='\033[0;32m'
readonly CLR_YELLOW='\033[0;33m'
readonly CLR_BLUE='\033[0;34m'
readonly CLR_MAGENTA='\033[0;35m'
readonly CLR_CYAN='\033[0;36m'
readonly CLR_WHITE='\033[0;37m'

readonly CLR_BOLD_RED='\033[1;31m'
readonly CLR_BOLD_GREEN='\033[1;32m'
readonly CLR_BOLD_YELLOW='\033[1;33m'
readonly CLR_BOLD_BLUE='\033[1;34m'
readonly CLR_BOLD_CYAN='\033[1;36m'
readonly CLR_BOLD_WHITE='\033[1;37m'

# Background colors
readonly BG_RED='\033[41m'
readonly BG_GREEN='\033[42m'
readonly BG_YELLOW='\033[43m'
readonly BG_BLUE='\033[44m'

# ---------------------------------------------------------------------------
# Log Configuration
# ---------------------------------------------------------------------------
KUBEOPS_LOG_DIR="${KUBEOPS_LOG_DIR:-/var/log/kubeops}"
KUBEOPS_LOG_FILE="${KUBEOPS_LOG_FILE:-${KUBEOPS_LOG_DIR}/kubeops-$(date +%Y%m%d).log}"
KUBEOPS_LOG_LEVEL="${KUBEOPS_LOG_LEVEL:-INFO}"  # DEBUG | INFO | WARN | ERROR
KUBEOPS_NO_COLOR="${KUBEOPS_NO_COLOR:-false}"

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# _log_init: ensure log directory exists
_log_init() {
    if [[ ! -d "${KUBEOPS_LOG_DIR}" ]]; then
        mkdir -p "${KUBEOPS_LOG_DIR}" 2>/dev/null || {
            # Fallback to home directory if /var/log is not writable
            KUBEOPS_LOG_DIR="${HOME}/.kubeops/logs"
            KUBEOPS_LOG_FILE="${KUBEOPS_LOG_DIR}/kubeops-$(date +%Y%m%d).log"
            mkdir -p "${KUBEOPS_LOG_DIR}"
        }
    fi
}

# _log_level_num LEVEL: returns numeric priority for a log level string
_log_level_num() {
    case "${1:-INFO}" in
        DEBUG) echo 0 ;;
        INFO)  echo 1 ;;
        WARN)  echo 2 ;;
        ERROR) echo 3 ;;
        *)     echo 1 ;;
    esac
}

# _should_log LEVEL: returns 0 if the given level should be emitted
_should_log() {
    local level="${1}"
    local current_num requested_num
    current_num=$(_log_level_num "${KUBEOPS_LOG_LEVEL:-INFO}")
    requested_num=$(_log_level_num "${level}")
    [[ "${requested_num}" -ge "${current_num}" ]]
}

# _colorize COLOR TEXT: returns colored text unless KUBEOPS_NO_COLOR=true
_colorize() {
    local color="${1}"
    local text="${2}"
    if [[ "${KUBEOPS_NO_COLOR}" == "true" ]]; then
        echo -n "${text}"
    else
        echo -ne "${color}${text}${CLR_RESET}"
    fi
}

# _timestamp: returns current ISO-8601 timestamp
_timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

# _write_log LEVEL MESSAGE: write structured log line to file
_write_log() {
    local level="${1}"
    local message="${2}"
    _log_init
    echo "[${level}] $(_timestamp) :: ${message}" >> "${KUBEOPS_LOG_FILE}" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Public Logging Functions
# ---------------------------------------------------------------------------

# log_debug MESSAGE
log_debug() {
    _should_log "DEBUG" || return 0
    local msg="${*}"
    _write_log "DEBUG" "${msg}"
    printf "[${CLR_DIM}DEBUG${CLR_RESET}] ${CLR_DIM}%b${CLR_RESET}\n" "${msg}" >&2
}

# log_info MESSAGE
log_info() {
    _should_log "INFO" || return 0
    local msg="${*}"
    _write_log "INFO" "${msg}"
    printf "${CLR_BOLD_BLUE}[INFO]${CLR_RESET}  %b\n" "${msg}"
}

# log_success MESSAGE
log_success() {
    local msg="${*}"
    _write_log "INFO" "[SUCCESS] ${msg}"
    printf "${CLR_BOLD_GREEN}[  OK  ]${CLR_RESET} %b\n" "${msg}"
}

# log_warn MESSAGE
log_warn() {
    _should_log "WARN" || return 0
    local msg="${*}"
    _write_log "WARN" "${msg}"
    printf "${CLR_BOLD_YELLOW}[ WARN ]${CLR_RESET} %b\n" "${msg}" >&2
}

# log_error MESSAGE
log_error() {
    local msg="${*}"
    _write_log "ERROR" "${msg}"
    printf "${CLR_BOLD_RED}[ERROR ]${CLR_RESET} %b\n" "${msg}" >&2
}

# log_fatal MESSAGE [EXIT_CODE]
log_fatal() {
    local msg="${1}"
    local exit_code="${2:-1}"
    _write_log "ERROR" "[FATAL] ${msg}"
    printf "\n${BG_RED}${CLR_BOLD_WHITE} FATAL ${CLR_RESET} %b\n\n" "${msg}" >&2
    exit "${exit_code}"
}

# log_step STEP_NUM TOTAL_STEPS MESSAGE
log_step() {
    local step="${1}"
    local total="${2}"
    local msg="${3}"
    _write_log "INFO" "Step ${step}/${total}: ${msg}"
    printf "\n${CLR_BOLD_CYAN}━━━ Step [%s/%s] ━━━${CLR_RESET} %b\n" "${step}" "${total}" "${msg}"
}

# log_section TITLE: prints a visual section header
log_section() {
    local title="${*}"
    local width=70
    local line
    line=$(printf '%.0s─' $(seq 1 ${width}))
    echo ""
    printf "${CLR_BOLD_BLUE}${line}${CLR_RESET}\n"
    printf "${CLR_BOLD_BLUE}  %-${width}s${CLR_RESET}\n" "${title}"
    printf "${CLR_BOLD_BLUE}${line}${CLR_RESET}\n"
    _write_log "INFO" "=== ${title} ==="
}

# log_cmd COMMAND: logs a command before executing it
log_cmd() {
    log_debug "Executing: $*"
    "$@"
}

# log_banner: prints the KubeOps-Suite ASCII banner
log_banner() {
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
    printf "${CLR_BOLD_WHITE}  Suite :: Principal Platform Automation v1.0.0${CLR_RESET}\n"
    printf "${CLR_DIM}  Kubernetes Provisioning & Management — Online / Air-Gapped${CLR_RESET}\n\n"
}

# log_progress_bar CURRENT TOTAL LABEL
log_progress_bar() {
    local current="${1}"
    local total="${2}"
    local label="${3:-Progress}"
    local bar_width=40
    local filled=$(( (current * bar_width) / total ))
    local empty=$(( bar_width - filled ))
    local pct=$(( (current * 100) / total ))
    local bar
    bar=$(printf '█%.0s' $(seq 1 ${filled}))
    local space
    space=$(printf '░%.0s' $(seq 1 ${empty}))
    printf "\r${CLR_CYAN}%s ${CLR_RESET}[${CLR_GREEN}%s${CLR_DIM}%s${CLR_RESET}] ${CLR_BOLD_WHITE}%3d%%${CLR_RESET}" \
        "${label}" "${bar}" "${space}" "${pct}"
    if [[ "${current}" -ge "${total}" ]]; then
        echo ""
    fi
}

# spinner_start MESSAGE: starts a background spinner, returns PID in SPINNER_PID
spinner_start() {
    local message="${1:-Processing...}"
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    (
        local i=0
        while true; do
            printf "\r${CLR_CYAN}%s${CLR_RESET} %s" "${frames[$((i % ${#frames[@]}))]}" "${message}"
            sleep 0.1
            (( i++ )) || true
        done
    ) &
    export SPINNER_PID=$!
    disown "${SPINNER_PID}" 2>/dev/null || true
}

# spinner_stop [SUCCESS_MSG]: stops the spinner started by spinner_start
spinner_stop() {
    local msg="${1:-Done}"
    local success="${2:-true}"
    if [[ -n "${SPINNER_PID:-}" ]]; then
        kill "${SPINNER_PID}" 2>/dev/null || true
        wait "${SPINNER_PID}" 2>/dev/null || true
        unset SPINNER_PID
    fi
    printf "\r\033[K"  # clear line
    if [[ "${success}" == "true" ]]; then
        log_success "${msg}"
    else
        log_error "${msg}"
    fi
}

# confirm PROMPT: asks yes/no question, returns 0 on yes
confirm() {
    local prompt="${1:-Are you sure?}"
    local response
    printf "${CLR_BOLD_YELLOW}%s ${CLR_RESET}[${CLR_BOLD_GREEN}y${CLR_RESET}/${CLR_BOLD_RED}N${CLR_RESET}]: " "${prompt}"
    read -r response
    case "${response}" in
        [yY][eE][sS]|[yY]) return 0 ;;
        *) return 1 ;;
    esac
}

# pause: wait for user to press Enter
pause() {
    local msg="${1:-Press [Enter] to continue...}"
    printf "\n${CLR_DIM}%s${CLR_RESET}" "${msg}"
    read -r _
}
