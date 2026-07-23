    #!/usr/bin/env bash
    # DevOps / SRE Environment Audit Script Wrapper
    # This script wrapper checks for python3 and executes the main python auditor.

    set -e

    # Colors for terminal
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    NC='\033[0m' # No Color

    log_err() {
        echo -e "${RED}[ERROR]${NC} $1" >&2
    }

    # 1. Check if python3 is installed
    if ! command -v python3 &>/dev/null; then
        echo -e "${YELLOW}[INFO]${NC} Python 3 no está instalado. Detectando distribución para instalarlo automáticamente..."
        if [ -f /etc/os-release ]; then
            . /etc/os-release
            case "$ID" in
                ubuntu|debian)
                    echo -e "${YELLOW}[INFO]${NC} Distribución basada en Debian detectada. Instalando Python 3..."
                    sudo apt-get update && sudo apt-get install -y python3
                    ;;
                rhel|centos|rocky|almalinux|fedora)
                    echo -e "${YELLOW}[INFO]${NC} Distribución basada en RHEL detectada. Instalando Python 3..."
                    sudo dnf install -y python3 || sudo yum install -y python3
                    ;;
                alpine)
                    echo -e "${YELLOW}[INFO]${NC} Alpine Linux detectado. Instalando Python 3..."
                    sudo apk add --no-cache python3
                    ;;
                *)
                    log_err "Distribución no soportada para autoinstalación ($ID)."
                    echo -e "${YELLOW}[HINT]${NC} Por favor, instala Python 3 manualmente."
                    exit 1
                    ;;
            esac
        else
            log_err "No se pudo detectar la distribución (falta /etc/os-release)."
            echo -e "${YELLOW}[HINT]${NC} Por favor, instala Python 3 manualmente."
            exit 1
        fi

        # Verify installation
        if ! command -v python3 &>/dev/null; then
            log_err "La instalación automática falló. Por favor, instala Python 3 manualmente."
            exit 1
        fi
        echo -e "${GREEN}[INFO]${NC} Python 3 instalado correctamente."
    fi

    # 2. Get the directory of this script
    SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
    PYTHON_SCRIPT="${SCRIPT_DIR}/audit_environment.py"

    if [ ! -f "$PYTHON_SCRIPT" ]; then
        log_err "No se encontró el script '$PYTHON_SCRIPT'."
        exit 1
    fi

    # 3. Ensure python script is executable (optional, since we call python3 directly)
    chmod +x "$PYTHON_SCRIPT"

    # 4. Run the python script forwarding all arguments
    python3 "$PYTHON_SCRIPT" "$@"
