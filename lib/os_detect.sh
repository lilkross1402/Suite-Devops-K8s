#!/usr/bin/env bash
# =============================================================================
# KubeOps-Suite :: lib/os_detect.sh
# Purpose : Detect the host operating system, configure the appropriate
#           package manager (apt/dnf/yum), and ensure baseline dependencies
#           (curl, tar, jq, git, openssl) are installed.
# Exports : PKG_MANAGER, PKG_INSTALL, PKG_UPDATE, OS_ID, OS_VERSION,
#           OS_FAMILY, OS_CODENAME, ARCH
# Author  : KubeOps-Suite (Principal Platform Engineer)
# =============================================================================
set -euo pipefail

# Ensure logger is available
if ! declare -f log_info &>/dev/null; then
    # shellcheck source=lib/logger.sh
    source "$(dirname "${BASH_SOURCE[0]}")/logger.sh"
fi

# ---------------------------------------------------------------------------
# Exported global variables (populated by os_detect)
# ---------------------------------------------------------------------------
OS_ID=""           # e.g., ubuntu, debian, rhel, rocky, centos, fedora
OS_VERSION=""      # e.g., 22.04, 9.2
OS_CODENAME=""     # e.g., jammy, focal  (Debian-based only)
OS_FAMILY=""       # "debian" | "rhel" | "unknown"
OS_PRETTY=""       # Full pretty name from /etc/os-release
ARCH=""            # x86_64 | aarch64 | arm64

PKG_MANAGER=""     # apt | dnf | yum
PKG_INSTALL=""     # e.g., "apt-get install -y"
PKG_UPDATE=""      # e.g., "apt-get update -qq"
PKG_REMOVE=""      # e.g., "apt-get remove -y"
PKG_QUERY=""       # Command to check if a package is installed
PKG_CLEAN=""       # Cache clean command

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
readonly OS_RELEASE_FILE="/etc/os-release"

# Minimum required dependencies for KubeOps-Suite operation
readonly REQUIRED_PKGS=(
    curl
    tar
    jq
    git
    openssl
    ca-certificates
    gnupg
    lsb-release
)

# Debian-family package name overrides
declare -A PKG_ALIASES_DEBIAN=(
    [lsb-release]="lsb-release"
    [openssl]="openssl"
)

# RHEL-family package name overrides
declare -A PKG_ALIASES_RHEL=(
    [lsb-release]="redhat-lsb-core"
    [ca-certificates]="ca-certificates"
)

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# _read_os_release: parse /etc/os-release into global vars
_read_os_release() {
    if [[ ! -f "${OS_RELEASE_FILE}" ]]; then
        log_error "/etc/os-release not found — cannot detect OS"
        return 1
    fi

    # Source the file safely by extracting known keys
    while IFS='=' read -r key value; do
        value="${value%\"}"   # strip trailing quote
        value="${value#\"}"   # strip leading quote
        case "${key}" in
            ID)               OS_ID="${value,,}" ;;       # lowercase
            VERSION_ID)       OS_VERSION="${value}" ;;
            VERSION_CODENAME) OS_CODENAME="${value}" ;;
            PRETTY_NAME)      OS_PRETTY="${value}" ;;
        esac
    done < "${OS_RELEASE_FILE}"

    # Some distros don't set VERSION_CODENAME — try to derive it
    if [[ -z "${OS_CODENAME}" ]] && command -v lsb_release &>/dev/null; then
        OS_CODENAME=$(lsb_release -cs 2>/dev/null || echo "")
    fi

    export OS_ID OS_VERSION OS_CODENAME OS_PRETTY
}

