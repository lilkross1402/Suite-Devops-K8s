# offline-assets/

Este directorio está **vacío por defecto**.

Coloca aquí los binarios, tarballs e imágenes necesarios para el modo **Air-Gapped**.

## Archivos esperados

| Archivo | Descripción |
|---------|-------------|
| `containerd-<version>-linux-amd64.tar.gz` | Runtime containerd |
| `runc.amd64` | Binary runc |
| `cni-plugins-linux-amd64-<version>.tgz` | Plugins CNI |
| `kubeadm`, `kubelet`, `kubectl` | Binarios K8s individuales |
| `kubernetes-<version>.tar.gz` | Binarios K8s en tarball |
| `registry:2.tar` | Imagen Docker Registry v2 |
| `kube-flannel.yml` | Manifiesto CNI Flannel |
| `calico.yaml` | Manifiesto CNI Calico (alternativo) |
| `k8s-images-<version>.tar` | Imágenes de K8s pre-cargadas |
| `prometheus-stack-*.yaml` | Manifiestos Prometheus+Grafana |
| `kong-*.yaml` | Manifiestos Kong Gateway |
| `redis-*.yaml` | Manifiestos Redis |

## Cómo generar el bundle Air-Gap (en nodo con acceso a internet)

```bash
# Descargar binarios K8s
K8S_VERSION=1.29.3
curl -LO https://dl.k8s.io/v${K8S_VERSION}/bin/linux/amd64/kubeadm
curl -LO https://dl.k8s.io/v${K8S_VERSION}/bin/linux/amd64/kubelet
curl -LO https://dl.k8s.io/v${K8S_VERSION}/bin/linux/amd64/kubectl
chmod +x kubeadm kubelet kubectl

# Descargar containerd
CONTAINERD_VERSION=1.7.13
curl -LO https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz

# Descargar runc
RUNC_VERSION=1.1.12
curl -LO https://github.com/opencontainers/runc/releases/download/v${RUNC_VERSION}/runc.amd64

# Descargar CNI plugins
CNI_VERSION=1.4.0
curl -LO https://github.com/containernetworking/plugins/releases/download/v${CNI_VERSION}/cni-plugins-linux-amd64-v${CNI_VERSION}.tgz

# Exportar imágenes K8s pre-pull
kubeadm config images pull
kubeadm config images list | while read img; do
  name=$(echo $img | tr '/:' '__')
  docker save $img > k8s-image-${name}.tar
done

# Exportar imagen de registry
docker pull registry:2
docker save registry:2 > registry2.tar

# Descargar manifiesto Flannel
curl -LO https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml
```
