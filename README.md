# KubeOps-Suite

> **Principal Platform Automation** — Kubernetes Provisioning & Management CLI  
> Soporte para entornos **Online** y **Air-Gapped** | Ubuntu/Debian & RHEL/Rocky

---

## ¿Qué es KubeOps-Suite?

KubeOps-Suite es una aplicación CLI completa, interactiva y modular escrita en Bash puro, diseñada para aprovisionar y gestionar clústeres de Kubernetes y microservicios en cualquier entorno — con o sin acceso a internet.

## Inicio Rápido

```bash
# Clonar / copiar la suite
cd kubeops-suite/

# Dar permisos de ejecución
chmod +x kubeops.sh modules/*.sh stack/*.sh lib/*.sh

# Ejecutar como root (requerido para operaciones de sistema)
sudo ./kubeops.sh
```

## Estructura de Directorios

```
kubeops-suite/
├── kubeops.sh              # ← PUNTO DE ENTRADA — Menú interactivo principal
├── lib/
│   ├── logger.sh           # Logging con colores ANSI, spinners, progress bars
│   ├── os_detect.sh        # Detección OS (Ubuntu/Debian, RHEL/Rocky) + package manager
│   ├── network_check.sh    # Detección Online/Air-Gapped + probes TCP/ICMP
│   └── state_manager.sh    # Estado persistente JSON (IPs, tokens, roles)
├── modules/
│   ├── 01_registry.sh      # Registro de imágenes local (Air-Gap)
│   ├── 02_containerd.sh    # Runtime containerd/Docker
│   ├── 03_k8s_master.sh    # Inicialización Master + generación de tokens
│   ├── 04_k8s_worker.sh    # Join de Worker (lee token automáticamente)
│   └── 05_cluster_info.sh  # Estado, nodos, pods y comandos Join
├── stack/
│   ├── deploy_monitoring.sh # Prometheus + Grafana + Alertmanager
│   ├── deploy_kong.sh       # Kong API Gateway
│   └── deploy_redis.sh      # Redis cache
└── offline-assets/          # ← Colocar binarios/tarballs aquí para Air-Gap
    └── README.md
```

## Menú Principal

```
  [1] 🏭  Local Image Registry        → Docker Registry v2 (Air-Gap)
  [2] ⚙️   Install Container Runtime   → containerd installation
  [3] 🎯  Initialize Master Node      → kubeadm init (primer control plane)
  [4] 🔀  Add Master Node (HA)        → Unión control plane adicional
  [5] 💼  Add Worker Node             → Join con token automático
  [6] 🔍  Cluster Status & Join Cmds  → Estado completo + comandos
  [7] 📈  Observability Stack         → Prometheus + Grafana
  [8] 🦍  API Gateway (Kong)          → Kong + Ingress Controller
  [9] 🔴  Redis Cache                 → Redis via Helm/manifests
  [S]     Show Cluster State          → Estado JSON completo
  [B]     Backup State                → Backup timestamped
  [L]     View Logs                   → Tail de logs KubeOps
  [R]     Reset State                 → Limpiar datos de clúster
  [Q]     Quit
```

## Motor de Estado (`state_manager.sh`)

El state manager persiste automáticamente:

| Campo | Descripción |
|-------|-------------|
| `cluster.name` | Nombre del clúster |
| `cluster.initialized` | Si el master fue inicializado |
| `masters[].ip` | IPs de nodos master |
| `workers[].ip` | IPs de nodos worker |
| `join.token` | Token kubeadm generado |
| `join.ca_cert_hash` | Hash del CA certificate |
| `join.kubeadm_join_worker` | Comando join completo para workers |
| `join.kubeadm_join_master` | Comando join completo para HA masters |
| `registry.url` | URL del registro local |

**Archivo de estado:** `~/.kubeops/cluster-state.json`

## Flujo de Despliegue Recomendado

### Entorno Online
```
1. [3] Initialize Master  →  Instala K8s, configura kubeadm
2. [5] Add Worker         →  Lee token automáticamente, hace join
3. [7] Deploy Monitoring  →  Prometheus + Grafana vía Helm
```

### Entorno Air-Gapped
```
0. Copiar binarios a offline-assets/ (ver offline-assets/README.md)
1. [1] Local Registry     →  Levanta Docker Registry v2
2. [3] Initialize Master  →  Usa binarios locales + registry
3. [5] Add Worker         →  Lee token + apunta al registry local
```

## Uso No-Interactivo

```bash
# Inicializar master directamente
sudo ./kubeops.sh --run master

# Agregar worker con variables de entorno
sudo K8S_CONTROL_PLANE=192.168.1.10 ./kubeops.sh --run worker

# Ver estado
./kubeops.sh --run state

# Debug mode
sudo ./kubeops.sh --debug --run master

# Archivo de estado personalizado
sudo KUBEOPS_STATE_FILE=/mnt/shared/state.json ./kubeops.sh
```

## Variables de Entorno

| Variable | Default | Descripción |
|----------|---------|-------------|
| `K8S_VERSION` | `1.29` | Versión minor de Kubernetes |
| `K8S_VERSION_FULL` | `1.29.3` | Versión completa |
| `POD_CIDR` | `10.244.0.0/16` | CIDR de pods |
| `SERVICE_CIDR` | `10.96.0.0/12` | CIDR de servicios |
| `CNI_PLUGIN` | `flannel` | Plugin CNI: flannel/calico/cilium |
| `REGISTRY_PORT` | `5000` | Puerto del registro local |
| `KUBEOPS_LOG_LEVEL` | `INFO` | DEBUG/INFO/WARN/ERROR |
| `KUBEOPS_STATE_FILE` | `~/.kubeops/cluster-state.json` | Ruta al estado |

## Seguridad

- `kubeconfig` con permisos `600`
- Swap deshabilitado automáticamente
- Parámetros kernel hardened (`sysctl`)
- Firewall configurado automáticamente (UFW/firewalld)
- Pod Security Standards aplicados
- TLS para registry (opcional, self-signed)
- Tokens nunca expuestos en pantalla completa (mascarados)

## OS Soportados

| Distribución | Versión | Soporte |
|-------------|---------|---------|
| Ubuntu | 20.04 / 22.04 / 24.04 | ✅ Completo |
| Debian | 11 / 12 | ✅ Completo |
| RHEL | 8 / 9 | ✅ Completo |
| Rocky Linux | 8 / 9 | ✅ Completo |
| AlmaLinux | 8 / 9 | ✅ Completo |
| Amazon Linux 2 | latest | ⚠️ Parcial |

## Requisitos del Sistema

| Rol | CPU | RAM | Disco |
|-----|-----|-----|-------|
| Master | 2+ cores | 2GB+ | 20GB+ |
| Worker | 2+ cores | 1GB+ | 10GB+ |
| Registry | 1 core | 512MB+ | 50GB+ (imágenes) |

---

**KubeOps-Suite v1.0.0** — Principal Platform Engineering  
Licencia: MIT