# _set_pkg_manager: configure package manager based on OS_FAMILY
_set_pkg_manager() {
    case "${OS_FAMILY}" in
        debian)
            if command -v apt-get &>/dev/null; then
                PKG_MANAGER="apt-get"
            else
                log_fatal "apt-get not found on Debian-family system"
            fi
            PKG_INSTALL="${PKG_MANAGER} install -y --no-install-recommends"
            PKG_UPDATE="${PKG_MANAGER} update -qq"
            PKG_REMOVE="${PKG_MANAGER} remove -y"
            PKG_CLEAN="${PKG_MANAGER} clean && rm -rf /var/lib/apt/lists/*"
            PKG_QUERY="dpkg -s"
            ;;
        rhel)
            if command -v dnf &>/dev/null; then
                PKG_MANAGER="dnf"
            elif command -v yum &>/dev/null; then
                PKG_MANAGER="yum"
            else
                log_fatal "Neither dnf nor yum found on RHEL-family system"
            fi
            PKG_INSTALL="${PKG_MANAGER} install -y"
            PKG_UPDATE="${PKG_MANAGER} makecache -q"
            PKG_REMOVE="${PKG_MANAGER} remove -y"
            PKG_CLEAN="${PKG_MANAGER} clean all"
            PKG_QUERY="rpm -q"
            ;;
        *)
            log_error "Unsupported OS family '${OS_FAMILY}'. Manual configuration required."
            return 1
            ;;
    esac

    export PKG_MANAGER PKG_INSTALL PKG_UPDATE PKG_REMOVE PKG_CLEAN PKG_QUERY
}

# _resolve_pkg_name PKG: resolves a package name to the distro-specific name
_resolve_pkg_name() {
    local pkg="${1}"
    if [[ "${OS_FAMILY}" == "rhel" ]] && [[ -n "${PKG_ALIASES_RHEL[${pkg}]+set}" ]]; then
        echo "${PKG_ALIASES_RHEL[${pkg}]}"
    elif [[ "${OS_FAMILY}" == "debian" ]] && [[ -n "${PKG_ALIASES_DEBIAN[${pkg}]+set}" ]]; then
        echo "${PKG_ALIASES_DEBIAN[${pkg}]}"
    else
        echo "${pkg}"
    fi
}

# ---------------------------------------------------------------------------
# Public Functions
# ---------------------------------------------------------------------------

# os_detect: Main detection routine — sets all exported variables
os_detect() {
    log_info "Detecting host operating system..."

    # Architecture
    ARCH=$(uname -m)
    export ARCH
    log_debug "Architecture: ${ARCH}"

    # Kernel
    local kernel
    kernel=$(uname -r)
    log_debug "Kernel: ${kernel}"

    # Parse /etc/os-release
    _read_os_release

    # Determine OS family
    case "${OS_ID}" in
        ubuntu|debian|raspbian|linuxmint|pop)
            OS_FAMILY="debian"
            ;;
        rhel|centos|rocky|almalinux|fedora|amzn|ol)
            OS_FAMILY="rhel"
            ;;
        *)
            # Try ID_LIKE field as fallback
            local id_like=""
            if [[ -f "${OS_RELEASE_FILE}" ]]; then
                id_like=$(grep '^ID_LIKE=' "${OS_RELEASE_FILE}" | cut -d'=' -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]')
            fi
            if echo "${id_like}" | grep -qE "debian|ubuntu"; then
                OS_FAMILY="debian"
            elif echo "${id_like}" | grep -qE "rhel|fedora|centos"; then
                OS_FAMILY="rhel"
            else
                OS_FAMILY="unknown"
                log_warn "Unknown OS: ${OS_ID}. Attempting to auto-detect package manager."
                if command -v apt-get &>/dev/null; then
                    OS_FAMILY="debian"
                elif command -v dnf &>/dev/null || command -v yum &>/dev/null; then
                    OS_FAMILY="rhel"
                fi
            fi
            ;;
    esac

    export OS_FAMILY

    # Configure package manager
    _set_pkg_manager

    log_success "OS detected: ${CLR_BOLD_WHITE}${OS_PRETTY:-${OS_ID} ${OS_VERSION}}${CLR_RESET} (${OS_FAMILY}-family)"
    log_info "Package manager: ${CLR_BOLD_CYAN}${PKG_MANAGER}${CLR_RESET} | Architecture: ${CLR_BOLD_CYAN}${ARCH}${CLR_RESET}"

    return 0
}

