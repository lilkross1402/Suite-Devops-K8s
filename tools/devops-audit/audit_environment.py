#!/usr/bin/env python3
"""
DevOps / SRE Environment Audit Script
This script performs a safe, read-only audit of:
- Docker / Containerd
- Kubernetes (k8s)
- SSL/TLS Certificates (Ingress, kubeadm)
- Host Linux environment

It outputs a structured report in Markdown and optionally JSON.
"""

import argparse
import datetime
import json
import os
import platform
import re
import socket
import ssl
import subprocess
import sys

# Color output helpers (for console display if interactive, otherwise ignored in markdown)
class Colors:
    HEADER = '\033[95m'
    OKBLUE = '\033[94m'
    OKCYAN = '\033[96m'
    OKGREEN = '\033[92m'
    WARNING = '\033[93m'
    FAIL = '\033[91m'
    ENDC = '\033[0m'
    BOLD = '\033[1m'
    UNDERLINE = '\033[4m'

def log_info(msg):
    print(f"{Colors.OKBLUE}[INFO]{Colors.ENDC} {msg}", file=sys.stderr)

def log_warn(msg):
    print(f"{Colors.WARNING}[WARN]{Colors.ENDC} {msg}", file=sys.stderr)

def log_error(msg):
    print(f"{Colors.FAIL}[ERROR]{Colors.ENDC} {msg}", file=sys.stderr)

def check_binary(binary):
    """Check if a binary exists in the PATH."""
    try:
        import shutil
        return shutil.which(binary) is not None
    except Exception:
        return False

def run_command(cmd, timeout=15):
    """Safely run a command and return stdout, stderr, and exit code.

    Hardened version:
    - stdin=DEVNULL prevents interactive tools (openssl, kubectl) from blocking
      while waiting for input that will never come.
    - On TimeoutExpired the child process is explicitly killed and drained so it
      does not linger as a zombie that blocks the parent thread.
    """
    proc = None
    try:
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            stdin=subprocess.DEVNULL,   # critical: no stdin blocking
            text=True,
            shell=isinstance(cmd, str)
        )
        try:
            stdout, stderr = proc.communicate(timeout=timeout)
            return stdout.strip(), stderr.strip(), proc.returncode
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.communicate()          # drain pipes so the OS reclaims resources
            return "", "Command timed out", -1
    except Exception as e:
        if proc is not None:
            try:
                proc.kill()
                proc.communicate()
            except Exception:
                pass
        return "", str(e), -1


def get_local_ips():
    """Get all local IP addresses of the host."""
    ips = {"127.0.0.1", "::1"}
    # Try using ip command on Linux/Unix
    if platform.system() != "Windows" and check_binary("ip"):
        stdout, _, code = run_command(["ip", "-o", "addr", "show"])
        if code == 0:
            for line in stdout.splitlines():
                parts = line.split()
                if len(parts) >= 4:
                    ip_part = parts[3]
                    if "/" in ip_part:
                        ip = ip_part.split("/")[0]
                        ips.add(ip)
    # Fallbacks using socket
    try:
        hostname = socket.gethostname()
        ips.add(socket.gethostbyname(hostname))
    except Exception:
        pass
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None):
            ips.add(info[4][0])
    except Exception:
        pass
    return ips

