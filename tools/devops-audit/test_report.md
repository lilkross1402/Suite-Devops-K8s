# REPORTE DE AUDITORÍA AUTOMATIZADA (DevOps / SRE)
**Fecha de Ejecución (UTC):** `2026-07-18T00:53:22.710739+00:00`  
**Host Ejecutor:** `DESKTOP-4ND5HHJ`  
**Kernel del Host:** `11`  
**Sistema Operativo:** `Windows-11-10.0.22631-SP0`  
**Rol del Host Detectado:** `Host No-Kubernetes (Externo)`  
**Motivo de Detección:** *No se detectaron procesos locales de Kubernetes (kubelet o control plane)*

---
## 1. Versiones de Componentes
Detalle de las versiones de los motores, orquestadores y el sistema host auditados:

| Componente | Detalle / Versión |
| :--- | :--- |
| Entorno Host (Linux) | **OS / Distribution**: `Windows AMD64`<br>**Kernel**: `11` |
| Docker / Containerd | `Docker version 24.0.6, build ed223bc` |
| Kubernetes (k8s) | `kubectl installed but no connection to cluster` |


## 2. Inventario Actual
Resumen del estado operativo de los recursos descubiertos en el entorno:

### 🐳 Docker / Containerd
- **Estado del Servicio:** `inactive (stopped)`
- **Contenedores:** Total `0` (Activos: `0` | Detenidos: `0`)
- **Imágenes Huérfanas (Dangling):** `0` (Espacio recuperable: `0.00 MB`)

### 🔒 Certificados y SSL/TLS
- **Certificados Kubeadm:** No aplicable (el host no es un nodo de Control Plane. Rol detectado: Host No-Kubernetes (Externo))
### 💻 Entorno Host (Linux)
- **Estado Firewall UFW:** `Not Installed`
- **Estado Firewall iptables:** `Not Installed`
- **Estado Firewall Firewalld:** `Not Installed`
- **Estado Firewall nftables:** `Not Installed`

## 3. Carencias (Vulnerabilidades / Errores)
Listado de fallos críticos, vulnerabilidades detectadas y malas configuraciones:

### 🔴 Fallos Críticos / Vulnerabilidades Graves
Se requiere acción inmediata para solventar estos hallazgos:
- **[Entorno Host (Linux)]** No se detectó ningún firewall activo (UFW, iptables, Firewalld o nftables).
  *Detalle: El host está expuesto directamente sin protección de filtrado a nivel de red.*

### ⚠️ Advertencias / Desviaciones de Buenas Prácticas
Hallazgos de riesgo medio que comprometen el rendimiento, trazabilidad o seguridad:
- **[Kubernetes (k8s)]** No se puede establecer conexión con el clúster Kubernetes.
  *Detalle: E0717 20:53:25.960261   38120 memcache.go:265] couldn't get current server API group list: Get "http://localhost:8080/api?timeout=32s": dial tcp [::1]:8080: connectex: No connection could be made because the target machine actively refused it.
E0717 20:53:28.329238   38120 memcache.go:265] couldn't get current server API group list: Get "http://localhost:8080/api?timeout=32s": dial tcp [::1]:8080: connectex: No connection could be made because the target machine actively refused it.
E0717 20:53:30.653252   38120 memcache.go:265] couldn't get current server API group list: Get "http://localhost:8080/api?timeout=32s": dial tcp [::1]:8080: connectex: No connection could be made because the target machine actively refused it.
E0717 20:53:32.992345   38120 memcache.go:265] couldn't get current server API group list: Get "http://localhost:8080/api?timeout=32s": dial tcp [::1]:8080: connectex: No connection could be made because the target machine actively refused it.
E0717 20:53:35.327038   38120 memcache.go:265] couldn't get current server API group list: Get "http://localhost:8080/api?timeout=32s": dial tcp [::1]:8080: connectex: No connection could be made because the target machine actively refused it.
Unable to connect to the server: dial tcp [::1]:8080: connectex: No connection could be made because the target machine actively refused it.*

## 4. Puntos de Mejora y Recomendaciones
Plan de acción recomendado para fortalecer la infraestructura y optimizar el entorno:

| Categoría | Recomendación Técnica | Impacto Estimado |
| :--- | :--- | :---: |
| Entorno Host (Linux) | Habilitar y configurar un firewall local (como UFW, iptables, firewalld o nftables) permitiendo únicamente los puertos necesarios. | 🟡 **Medium** |


---
*Reporte generado automáticamente de forma no invasiva (solo lectura).*