# os_check_root: verifies the script is running as root (or sudo)
os_check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        log_fatal "This operation requires root privileges. Please run with sudo or as root." 2
    fi
    log_debug "Running as root: OK"
}

# os_check_root_or_warn: warns but does not exit
os_check_root_or_warn() {
    if [[ "${EUID}" -ne 0 ]]; then
        log_warn "Not running as root. Some operations may fail."
        return 1
    fi
    return 0
}

# os_pkg_installed PKG_NAME: returns 0 if the package is installed
os_pkg_installed() {
    local pkg="${1}"
    case "${OS_FAMILY}" in
        debian) dpkg -s "${pkg}" &>/dev/null ;;
        rhel)   rpm -q "${pkg}" &>/dev/null ;;
        *)      command -v "${pkg}" &>/dev/null ;;
    esac
}

# os_pkg_binary_exists BINARY: returns 0 if the binary exists in PATH
os_pkg_binary_exists() {
    command -v "${1}" &>/dev/null
}

# os_update_pkg_cache: runs package manager update/makecache
os_update_pkg_cache() {
    log_info "Updating package cache..."
    # shellcheck disable=SC2086
    if ! eval "sudo ${PKG_UPDATE}" &>/dev/null; then
        log_warn "Package cache update had warnings (continuing)"
    else
        log_success "Package cache updated"
    fi
}