class EnvironmentAuditor:
    def __init__(self, kubeconfig=None):
        self.kubeconfig = kubeconfig
        self.local_ips = get_local_ips()
        self.detected_role = "Unknown"
        self.detected_role_reason = "No se ha realizado la detección"
        self.detect_role_from_processes()
        
        self.report_data = {
            "metadata": {
                "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                "hostname": socket.gethostname(),
                "kernel": platform.release(),
                "os": platform.platform(),
                "detected_role": self.detected_role,
                "detected_role_reason": self.detected_role_reason
            },
            "versions": {},
            "inventory": {},
            "findings": {
                "critical": [],
                "warnings": [],
                "info": []
            },
            "improvements": []
        }

    def detect_role_from_processes(self):
        """Perform initial local role detection based on running processes."""
        k8s_processes = {
            "kube-apiserver": False,
            "kube-controller-manager": False,
            "kube-scheduler": False,
            "etcd": False,
            "kubelet": False
        }
        
        is_linux = platform.system() == "Linux"
        if is_linux and os.path.exists("/proc"):
            try:
                for pid_dir in os.listdir("/proc"):
                    if pid_dir.isdigit():
                        cmdline_path = os.path.join("/proc", pid_dir, "cmdline")
                        if os.path.exists(cmdline_path):
                            try:
                                with open(cmdline_path, "rb") as f:
                                    cmdline = f.read().decode('utf-8', errors='ignore').replace('\x00', ' ')
                                    for name in k8s_processes:
                                        if name in cmdline:
                                            k8s_processes[name] = True
                            except Exception:
                                pass
            except Exception:
                pass

        has_control_plane_proc = k8s_processes["kube-apiserver"] or k8s_processes["kube-controller-manager"] or k8s_processes["kube-scheduler"]
        has_kubelet_proc = k8s_processes["kubelet"]
        
        if has_control_plane_proc:
            self.detected_role = "Control Plane (Master)"
            self.detected_role_reason = "Procesos de control plane (kube-apiserver/controller/scheduler) activos en el host"
        elif has_kubelet_proc:
            self.detected_role = "Worker Node"
            self.detected_role_reason = "Proceso kubelet activo en el host (sin procesos de control plane)"
        else:
            self.detected_role = "Host No-Kubernetes (Externo)"
            self.detected_role_reason = "No se detectaron procesos locales de Kubernetes (kubelet o control plane)"

    def refine_role_from_cluster(self, nodes_list):
        """Refine the role of the local host using node status gathered from the Kubernetes API."""
        if not nodes_list:
            return
            
        local_hostname = socket.gethostname().lower()
        local_ips = self.local_ips
        matched_node = None
        
        for node in nodes_list:
            node_name = node.get("Name", "")
            node_ips = node.get("IPs", [])
            
            # Match by hostname (case-insensitive)
            if node_name.lower() == local_hostname:
                matched_node = node
                break
                
            # Match by IPs
            match_found = False
            for ip in node_ips:
                if ip in local_ips:
                    matched_node = node
                    match_found = True
                    break
            if match_found:
                break
                
        if matched_node:
            roles = matched_node.get("Roles", "worker")
            if "master" in roles.lower() or "control-plane" in roles.lower() or "controlplane" in roles.lower():
                self.detected_role = f"Control Plane (Master) [{roles}]"
            else:
                self.detected_role = f"Worker Node [{roles}]"
            self.detected_role_reason = f"Correlacionado con el nodo '{matched_node['Name']}' del clúster"
        else:
            self.detected_role = "Runner Externo / Bastion"
            self.detected_role_reason = "Conexión exitosa a Kubernetes, pero el host local no figura en la lista de nodos"

    def add_finding(self, level, category, description, detail=""):
        """Add a security/configuration finding."""
        finding = {
            "category": category,
            "description": description,
            "detail": detail
        }
        if level == "critical":
            self.report_data["findings"]["critical"].append(finding)
        elif level == "warning":
            self.report_data["findings"]["warnings"].append(finding)
        else:
            self.report_data["findings"]["info"].append(finding)

    def add_improvement(self, category, recommendation, impact="Medium"):
        """Add a point of improvement."""
        self.report_data["improvements"].append({
            "category": category,
            "recommendation": recommendation,
            "impact": impact
        })

    def run_all(self):
        log_info("Starting Host Linux Audit...")
        self.audit_host()

        log_info("Starting Docker / Containerd Audit...")
        self.audit_docker()

        log_info("Starting Kubernetes Audit...")
        self.audit_k8s()

        log_info("Starting Certificates & SSL/TLS Audit...")
        self.audit_certificates()

        log_info("Starting Local YAML Manifests Audit...")
        self.audit_local_manifests()

        log_info("Starting Pod Security Context Audit...")
        self.audit_pod_security()

        log_info("Starting Network Policy Isolation Audit...")
        self.audit_network_policies()

        log_info("Starting HPA / FinOps Audit...")
        self.audit_hpa_finops()

        log_info("Starting Storage & Backup Audit...")
        self.audit_storage()

        log_info("Starting Remediation Commands Generator...")
        self.audit_remediation_commands()

        log_info("Starting Local YAML Linter (dry-run)...")
        self.audit_yaml_linter()


        log_info("Starting RBAC Permissions Audit...")
        self.audit_rbac_permissions()

        log_info("Starting PDB Resilience Audit...")
        self.audit_pdb_resilience()

        log_info("Starting Ephemeral Storage Limits Audit...")
        self.audit_ephemeral_storage()

        log_info("Starting Anomalous Events Audit...")
        self.audit_anomalous_events()

        log_info("Starting Root-Cause Analysis Audit...")
        self.audit_root_cause_analysis()

        log_info("Starting Ingress & Gateway Audit...")
        self.audit_ingress_gateway()

        log_info("Starting Orphan Resources Audit...")
        self.audit_orphan_resources()
    def audit_host(self):
        category = "Entorno Host (Linux)"
        self.report_data["inventory"][category] = {}
        
        # 1. Kernel and Distribution
        log_info("Inspecting Host Linux OS and Kernel version...")
        kernel = platform.release()
        
        distro = "Unknown Linux Distribution"
        if os.path.exists("/etc/os-release"):
            try:
                with open("/etc/os-release", "r") as f:
                    for line in f:
                        if line.startswith("PRETTY_NAME="):
                            distro = line.split("=")[1].strip().strip('"')
                            break
            except Exception:
                pass
        else:
            # Fallback if os-release is not present
            distro = f"{platform.system()} {platform.machine()}"

        self.report_data["versions"][category] = {
            "OS / Distribution": distro,
            "Kernel": kernel
        }

        # 2. Firewall Status (UFW / iptables / firewalld / nftables)
        log_info("Checking firewall status (UFW / iptables / firewalld / nftables)...")
        firewall_status = {}
        
        # Check UFW
        if check_binary("ufw"):
            stdout, stderr, code = run_command(["ufw", "status"])
            if code == 0:
                firewall_status["UFW"] = stdout.split("\n")[0] if stdout else "Unknown"
                firewall_status["UFW_Details"] = stdout
            else:
                firewall_status["UFW"] = f"Error or requires sudo: {stderr.strip()}"
        else:
            firewall_status["UFW"] = "Not Installed"

        # Check iptables (basic list)
        if check_binary("iptables"):
            stdout, stderr, code = run_command(["iptables", "-L", "-n"])
            if code == 0:
                firewall_status["iptables"] = "Active/Configured"
                # Keep lines count
                firewall_status["iptables_rules_count"] = len(stdout.split("\n"))
            else:
                firewall_status["iptables"] = f"Error or requires sudo: {stderr.strip()}"
        else:
            firewall_status["iptables"] = "Not Installed"

        # Check Firewalld (CentOS / RHEL / Alma / Rocky / Suse)
        if check_binary("firewall-cmd"):
            stdout, stderr, code = run_command(["firewall-cmd", "--state"])
            if code == 0 and "running" in stdout.lower():
                firewall_status["Firewalld"] = "Active"
                rules_stdout, _, rules_code = run_command(["firewall-cmd", "--list-all"])
                if rules_code == 0:
                    firewall_status["Firewalld_Details"] = rules_stdout
            else:
                firewall_status["Firewalld"] = "Inactive" if code == 0 else f"Error or requires sudo: {stderr.strip()}"
        else:
            firewall_status["Firewalld"] = "Not Installed"

        # Check nftables
        if check_binary("nft"):
            stdout, stderr, code = run_command(["nft", "list", "ruleset"])
            if code == 0:
                firewall_status["nftables"] = "Active/Configured"
                firewall_status["nftables_rules_count"] = len(stdout.split("\n"))
            else:
                firewall_status["nftables"] = f"Error or requires sudo: {stderr.strip()}"
        else:
            firewall_status["nftables"] = "Not Installed"

        self.report_data["inventory"][category]["Firewall"] = firewall_status

        # 3. Exposed Ports (using ss -tuln or netstat -tuln)
        log_info("Inspecting exposed ports on the host...")
        ports_stdout = ""
        ports_code = -1
        
        if check_binary("ss"):
            ports_stdout, _, ports_code = run_command(["ss", "-tuln"])
        elif check_binary("netstat"):
            ports_stdout, _, ports_code = run_command(["netstat", "-tuln"])
            
        exposed_ports = []
        unusual_ports = []
        
        # Common secure/expected ports exposed to 0.0.0.0 or ::
        # 22 (SSH), 80 (HTTP), 443 (HTTPS), 6443 (k8s API), 8443 (k8s API alternate), 10250 (kubelet), 10256 (kube-proxy)
        expected_ports = {22, 80, 443, 6443, 8443, 10250, 10256}

        if ports_code == 0 and ports_stdout:
            lines = ports_stdout.strip().split("\n")
            for line in lines[1:]: # Skip header
                parts = line.split()
                # ss output usually has: Netid State Recv-Q Send-Q Local Address:Port Peer Address:Port
                # netstat output has: Proto Recv-Q Send-Q Local Address Foreign Address State
                if len(parts) >= 5:
                    proto = parts[0]
                    # Local Address:Port might be separated by a colon (ss uses IP:PORT or [IP]:PORT)
                    local_addr_part = parts[4] if proto == "tcp" or proto == "udp" or "tcp" in proto or "udp" in proto else parts[3]
                    
                    # Parse IP and Port
                    port_str = ""
                    ip_str = ""
                    if ":" in local_addr_part:
                        # Extract port (last element after colon)
                        port_parts = local_addr_part.split(":")
                        port_str = port_parts[-1]
                        ip_str = ":".join(port_parts[:-1])
                    
                    if port_str.isdigit():
                        port = int(port_str)
                        # We only care about ports listening on all interfaces (0.0.0.0 or * or [::] or wildcard)
                        is_wildcard = ip_str in ["0.0.0.0", "*", "[::]", ":::"] or ip_str.endswith("]") and ip_str.startswith("[") and ip_str == "[::]"
                        
                        # Fallback parsing in case of netstat format which can be 0.0.0.0:22 or :::22
                        if not is_wildcard and (ip_str == "" or ip_str == "::"):
                            is_wildcard = True

                        if is_wildcard:
                            exposed_ports.append({
                                "Protocol": proto.upper(),
                                "Port": port,
                                "Interface": ip_str or "All"
                            })
                            
                            # Check if the port is unusual/unexpected
                            # In Kubernetes, we also see NodePorts in 30000-32767 which are expected, we ignore them in alerts
                            if port not in expected_ports and not (30000 <= port <= 32767):
                                unusual_ports.append(f"{proto.upper()}/{port}")

        self.report_data["inventory"][category]["ExposedPorts"] = exposed_ports
        self.report_data["inventory"][category]["UnusualPorts"] = unusual_ports

        if unusual_ports:
            # De-duplicate while preserving order
            seen = set()
            unusual_ports_unique = [x for x in unusual_ports if not (x in seen or seen.add(x))]
            ports_str = ", ".join(unusual_ports_unique)
            self.add_finding(
                "warning",
                category,
                f"Se detectaron {len(unusual_ports_unique)} puertos inusuales expuestos públicamente.",
                f"Puertos expuestos: {ports_str}. Los puertos inusuales expuestos al exterior aumentan la superficie de ataque del host."
            )
            self.add_improvement(
                category,
                f"Cerrar o restringir el acceso a los puertos expuestos ({ports_str}) mediante reglas de firewall si no requieren exposición externa."
            )

        # General OS findings
        has_active_firewall = False
        for fw_name in ["UFW", "iptables", "Firewalld", "nftables"]:
            val = firewall_status.get(fw_name, "").lower()
            if "active" in val or "running" in val or "configured" in val:
                has_active_firewall = True
                break

        if not has_active_firewall:
            self.add_finding(
                "critical",
                category,
                "No se detectó ningún firewall activo (UFW, iptables, Firewalld o nftables).",
                "El host está expuesto directamente sin protección de filtrado a nivel de red."
            )
            self.add_improvement(
                category,
                "Habilitar y configurar un firewall local (como UFW, iptables, firewalld o nftables) permitiendo únicamente los puertos necesarios."
            )


    def audit_docker(self):
        category = "Docker / Containerd"
        self.report_data["inventory"][category] = {}
        
        if not check_binary("docker"):
            # Check if crictl is available instead (common for standalone containerd in k8s)
            if check_binary("crictl"):
                self.audit_crictl()
                return
            
            log_warn("Docker or crictl binary not found in PATH.")
            self.report_data["versions"][category] = "Not Installed"
            self.add_finding("warning", category, "Docker/Containerd no está instalado en el sistema host.")
            return

        # 1. Version and Service Status
        log_info("Inspecting Docker version and service status...")
        self.report_data["versions"][category] = {}
        
        # Get Version
        ver_stdout, _, code = run_command(["docker", "version", "--format", "{{json .}}"])
        if code == 0:
            try:
                ver_json = json.loads(ver_stdout)
                client_ver = ver_json.get("Client", {}).get("Version", "Unknown")
                server_ver = ver_json.get("Server", {}).get("Version", "Unknown")
                self.report_data["versions"][category] = {
                    "Client": client_ver,
                    "Server": server_ver
                }
            except json.JSONDecodeError:
                self.report_data["versions"][category] = "Installed (JSON Parse Error)"
        else:
            # Fallback to plain version command
            ver_stdout, _, _ = run_command(["docker", "--version"])
            self.report_data["versions"][category] = ver_stdout if ver_stdout else "Installed (Unknown Version)"

        # Check Service Status
        service_status = "Unknown"
        sys_stdout, _, sys_code = run_command(["systemctl", "is-active", "docker"])
        if sys_code == 0:
            service_status = sys_stdout
        else:
            # Fallback: check if docker info works
            _, _, info_code = run_command(["docker", "info"])
            service_status = "active (running)" if info_code == 0 else "inactive (stopped)"

        self.report_data["inventory"][category]["ServiceStatus"] = service_status
        if "active" not in service_status:
            self.add_finding("critical", category, "El servicio Docker está inactivo o no responde.")
            return

        # 2. Inspect Containers
        log_info("Auditing running and stopped containers...")
        ps_stdout, _, ps_code = run_command(["docker", "ps", "-a", "-q"])
        container_ids = ps_stdout.split() if ps_code == 0 and ps_stdout else []

        running_containers = 0
        stopped_containers = 0
        total_containers = len(container_ids)

        self.report_data["inventory"][category]["Containers"] = {
            "Total": total_containers,
            "Running": 0,
            "Stopped": 0
        }

        privileged_containers = []
        missing_limits_containers = []
        latest_tag_containers = []

        if container_ids:
            # We inspect all containers in chunks to avoid command line length limits
            # but usually a few containers fit in one command
            chunk_size = 50
            for i in range(0, len(container_ids), chunk_size):
                chunk = container_ids[i:i+chunk_size]
                inspect_stdout, _, inspect_code = run_command(["docker", "inspect"] + chunk)
                if inspect_code == 0:
                    try:
                        containers_data = json.loads(inspect_stdout)
                        for c in containers_data:
                            name = c.get("Name", "").lstrip("/")
                            state = c.get("State", {})
                            is_running = state.get("Running", False)
                            
                            if is_running:
                                running_containers += 1
                            else:
                                stopped_containers += 1

                            # Security checks
                            host_config = c.get("HostConfig", {})
                            config = c.get("Config", {})
                            
                            # A. Privileged mode
                            is_privileged = host_config.get("Privileged", False)
                            if is_privileged:
                                privileged_containers.append(name)

                            # B. Resource limits
                            # Memory limit is in bytes. NanoCpus is CPU * 10^9.
                            mem_limit = host_config.get("Memory", 0)
                            nano_cpus = host_config.get("NanoCpus", 0)
                            cpu_quota = host_config.get("CpuQuota", 0)
                            
                            has_mem_limit = mem_limit > 0
                            has_cpu_limit = (nano_cpus > 0) or (cpu_quota > 0)

                            if is_running and (not has_mem_limit or not has_cpu_limit):
                                missing_limits = []
                                if not has_mem_limit: missing_limits.append("RAM")
                                if not has_cpu_limit: missing_limits.append("CPU")
                                missing_limits_containers.append(f"'{name}' (falta {', '.join(missing_limits)})")

                            # C. Latest tag
                            image_name = config.get("Image", "")
                            # Check if latest tag is explicitly used or implicitly (no tag specified)
                            is_latest = False
                            if ":" not in image_name:
                                is_latest = True
                            elif image_name.endswith(":latest"):
                                is_latest = True
                            
                            if is_latest:
                                latest_tag_containers.append(f"'{name}' ({image_name})")

                    except json.JSONDecodeError:
                        log_error("Error parsing docker inspect output.")

        self.report_data["inventory"][category]["Containers"]["Running"] = running_containers
        self.report_data["inventory"][category]["Containers"]["Stopped"] = stopped_containers

        if privileged_containers:
            names_str = ", ".join(privileged_containers)
            self.add_finding(
                "critical",
                category,
                f"Se detectaron {len(privileged_containers)} contenedores corriendo en modo PRIVILEGIADO.",
                f"Contenedores: {names_str}. Esto salta los mecanismos de seguridad de Linux y expone el Host."
            )
            self.add_improvement(
                category,
                f"Evitar el uso de modo privilegiado para los contenedores: {names_str}. Usar capacidades específicas de Linux (capabilities) en su lugar."
            )

        if missing_limits_containers:
            names_str = ", ".join(missing_limits_containers)
            self.add_finding(
                "warning",
                category,
                f"Se detectaron {len(missing_limits_containers)} contenedores ejecutándose sin límites de CPU o RAM.",
                f"Contenedores afectados: {names_str}. Esto puede causar denegación de servicio (DoS) por agotamiento de recursos del host."
            )
            self.add_improvement(
                category,
                f"Definir límites de recursos (CPU/RAM) para los contenedores: {names_str}."
            )

        if latest_tag_containers:
            names_str = ", ".join(latest_tag_containers)
            self.add_finding(
                "warning",
                category,
                f"Se detectaron {len(latest_tag_containers)} contenedores usando la etiqueta 'latest' en su imagen.",
                f"Contenedores: {names_str}. El uso de 'latest' impide la trazabilidad de versiones y puede romper despliegues al actualizarse."
            )
            self.add_improvement(
                category,
                f"Reemplazar la etiqueta 'latest' por tags específicos de versión o hashes SHA256 de las imágenes para los contenedores: {names_str}."
            )

        # 3. Dangling images
        log_info("Auditing dangling Docker images...")
        dangling_stdout, _, dang_code = run_command(["docker", "images", "-f", "dangling=true", "-q"])
        dangling_ids = dangling_stdout.split() if dang_code == 0 and dangling_stdout else []
        
        self.report_data["inventory"][category]["DanglingImages"] = {
            "Count": len(dangling_ids),
            "ReclaimableSpaceBytes": 0
        }

        if dangling_ids:
            # Inspect dangling images to sum their size
            inspect_img_stdout, _, inspect_img_code = run_command(["docker", "inspect"] + list(set(dangling_ids)))
            if inspect_img_code == 0:
                try:
                    images_data = json.loads(inspect_img_stdout)
                    total_size = sum(img.get("Size", 0) for img in images_data)
                    self.report_data["inventory"][category]["DanglingImages"]["ReclaimableSpaceBytes"] = total_size
                    
                    if total_size > 0:
                        size_mb = total_size / (1024 * 1024)
                        self.add_finding(
                            "info",
                            category,
                            f"Se encontraron {len(dangling_ids)} imágenes huérfanas (dangling) consumiendo {size_mb:.2f} MB de disco.",
                            "Estas imágenes no están asociadas a ningún contenedor y se pueden limpiar de forma segura."
                        )
                        self.add_improvement(
                            category,
                            f"Liberar espacio en disco ejecutando 'docker image prune' para eliminar las {len(dangling_ids)} imágenes huérfanas.",
                            impact="Low"
                        )
                except json.JSONDecodeError:
                    pass

    def audit_crictl(self):
        category = "Docker / Containerd"
        self.report_data["versions"][category] = "Containerd (via crictl)"
        
        # Check crictl version
        ver_stdout, _, code = run_command(["crictl", "version"])
        if code == 0:
            self.report_data["versions"][category] = {
                "crictl_version_output": ver_stdout.replace("\n", " | ")
            }
        
        # Check container list
        ps_stdout, _, ps_code = run_command(["crictl", "ps", "-a", "-o", "json"])
        if ps_code == 0 and ps_stdout:
            try:
                ps_json = json.loads(ps_stdout)
                containers = ps_json.get("containers", [])
                self.report_data["inventory"][category]["Containers"] = {
                    "Total": len(containers),
                    "Running": sum(1 for c in containers if c.get("state") == "CONTAINER_RUNNING"),
                    "Stopped": sum(1 for c in containers if c.get("state") != "CONTAINER_RUNNING")
                }
            except json.JSONDecodeError:
                pass
        else:
            self.report_data["inventory"][category]["Containers"] = "Error query via crictl"
            
        # Add basic info/warning
        self.add_finding("info", category, "El nodo utiliza Containerd autónomo (crictl) en lugar de Docker.")


    def run_kubectl(self, args, timeout=15):
        """Helper to run kubectl commands with optional kubeconfig."""
        cmd = ["kubectl"]
        if self.kubeconfig:
            cmd.append(f"--kubeconfig={self.kubeconfig}")
        cmd.extend(args)
        return run_command(cmd, timeout=timeout)

    def audit_k8s(self):
        category = "Kubernetes (k8s)"
        self.report_data["inventory"][category] = {}

        if not check_binary("kubectl"):
            log_warn("kubectl binary not found in PATH.")
            self.report_data["versions"][category] = "Not Installed"
            self.add_finding("warning", category, "kubectl no está instalado en el sistema host.")
            return

        # Check connectivity to Cluster
        log_info("Checking connection to Kubernetes cluster...")
        _, conn_err, conn_code = self.run_kubectl(["cluster-info"])
        if conn_code != 0:
            log_warn("Failed to connect to Kubernetes cluster.")
            self.report_data["versions"][category] = "kubectl installed but no connection to cluster"
            self.add_finding("warning", category, "No se puede establecer conexión con el clúster Kubernetes.", conn_err)
            return

        # 1. Cluster Versions (Client & Server)
        log_info("Fetching Kubernetes version...")
        self.report_data["versions"][category] = {}
        ver_stdout, _, ver_code = self.run_kubectl(["version", "-o", "json"])
        if ver_code == 0:
            try:
                ver_json = json.loads(ver_stdout)
                client_ver = ver_json.get("clientVersion", {}).get("gitVersion", "Unknown")
                server_ver = ver_json.get("serverVersion", {}).get("gitVersion", "Unknown")
                self.report_data["versions"][category] = {
                    "Client": client_ver,
                    "Server": server_ver
                }
            except json.JSONDecodeError:
                self.report_data["versions"][category] = "Installed (JSON Parse Error)"
        else:
            # Fallback for older kubectl version
            ver_stdout, _, _ = self.run_kubectl(["version", "--short"])
            if not ver_stdout:
                # Try just normal output
                ver_stdout, _, _ = self.run_kubectl(["version"])
            self.report_data["versions"][category] = ver_stdout.replace("\n", " | ") if ver_stdout else "Installed"

        # 2. Nodes Status and resources
        log_info("Auditing Kubernetes nodes...")
        nodes_stdout, _, nodes_code = self.run_kubectl(["get", "nodes", "-o", "json"])
        
        ready_nodes = 0
        not_ready_nodes = 0
        nodes_list = []
        
        self.report_data["inventory"][category]["Nodes"] = {
            "Total": 0,
            "Ready": 0,
            "NotReady": 0,
            "NodeList": []
        }

        pressure_nodes = []
        if nodes_code == 0 and nodes_stdout:
            try:
                nodes_data = json.loads(nodes_stdout)
                items = nodes_data.get("items", [])
                self.report_data["inventory"][category]["Nodes"]["Total"] = len(items)
                
                for node in items:
                    name = node.get("metadata", {}).get("name", "Unknown")
                    status = "NotReady"
                    conditions = node.get("status", {}).get("conditions", [])
                    for cond in conditions:
                        if cond.get("type") == "Ready":
                            status = "Ready" if cond.get("status") == "True" else "NotReady"
                            break
                    
                    if status == "Ready":
                        ready_nodes += 1
                    else:
                        not_ready_nodes += 1
                        self.add_finding(
                            "critical",
                            category,
                            f"El Nodo '{name}' está en estado NOT READY.",
                            "Un nodo no listo reduce la capacidad del clúster y puede causar que pods queden huérfanos o sin programar."
                        )
                    
                    # Check pressure conditions
                    node_pressures = []
                    for cond in conditions:
                        cond_type = cond.get("type")
                        if cond_type in ["MemoryPressure", "DiskPressure", "PIDPressure"]:
                            if cond.get("status") == "True":
                                node_pressures.append(cond_type)
                    if node_pressures:
                        pressure_nodes.append(f"'{name}' ({', '.join(node_pressures)})")

                    # Extract roles
                    labels = node.get("metadata", {}).get("labels", {})
                    roles = []
                    for label in labels:
                        if label.startswith("node-role.kubernetes.io/"):
                            roles.append(label.split("/")[-1])
                    if not roles:
                        roles = ["worker"]

                    # Extract node IPs
                    addresses = node.get("status", {}).get("addresses", [])
                    node_ips = [addr.get("address") for addr in addresses if addr.get("address")]

                    nodes_list.append({
                        "Name": name,
                        "Status": status,
                        "Roles": ", ".join(roles),
                        "IPs": node_ips
                    })
            except json.JSONDecodeError:
                pass
        
        self.report_data["inventory"][category]["Nodes"]["Ready"] = ready_nodes
        self.report_data["inventory"][category]["Nodes"]["NotReady"] = not_ready_nodes
        self.report_data["inventory"][category]["Nodes"]["NodeList"] = nodes_list

        if pressure_nodes:
            self.add_finding(
                "critical",
                category,
                f"Se detectó presión de recursos en {len(pressure_nodes)} nodos del clúster.",
                f"Nodos afectados: {', '.join(pressure_nodes)}. Esto puede causar inestabilidad en la programación y desalojo de Pods."
            )
            self.add_improvement(
                category,
                f"Revisar el consumo de recursos en los nodos con presión ({', '.join(pressure_nodes)}) y liberar recursos o escalar el clúster."
            )

        # Refine local node role based on k8s nodes list
        self.refine_role_from_cluster(nodes_list)
        self.report_data["metadata"]["detected_role"] = self.detected_role
        self.report_data["metadata"]["detected_role_reason"] = self.detected_role_reason

        # Top Nodes (Resources)
        top_stdout, _, top_code = self.run_kubectl(["top", "nodes", "--no-headers"])
        node_metrics = []
        if top_code == 0 and top_stdout:
            for line in top_stdout.strip().split("\n"):
                parts = line.split()
                if len(parts) >= 5:
                    node_metrics.append({
                        "Node": parts[0],
                        "CPU_Usage": parts[1],
                        "CPU_Percentage": parts[2],
                        "Memory_Usage": parts[3],
                        "Memory_Percentage": parts[4]
                    })
        self.report_data["inventory"][category]["NodeMetrics"] = node_metrics

        # 3. Pod Inventory, QoS, and OOMKilled Auditing
        log_info("Auditing Pod status, QoS classes and OOMKilled states...")
        self.report_data["inventory"][category]["Pods"] = {}
        
        for ns in ["kube-system", "default"]:
            self.report_data["inventory"][category]["Pods"][ns] = {
                "Total": 0,
                "Running": 0,
                "FailedOrPending": 0,
                "Details": []
            }
            
        best_effort_pods = []
        oom_killed_pods = []
        
        pods_stdout, _, pods_code = self.run_kubectl(["get", "pods", "-A", "-o", "json"])
        if pods_code == 0 and pods_stdout:
            try:
                pods_data = json.loads(pods_stdout)
                items = pods_data.get("items", [])
                
                for pod in items:
                    pod_name = pod.get("metadata", {}).get("name", "Unknown")
                    ns = pod.get("metadata", {}).get("namespace", "Unknown")
                    phase = pod.get("status", {}).get("phase", "Unknown")
                    
                    # 3.a. Inventory for critical namespaces
                    if ns in ["kube-system", "default"]:
                        self.report_data["inventory"][category]["Pods"][ns]["Total"] += 1
                        
                        container_statuses = pod.get("status", {}).get("containerStatuses", []) or []
                        bad_status_reason = None
                        for cs in container_statuses:
                            state = cs.get("state", {})
                            waiting = state.get("waiting", {})
                            if waiting:
                                reason = waiting.get("reason", "")
                                if reason in ["CrashLoopBackOff", "ImagePullBackOff", "CreateContainerConfigError", "ErrImagePull"]:
                                    bad_status_reason = reason
                                    break
                            last_state = cs.get("lastState", {})
                            terminated = last_state.get("terminated", {})
                            if terminated and terminated.get("reason") == "OOMKilled":
                                bad_status_reason = "OOMKilled"
                                break
                                
                        if phase == "Running" and not bad_status_reason:
                            self.report_data["inventory"][category]["Pods"][ns]["Running"] += 1
                        else:
                            self.report_data["inventory"][category]["Pods"][ns]["FailedOrPending"] += 1
                            reason_str = bad_status_reason if bad_status_reason else phase
                            self.add_finding(
                                "critical" if ns == "kube-system" else "warning",
                                category,
                                f"Pod '{pod_name}' en namespace '{ns}' tiene estado problemático: {reason_str}.",
                                f"Fase de Pod: {phase}. Esto puede interrumpir la disponibilidad de los servicios críticos del sistema o de la app."
                            )
                            self.add_improvement(
                                category,
                                f"Revisar logs del pod '{pod_name}' en '{ns}' con 'kubectl logs {pod_name} -n {ns}' para diagnosticar el fallo."
                            )
                            
                        # Determine parent workload/controller
                        owner_kind = "Pod"
                        owner_name = pod_name
                        owner_refs = pod.get("metadata", {}).get("ownerReferences", [])
                        if owner_refs:
                            owner_kind = owner_refs[0].get("kind", "Unknown")
                            owner_name = owner_refs[0].get("name", "Unknown")
                            if owner_kind == "ReplicaSet":
                                parts = owner_name.split("-")
                                if len(parts) > 1:
                                    owner_name = "-".join(parts[:-1])
                                    owner_kind = "Deployment"

                        self.report_data["inventory"][category]["Pods"][ns]["Details"].append({
                            "Name": pod_name,
                            "Phase": phase,
                            "Reason": bad_status_reason or "Healthy",
                            "WorkloadKind": owner_kind,
                            "WorkloadName": owner_name
                        })
                    
                    # 3.b. QoS Evaluation
                    qos_class = pod.get("status", {}).get("qosClass")
                    if qos_class == "BestEffort":
                        best_effort_pods.append(f"'{pod_name}' ({ns})")
                        
                    # 3.c. OOMKilled scanning (all namespaces)
                    container_statuses = pod.get("status", {}).get("containerStatuses", []) or []
                    init_container_statuses = pod.get("status", {}).get("initContainerStatuses", []) or []
                    
                    for cs in container_statuses + init_container_statuses:
                        c_name = cs.get("name", "")
                        
                        # Current state terminated
                        state = cs.get("state", {})
                        terminated = state.get("terminated", {})
                        if terminated and terminated.get("reason") == "OOMKilled":
                            oom_killed_pods.append(f"'{c_name}' en pod '{pod_name}' ({ns})")
                            continue
                            
                        # Last state terminated
                        last_state = cs.get("lastState", {})
                        last_terminated = last_state.get("terminated", {})
                        if last_terminated and last_terminated.get("reason") == "OOMKilled":
                            oom_killed_pods.append(f"'{c_name}' en pod '{pod_name}' ({ns}, reinicio previo)")
            except json.JSONDecodeError:
                pass
                
        # Add SRE findings for QoS and OOMKilled
        if best_effort_pods:
            self.add_finding(
                "warning",
                category,
                f"Se detectaron {len(best_effort_pods)} Pods con clase QoS 'BestEffort'.",
                f"Pods: {', '.join(best_effort_pods[:10])}{(f' y {len(best_effort_pods)-10} más' if len(best_effort_pods) > 10 else '')}. Estos pods no definen limits ni requests de CPU/RAM, por lo que corren riesgo de inanición y desalojo bajo presión del nodo."
            )
            self.add_improvement(
                category,
                f"Configurar requests y/o limits de CPU/RAM para los {len(best_effort_pods)} Pods en BestEffort para asegurar recursos mínimos."
            )
            
        if oom_killed_pods:
            # Deduplicate oom_killed_pods while preserving order
            seen = set()
            oom_killed_unique = [x for x in oom_killed_pods if not (x in seen or seen.add(x))]
            self.add_finding(
                "critical",
                category,
                f"Se detectaron {len(oom_killed_unique)} reinicios de contenedores por OOMKilled (exceso de memoria).",
                f"Contenedores: {', '.join(oom_killed_unique)}. Esto ocurre cuando el consumo de memoria del contenedor supera su límite configurado."
            )
            self.add_improvement(
                category,
                f"Incrementar el límite de memoria en el manifiesto para los contenedores afectados por OOMKilled."
            )

        # 4. Deployments and StatefulSets resources validation
        log_info("Auditing Deployments and StatefulSets resource configurations...")
        deprecated_apis = []
        missing_limits_k8s = []
        missing_probes = []
        replicas_one = []
        recreate_strategy = []
        missing_antiaffinity = []
        all_workloads = []

        for resource_type in ["deployments", "statefulsets"]:
            res_stdout, _, res_code = self.run_kubectl(["get", resource_type, "-A", "-o", "json"])
            if res_code == 0 and res_stdout:
                try:
                    res_data = json.loads(res_stdout)
                    items = res_data.get("items", [])
                    for item in items:
                        name = item.get("metadata", {}).get("name", "Unknown")
                        ns = item.get("metadata", {}).get("namespace", "Unknown")
                        all_workloads.append(name.lower())
                        
                        # Check resource API version for deprecation
                        api_version = item.get("apiVersion", "")
                        is_deprecated = False
                        correct_api = "apps/v1"
                        
                        if api_version in ["extensions/v1beta1", "apps/v1beta1", "apps/v1beta2"]:
                            is_deprecated = True
                            
                        if is_deprecated:
                            deprecated_apis.append(f"{resource_type[:-1].capitalize()} '{name}' ({ns}) usa '{api_version}' (usar '{correct_api}')")

                        # Check resources limits/requests, probes, and affinity
                        pod_template_spec = item.get("spec", {}).get("template", {}).get("spec", {})
                        containers = pod_template_spec.get("containers", [])
                        
                        for c in containers:
                            c_name = c.get("name", "")
                            resources = c.get("resources", {})
                            limits = resources.get("limits", {})
                            requests = resources.get("requests", {})
                            
                            has_limits = limits.get("cpu") and limits.get("memory")
                            has_requests = requests.get("cpu") and requests.get("memory")
                            
                            if not has_limits or not has_requests:
                                missing = []
                                if not has_requests: missing.append("requests")
                                if not has_limits: missing.append("limits")
                                missing_limits_k8s.append(f"'{c_name}' de {resource_type[:-1]} '{name}' ({ns}, falta {', '.join(missing)})")
                                
                            # Check probes
                            liveness = c.get("livenessProbe")
                            readiness = c.get("readinessProbe")
                            if not liveness or not readiness:
                                missing_pr = []
                                if not liveness: missing_pr.append("livenessProbe")
                                if not readiness: missing_pr.append("readinessProbe")
                                missing_probes.append(f"'{c_name}' de {resource_type[:-1]} '{name}' ({ns}, falta {', '.join(missing_pr)})")

                        # Check HA (replicas: 1) and recreate strategy (ONLY Deployments)
                        replicas = 1
                        if resource_type == "deployments":
                            replicas = item.get("spec", {}).get("replicas", 1)
                            if replicas == 1:
                                replicas_one.append(f"'{name}' ({ns})")
                                
                            strategy = item.get("spec", {}).get("strategy", {})
                            strategy_type = strategy.get("type", "RollingUpdate")
                            if strategy_type == "Recreate":
                                recreate_strategy.append(f"'{name}' ({ns})")
                                
                        # Check podAntiAffinity for HA workloads
                        is_ha_candidate = (resource_type == "statefulsets") or (resource_type == "deployments" and replicas > 1)
                        if is_ha_candidate:
                            affinity = pod_template_spec.get("affinity", {})
                            pod_anti_affinity = affinity.get("podAntiAffinity")
                            if not pod_anti_affinity:
                                missing_antiaffinity.append(f"{resource_type[:-1]} '{name}' ({ns})")

                except json.JSONDecodeError:
                    pass

        # 5. Check Other Deprecated APIs (Ingresses, CronJobs)
        log_info("Auditing other resources for deprecated APIs...")
        # Check Ingresses
        ing_stdout, _, ing_code = self.run_kubectl(["get", "ingresses", "-A", "-o", "json"])
        if ing_code == 0 and ing_stdout:
            try:
                ing_data = json.loads(ing_stdout)
                for item in ing_data.get("items", []):
                    name = item.get("metadata", {}).get("name", "Unknown")
                    ns = item.get("metadata", {}).get("namespace", "Unknown")
                    api_version = item.get("apiVersion", "")
                    if api_version in ["extensions/v1beta1", "networking.k8s.io/v1beta1"]:
                        deprecated_apis.append(f"Ingress '{name}' ({ns}) usa '{api_version}' (usar 'networking.k8s.io/v1')")
            except json.JSONDecodeError:
                pass

        # Check CronJobs
        cj_stdout, _, cj_code = self.run_kubectl(["get", "cronjobs", "-A", "-o", "json"])
        if cj_code == 0 and cj_stdout:
            try:
                cj_data = json.loads(cj_stdout)
                for item in cj_data.get("items", []):
                    name = item.get("metadata", {}).get("name", "Unknown")
                    ns = item.get("metadata", {}).get("namespace", "Unknown")
                    api_version = item.get("apiVersion", "")
                    if api_version == "batch/v1beta1":
                        deprecated_apis.append(f"CronJob '{name}' ({ns}) usa '{api_version}' (usar 'batch/v1')")
            except json.JSONDecodeError:
                pass

        # SRE Stack Check
        has_metrics_server = False
        has_prometheus = False
        has_ingress_controller = False
        
        for wl in all_workloads:
            if "metrics-server" in wl or "kube-state-metrics" in wl:
                has_metrics_server = True
            if "prometheus" in wl or "grafana" in wl or "alertmanager" in wl:
                has_prometheus = True
            if "ingress-nginx" in wl or "ingress-controller" in wl or "traefik" in wl or "alb-ingress" in wl:
                has_ingress_controller = True
                
        if not has_metrics_server:
            self.add_improvement(
                "Integración SRE/Observabilidad",
                "Instalar 'metrics-server' en el clúster. Es requerido para permitir el autoescalado horizontal de Pods (HPA) y habilitar 'kubectl top'.",
                impact="High"
            )
        if not has_prometheus:
            self.add_improvement(
                "Integración SRE/Observabilidad",
                "Implementar un stack de monitoreo (como 'kube-prometheus-stack' u operador de Prometheus) para recolectar métricas del clúster e instrumentar alertas en tiempo real.",
                impact="High"
            )
        if not has_ingress_controller:
            self.add_improvement(
                "Integración SRE/Observabilidad",
                "Instalar un Ingress Controller (ej. ingress-nginx, traefik o AWS ALB ingress controller) para centralizar la entrada y enrutamiento de tráfico HTTP/HTTPS.",
                impact="Medium"
            )
            
        self.report_data["inventory"][category]["SREStack"] = {
            "metrics-server": "Instalado" if has_metrics_server else "Faltante",
            "prometheus-stack": "Instalado" if has_prometheus else "Faltante",
            "ingress-controller": "Instalado" if has_ingress_controller else "Faltante"
        }

        # Save aggregated findings for Kubernetes
        if deprecated_apis:
            self.add_finding(
                "warning",
                category,
                f"Se detectaron {len(deprecated_apis)} recursos de clúster utilizando APIs obsoletas/deprecadas.",
                f"Detalle: {', '.join(deprecated_apis)}. Deben migrarse a las APIs recomendadas antes de actualizar el clúster."
            )
            self.add_improvement(
                category,
                f"Actualizar las APIs deprecadas en los archivos YAML de los {len(deprecated_apis)} recursos indicados."
            )

        if missing_limits_k8s:
            self.add_finding(
                "warning",
                category,
                f"Se detectaron {len(missing_limits_k8s)} contenedores en Deployments/StatefulSets sin límites o requests de CPU/RAM.",
                f"Detalle: {', '.join(missing_limits_k8s)}. Esto impide una asignación eficiente del scheduler."
            )
            self.add_improvement(
                category,
                f"Definir requests y limits de CPU/RAM para los {len(missing_limits_k8s)} contenedores identificados en sus manifiestos."
            )

        if missing_probes:
            self.add_finding(
                "critical",
                category,
                f"Se detectaron {len(missing_probes)} contenedores en Deployments/StatefulSets sin sondeos de salud (Liveness y/o Readiness Probes).",
                f"Detalle: {', '.join(missing_probes[:10])}{(f' y {len(missing_probes)-10} más' if len(missing_probes) > 10 else '')}. Sin sondeos, Kubernetes no puede monitorear correctamente la disponibilidad y el ciclo de vida de la aplicación."
            )
            self.add_improvement(
                category,
                f"Configurar livenessProbe y readinessProbe en los manifiestos para los {len(missing_probes)} contenedores identificados."
            )

        if replicas_one:
            self.add_finding(
                "warning",
                category,
                f"Se detectaron {len(replicas_one)} Deployments ejecutándose con replicas: 1 (punto único de fallo).",
                f"Detalle: {', '.join(replicas_one[:10])}{(f' y {len(replicas_one)-10} más' if len(replicas_one) > 10 else '')}. Se desaprovecha la tolerancia a fallos innata de Kubernetes."
            )
            self.add_improvement(
                category,
                f"Incrementar el número de réplicas a mínimo 2 para los {len(replicas_one)} Deployments identificados."
            )

        if recreate_strategy:
            self.add_finding(
                "warning",
                category,
                f"Se detectaron {len(recreate_strategy)} Deployments utilizando la estrategia de actualización 'Recreate'.",
                f"Detalle: {', '.join(recreate_strategy[:10])}{(f' y {len(recreate_strategy)-10} más' if len(recreate_strategy) > 10 else '')}. Provoca indisponibilidad temporal (downtime) durante el proceso de despliegue."
            )
            self.add_improvement(
                category,
                f"Evaluar migrar a la estrategia de actualización 'RollingUpdate' en los {len(recreate_strategy)} Deployments identificados para despliegues Zero-Downtime."
            )

        if missing_antiaffinity:
            self.add_finding(
                "warning",
                category,
                f"Se detectaron {len(missing_antiaffinity)} cargas de trabajo con réplicas múltiples sin reglas de podAntiAffinity.",
                f"Detalle: {', '.join(missing_antiaffinity[:10])}{(f' y {len(missing_antiaffinity)-10} más' if len(missing_antiaffinity) > 10 else '')}. Corre el riesgo de que todas las réplicas del pod se ejecuten en el mismo nodo."
            )
            self.add_improvement(
                category,
                f"Añadir reglas de podAntiAffinity para distribuir las réplicas entre diferentes nodos físicos y maximizar la resiliencia."
            )
        # 5. Services Inventory
        log_info("Auditing Services per Namespace...")
        svc_stdout, _, svc_code = self.run_kubectl(["get", "svc", "-A", "-o", "json"])
        if svc_code == 0 and svc_stdout:
            try:
                svc_data = json.loads(svc_stdout)
                services_by_ns = {}
                for item in svc_data.get("items", []):
                    name = item.get("metadata", {}).get("name", "Unknown")
                    ns = item.get("metadata", {}).get("namespace", "Unknown")
                    svc_type = item.get("spec", {}).get("type", "Unknown")
                    cluster_ip = item.get("spec", {}).get("clusterIP", "None")
                    
                    if ns not in services_by_ns:
                        services_by_ns[ns] = []
                    services_by_ns[ns].append(f"{name} ({svc_type} - {cluster_ip})")
                
                self.report_data["inventory"][category]["Services"] = services_by_ns
            except json.JSONDecodeError:
                pass


    def get_ingress_hosts(self):
        """Extract Ingress hosts from Kubernetes if kubectl is functional."""
        hosts = set()
        if not check_binary("kubectl"):
            return hosts

        # Check API Server Host
        api_stdout, _, api_code = self.run_kubectl(["config", "view", "--minify", "-o", "jsonpath={.clusters[0].cluster.server}"])
        if api_code == 0 and api_stdout:
            # Parse host from URL e.g. https://192.168.49.2:8443
            match = re.search(r'https?://([^:/]+)', api_stdout)
            if match:
                hosts.add(match.group(1))

        # Check Ingresses
        ing_stdout, _, ing_code = self.run_kubectl(["get", "ingresses", "-A", "-o", "json"])
        if ing_code == 0 and ing_stdout:
            try:
                ing_data = json.loads(ing_stdout)
                for item in ing_data.get("items", []):
                    spec = item.get("spec", {})
                    # Add rule hosts
                    for rule in spec.get("rules", []):
                        host = rule.get("host")
                        if host:
                            hosts.add(host)
                    # Add TLS hosts
                    for tls in spec.get("tls", []):
                        for host in tls.get("hosts", []):
                            if host:
                                hosts.add(host)
            except json.JSONDecodeError:
                pass
        return hosts

    def check_ssl_expiry_openssl(self, host, port=443):
        """Check SSL certificate expiration date using openssl binary."""
        if not check_binary("openssl"):
            return None, "openssl binary not found"

        # Safe command to extract enddate from SSL certificate
        # echo | openssl s_client -connect host:port -servername host 2>/dev/null | openssl x509 -noout -enddate
        # In Python subprocess, we handle this via pipeline or passing empty input
        cmd_connect = ["openssl", "s_client", "-connect", f"{host}:{port}", "-servername", host, "-verify_hostname", host]
        cmd_x509 = ["openssl", "x509", "-noout", "-enddate"]

        try:
            # We run s_client and pass its output to x509
            p1 = subprocess.Popen(cmd_connect, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            # Send EOF to s_client immediately so it closes connection
            stdout_connect, _ = p1.communicate(input="\n", timeout=5)
            
            p2 = subprocess.Popen(cmd_x509, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            stdout_x509, stderr_x509 = p2.communicate(input=stdout_connect, timeout=5)
            
            if p2.returncode == 0 and "notAfter=" in stdout_x509:
                # e.g., notAfter=Jan 24 13:24:00 2027 GMT
                date_str = stdout_x509.replace("notAfter=", "").strip()
                return date_str, None
            else:
                return None, stderr_x509 or "Failed to extract certificate details"
        except Exception as e:
            return None, str(e)

    def parse_openssl_date(self, date_str):
        """Parse different openssl date formats safely into datetime."""
        # Standard format: Jan 24 13:24:00 2027 GMT
        # Try different formats
        formats = [
            "%b %d %H:%M:%S %Y %Z",
            "%b %d %H:%M:%S %Y",
            "%B %d %H:%M:%S %Y %Z",
            "%Y-%m-%d %H:%M:%S"
        ]
        
        # Remove multiple spaces if any
        clean_date = re.sub(r'\s+', ' ', date_str)
        
        for fmt in formats:
            try:
                # If GMT/UTC is in string, make it timezone aware or parse it
                # We strip timezone text in python for parsing and treat as UTC
                dt = datetime.datetime.strptime(clean_date, fmt)
                if dt.tzinfo is None:
                    dt = dt.replace(tzinfo=datetime.timezone.utc)
                return dt
            except ValueError:
                continue
                
        # If standard formats fail, try email parser (very robust for RFC-like dates)
        import email.utils
        try:
            dt = email.utils.parsedate_to_datetime(clean_date)
            return dt
        except Exception:
            return None

    def check_local_cert_expiry_openssl(self, filepath):
        """Extract subject and enddate from a local cert file using openssl x509."""
        if not check_binary("openssl"):
            return None, None, "openssl binary not found"
        try:
            # Run: openssl x509 -noout -subject -enddate -in <filepath>
            cmd = ["openssl", "x509", "-noout", "-subject", "-enddate", "-in", filepath]
            stdout, stderr, code = run_command(cmd, timeout=5)
            if code == 0 and stdout:
                subject = "Unknown"
                enddate = "Unknown"
                for line in stdout.split("\n"):
                    if line.startswith("subject="):
                        subject = line.replace("subject=", "").strip()
                    elif line.startswith("notAfter="):
                        enddate = line.replace("notAfter=", "").strip()
                return subject, enddate, None
            else:
                return None, None, stderr or "Failed to run openssl x509"
        except Exception as e:
            return None, None, str(e)

    def scan_host_pki_certificates(self):
        """Recursively scan PKI directories on the host filesystem for certs."""
        certs = []
        pki_paths = ["/etc/kubernetes/pki", "/var/lib/kubelet/pki"]
        
        for base_path in pki_paths:
            if not os.path.isdir(base_path):
                continue
            
            for root, _, files in os.walk(base_path):
                for file in files:
                    if file.endswith((".crt", ".pem")):
                        filepath = os.path.join(root, file)
                        subject, expiry_str, err = self.check_local_cert_expiry_openssl(filepath)
                        if subject and expiry_str:
                            expiry_dt = self.parse_openssl_date(expiry_str)
                            days_remaining = None
                            if expiry_dt:
                                now_utc = datetime.datetime.now(datetime.timezone.utc)
                                delta = expiry_dt - now_utc
                                days_remaining = delta.days
                            
                            certs.append({
                                "Path": filepath,
                                "Subject": subject,
                                "Expires": expiry_str,
                                "DaysRemaining": days_remaining
                            })
        return certs

    def parse_k8s_yaml_simple(self, file_path):
        """Parse a Kubernetes YAML file using simple line checks (zero-dependency)."""
        metadata = {"apiVersion": None, "kind": None, "name": None}
        try:
            with open(file_path, "r", encoding="utf-8", errors="ignore") as f:
                in_metadata = False
                for line in f:
                    line_strip = line.strip()
                    if not line_strip or line_strip.startswith("#") or line_strip.startswith("---"):
                        continue
                    
                    if ":" in line_strip:
                        parts = line_strip.split(":", 1)
                        key = parts[0].strip()
                        val = parts[1].strip().strip('"').strip("'")
                        
                        if key == "apiVersion":
                            metadata["apiVersion"] = val
                        elif key == "kind":
                            metadata["kind"] = val
                        elif key == "metadata":
                            in_metadata = True
                        elif in_metadata:
                            indent = len(line) - len(line.lstrip())
                            if indent == 0 and key != "metadata":
                                in_metadata = False
                            elif key == "name":
                                metadata["name"] = val
                                in_metadata = False
        except Exception:
            pass
        return metadata

    def audit_local_manifests(self):
        """Audit and locate Kubernetes YAML files on the host filesystem."""
        category = "Manifiestos Locales (YAML)"
        self.report_data["inventory"][category] = {
            "ManifestList": []
        }
        
        paths_to_scan = ["/etc/kubernetes", "/home", "/root"]
        exclude_dirs = {".git", ".cache", "node_modules", ".kube"}
        manifests = []
        
        log_info("Scanning host filesystem for Kubernetes YAML manifests...")
        
        for base_path in paths_to_scan:
            if not os.path.isdir(base_path):
                continue
            
            for root, dirs, files in os.walk(base_path):
                dirs[:] = [d for d in dirs if d not in exclude_dirs and not d.startswith(".")]
                
                for file in files:
                    if file.endswith((".yaml", ".yml")):
                        filepath = os.path.join(root, file)
                        meta = self.parse_k8s_yaml_simple(filepath)
                        if meta.get("kind") and meta.get("apiVersion"):
                            manifests.append({
                                "Path": filepath,
                                "Kind": meta["kind"],
                                "Name": meta.get("name", "Unknown"),
                                "APIVersion": meta["apiVersion"]
                            })
                            
        self.report_data["inventory"][category]["ManifestList"] = manifests

    # ─────────────────────────────────────────────────────────────────────────
    # NEW SECURITY, FINOPS & STORAGE AUDITS
    # These functions are completely independent and inject their results
    # directly into the shared findings / improvements lists so the existing
    # console/JSON renderers pick them up without any modification.
    # ─────────────────────────────────────────────────────────────────────────

    def audit_pod_security(self):
        """Evaluate Pod Security Context in Deployments, StatefulSets and DaemonSets."""
        category = "Seguridad de Cargas de Trabajo (Pod Security)"

        if not check_binary("kubectl"):
            return

        privileged_containers  = []
        non_root_missing       = []
        latest_tag_containers  = []

        system_namespaces = {
            "kube-system", "kube-public", "kube-node-lease",
            "calico-system", "calico-apiserver", "tigera-operator",
            "metallb-system", "cert-manager", "istio-system",
        }

        for resource_type in ["deployments", "statefulsets", "daemonsets"]:
            stdout, _, code = self.run_kubectl(["get", resource_type, "-A", "-o", "json"])
            if code != 0 or not stdout:
                continue
            try:
                data = json.loads(stdout)
            except json.JSONDecodeError:
                continue

            for item in data.get("items", []):
                name = item.get("metadata", {}).get("name", "Unknown")
                ns   = item.get("metadata", {}).get("namespace", "Unknown")
                ref  = f"{resource_type[:-1]} '{name}' ({ns})"

                pod_template_spec = (
                    item.get("spec", {})
                        .get("template", {})
                        .get("spec", {})
                )
                containers = (
                    pod_template_spec.get("containers", []) +
                    pod_template_spec.get("initContainers", [])
                )

                for c in containers:
                    c_name  = c.get("name", "?")
                    image   = c.get("image", "")
                    sc      = c.get("securityContext", {})

                    # 1. Privileged
                    if sc.get("privileged") is True:
                        privileged_containers.append(f"'{c_name}' en {ref}")

                    # 2. runAsNonRoot missing or False
                    run_as_non_root = sc.get("runAsNonRoot")
                    if run_as_non_root is not True:
                        # Also check pod-level securityContext
                        pod_sc = pod_template_spec.get("securityContext", {})
                        if pod_sc.get("runAsNonRoot") is not True:
                            non_root_missing.append(f"'{c_name}' en {ref}")

                    # 3. :latest tag
                    img_tag = image.split(":")[-1] if ":" in image else "latest"
                    if img_tag == "latest" or ":" not in image:
                        latest_tag_containers.append(f"'{c_name}' ({image}) en {ref}")

        # ── Emit consolidated findings ──
        if privileged_containers:
            self.add_finding(
                "critical", category,
                f"Se detectaron {len(privileged_containers)} contenedores ejecutándose en modo "
                f"PRIVILEGIADO (securityContext.privileged: true).",
                f"Contenedores: {', '.join(privileged_containers[:10])}"
                + (f" y {len(privileged_containers)-10} más" if len(privileged_containers) > 10 else "")
                + ". Un contenedor privilegiado tiene acceso completo al kernel del nodo host, "
                  "lo que representa un riesgo crítico de escape de contenedor."
            )
            self.add_improvement(
                category,
                f"Eliminar 'securityContext.privileged: true' de los {len(privileged_containers)} "
                "contenedores identificados y revisar si realmente necesitan acceso privilegiado al nodo.",
                impact="High"
            )

        if non_root_missing:
            self.add_finding(
                "warning", category,
                f"Se detectaron {len(non_root_missing)} contenedores sin 'securityContext.runAsNonRoot: true'.",
                f"Contenedores: {', '.join(non_root_missing[:10])}"
                + (f" y {len(non_root_missing)-10} más" if len(non_root_missing) > 10 else "")
                + ". Ejecutar como root dentro del contenedor aumenta el radio de impacto ante una "
                  "vulnerabilidad de escape de contenedor."
            )
            self.add_improvement(
                category,
                f"Añadir 'securityContext.runAsNonRoot: true' a los manifiestos de los "
                f"{len(non_root_missing)} contenedores identificados para reducir la superficie de ataque.",
                impact="High"
            )

        if latest_tag_containers:
            self.add_finding(
                "warning", category,
                f"Se detectaron {len(latest_tag_containers)} contenedores usando imagen con tag ':latest' "
                "o sin tag explícito.",
                f"Contenedores: {', '.join(latest_tag_containers[:10])}"
                + (f" y {len(latest_tag_containers)-10} más" if len(latest_tag_containers) > 10 else "")
                + ". El tag ':latest' no es inmutable y puede provocar despliegues inconsistentes "
                  "o inesperados entre entornos."
            )
            self.add_improvement(
                category,
                f"Reemplazar el tag ':latest' por un tag de versión semántica (ej. ':1.2.3' o SHA de imagen) "
                f"en los {len(latest_tag_containers)} contenedores identificados.",
                impact="Medium"
            )

        # Store summary in inventory for JSON output
        self.report_data["inventory"][category] = {
            "PrivilegedContainers":  len(privileged_containers),
            "NonRootMissing":        len(non_root_missing),
            "LatestTagContainers":   len(latest_tag_containers),
        }

    def audit_network_policies(self):
        """Check that business namespaces have at least one NetworkPolicy."""
        category = "Aislamiento de Red (NetworkPolicy)"

        if not check_binary("kubectl"):
            return

        system_namespace_prefixes = (
            "kube-", "calico-", "tigera-", "metallb-",
            "cert-manager", "istio-", "monitoring", "velero",
        )
        system_namespaces_exact = {
            "kube-system", "kube-public", "kube-node-lease",
            "calico-system", "calico-apiserver", "tigera-operator",
            "metallb-system", "istio-system", "lens-metrics",
        }

        # Fetch all namespaces
        ns_stdout, _, ns_code = self.run_kubectl(["get", "namespaces", "-o", "json"])
        if ns_code != 0 or not ns_stdout:
            return
        try:
            ns_data = json.loads(ns_stdout)
        except json.JSONDecodeError:
            return

        all_namespaces = [
            item.get("metadata", {}).get("name", "")
            for item in ns_data.get("items", [])
            if item.get("status", {}).get("phase") == "Active"
        ]

        business_namespaces = [
            ns for ns in all_namespaces
            if ns not in system_namespaces_exact
            and not any(ns.startswith(p) for p in system_namespace_prefixes)
        ]

        # Fetch all NetworkPolicies
        np_stdout, _, np_code = self.run_kubectl(["get", "networkpolicies", "-A", "-o", "json"])
        covered_namespaces = set()
        if np_code == 0 and np_stdout:
            try:
                np_data = json.loads(np_stdout)
                for item in np_data.get("items", []):
                    covered_namespaces.add(
                        item.get("metadata", {}).get("namespace", "")
                    )
            except json.JSONDecodeError:
                pass

        unprotected = [ns for ns in business_namespaces if ns not in covered_namespaces]

        self.report_data["inventory"][category] = {
            "BusinessNamespaces":    business_namespaces,
            "CoveredNamespaces":     sorted(covered_namespaces),
            "UnprotectedNamespaces": unprotected,
        }

        if unprotected:
            self.add_finding(
                "warning", category,
                f"Se detectaron {len(unprotected)} namespaces de negocio sin ningún NetworkPolicy.",
                f"Namespaces sin aislamiento: {', '.join(unprotected)}. "
                "Sin NetworkPolicies, todo pod dentro del clúster puede establecer conexiones "
                "con cualquier otro pod, aumentando el radio de impacto ante una brecha."
            )
            self.add_improvement(
                category,
                f"Definir NetworkPolicies de tipo 'deny-all' + reglas explícitas de entrada/salida "
                f"para los {len(unprotected)} namespaces identificados: {', '.join(unprotected)}.",
                impact="High"
            )
        else:
            self.add_finding(
                "info", category,
                "Todos los namespaces de negocio tienen al menos un NetworkPolicy configurado."
            )

    def audit_hpa_finops(self):
        """Cross-check HPAs vs Deployments; alert on missing HPAs or missing resource requests."""
        category = "FinOps / Escalado (HPA)"

        if not check_binary("kubectl"):
            return

        system_namespace_prefixes = (
            "kube-", "calico-", "tigera-", "metallb-",
            "cert-manager", "istio-", "lens-",
        )
        system_namespaces_exact = {
            "kube-system", "kube-public", "kube-node-lease",
            "calico-system", "calico-apiserver", "tigera-operator",
            "metallb-system", "istio-system",
        }

        def is_business_ns(ns):
            return (
                ns not in system_namespaces_exact
                and not any(ns.startswith(p) for p in system_namespace_prefixes)
            )

        # Fetch all Deployments in business namespaces
        dep_stdout, _, dep_code = self.run_kubectl(["get", "deployments", "-A", "-o", "json"])
        deployments = {}   # key: (ns, name) -> has_cpu_requests bool
        if dep_code == 0 and dep_stdout:
            try:
                dep_data = json.loads(dep_stdout)
                for item in dep_data.get("items", []):
                    ns   = item.get("metadata", {}).get("namespace", "")
                    name = item.get("metadata", {}).get("name", "")
                    if not is_business_ns(ns):
                        continue
                    containers = (
                        item.get("spec", {})
                            .get("template", {})
                            .get("spec", {})
                            .get("containers", [])
                    )
                    has_cpu_req = all(
                        c.get("resources", {}).get("requests", {}).get("cpu")
                        for c in containers
                    )
                    deployments[(ns, name)] = has_cpu_req
            except json.JSONDecodeError:
                pass

        # Fetch all HPAs
        hpa_stdout, _, hpa_code = self.run_kubectl(["get", "hpa", "-A", "-o", "json"])
        hpa_targets = {}   # key: (ns, deployment_name) -> hpa_name
        hpa_without_requests = []

        if hpa_code == 0 and hpa_stdout:
            try:
                hpa_data = json.loads(hpa_stdout)
                for item in hpa_data.get("items", []):
                    hpa_name    = item.get("metadata", {}).get("name", "Unknown")
                    ns          = item.get("metadata", {}).get("namespace", "")
                    target_ref  = item.get("spec", {}).get("scaleTargetRef", {})
                    target_kind = target_ref.get("kind", "")
                    target_name = target_ref.get("name", "")

                    if target_kind == "Deployment":
                        hpa_targets[(ns, target_name)] = hpa_name
                        # Check if the target deployment has CPU requests defined
                        cpu_ok = deployments.get((ns, target_name))
                        if cpu_ok is False:
                            hpa_without_requests.append(
                                f"HPA '{hpa_name}' -> Deployment '{target_name}' ({ns}) sin requests de CPU"
                            )
            except json.JSONDecodeError:
                pass

        deployments_without_hpa = [
            f"'{name}' ({ns})"
            for (ns, name) in deployments
            if (ns, name) not in hpa_targets
        ]

        self.report_data["inventory"][category] = {
            "BusinessDeployments": len(deployments),
            "HPAsConfigured":      len(hpa_targets),
            "DeploymentsWithoutHPA": deployments_without_hpa,
            "HPAsWithoutRequests":   hpa_without_requests,
        }

        if deployments_without_hpa:
            self.add_finding(
                "warning", category,
                f"Se detectaron {len(deployments_without_hpa)} Deployments de negocio sin "
                f"HorizontalPodAutoscaler (HPA) configurado.",
                f"Deployments: {', '.join(deployments_without_hpa[:10])}"
                + (f" y {len(deployments_without_hpa)-10} más" if len(deployments_without_hpa) > 10 else "")
                + ". Sin HPA, la capacidad de respuesta ante picos de tráfico es manual "
                  "y propenso a tiempos de respuesta degradados (FinOps: recursos sobredimensionados o infra insuficiente)."
            )
            self.add_improvement(
                category,
                f"Evaluar la implementación de HPA para los {len(deployments_without_hpa)} Deployments "
                "de negocio identificados, definiendo métricas de CPU y/o memoria como umbrales de escalado.",
                impact="Medium"
            )

        if hpa_without_requests:
            self.add_finding(
                "critical", category,
                f"Se detectaron {len(hpa_without_requests)} HPAs apuntando a Deployments "
                "sin 'requests' de CPU definidos.",
                f"HPAs afectados: {', '.join(hpa_without_requests)}. "
                "Un HPA basado en CPU no puede calcular el porcentaje de utilización si el "
                "Deployment no tiene 'requests.cpu', por lo que el autoscaler es completamente inefectivo."
            )
            self.add_improvement(
                category,
                "Definir 'resources.requests.cpu' en todos los contenedores de los Deployments "
                "con HPA configurado para que el autoscaler pueda funcionar correctamente.",
                impact="High"
            )

    def audit_storage(self):
        """Evaluate PersistentVolumeClaims status and backup tool presence."""
        category = "Almacenamiento y Recuperación (Storage)"

        if not check_binary("kubectl"):
            return

        pvc_stdout, _, pvc_code = self.run_kubectl(["get", "pvc", "-A", "-o", "json"])

        unbound_pvcs  = []
        all_pvcs      = []

        if pvc_code == 0 and pvc_stdout:
            try:
                pvc_data = json.loads(pvc_stdout)
                for item in pvc_data.get("items", []):
                    name   = item.get("metadata", {}).get("name", "Unknown")
                    ns     = item.get("metadata", {}).get("namespace", "Unknown")
                    phase  = item.get("status", {}).get("phase", "Unknown")
                    sc     = item.get("spec", {}).get("storageClassName", "N/A")
                    cap    = (
                        item.get("status", {})
                            .get("capacity", {})
                            .get("storage", "N/A")
                    )
                    all_pvcs.append({"Name": name, "Namespace": ns, "Phase": phase,
                                      "StorageClass": sc, "Capacity": cap})
                    if phase != "Bound":
                        unbound_pvcs.append(f"'{name}' ({ns}) - Fase: {phase}")
            except json.JSONDecodeError:
                pass

        # Backup tool detection: search deployment/pod names for known backup patterns
        backup_keywords = {"velero", "backup", "kasten", "k10", "stash", "restic"}
        has_backup = False

        dep_stdout, _, dep_code = self.run_kubectl(["get", "deployments", "-A", "-o", "json"])
        if dep_code == 0 and dep_stdout:
            try:
                dep_data = json.loads(dep_stdout)
                for item in dep_data.get("items", []):
                    dep_name = item.get("metadata", {}).get("name", "").lower()
                    dep_ns   = item.get("metadata", {}).get("namespace", "").lower()
                    if any(kw in dep_name or kw in dep_ns for kw in backup_keywords):
                        has_backup = True
                        break
            except json.JSONDecodeError:
                pass

        self.report_data["inventory"][category] = {
            "TotalPVCs":    len(all_pvcs),
            "UnboundPVCs":  len(unbound_pvcs),
            "PVCList":      all_pvcs,
            "BackupToolDetected": has_backup,
        }

        if unbound_pvcs:
            self.add_finding(
                "critical", category,
                f"Se detectaron {len(unbound_pvcs)} PersistentVolumeClaims (PVCs) en estado NO Bound.",
                f"PVCs afectados: {', '.join(unbound_pvcs)}. "
                "Un PVC en estado 'Pending' o 'Lost' significa que los pods que lo necesitan no podrán "
                "arrancar o perderán acceso a sus datos persistentes."
            )
            self.add_improvement(
                category,
                f"Revisar el aprovisionador de almacenamiento para los {len(unbound_pvcs)} PVCs "
                "en estado no-Bound. Verificar StorageClass, capacidad disponible y eventos del PVC "
                "con 'kubectl describe pvc <nombre> -n <namespace>'.",
                impact="High"
            )

        if not has_backup:
            self.add_improvement(
                category,
                "No se detectó ningún sistema de backup/recuperación ante desastres en el clúster "
                "(Velero, Kasten K10, Stash, etc.). Se recomienda implementar una solución de DR "
                "para proteger los PVCs y recursos críticos del clúster.",
                impact="High"
            )


    def audit_remediation_commands(self):
        """Generate exact kubectl CLI commands to remediate detected issues.

        Reads data already collected by previous audit methods (no new kubectl
        calls) and builds a list of actionable fix commands grouped by concern.
        Results are stored in report_data["inventory"][category] so both the
        console and markdown renderers can display them under section [5].
        """
        category = "Remediaci\u00f3n Autom\u00e1tica (Actionable Fixes)"
        commands = []

        # ── Helper: extract (ns, name) tuples from strings like "'name' (ns, ...)"
        # The format written by existing audits is: "'<name>' (<ns>[, extra...])"
        import re as _re

        def _parse_ns_name(entry: str):
            """Return (name, ns) parsed from the audit entry strings."""
            m = _re.match(r"'([^']+)'\s+\(([^,)]+)", entry)
            if m:
                return m.group(1), m.group(2).strip()
            return None, None

        # ── 1. HPAs faltantes  (data from audit_hpa_finops)
        hpa_inv = self.report_data["inventory"].get("FinOps / Escalado (HPA)", {})
        for entry in hpa_inv.get("DeploymentsWithoutHPA", []):
            name, ns = _parse_ns_name(entry)
            if name and ns:
                commands.append({
                    "concern": "HPA Faltante",
                    "target": entry.strip(),
                    "command": (
                        f"kubectl autoscale deployment {name} "
                        f"-n {ns} "
                        f"--cpu-percent=80 --min=2 --max=5"
                    ),
                    "note": "Aseg\u00farate de tener requests.cpu definidos en el Deployment antes de ejecutar."
                })

        # ── 2. Resources / QoS faltantes  (data from audit_k8s)
        k8s_inv = self.report_data["inventory"].get("Kubernetes (k8s)", {})
        quality_inv = k8s_inv.get("WorkloadQuality", {})
        for entry in quality_inv.get("MissingResourceLimits", []):
            # format: "'<container>' de deployment '<dep>' (<ns>, falta ...)"
            m2 = _re.match(r"'[^']+' de \w+ '([^']+)' \(([^,)]+)", entry)
            if m2:
                dep_name, ns = m2.group(1), m2.group(2).strip()
                commands.append({
                    "concern": "Recursos (requests/limits) faltantes",
                    "target": entry.strip(),
                    "command": (
                    f"kubectl set resources deployment {dep_name} "
                        f"-n {ns} "
                        f"--requests=cpu=100m,memory=128Mi "
                        f"--limits=cpu=500m,memory=512Mi"
                    ),
                    "note": "Ajusta los valores de CPU/memoria a los requisitos reales de la aplicación."
                })

        # ── 3. Probes faltantes  (data from audit_k8s)
        for entry in quality_inv.get("MissingProbes", []):
            # format: "'<container>' de deployment '<dep>' (<ns>, falta livenessProbe...)"
            m3 = _re.match(r"'([^']+)' de \w+ '([^']+)' \(([^,)]+)", entry)
            if m3:
                c_name, dep_name, ns = m3.group(1), m3.group(2), m3.group(3).strip()
                patch_json = (
                    '{"spec":{"template":{"spec":{"containers":['
                    + '{"name":"' + c_name + '",'
                    + '"livenessProbe":{"httpGet":{"path":"/healthz","port":8080},'
                    + '"initialDelaySeconds":15,"periodSeconds":20}}'
                    + ']}}}}'
                )
                commands.append({
                    "concern": "Probes faltantes",
                    "target": entry.strip(),
                    "command": "kubectl patch deployment " + dep_name + " -n " + ns + " -p '" + patch_json + "'",
                    "note": "Adapta path y port del livenessProbe al endpoint real de tu app antes de aplicar."
                })

        # SOLO genera texto sugerido. No ejecuta ningun cambio en el cluster.
        self.report_data["inventory"][category] = {"Commands": commands}

    def audit_yaml_linter(self):
        """Dry-run lint each locally discovered YAML manifest via kubectl apply.

        Reads the manifest list already built by audit_local_manifests() so no
        new filesystem scan is needed. Runs 'kubectl apply --dry-run=client -f
        <path>' for every file and captures any validation error. Results are
        stored in report_data["inventory"][category] for section [6].

        Hardening:
        - stdin=DEVNULL prevents kubectl from blocking on stdin.
        - Per-file timeout with explicit kill() ensures child processes are reaped.
        - Static control-plane manifests (etcd, kube-apiserver, etc.) are skipped
          because they always fail dry-run validation and are not user-managed.
        - Total files capped at MAX_LINT_FILES to avoid excessive runtime.
        """
        category = "Validaci\u00f3n de Manifiestos Locales (Linter)"
        results = []

        MAX_LINT_FILES = 30          # hard cap to avoid runaway linting
        PER_FILE_TIMEOUT = 8         # seconds; generous but bounded

        # Static manifests managed by kubeadm that always fail dry-run
        SKIP_FILENAMES = {
            "etcd.yaml", "kube-apiserver.yaml", "kube-controller-manager.yaml",
            "kube-scheduler.yaml", "kube-proxy.yaml",
        }
        # Skip entire directories: kubeadm statics and Helm chart template dirs
        # (Helm templates contain Go syntax {{ }} that kubectl cannot parse)
        SKIP_DIR_SUFFIXES = (
            "/etc/kubernetes/manifests",
            "/templates",        # Helm chart templates
            "/charts",           # Helm chart subdirs
            "/manifests/profiles",  # Istio profiles (IstioOperator CRDs, need server-side)
        )

        if not check_binary("kubectl"):
            self.report_data["inventory"][category] = {
                "Status": "No ejecutable localmente (kubectl no encontrado)",
                "Results": []
            }
            return

        manifest_inv = self.report_data["inventory"].get(
            "Manifiestos Locales (YAML)", {}
        )
        manifest_list = manifest_inv.get("ManifestList", [])

        if not manifest_list:
            self.report_data["inventory"][category] = {
                "Status": "Sin manifiestos locales para validar",
                "Results": []
            }
            return

        skipped = 0
        for manifest in manifest_list:
            if len(results) >= MAX_LINT_FILES:
                skipped += len(manifest_list) - manifest_list.index(manifest)
                break

            path = manifest.get("Path", "")
            if not path or not os.path.isfile(path):
                continue

            filename = os.path.basename(path)
            parent_dir = os.path.dirname(path)

            # Skip known static control-plane manifests and Helm template dirs
            if filename in SKIP_FILENAMES:
                skipped += 1
                continue
            if any(parent_dir.endswith(sfx) or (sfx in parent_dir) for sfx in SKIP_DIR_SUFFIXES):
                skipped += 1
                continue

            # Skip files containing Go template syntax (Helm) — kubectl cannot parse them
            try:
                with open(path, "r", encoding="utf-8", errors="ignore") as _f:
                    first_4k = _f.read(4096)
                if "{{" in first_4k and "}}" in first_4k:
                    skipped += 1
                    continue
            except OSError:
                pass

            # Skip files that are likely secrets/configs, not K8s objects
            if os.path.getsize(path) > 512 * 1024:   # skip files > 512 KB
                results.append({"Path": path, "Status": "Omitido", "Error": "Archivo demasiado grande (>512KB)"})
                continue

            proc = None
            try:
                proc = subprocess.Popen(
                    ["kubectl", "apply", "--dry-run=client", "-f", path],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    stdin=subprocess.DEVNULL,   # ← critical: no stdin blocking
                    text=True,
                )
                try:
                    stdout_data, stderr_data = proc.communicate(timeout=PER_FILE_TIMEOUT)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.communicate()           # drain pipes after kill
                    results.append({
                        "Path": path,
                        "Status": "Timeout",
                        "Error": f"kubectl no respondi\u00f3 en {PER_FILE_TIMEOUT}s \u2014 archivo omitido"
                    })
                    continue

                if proc.returncode == 0:
                    results.append({"Path": path, "Status": "V\u00e1lido", "Error": ""})
                else:
                    error_msg = (stderr_data or stdout_data or "Error desconocido").strip()
                    results.append({
                        "Path": path,
                        "Status": "YAML Inv\u00e1lido",
                        "Error": error_msg[:400]
                    })
                    self.add_finding(
                        "warning",
                        category,
                        f"YAML inv\u00e1lido detectado: {filename}",
                        f"Ruta: {path}. Error: {error_msg[:200]}"
                    )

            except Exception as e:
                if proc is not None:
                    try:
                        proc.kill()
                        proc.communicate()
                    except Exception:
                        pass
                results.append({"Path": path, "Status": "Error", "Error": str(e)})

        valid_count   = sum(1 for r in results if r["Status"] == "V\u00e1lido")
        invalid_count = sum(1 for r in results if r["Status"] == "YAML Inv\u00e1lido")
        timeout_count = sum(1 for r in results if r["Status"] == "Timeout")

        status_msg = "Completado"
        if skipped > 0:
            status_msg += f" ({skipped} archivo(s) omitido(s) \u2014 est\u00e1ticos del sistema o l\u00edmite alcanzado)"

        self.report_data["inventory"][category] = {
            "Status": status_msg,
            "Total": len(results),
            "Valid": valid_count,
            "Invalid": invalid_count,
            "Results": results
        }

    def audit_certificates(self):

        category = "Certificados y Seguridad"
        self.report_data["inventory"][category] = {
            "KubeadmCertificates": [],
            "LocalPKICertificates": [],
            "SSLDomains": []
        }

        # 1. Kubeadm Certificate Expiration
        is_control_plane = "control plane" in self.detected_role.lower() or "master" in self.detected_role.lower()
        if is_control_plane:
            if check_binary("kubeadm"):
                log_info("Checking kubeadm certificates expiration...")
                stdout, stderr, code = run_command(["kubeadm", "certs", "check-expiration"])
                if code != 0:
                    # Try older command format
                    stdout, stderr, code = run_command(["kubeadm", "alpha", "certs", "check-expiration"])
                    
                if code == 0 and stdout:
                    lines = stdout.split("\n")
                    # Parse lines. Format is usually:
                    # CERTIFICATE                EXPIRES                  RESIDUAL TIME   CERTIFICATE AUTHORITY   EXTERNALLY MANAGED
                    # admin.conf                 Dec 30, 2026 12:00 UTC   340d            ca                      no
                    started = False
                    for line in lines:
                        if "CERTIFICATE" in line and "EXPIRES" in line:
                            started = True
                            continue
                        if started and line.strip():
                            parts = re.split(r'\s{2,}', line.strip())
                            if len(parts) >= 3:
                                cert_name = parts[0]
                                expires_str = parts[1]
                                residual = parts[2]
                                
                                self.report_data["inventory"][category]["KubeadmCertificates"].append({
                                    "Certificate": cert_name,
                                    "Expires": expires_str,
                                    "ResidualTime": residual
                                })
                                
                                # Parse residual time like '340d' or '23h'
                                days_left = 999
                                match_days = re.match(r'(\d+)d', residual)
                                match_hours = re.match(r'(\d+)h', residual)
                                if match_days:
                                    days_left = int(match_days.group(1))
                                elif match_hours:
                                    days_left = 0
                                    
                                if days_left < 30:
                                    self.add_finding(
                                        "critical" if days_left < 7 else "warning",
                                        category,
                                        f"Certificado interno de Kubernetes '{cert_name}' expira en {residual}.",
                                        f"Expiración: {expires_str}. Si expira, el plano de control (control plane) dejará de funcionar."
                                    )
                                    self.add_improvement(
                                        category,
                                        f"Renovar los certificados internos del clúster ejecutando 'kubeadm certs renew all'."
                                    )
                else:
                    log_warn(f"kubeadm certs check-expiration failed: {stderr}")
                    self.report_data["inventory"][category]["KubeadmCertificates"] = f"Failed to check expiration: {stderr}"
                    self.add_finding(
                        "warning",
                        category,
                        "No se pudo verificar la expiración de certificados de kubeadm a pesar de estar en un nodo Control Plane.",
                        stderr
                    )
            else:
                log_warn("Running on Control Plane but kubeadm binary not found in PATH.")
                self.report_data["inventory"][category]["KubeadmCertificates"] = "kubeadm not available on control plane host"
                self.add_finding(
                    "warning",
                    category,
                    "No se encontró el binario 'kubeadm' en un nodo identificado como Control Plane.",
                    "Esto impide auditar la expiración de los certificados locales del plano de control."
                )
        else:
            log_info(f"Skipping kubeadm certificates check (not a Control Plane node, detected role: {self.detected_role})")
            self.report_data["inventory"][category]["KubeadmCertificates"] = f"No aplicable (el host no es un nodo de Control Plane. Rol detectado: {self.detected_role})"

        # 1.b. Local PKI Certificate Scan (Directly on Disk)
        log_info("Scanning host PKI directories for certificates...")
        local_certs = self.scan_host_pki_certificates()
        self.report_data["inventory"][category]["LocalPKICertificates"] = local_certs
        
        expiring_local = []
        for cert in local_certs:
            days = cert.get("DaysRemaining")
            if days is not None and days < 30:
                expiring_local.append(f"'{os.path.basename(cert['Path'])}' ({days} días)")
                
        if expiring_local:
            self.add_finding(
                "critical" if any(cert.get("DaysRemaining", 999) < 7 for cert in local_certs if cert.get("DaysRemaining") is not None) else "warning",
                category,
                f"Se detectaron {len(expiring_local)} certificados locales en disco próximos a expirar (< 30 días).",
                f"Certificados afectados: {', '.join(expiring_local)}. Si expiran, se interrumpirá la comunicación de los componentes del plano de control."
            )
            self.add_improvement(
                category,
                "Renovar los certificados del plano de control y el kubelet en el nodo host mediante kubeadm o el gestor de certificados del clúster."
            )

        # 2. SSL/TLS Verification for Ingress domains and Local components
        log_info("Autodetecting and auditing SSL/TLS endpoints...")
        hosts = self.get_ingress_hosts()
        
        # If no hosts detected but kubectl is connected, we can try localhost api endpoint as fallback
        if not hosts:
            hosts.add("localhost")
            
        now_utc = datetime.datetime.now(datetime.timezone.utc)

        for host in sorted(list(hosts)):
            # Check on port 443 (standard HTTPS) and port 6443 (Kubernetes API server default)
            ports_to_check = [443]
            if host in ["localhost", "127.0.0.1"] or "192.168" in host or "10." in host:
                ports_to_check.append(6443)
                
            for port in ports_to_check:
                # Test connectivity first
                try:
                    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                    s.settimeout(2)
                    s.connect((host, port))
                    s.close()
                except Exception:
                    # Skip if host:port is unreachable
                    continue

                log_info(f"Checking SSL for {host}:{port}...")
                date_str, err = self.check_ssl_expiry_openssl(host, port)
                
                if err:
                    self.report_data["inventory"][category]["SSLDomains"].append({
                        "Host": host,
                        "Port": port,
                        "Status": "Error",
                        "Error": err
                    })
                    continue

                expiry_date = self.parse_openssl_date(date_str)
                if expiry_date:
                    delta = expiry_date - now_utc
                    days_remaining = delta.days
                    
                    status = "Valid"
                    if days_remaining < 0:
                        status = "Expired"
                        self.add_finding(
                            "critical",
                            category,
                            f"Certificado SSL para '{host}:{port}' ha EXPIRADO.",
                            f"Expiró hace {-days_remaining} días. Esto bloquea todo tráfico legítimo de clientes."
                        )
                    elif days_remaining < 30:
                        status = "Critical (Expiring < 30d)"
                        self.add_finding(
                            "critical" if days_remaining < 10 else "warning",
                            category,
                            f"Certificado SSL para '{host}:{port}' expira en {days_remaining} días.",
                            f"Fecha de expiración: {expiry_date.strftime('%Y-%m-%d')}. Se requiere renovación inmediata."
                        )
                        self.add_improvement(
                            category,
                            f"Renovar el certificado SSL/TLS para el dominio '{host}' expuesto en el puerto {port}."
                        )
                        
                    self.report_data["inventory"][category]["SSLDomains"].append({
                        "Host": host,
                        "Port": port,
                        "Status": status,
                        "ExpiryDate": expiry_date.strftime('%Y-%m-%d %H:%M:%S UTC'),
                        "DaysRemaining": days_remaining
                    })
                else:
                    self.report_data["inventory"][category]["SSLDomains"].append({
                        "Host": host,
                        "Port": port,
                        "Status": "Parse Error",
                        "RawDate": date_str
                    })



    def audit_rbac_permissions(self):
        """Módulo 1: Auditoría RBAC (Permisos Excesivos)"""
        category = "Seguridad RBAC"
        stdout, stderr, code = run_command(["kubectl", "get", "clusterrolebindings", "-o", "json"])
        if code != 0:
            return
        
        try:
            data = json.loads(stdout)
            items = data.get("items", [])
            risky_sas = []
            
            for crb in items:
                role_ref = crb.get("roleRef", {})
                if role_ref.get("name") == "cluster-admin":
                    subjects = crb.get("subjects", [])
                    if not subjects:
                        continue
                    for sub in subjects:
                        if sub.get("kind") == "ServiceAccount" and sub.get("namespace") != "kube-system":
                            sa_name = f"{sub.get('namespace')}/{sub.get('name')}"
                            if sa_name not in risky_sas:
                                risky_sas.append(sa_name)
            
            if risky_sas:
                self.add_finding(
                    "critical",
                    category,
                    f"Se detectaron {len(risky_sas)} ServiceAccounts fuera de kube-system con rol cluster-admin.",
                    f"ServiceAccounts con permisos excesivos: {', '.join(risky_sas)}. Esto representa un riesgo crítico de escalado de privilegios."
                )
                self.add_improvement(
                    category,
                    "Revisar y revocar el rol 'cluster-admin' a las ServiceAccounts detectadas. Aplicar el principio de mínimo privilegio creando Roles/ClusterRoles específicos.",
                    "High"
                )
        except Exception:
            pass

    def audit_pdb_resilience(self):
        """Módulo 2: Resiliencia (Pod Disruption Budgets - PDB)"""
        category = "Resiliencia (PDB)"
        out_dep, err_dep, code_dep = run_command(["kubectl", "get", "deployments", "-A", "-o", "json"])
        out_pdb, err_pdb, code_pdb = run_command(["kubectl", "get", "pdb", "-A", "-o", "json"])
        
        if code_dep != 0 or code_pdb != 0:
            return
            
        try:
            deps_data = json.loads(out_dep)
            pdbs_data = json.loads(out_pdb)
            system_ns = {"kube-system", "kube-public", "kube-node-lease", "calico-system", "tigera-operator", "istio-system"}
            
            deployments_to_check = []
            for dep in deps_data.get("items", []):
                ns = dep["metadata"]["namespace"]
                if ns in system_ns:
                    continue
                replicas = dep.get("spec", {}).get("replicas", 1)
                if replicas > 1:
                    deployments_to_check.append(dep)
                    
            missing_pdb = []
            for dep in deployments_to_check:
                ns = dep["metadata"]["namespace"]
                name = dep["metadata"]["name"]
                dep_labels = dep.get("spec", {}).get("selector", {}).get("matchLabels", {})
                
                has_pdb = False
                for pdb in pdbs_data.get("items", []):
                    if pdb["metadata"]["namespace"] == ns:
                        pdb_labels = pdb.get("spec", {}).get("selector", {}).get("matchLabels", {})
                        if pdb_labels and all(item in dep_labels.items() for item in pdb_labels.items()):
                            has_pdb = True
                            break
                            
                if not has_pdb:
                    missing_pdb.append(f"'{name}' ({ns})")
                    
            if missing_pdb:
                self.add_finding(
                    "warning",
                    category,
                    f"Se detectaron {len(missing_pdb)} Deployments con múltiples réplicas sin Pod Disruption Budget (PDB).",
                    f"Deployments sin PDB: {', '.join(missing_pdb)}. Sin PDB, las interrupciones voluntarias (ej. drain de nodos) podrían causar downtime."
                )
                self.add_improvement(
                    category,
                    "Configurar Pod Disruption Budgets (PDB) para garantizar que un número mínimo de réplicas esté siempre disponible durante el mantenimiento de nodos.",
                    "Medium"
                )
        except Exception:
            pass

    def audit_ephemeral_storage(self):
        """Módulo 3: Límites de Almacenamiento Efímero"""
        category = "Kubernetes (k8s) - Storage"
        stdout, stderr, code = run_command(["kubectl", "get", "pods", "-A", "-o", "json"])
        if code != 0:
            return
            
        try:
            data = json.loads(stdout)
            missing_ephemeral = []
            
            for pod in data.get("items", []):
                ns = pod["metadata"]["namespace"]
                name = pod["metadata"]["name"]
                if pod.get("status", {}).get("phase") != "Running":
                    continue
                    
                containers = pod.get("spec", {}).get("containers", [])
                for c in containers:
                    limits = c.get("resources", {}).get("limits", {})
                    if "ephemeral-storage" not in limits:
                        missing_ephemeral.append(f"'{c.get('name')}' en pod '{name}' ({ns})")
            
            if missing_ephemeral:
                detail_str = ", ".join(missing_ephemeral[:15])
                if len(missing_ephemeral) > 15:
                    detail_str += f" y {len(missing_ephemeral) - 15} más"
                
                self.add_improvement(
                    category,
                    f"Definir límites de 'ephemeral-storage' en {len(missing_ephemeral)} contenedores (ej. {detail_str}) para prevenir que un contenedor agote el disco del nodo y cause 'DiskPressure'.",
                    "Medium"
                )
        except Exception:
            pass

    def audit_anomalous_events(self):
        """Módulo 4: Análisis Predictivo (Eventos Warning)"""
        category = "Eventos Anómalos Recientes (Warning Events)"
        self.report_data["inventory"][category] = {"ReasonCounts": {}, "RecentEvents": []}
        
        stdout, stderr, code = run_command(["kubectl", "get", "events", "--field-selector", "type=Warning", "-A", "-o", "json"])
        if code != 0:
            return
            
        try:
            data = json.loads(stdout)
            items = data.get("items", [])
            
            def get_time(ev):
                return ev.get("lastTimestamp") or ev.get("eventTime") or ev.get("metadata", {}).get("creationTimestamp") or ""
                
            items.sort(key=get_time, reverse=True)
            recent_events = items[:15]
            
            reason_counts = {}
            for ev in items:
                reason = ev.get("reason", "Unknown")
                count = ev.get("count", 1)
                reason_counts[reason] = reason_counts.get(reason, 0) + count
                
            events_list = []
            for ev in recent_events:
                kind = ev.get("involvedObject", {}).get("kind", "")
                name = ev.get("involvedObject", {}).get("name", "")
                ns = ev.get("involvedObject", {}).get("namespace", "default")
                reason = ev.get("reason", "")
                msg = ev.get("message", "").replace("\n", " ")
                count = ev.get("count", 1)
                time = get_time(ev)
                
                events_list.append({
                    "time": time,
                    "target": f"{kind}/{name} ({ns})",
                    "reason": reason,
                    "count": count,
                    "message": msg
                })
                
            self.report_data["inventory"][category] = {
                "ReasonCounts": reason_counts,
                "RecentEvents": events_list
            }
        except Exception:
            pass


    def audit_root_cause_analysis(self):
        """Fase 3: Root-Cause Analysis para Pods fallando"""
        category = "Diagnóstico de Fallos (Root-Cause)"
        self.report_data["inventory"][category] = []
        
        # Buscar pods que NO estén Running ni Succeeded
        out, err, code = run_command(["kubectl", "get", "pods", "-A", "-o", "json"])
        if code != 0: return
        
        try:
            data = json.loads(out)
            broken_pods = []
            for pod in data.get("items", []):
                phase = pod.get("status", {}).get("phase", "")
                if phase not in ["Running", "Succeeded", "Pending"]:
                    broken_pods.append(pod)
                else:
                    # Chequear container statuses para CrashLoopBackOff
                    for cs in pod.get("status", {}).get("containerStatuses", []):
                        state = cs.get("state", {})
                        if "waiting" in state and state["waiting"].get("reason") == "CrashLoopBackOff":
                            broken_pods.append(pod)
                            break
                            
            import re
            err_pattern = re.compile(r'(?i)(exception|panic|error:|connection refused|fatal)')
            
            for pod in broken_pods:
                ns = pod["metadata"]["namespace"]
                name = pod["metadata"]["name"]
                
                # Fetch tail logs (try previous first, if empty try current)
                log_out, _, _ = run_command(["kubectl", "logs", name, "-n", ns, "--tail=30", "--previous"])
                if not log_out:
                    log_out, _, _ = run_command(["kubectl", "logs", name, "-n", ns, "--tail=30"])
                    
                matches = []
                for line in log_out.split("\n"):
                    if err_pattern.search(line):
                        matches.append(line.strip())
                        if len(matches) >= 3: # Max 3 líneas de error por pod
                            break
                            
                self.report_data["inventory"][category].append({
                    "Pod": f"{name} ({ns})",
                    "Phase": pod.get("status", {}).get("phase", "Unknown"),
                    "ExtractedErrors": matches if matches else ["No se detectaron palabras clave de error en los últimos 30 logs."]
                })
        except Exception:
            pass

    def audit_ingress_gateway(self):
        """Fase 3: Exposición de Red (Ingress/Gateway)"""
        category = "Exposición de Red (Ingress)"
        self.report_data["inventory"][category] = []
        
        out, err, code = run_command(["kubectl", "get", "ingress", "-A", "-o", "json"])
        if code != 0: return
        
        try:
            data = json.loads(out)
            for ing in data.get("items", []):
                ns = ing["metadata"]["namespace"]
                name = ing["metadata"]["name"]
                tls = ing.get("spec", {}).get("tls", [])
                rules = ing.get("spec", {}).get("rules", [])
                
                hosts = [r.get("host", "*") for r in rules]
                
                has_tls = len(tls) > 0
                if not has_tls:
                    self.add_finding(
                        "warning",
                        "Seguridad Ingress",
                        f"El Ingress '{name}' ({ns}) no tiene configuración TLS.",
                        f"Hosts expuestos en texto claro: {', '.join(hosts)}"
                    )
                
                self.report_data["inventory"][category].append({
                    "Ingress": f"{name} ({ns})",
                    "Hosts": hosts,
                    "TLS_Enabled": has_tls
                })
        except Exception:
            pass

    def audit_orphan_resources(self):
        """Fase 3: Recursos Huérfanos (ConfigMaps/Secrets)"""
        category = "Recursos Huérfanos"
        self.report_data["inventory"][category] = {"OrphanConfigMaps": [], "OrphanSecrets": []}
        
        # Saltamos namespaces del sistema para evitar ruido
        ignore_ns = {"kube-system", "kube-public", "kube-node-lease", "calico-system", "tigera-operator", "istio-system"}
        
        def get_items(res):
            out, _, code = run_command(["kubectl", "get", res, "-A", "-o", "json"])
            if code != 0: return []
            try: return json.loads(out).get("items", [])
            except Exception: return []

        pods = get_items("pods")
        cms = get_items("cm")
        secrets = get_items("secret")
        
        used_cms = set()
        used_secrets = set()
        
        # Buscar usos en pods
        for pod in pods:
            for vol in pod.get("spec", {}).get("volumes", []):
                if "configMap" in vol: used_cms.add(vol["configMap"].get("name"))
                if "secret" in vol: used_secrets.add(vol["secret"].get("secretName"))
            for c in pod.get("spec", {}).get("containers", []) + pod.get("spec", {}).get("initContainers", []):
                for envFrom in c.get("envFrom", []):
                    if "configMapRef" in envFrom: used_cms.add(envFrom["configMapRef"].get("name"))
                    if "secretRef" in envFrom: used_secrets.add(envFrom["secretRef"].get("name"))
                for env in c.get("env", []):
                    if "valueFrom" in env:
                        if "configMapKeyRef" in env["valueFrom"]: used_cms.add(env["valueFrom"]["configMapKeyRef"].get("name"))
                        if "secretKeyRef" in env["valueFrom"]: used_secrets.add(env["valueFrom"]["secretKeyRef"].get("name"))
                        
        orphan_cms = []
        for cm in cms:
            ns = cm["metadata"]["namespace"]
            name = cm["metadata"]["name"]
            if ns in ignore_ns or name.startswith("kube-root-ca.crt") or name.startswith("istio-ca-root-cert"): continue
            if name not in used_cms:
                orphan_cms.append(f"{name} ({ns})")
                
        orphan_secrets = []
        for sec in secrets:
            ns = sec["metadata"]["namespace"]
            name = sec["metadata"]["name"]
            type_sec = sec.get("type", "")
            if ns in ignore_ns or type_sec == "kubernetes.io/service-account-token" or type_sec == "helm.sh/release.v1": continue
            if name not in used_secrets:
                orphan_secrets.append(f"{name} ({ns})")
                
        self.report_data["inventory"][category]["OrphanConfigMaps"] = orphan_cms
        self.report_data["inventory"][category]["OrphanSecrets"] = orphan_secrets
        
        if orphan_cms or orphan_secrets:
            self.add_improvement(
                "Higiene del Clúster",
                f"Se detectaron {len(orphan_cms)} ConfigMaps y {len(orphan_secrets)} Secrets en namespaces de negocio que no están siendo usados por ningún Pod activo. Recomendamos revisarlos y eliminarlos para limpiar etcd.",
                "Low"
            )

    def generate_html_dashboard(self):
        """Fase 3: Generador de Reporte HTML Independiente"""
        meta = self.report_data["metadata"]
        
        html = f"""<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <title>SRE Audit Dashboard</title>
    <style>
        body {{ font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; background-color: #f4f6f8; margin: 0; padding: 20px; color: #333; }}
        h1, h2, h3 {{ color: #2c3e50; }}
        .header {{ background-color: #2c3e50; color: white; padding: 20px; border-radius: 8px; margin-bottom: 20px; }}
        .card {{ background-color: white; padding: 20px; border-radius: 8px; box-shadow: 0 4px 6px rgba(0,0,0,0.1); margin-bottom: 20px; }}
        .badge {{ display: inline-block; padding: 5px 10px; border-radius: 4px; font-weight: bold; color: white; font-size: 0.9em; }}
        .badge.critical {{ background-color: #e74c3c; }}
        .badge.warning {{ background-color: #f39c12; }}
        .badge.info {{ background-color: #3498db; }}
        table {{ width: 100%; border-collapse: collapse; margin-top: 10px; }}
        th, td {{ padding: 12px; text-align: left; border-bottom: 1px solid #ddd; }}
        th {{ background-color: #ecf0f1; }}
        pre {{ background-color: #2c3e50; color: #ecf0f1; padding: 10px; border-radius: 5px; overflow-x: auto; }}
    </style>
</head>
<body>
    <div class="header">
        <h1>🚀 DevOps / SRE Environment Audit</h1>
        <p><strong>Fecha (UTC):</strong> {meta['timestamp']} | <strong>Host:</strong> {meta['hostname']} ({meta['os']})</p>
    </div>
"""
        
        # Vulnerabilidades
        crit = self.report_data["findings"]["critical"]
        warn = self.report_data["findings"]["warnings"]
        
        html += "<div class='card'><h2>🔥 Hallazgos Críticos y Advertencias</h2>"
        html += "<table><tr><th>Nivel</th><th>Categoría</th><th>Descripción</th></tr>"
        for c in crit:
            html += f"<tr><td><span class='badge critical'>Critical</span></td><td>{c['category']}</td><td>{c['description']}<br><small>{c['detail']}</small></td></tr>"
        for w in warn:
            html += f"<tr><td><span class='badge warning'>Warning</span></td><td>{w['category']}</td><td>{w['description']}<br><small>{w['detail']}</small></td></tr>"
        html += "</table></div>"
        
        # Root Cause
        rc = self.report_data["inventory"].get("Diagnóstico de Fallos (Root-Cause)", [])
        if rc:
            html += "<div class='card'><h2>🕵️ Análisis de Causa Raíz (Pods Rotos)</h2>"
            for pod in rc:
                html += f"<h3>Pod: {pod['Pod']} (Estado: {pod['Phase']})</h3>"
                html += "<pre>" + "\n".join(pod['ExtractedErrors']) + "</pre>"
            html += "</div>"
            
        html += "</body></html>"
        return html
    def generate_markdown(self):
        m = []
        meta = self.report_data["metadata"]
        
        m.append("# REPORTE DE AUDITORÍA AUTOMATIZADA (DevOps / SRE)")
        m.append(f"**Fecha de Ejecución (UTC):** `{meta['timestamp']}`  ")
        m.append(f"**Host Ejecutor:** `{meta['hostname']}`  ")
        m.append(f"**Kernel del Host:** `{meta['kernel']}`  ")
        m.append(f"**Sistema Operativo:** `{meta['os']}`  ")
        m.append(f"**Rol del Host Detectado:** `{meta.get('detected_role', 'Unknown')}`  ")
        m.append(f"**Motivo de Detección:** *{meta.get('detected_role_reason', 'N/A')}*\n")
        
        m.append("---")
        
        # ----------------- SECCIÓN 1: VERSIONES -----------------
        m.append("## 1. Versiones de Componentes")
        m.append("Detalle de las versiones de los motores, orquestadores y el sistema host auditados:\n")
        
        versions = self.report_data["versions"]
        m.append("| Componente | Detalle / Versión |")
        m.append("| :--- | :--- |")
        
        for comp, detail in versions.items():
            if isinstance(detail, dict):
                detail_str = "<br>".join([f"**{k}**: `{v}`" for k, v in detail.items()])
            else:
                detail_str = f"`{detail}`"
            m.append(f"| {comp} | {detail_str} |")
        m.append("\n")

        # ----------------- SECCIÓN 2: INVENTARIO ACTUAL -----------------
        m.append("## 2. Inventario Actual")
        m.append("Resumen del estado operativo de los recursos descubiertos en el entorno:\n")
        
        inv = self.report_data["inventory"]
        
        # Docker Inventory
        docker_inv = inv.get("Docker / Containerd", {})
        if docker_inv and isinstance(docker_inv, dict):
            m.append("### 🐳 Docker / Containerd")
            m.append(f"- **Estado del Servicio:** `{docker_inv.get('ServiceStatus', 'N/A')}`")
            containers = docker_inv.get("Containers", {})
            if isinstance(containers, dict):
                m.append(f"- **Contenedores:** Total `{containers.get('Total', 0)}` (Activos: `{containers.get('Running', 0)}` | Detenidos: `{containers.get('Stopped', 0)}`)")
            else:
                m.append(f"- **Contenedores:** `{containers}`")
                
            dangling = docker_inv.get("DanglingImages", {})
            if isinstance(dangling, dict):
                space_mb = dangling.get("ReclaimableSpaceBytes", 0) / (1024 * 1024)
                m.append(f"- **Imágenes Huérfanas (Dangling):** `{dangling.get('Count', 0)}` (Espacio recuperable: `{space_mb:.2f} MB`)")
            m.append("")

        # Kubernetes Inventory
        k8s_inv = inv.get("Kubernetes (k8s)", {})
        if k8s_inv and isinstance(k8s_inv, dict):
            m.append("### ☸️ Kubernetes (k8s)")
            nodes = k8s_inv.get("Nodes", {})
            if isinstance(nodes, dict) and nodes.get("Total", 0) > 0:
                m.append(f"- **Nodos del Clúster:** `{nodes.get('Total', 0)}` (Listos: `{nodes.get('Ready', 0)}` | No Listos: `{nodes.get('NotReady', 0)}`)")
                m.append("\n**Lista de Nodos:**")
                m.append("| Nodo | Estado | Roles |")
                m.append("| :--- | :--- | :--- |")
                for node in nodes.get("NodeList", []):
                    status_emoji = "🟢 Ready" if node['Status'] == "Ready" else "🔴 NotReady"
                    m.append(f"| `{node['Name']}` | {status_emoji} | `{node['Roles']}` |")
                m.append("")
            else:
                m.append("- **Nodos del Clúster:** No se pudo obtener información de los nodos (sin conexión o clúster vacío).")

            # Metrics
            metrics = k8s_inv.get("NodeMetrics", [])
            if metrics:
                m.append("**Consumo de Recursos por Nodo:**")
                m.append("| Nodo | Uso CPU | % CPU | Uso Memoria | % Memoria |")
                m.append("| :--- | :--- | :--- | :--- | :--- |")
                for met in metrics:
                    m.append(f"| `{met['Node']}` | {met['CPU_Usage']} | {met['CPU_Percentage']} | {met['Memory_Usage']} | {met['Memory_Percentage']} |")
                m.append("")

            # Pods
            pods = k8s_inv.get("Pods", {})
            if pods:
                m.append("**Pods en Namespaces Críticos:**")
                m.append("| Namespace | Total Pods | En Ejecución | Con Fallos/Pendientes |")
                m.append("| :--- | :---: | :---: | :---: |")
                for ns, p_data in pods.items():
                    m.append(f"| `{ns}` | `{p_data.get('Total', 0)}` | `{p_data.get('Running', 0)}` | `{p_data.get('FailedOrPending', 0)}` |")
                m.append("")

                m.append("**Mapeo de Pods a Despliegues / Workloads:**")
                m.append("| Namespace | Pod | Estado | Parent Workload |")
                m.append("| :--- | :--- | :--- | :--- |")
                for ns, p_data in pods.items():
                    for detail in p_data.get("Details", []):
                        workload_str = f"`{detail.get('WorkloadKind', 'None')}/{detail.get('WorkloadName', 'None')}`"
                        m.append(f"| `{ns}` | `{detail['Name']}` | `{detail['Phase']}` | {workload_str} |")
                m.append("")

            # Services
            services = k8s_inv.get("Services", {})
            if services:
                m.append("**Servicios por Namespace:**")
                m.append("| Namespace | Servicio (Tipo - ClusterIP) |")
                m.append("| :--- | :--- |")
                for ns, svc_list in services.items():
                    for svc in svc_list:
                        m.append(f"| `{ns}` | `{svc}` |")
                m.append("")

            # SRE Stack
            sre_stack = k8s_inv.get("SREStack", {})
            if sre_stack:
                m.append("**Integración de Stack SRE y Observabilidad:**")
                m.append("| Componente | Estado |")
                m.append("| :--- | :--- |")
                for tool, status in sre_stack.items():
                    m.append(f"| {tool} | {status} |")
                m.append("")

        # Certificates & SSL
        cert_inv = inv.get("Certificados y Seguridad", {})
        if cert_inv and isinstance(cert_inv, dict):
            m.append("### 🔒 Certificados y SSL/TLS")
            
            # Kubeadm
            kubeadm_certs = cert_inv.get("KubeadmCertificates")
            if isinstance(kubeadm_certs, list) and kubeadm_certs:
                m.append("**Certificados de Plano de Control (kubeadm):**")
                m.append("| Certificado | Expiración | Tiempo Restante |")
                m.append("| :--- | :--- | :--- |")
                for cert in kubeadm_certs:
                    m.append(f"| `{cert['Certificate']}` | `{cert['Expires']}` | `{cert['ResidualTime']}` |")
                m.append("")
            elif isinstance(kubeadm_certs, str):
                m.append(f"- **Certificados Kubeadm:** {kubeadm_certs}")

            # Local PKI Certificates
            local_certs = cert_inv.get("LocalPKICertificates", [])
            if local_certs:
                m.append("**Certificados PKI en Disco del Host:**")
                m.append("| Ruta Archivo | Subject | Expiración | Días Restantes |")
                m.append("| :--- | :--- | :--- | :--- |")
                for cert in local_certs:
                    m.append(f"| `{cert['Path']}` | `{cert['Subject']}` | `{cert['Expires']}` | `{cert['DaysRemaining'] or 'N/A'}` |")
                m.append("")

            # SSL Domains
            ssl_domains = cert_inv.get("SSLDomains", [])
            if ssl_domains:
                m.append("**Endpoints SSL/TLS Auditados:**")
                m.append("| Host:Puerto | Estado | Expiración | Días Restantes |")
                m.append("| :--- | :--- | :--- | :--- |")
                for dom in ssl_domains:
                    status = dom.get("Status", "Unknown")
                    status_formatted = f"`{status}`"
                    if "Critical" in status or "Expired" in status:
                        status_formatted = f"🔴 **{status}**"
                    elif status == "Valid":
                        status_formatted = "🟢 Valid"
                    
                    exp = dom.get("ExpiryDate") or dom.get("RawDate") or dom.get("Error") or "N/A"
                    days = f"`{dom.get('DaysRemaining')}`" if dom.get("DaysRemaining") is not None else "N/A"
                    m.append(f"| `{dom['Host']}:{dom['Port']}` | {status_formatted} | `{exp}` | {days} |")
                m.append("")

        # Local YAML Manifests
        yaml_inv = inv.get("Manifiestos Locales (YAML)", {})
        if yaml_inv and isinstance(yaml_inv, dict):
            manifest_list = yaml_inv.get("ManifestList", [])
            if manifest_list:
                m.append("### 📄 Manifiestos Locales (YAML) en el Host")
                m.append("Se localizaron los siguientes archivos de manifiestos Kubernetes en el disco del host:")
                m.append("| Ruta Archivo | Kind | Nombre del Recurso | apiVersion |")
                m.append("| :--- | :--- | :--- | :--- |")
                for mn in manifest_list:
                    m.append(f"| `{mn['Path']}` | `{mn['Kind']}` | `{mn['Name']}` | `{mn['APIVersion']}` |")
                m.append("")

        # Host Inventory
        host_inv = inv.get("Entorno Host (Linux)", {})
        if host_inv and isinstance(host_inv, dict):
            m.append("### 💻 Entorno Host (Linux)")
            fw = host_inv.get("Firewall", {})
            m.append(f"- **Estado Firewall UFW:** `{fw.get('UFW', 'N/A')}`")
            m.append(f"- **Estado Firewall iptables:** `{fw.get('iptables', 'N/A')}`")
            m.append(f"- **Estado Firewall Firewalld:** `{fw.get('Firewalld', 'N/A')}`")
            m.append(f"- **Estado Firewall nftables:** `{fw.get('nftables', 'N/A')}`")
            
            exposed = host_inv.get("ExposedPorts", [])
            if exposed:
                m.append(f"- **Puertos expuestos (Escuchando en 0.0.0.0 o wildcard):**")
                port_list = [f"`{p['Protocol']}/{p['Port']}`" for p in exposed]
                m.append("  " + ", ".join(port_list))
            m.append("")

        # ----------------- SECCIÓN 3: CARENCIAS (VULNERABILIDADES / ERRORES) -----------------
        m.append("## 3. Carencias (Vulnerabilidades / Errores)")
        m.append("Listado de fallos críticos, vulnerabilidades detectadas y malas configuraciones:\n")

        findings = self.report_data["findings"]
        total_findings = len(findings["critical"]) + len(findings["warnings"]) + len(findings["info"])

        if total_findings == 0:
            m.append("🟢 **¡Felicidades! No se detectaron carencias críticas ni advertencias en el entorno.**\n")
        else:
            if findings["critical"]:
                m.append("### 🔴 Fallos Críticos / Vulnerabilidades Graves")
                m.append("Se requiere acción inmediata para solventar estos hallazgos:")
                for f in findings["critical"]:
                    m.append(f"- **[{f['category']}]** {f['description']}")
                    if f['detail']:
                        m.append(f"  *Detalle: {f['detail']}*")
                m.append("")

            if findings["warnings"]:
                m.append("### ⚠️ Advertencias / Desviaciones de Buenas Prácticas")
                m.append("Hallazgos de riesgo medio que comprometen el rendimiento, trazabilidad o seguridad:")
                for f in findings["warnings"]:
                    m.append(f"- **[{f['category']}]** {f['description']}")
                    if f['detail']:
                        m.append(f"  *Detalle: {f['detail']}*")
                m.append("")

            if findings["info"]:
                m.append("### ℹ️ Información Adicional")
                m.append("Hallazgos informativos sobre el estado de la infraestructura:")
                for f in findings["info"]:
                    m.append(f"- **[{f['category']}]** {f['description']}")
                    if f['detail']:
                        m.append(f"  *Detalle: {f['detail']}*")
                m.append("")

        # ----------------- SECCIÓN 4: PUNTOS DE MEJORA -----------------
        m.append("## 4. Puntos de Mejora y Recomendaciones")
        m.append("Plan de acción recomendado para fortalecer la infraestructura y optimizar el entorno:\n")

        improvements = self.report_data["improvements"]
        if not improvements:
            m.append("🟢 **No se requieren mejoras urgentes en el sistema actual.**\n")
        else:
            m.append("| Categoría | Recomendación Técnica | Impacto Estimado |")
            m.append("| :--- | :--- | :---: |")
            for imp in improvements:
                impact_formatted = imp.get("impact", "Medium")
                if impact_formatted == "High":
                    impact_formatted = "🔴 **High**"
                elif impact_formatted == "Medium":
                    impact_formatted = "🟡 **Medium**"
                else:
                    impact_formatted = "🟢 **Low**"
                    
                m.append(f"| {imp['category']} | {imp['recommendation']} | {impact_formatted} |")
            m.append("")

        # ----------------- SECCIÓN 5: REMEDIACIÓN AUTOMÁTICA -----------------
        m.append("## 5. Comandos de Remediación Sugeridos (Actionable Fixes)")
        m.append("Comandos CLI exactos para resolver los hallazgos detectados. "
                 "**Revisa y adapta cada comando antes de ejecutarlo en producción.**\n")

        remediation_inv = self.report_data["inventory"].get(
            "Remediación Automática (Actionable Fixes)", {}
        )
        remediation_cmds = remediation_inv.get("Commands", [])
        if remediation_cmds:
            m.append("| Tipo de Carencia | Objetivo | Comando Sugerido | Nota |")
            m.append("| :--- | :--- | :--- | :--- |")
            for cmd in remediation_cmds:
                m.append(
                    f"| {cmd['concern']} "
                    f"| `{cmd['target'][:60]}` "
                    f"| `{cmd['command']}` "
                    f"| {cmd['note']} |"
                )
            m.append("")
        else:
            m.append("🟢 **No se generaron comandos de remediación. "
                     "No se detectaron carencias accionables.**\n")

        # ----------------- SECCIÓN 6: LINTER DE YAMLS LOCALES -----------------
        m.append("## 6. Validación de Manifiestos Locales (Linter)")
        linter_inv = self.report_data["inventory"].get(
            "Validación de Manifiestos Locales (Linter)", {}
        )
        linter_status = linter_inv.get("Status", "No ejecutado")
        linter_results = linter_inv.get("Results", [])

        m.append(f"**Estado:** {linter_status}  ")
        if linter_results:
            total   = linter_inv.get("Total", len(linter_results))
            valid   = linter_inv.get("Valid", 0)
            invalid = linter_inv.get("Invalid", 0)
            m.append(f"**Total evaluados:** {total} | "
                     f"**Válidos:** {valid} | **Inválidos:** {invalid}\n")
            m.append("| Archivo | Estado | Error |")
            m.append("| :--- | :---: | :--- |")
            for r in linter_results:
                status_icon = "✅" if r["Status"] == "Válido" else "❌"
                err = r.get("Error", "").replace("\n", " ")[:150]
                m.append(f"| `{r['Path']}` | {status_icon} {r['Status']} | {err} |")
            m.append("")
        else:
            m.append("")


        # 7. EVENTOS ANÓMALOS RECIENTES (Warning Events)
        events_inv = self.report_data["inventory"].get("Eventos Anómalos Recientes (Warning Events)", {})
        if events_inv:
            counts = events_inv.get("ReasonCounts", {})
            recent = events_inv.get("RecentEvents", [])
            
            m.append("## 7. Eventos Anómalos Recientes (Warning Events)\n")
            if not recent:
                m.append("🟢 **No se detectaron eventos tipo Warning recientes.**\n")
            else:
                m.append("**Frecuencia por Motivo:**\n")
                for reason, count in sorted(counts.items(), key=lambda x: x[1], reverse=True):
                    m.append(f"- **{reason}**: {count} ocurrencias")
                m.append("\n**Últimos 15 eventos:**\n")
                m.append("| Timestamp | Motivo | Objetivo | Mensaje |")
                m.append("| :--- | :--- | :--- | :--- |")
                for ev in recent:
                    m.append(f"| `{ev['time']}` | ⚠️ **{ev['reason']}** | `{ev['target']}` | {ev['message'][:150]} |")
            m.append("")


        # Módulo 3: Root Cause & Ingress
        rc_inv = self.report_data["inventory"].get("Diagnóstico de Fallos (Root-Cause)", [])
        if rc_inv:
            m.append("## 8. Diagnóstico de Fallos (Root-Cause)\n")
            for pod in rc_inv:
                m.append(f"**Pod:** `{pod['Pod']}` (Phase: {pod['Phase']})")
                m.append("```text")
                for err_line in pod['ExtractedErrors']:
                    m.append(err_line)
                m.append("```\n")
        # Firm of the Auditor
        m.append("\n---")
        m.append("*Reporte generado automáticamente de forma no invasiva (solo lectura).*")
        return "\n".join(m)


    def generate_json(self):
        return json.dumps(self.report_data, indent=2)

    def generate_console_dashboard(self):
        m = []
        meta = self.report_data["metadata"]
        
        # Header
        m.append(f"{Colors.BOLD}{Colors.HEADER}======================================================================{Colors.ENDC}")
        m.append(f"{Colors.BOLD}{Colors.HEADER}            REPORTE DE AUDITORÍA AUTOMATIZADA (DevOps / SRE)          {Colors.ENDC}")
        m.append(f"{Colors.BOLD}{Colors.HEADER}======================================================================{Colors.ENDC}")
        m.append(f"  {Colors.BOLD}Fecha (UTC):{Colors.ENDC} {meta['timestamp']}")
        m.append(f"  {Colors.BOLD}Host Ejecutor:{Colors.ENDC} {meta['hostname']}")
        m.append(f"  {Colors.BOLD}Sistema Operativo:{Colors.ENDC} {meta['os']}")
        
        # Highlight Role
        role_color = Colors.OKGREEN
        role_str = meta.get('detected_role', 'Unknown')
        if "master" in role_str.lower() or "control" in role_str.lower():
            role_color = Colors.OKCYAN
        elif "worker" in role_str.lower():
            role_color = Colors.OKBLUE
        elif "externo" in role_str.lower() or "runner" in role_str.lower():
            role_color = Colors.WARNING
            
        m.append(f"  {Colors.BOLD}Rol del Host:{Colors.ENDC} {role_color}{Colors.BOLD}{role_str}{Colors.ENDC}")
        m.append(f"  {Colors.BOLD}Motivo Detección:{Colors.ENDC} {meta.get('detected_role_reason', 'N/A')}")
        m.append(f"{Colors.BOLD}{Colors.HEADER}----------------------------------------------------------------------{Colors.ENDC}")
        
        # 1. VERSIONES
        m.append(f"\n{Colors.BOLD}{Colors.OKCYAN}[1] Versiones de Componentes{Colors.ENDC}")
        versions = self.report_data["versions"]
        for comp, detail in versions.items():
            if isinstance(detail, dict):
                detail_str = " | ".join([f"{k}: {v}" for k, v in detail.items()])
            else:
                detail_str = str(detail)
            m.append(f"  * {Colors.BOLD}{comp}:{Colors.ENDC} {detail_str}")
            
        # 2. INVENTARIO
        m.append(f"\n{Colors.BOLD}{Colors.OKCYAN}[2] Resumen de Inventario{Colors.ENDC}")
        inv = self.report_data["inventory"]
        
        # Host/OS Exposed Ports
        host_inv = inv.get("Entorno Host (Linux)", {})
        if host_inv and isinstance(host_inv, dict):
            fw = host_inv.get("Firewall", {})
            m.append(f"  {Colors.BOLD}Firewall Status:{Colors.ENDC} UFW: {fw.get('UFW', 'N/A')} | iptables: {fw.get('iptables', 'N/A')} | Firewalld: {fw.get('Firewalld', 'N/A')} | nftables: {fw.get('nftables', 'N/A')}")
            exposed = host_inv.get("ExposedPorts", [])
            if exposed:
                port_list = [f"{p['Protocol']}/{p['Port']}" for p in exposed]
                m.append(f"  {Colors.BOLD}Puertos Abiertos:{Colors.ENDC} {', '.join(port_list)}")
        
        # Docker/Containerd
        docker_inv = inv.get("Docker / Containerd", {})
        if docker_inv and isinstance(docker_inv, dict):
            containers = docker_inv.get("Containers", {})
            if isinstance(containers, dict):
                m.append(f"  {Colors.BOLD}Contenedores:{Colors.ENDC} Total {containers.get('Total', 0)} (Activos: {containers.get('Running', 0)} | Detenidos: {containers.get('Stopped', 0)})")
            else:
                m.append(f"  {Colors.BOLD}Contenedores:{Colors.ENDC} {containers}")
                
        # Kubernetes Nodes
        k8s_inv = inv.get("Kubernetes (k8s)", {})
        if k8s_inv and isinstance(k8s_inv, dict):
            nodes = k8s_inv.get("Nodes", {})
            if isinstance(nodes, dict) and nodes.get("Total", 0) > 0:
                m.append(f"  {Colors.BOLD}Nodos Clúster ({nodes.get('Total', 0)}):{Colors.ENDC}")
                for node in nodes.get("NodeList", []):
                    status_str = f"{Colors.OKGREEN}Ready{Colors.ENDC}" if node['Status'] == "Ready" else f"{Colors.FAIL}NotReady{Colors.ENDC}"
                    m.append(f"    - {Colors.BOLD}{node['Name']}{Colors.ENDC}: {status_str} (Rol: {node['Roles']})")

            # Pods in execution mapped to parent workloads
            pods = k8s_inv.get("Pods", {})
            if pods:
                m.append(f"  {Colors.BOLD}Pods en Ejecución y sus Despliegues:{Colors.ENDC}")
                for ns in ["kube-system", "default"]:
                    p_data = pods.get(ns, {})
                    details = p_data.get("Details", [])
                    if details:
                        m.append(f"    {Colors.BOLD}Namespace: {ns}{Colors.ENDC}")
                        for pod_detail in details:
                            p_name = pod_detail["Name"]
                            p_phase = pod_detail["Phase"]
                            p_workload = f"{pod_detail.get('WorkloadKind', 'None')}/{pod_detail.get('WorkloadName', 'None')}"
                            phase_c = Colors.OKGREEN if p_phase == "Running" else Colors.FAIL
                            m.append(f"      - {p_name} -> {phase_c}{p_phase}{Colors.ENDC} (Workload: {p_workload})")

            # Services
            services = k8s_inv.get("Services", {})
            if services:
                m.append(f"  {Colors.BOLD}Servicios por Namespace:{Colors.ENDC}")
                for ns, svc_list in services.items():
                    m.append(f"    {Colors.BOLD}Namespace: {ns}{Colors.ENDC}")
                    for svc in svc_list:
                        m.append(f"      - {svc}")

            # SRE Stack status
            sre_stack = k8s_inv.get("SREStack", {})
            if sre_stack:
                m.append(f"  {Colors.BOLD}SRE/Observability Stack:{Colors.ENDC}")
                for tool, status in sre_stack.items():
                    status_color = Colors.OKGREEN if status == "Instalado" else Colors.WARNING
                    m.append(f"    - {Colors.BOLD}{tool}{Colors.ENDC}: {status_color}{status}{Colors.ENDC}")
                    
        # Certificates & SSL
        cert_inv = inv.get("Certificados y Seguridad", {})
        if cert_inv and isinstance(cert_inv, dict):
            kubeadm_certs = cert_inv.get("KubeadmCertificates")
            if isinstance(kubeadm_certs, list) and kubeadm_certs:
                m.append(f"  {Colors.BOLD}Vigencia de Certificados Kubeadm:{Colors.ENDC}")
                for cert in kubeadm_certs:
                    m.append(f"    - {cert['Certificate']} -> expira: {cert['Expires']} (restante: {cert['ResidualTime']})")
            
            local_certs = cert_inv.get("LocalPKICertificates", [])
            if local_certs:
                m.append(f"  {Colors.BOLD}Vigencia de Certificados PKI en Disco:{Colors.ENDC}")
                for cert in local_certs:
                    name = os.path.basename(cert['Path'])
                    days = cert['DaysRemaining']
                    days_str = f"{days} días" if days is not None else "Desconocido"
                    days_c = Colors.OKGREEN if (days is None or days >= 30) else (Colors.FAIL if days < 7 else Colors.WARNING)
                    m.append(f"    - {name} ({cert['Path']}) -> expira: {cert['Expires']} ({days_c}{days_str}{Colors.ENDC})")
            
            ssl_domains = cert_inv.get("SSLDomains", [])
            if ssl_domains:
                m.append(f"  {Colors.BOLD}Endpoints SSL/TLS:{Colors.ENDC} {len(ssl_domains)} auditados")
                for dom in ssl_domains:
                    status = dom.get("Status", "Unknown")
                    status_c = Colors.OKGREEN if status == "Valid" else Colors.FAIL
                    m.append(f"    - {dom['Host']}:{dom['Port']} -> {status_c}{status}{Colors.ENDC} (expira {dom.get('ExpiryDate', 'N/A')})")

        # Local YAML Manifests
        yaml_inv = inv.get("Manifiestos Locales (YAML)", {})
        if yaml_inv and isinstance(yaml_inv, dict):
            manifest_list = yaml_inv.get("ManifestList", [])
            if manifest_list:
                m.append(f"  {Colors.BOLD}Manifiestos Locales (YAML):{Colors.ENDC} {len(manifest_list)} archivos localizados en el host")
                    
        # 3. HALLAZGOS (VULNERABILIDADES Y ERRORES)
        m.append(f"\n{Colors.BOLD}{Colors.OKCYAN}[3] Carencias (Vulnerabilidades / Errores){Colors.ENDC}")
        findings = self.report_data["findings"]
        total_findings = len(findings["critical"]) + len(findings["warnings"]) + len(findings["info"])
        
        if total_findings == 0:
            m.append(f"  {Colors.OKGREEN}✓ No se detectaron carencias críticas ni advertencias en el entorno.{Colors.ENDC}")
        else:
            if findings["critical"]:
                m.append(f"  {Colors.BOLD}{Colors.FAIL}🔴 Fallos Críticos / Vulnerabilidades Graves:{Colors.ENDC}")
                for f in findings["critical"]:
                    m.append(f"    - {Colors.BOLD}[{f['category']}]{Colors.ENDC} {f['description']}")
                    if f['detail']:
                        m.append(f"      {Colors.OKBLUE}Detalle:{Colors.ENDC} {f['detail']}")
                        
            if findings["warnings"]:
                m.append(f"  {Colors.BOLD}{Colors.WARNING}⚠️ Advertencias / Desviaciones de Buenas Prácticas:{Colors.ENDC}")
                for f in findings["warnings"]:
                    m.append(f"    - {Colors.BOLD}[{f['category']}]{Colors.ENDC} {f['description']}")
                    if f['detail']:
                        m.append(f"      {Colors.OKBLUE}Detalle:{Colors.ENDC} {f['detail']}")
                        
            if findings["info"]:
                m.append(f"  {Colors.BOLD}{Colors.OKBLUE}ℹ️ Información Adicional:{Colors.ENDC}")
                for f in findings["info"]:
                    m.append(f"    - {Colors.BOLD}[{f['category']}]{Colors.ENDC} {f['description']}")
                    if f['detail']:
                        m.append(f"      {Colors.OKBLUE}Detalle:{Colors.ENDC} {f['detail']}")

        # 4. RECOMENDACIONES Y MEJORAS
        m.append(f"\n{Colors.BOLD}{Colors.OKCYAN}[4] Puntos de Mejora y Recomendaciones{Colors.ENDC}")
        improvements = self.report_data["improvements"]
        if not improvements:
            m.append(f"  {Colors.OKGREEN}✓ No se requieren mejoras urgentes en el sistema.{Colors.ENDC}")
        else:
            for idx, imp in enumerate(improvements, 1):
                impact = imp.get("impact", "Medium")
                if impact == "High":
                    imp_color = f"{Colors.FAIL}High{Colors.ENDC}"
                elif impact == "Medium":
                    imp_color = f"{Colors.WARNING}Medium{Colors.ENDC}"
                else:
                    imp_color = f"{Colors.OKGREEN}Low{Colors.ENDC}"
                m.append(f"  {idx}. {Colors.BOLD}[{imp['category']}]{Colors.ENDC} {imp['recommendation']}")
                m.append(f"     {Colors.BOLD}Impacto:{Colors.ENDC} {imp_color}")
                

        # 5. REMEDIACIÓN AUTOMÁTICA
        remediation_inv = self.report_data["inventory"].get(
            "Remediación Automática (Actionable Fixes)", {}
        )
        remediation_cmds = remediation_inv.get("Commands", [])
        m.append(f"\n{Colors.BOLD}{Colors.OKCYAN}[5] Comandos de Remediación Sugeridos (Actionable Fixes){Colors.ENDC}")
        if remediation_cmds:
            m.append(f"  {Colors.WARNING}⚠️  Revisa y adapta cada comando antes de ejecutarlo en producción.{Colors.ENDC}")
            grouped = {}
            for cmd in remediation_cmds:
                grouped.setdefault(cmd["concern"], []).append(cmd)
            for concern, items in grouped.items():
                m.append(f"  {Colors.BOLD}{concern} ({len(items)} elemento(s)):{Colors.ENDC}")
                for cmd in items:
                    m.append(f"    {Colors.OKBLUE}$ {cmd['command']}{Colors.ENDC}")
                    m.append(f"      {Colors.WARNING}Nota:{Colors.ENDC} {cmd['note']}")
        else:
            m.append(f"  {Colors.OKGREEN}✓ No se generaron comandos de remediación. Sin carencias accionables detectadas.{Colors.ENDC}")

        # 6. LINTER DE YAMLS LOCALES
        linter_inv = self.report_data["inventory"].get(
            "Validación de Manifiestos Locales (Linter)", {}
        )
        linter_status = linter_inv.get("Status", "No ejecutado")
        linter_results = linter_inv.get("Results", [])
        m.append(f"\n{Colors.BOLD}{Colors.OKCYAN}[6] Validación de Manifiestos Locales (Linter){Colors.ENDC}")
        m.append(f"  {Colors.BOLD}Estado:{Colors.ENDC} {linter_status}")
        if linter_results:
            total   = linter_inv.get("Total", len(linter_results))
            valid   = linter_inv.get("Valid", 0)
            invalid = linter_inv.get("Invalid", 0)
            m.append(f"  {Colors.BOLD}Total:{Colors.ENDC} {total}  |  "
                     f"{Colors.OKGREEN}Válidos: {valid}{Colors.ENDC}  |  "
                     f"{Colors.FAIL}Inválidos: {invalid}{Colors.ENDC}")
            for r in linter_results:
                if r["Status"] == "Válido":
                    status_c = Colors.OKGREEN
                    icon = "✓"
                else:
                    status_c = Colors.FAIL
                    icon = "✗"
                short_path = r["Path"]
                m.append(f"    {status_c}{icon}{Colors.ENDC} {short_path}")
                if r.get("Error"):
                    err_short = r["Error"].replace("\n", " ")[:160]
                    m.append(f"      {Colors.OKBLUE}Error:{Colors.ENDC} {err_short}")


        # 7. EVENTOS ANÓMALOS RECIENTES (Warning Events)
        events_inv = self.report_data["inventory"].get("Eventos Anómalos Recientes (Warning Events)", {})
        if events_inv:
            counts = events_inv.get("ReasonCounts", {})
            recent = events_inv.get("RecentEvents", [])
            
            m.append(f"\n{Colors.BOLD}{Colors.OKCYAN}[7] Eventos Anómalos Recientes (Warning Events){Colors.ENDC}")
            if not recent:
                m.append(f"  {Colors.OKGREEN}✓ No se detectaron eventos tipo Warning recientes.{Colors.ENDC}")
            else:
                m.append(f"  {Colors.BOLD}Frecuencia por Motivo (Reason):{Colors.ENDC}")
                for reason, count in sorted(counts.items(), key=lambda x: x[1], reverse=True):
                    m.append(f"    - {reason}: {count} ocurrencias")
                m.append(f"\n  {Colors.BOLD}Últimos 15 eventos:{Colors.ENDC}")
                for ev in recent:
                    m.append(f"    [{ev['time']}] {Colors.WARNING}{ev['reason']}{Colors.ENDC} en {ev['target']}")
                    m.append(f"      {ev['message'][:120]}...")


        # Módulo 3: Root Cause & Ingress
        rc_inv = self.report_data["inventory"].get("Diagnóstico de Fallos (Root-Cause)", [])
        if rc_inv:
            m.append(f"\n{Colors.BOLD}{Colors.FAIL}[8] Diagnóstico de Fallos (Root-Cause){Colors.ENDC}")
            for pod in rc_inv:
                m.append(f"  {Colors.BOLD}Pod:{Colors.ENDC} {pod['Pod']} (Phase: {pod['Phase']})")
                for err_line in pod['ExtractedErrors']:
                    m.append(f"    {Colors.WARNING}> {err_line[:120]}{Colors.ENDC}")
        m.append(f"\n{Colors.BOLD}{Colors.HEADER}======================================================================{Colors.ENDC}")
        m.append(f"{Colors.HEADER}* Reporte generado. *{Colors.ENDC}")
        return "\n".join(m)


def main():
    parser = argparse.ArgumentParser(description="Automated DevOps/SRE Environment Audit Script")
    parser.add_argument("-o", "--output", help="Output file path (without extension). Will create .md and/or .json files.")
    parser.add_argument("-f", "--format", choices=["markdown", "json", "console", "all"], default="console",
                        help="Format of the output report (default: console)")
    parser.add_argument("--kubeconfig", help="Path to kubeconfig file")
    args = parser.parse_args()

    auditor = EnvironmentAuditor(kubeconfig=args.kubeconfig)
    auditor.run_all()

    if args.output:
        # Write files if output target is specified
        if args.format in ["markdown", "all", "console"]:
            md_content = auditor.generate_markdown()
            with open(f"{args.output}.md", "w", encoding="utf-8") as f:
                f.write(md_content)
            log_info(f"Markdown report written to {args.output}.md")
        if args.format in ["json", "all"]:
            json_content = auditor.generate_json()
            with open(f"{args.output}.json", "w", encoding="utf-8") as f:
                f.write(json_content)
            log_info(f"JSON report written to {args.output}.json")
    else:
        # Print directly to stdout if no output file is specified
        if args.format == "console":
            print(auditor.generate_console_dashboard())
        elif args.format == "markdown":
            print(auditor.generate_markdown())
        elif args.format == "json":
            print(auditor.generate_json())
        elif args.format == "all":
            # Print console dashboard first
            print(auditor.generate_console_dashboard())

    # HTML is generated automatically regardless of output args
    try:
        html_content = auditor.generate_html_dashboard()
        html_file = f"{args.output}.html" if args.output else "sre_audit_report.html"
        with open(html_file, "w", encoding="utf-8") as f:
            f.write(html_content)
        log_info(f"HTML dashboard generated locally at: {html_file}")
    except Exception as e:
        log_warn(f"Failed to generate HTML report: {e}")


if __name__ == "__main__":
    main()