# os_install_pkg PKG...: installs one or more packages
os_install_pkg() {
    local packages=("$@")
    if [[ ${#packages[@]} -eq 0 ]]; then
        log_warn "os_install_pkg called with no packages"
        return 0
    fi

    log_info "Installing: ${packages[*]}"
    # shellcheck disable=SC2086
    if sudo ${PKG_INSTALL} "${packages[@]}"; then
        log_success "Installed: ${packages[*]}"
        return 0
    else
        log_error "Failed to install: ${packages[*]}"
        return 1
    fi
}

# os_ensure_dependencies: installs REQUIRED_PKGS if not already present
os_ensure_dependencies() {
    log_section "Dependency Check"

    local missing=()
    for pkg in "${REQUIRED_PKGS[@]}"; do
        local resolved
        resolved=$(_resolve_pkg_name "${pkg}")
        if os_pkg_installed "${resolved}"; then
            log_debug "Already installed: ${resolved}"
        else
            # Also check if the binary exists
            if os_pkg_binary_exists "${pkg}"; then
                log_debug "Binary found in PATH: ${pkg}"
            else
                log_warn "Missing: ${resolved}"
                missing+=("${resolved}")
            fi
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        log_success "All baseline dependencies are satisfied"
        return 0
    fi

    log_info "Installing ${#missing[@]} missing package(s): ${missing[*]}"
    os_update_pkg_cache
    os_install_pkg "${missing[@]}"
    log_success "Dependency installation complete"
}

# os_add_apt_key URL KEYRING_PATH: adds a signed apt repository key
os_add_apt_key() {
    local url="${1}"
    local keyring="${2}"
    if [[ "${OS_FAMILY}" != "debian" ]]; then
        log_warn "os_add_apt_key is only applicable for Debian-family systems"
        return 1
    fi
    log_info "Adding apt key: ${url} → ${keyring}"
    curl -fsSL "${url}" | sudo gpg --dearmor -o "${keyring}"
    sudo chmod 644 "${keyring}"
    log_success "Key added: ${keyring}"
}

# os_add_apt_repo REPO_LINE LIST_FILE KEYRING_PATH: adds apt repository
os_add_apt_repo() {
    local repo_line="${1}"
    local list_file="${2}"
    local keyring="${3}"
    log_info "Adding apt repository: ${list_file}"
    echo "${repo_line}" | sudo tee "${list_file}" > /dev/null
    log_success "Repository added: ${list_file}"
}

# os_add_dnf_repo URL REPO_NAME: adds a DNF/YUM repository
os_add_dnf_repo() {
    local url="${1}"
    local repo_name="${2}"
    if [[ "${OS_FAMILY}" != "rhel" ]]; then
        log_warn "os_add_dnf_repo is only applicable for RHEL-family systems"
        return 1
    fi
    log_info "Adding DNF repo: ${repo_name}"
    sudo "${PKG_MANAGER}" config-manager --add-repo "${url}" 2>/dev/null || \
    sudo "${PKG_MANAGER}" install -y "${url}" 2>/dev/null || {
        log_error "Failed to add DNF repo: ${url}"
        return 1
    }
    log_success "DNF repo added: ${repo_name}"
}

# os_disable_swap: disables swap (required for Kubernetes)
os_disable_swap() {
    log_info "Disabling swap..."
    if swapon --show 2>/dev/null | grep -q .; then
        sudo swapoff -a
        # Remove swap entries from /etc/fstab
        sudo sed -i.bak '/\bswap\b/d' /etc/fstab
        log_success "Swap disabled and removed from /etc/fstab"
    else
        log_info "Swap is already disabled"
    fi
}

# os_set_sysctl PARAMS: applies kernel parameters for Kubernetes
os_set_sysctl() {
    log_info "Configuring kernel parameters for Kubernetes..."
    local sysctl_conf="/etc/sysctl.d/99-kubeops-k8s.conf"

    sudo tee "${sysctl_conf}" > /dev/null <<'EOF'
# KubeOps-Suite :: Kubernetes kernel parameters
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
net.ipv4.conf.all.rp_filter         = 0
net.ipv4.conf.default.rp_filter     = 0
fs.inotify.max_user_instances       = 8192
fs.inotify.max_user_watches         = 524288
vm.overcommit_memory                = 1
vm.panic_on_oom                     = 0
kernel.panic                        = 10
kernel.panic_on_oops                = 1
EOF

    # Load br_netfilter module
    sudo modprobe br_netfilter 2>/dev/null || log_warn "Could not load br_netfilter module"
    sudo modprobe overlay 2>/dev/null || log_warn "Could not load overlay module"

    # Persist modules
    sudo tee /etc/modules-load.d/kubeops-k8s.conf > /dev/null <<'EOF'
br_netfilter
overlay
EOF

    # Apply sysctl
    sudo sysctl --system -q
    log_success "Kernel parameters applied: ${sysctl_conf}"
}

# os_configure_firewall_k8s: opens Kubernetes required ports
os_configure_firewall_k8s() {
    local role="${1:-master}"  # master | worker
    log_info "Configuring firewall for Kubernetes role: ${role}"

    if command -v ufw &>/dev/null; then
        # UFW (Ubuntu/Debian)
        if [[ "${role}" == "master" ]]; then
            sudo ufw allow 6443/tcp comment "K8s API Server"    2>/dev/null || true
            sudo ufw allow 2379:2380/tcp comment "etcd"          2>/dev/null || true
            sudo ufw allow 10250/tcp comment "kubelet API"       2>/dev/null || true
            sudo ufw allow 10251/tcp comment "kube-scheduler"    2>/dev/null || true
            sudo ufw allow 10252/tcp comment "kube-controller"   2>/dev/null || true
            sudo ufw allow 10255/tcp comment "kubelet read-only" 2>/dev/null || true
        else
            sudo ufw allow 10250/tcp comment "kubelet API"       2>/dev/null || true
            sudo ufw allow 30000:32767/tcp comment "NodePort"    2>/dev/null || true
        fi
        sudo ufw allow 8472/udp comment "Flannel VXLAN"         2>/dev/null || true
        sudo ufw allow 179/tcp comment "Calico BGP"              2>/dev/null || true
        log_success "UFW rules configured for Kubernetes ${role}"

    elif command -v firewall-cmd &>/dev/null; then
        # firewalld (RHEL/Rocky)
        if [[ "${role}" == "master" ]]; then
            sudo firewall-cmd --permanent --add-port=6443/tcp 2>/dev/null || true
            sudo firewall-cmd --permanent --add-port=2379-2380/tcp 2>/dev/null || true
            sudo firewall-cmd --permanent --add-port=10250-10252/tcp 2>/dev/null || true
        else
            sudo firewall-cmd --permanent --add-port=10250/tcp 2>/dev/null || true
            sudo firewall-cmd --permanent --add-port=30000-32767/tcp 2>/dev/null || true
        fi
        sudo firewall-cmd --permanent --add-port=8472/udp 2>/dev/null || true
        sudo firewall-cmd --permanent --add-masquerade 2>/dev/null || true
        sudo firewall-cmd --reload 2>/dev/null || true
        log_success "firewalld rules configured for Kubernetes ${role}"
    else
        log_warn "No supported firewall found (ufw/firewalld). Skipping firewall configuration."
    fi
}

# os_show_info: prints a formatted OS information table
os_show_info() {
    log_section "System Information"
    printf "  %-25s %s\n" "OS:"          "${OS_PRETTY:-Unknown}"
    printf "  %-25s %s\n" "OS ID:"       "${OS_ID:-Unknown}"
    printf "  %-25s %s\n" "OS Version:"  "${OS_VERSION:-Unknown}"
    printf "  %-25s %s\n" "OS Family:"   "${OS_FAMILY:-Unknown}"
    if [[ -n "${OS_CODENAME}" ]]; then
        printf "  %-25s %s\n" "Codename:"    "${OS_CODENAME}"
    fi
    printf "  %-25s %s\n" "Architecture:" "${ARCH:-$(uname -m)}"
    printf "  %-25s %s\n" "Package Mgr:" "${PKG_MANAGER:-Unknown}"
    printf "  %-25s %s\n" "Kernel:"      "$(uname -r)"
    printf "  %-25s %s\n" "Hostname:"    "$(hostname -f 2>/dev/null || hostname)"
    local ram_mb
    ram_mb=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo "N/A")
    printf "  %-25s %s MB\n" "Total RAM:"   "${ram_mb}"
    local cpu_cores
    cpu_cores=$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo "N/A")
    printf "  %-25s %s\n" "CPU Cores:"   "${cpu_cores}"
    local disk_info
    disk_info=$(df -h / 2>/dev/null | awk 'NR==2{printf "%s used / %s total", $3, $2}' || echo "N/A")
    printf "  %-25s %s\n" "Disk (/):"    "${disk_info}"
    echo ""
}

# os_check_requirements MIN_RAM_MB MIN_CPU MIN_DISK_GB
os_check_requirements() {
    local min_ram="${1:-2048}"      # MB
    local min_cpu="${2:-2}"
    local min_disk="${3:-20}"       # GB

    log_info "Checking system requirements (RAM: ${min_ram}MB, CPU: ${min_cpu}, Disk: ${min_disk}GB)..."
    local errors=0

    # RAM check
    local ram_mb
    ram_mb=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo "0")
    if [[ "${ram_mb}" -lt "${min_ram}" ]]; then
        log_warn "RAM: ${ram_mb}MB (minimum: ${min_ram}MB)"
        (( errors++ )) || true
    else
        log_success "RAM: ${ram_mb}MB ✓"
    fi

    # CPU check
    local cpu_cores
    cpu_cores=$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo "0")
    if [[ "${cpu_cores}" -lt "${min_cpu}" ]]; then
        log_warn "CPU cores: ${cpu_cores} (minimum: ${min_cpu})"
        (( errors++ )) || true
    else
        log_success "CPU cores: ${cpu_cores} ✓"
    fi

    # Disk check
    local disk_gb
    disk_gb=$(df -BG / 2>/dev/null | awk 'NR==2{gsub(/G/,"",$4); print $4}' || echo "0")
    if [[ "${disk_gb}" -lt "${min_disk}" ]]; then
        log_warn "Disk space: ${disk_gb}GB free (minimum: ${min_disk}GB)"
        (( errors++ )) || true
    else
        log_success "Disk space: ${disk_gb}GB free ✓"
    fi

    if [[ "${errors}" -gt 0 ]]; then
        log_warn "${errors} requirement(s) not met. Proceeding may cause instability."
        return 1
    fi
    log_success "All system requirements satisfied"
    return 0
}
