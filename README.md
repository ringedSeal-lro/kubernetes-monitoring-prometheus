# Kubernetes Monitoring with Prometheus and Grafana

This repository automates the deployment of a Kubernetes monitoring stack using Prometheus, Grafana, MetalLB, and NGINX Ingress Controller. It provides installation and uninstallation scripts, together with Kubernetes manifests for external service access.

The main goal is to monitor Kubernetes resources and investigate whether Prometheus metrics can be used to analyze Apache Spark application executions without requiring a custom data collection program.

## Architecture

The project includes the following components:

- **Prometheus:** collects and stores time-series metrics from configured monitoring targets and supports PromQL queries.
- **Grafana:** provides dashboards and visualizations based on Prometheus data.
- **kube-prometheus-stack:** Helm chart that deploys Prometheus, Grafana, the Prometheus Operator, and additional monitoring components.
- **MetalLB:** allocates external IP addresses to `LoadBalancer` services and advertises them on the local network using Layer 2.
- **NGINX Ingress Controller:** provides an entry point for HTTP/HTTPS routing to applications exposed through Kubernetes Ingress resources.
    
- **Helm:** manages the installation and removal of the monitoring stack and the NGINX Ingress Controller.
    

## Repository Files

|File|Description|
|---|---|
|`IPPool.yaml`|Defines the MetalLB IP address pool and Layer 2 advertisement.|
|`prometheus-lb.yaml`|Exposes Prometheus through a MetalLB `LoadBalancer` service.|
|`grafana-lb.yaml`|Exposes Grafana through a MetalLB `LoadBalancer` service.|
|`install.sh`|Installs and configures the required components.|
|`uninstall.sh`|Removes the components installed by the project.|

## 1. Prerequisites

Before running the scripts, ensure that the environment has:

- An operational Kubernetes cluster.
- `kubectl` configured with sufficient cluster permissions.
- Helm installed.
- A working MetalLB-compatible local network configuration.
- Available IP addresses reserved for MetalLB.
- Network connectivity between clients and the cluster.
- Python 3 and PyYAML if automated `kube-proxy` configuration is enabled.
    

The reference configuration uses:

- MetalLB `v0.15.3`
- NGINX Ingress Controller chart `2.5.1`
- The `kube-prometheus-stack` chart from the Prometheus Community OCI registry
    

Check the active Kubernetes context before making changes:

```
kubectl config current-context
kubectl get nodes
helm version
```

## 2. IP Address Configuration

The example uses the following MetalLB address pool:

```
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: metallb-single-ip
  namespace: metallb-system
spec:
  addresses:
    - 192.168.1.240-192.168.1.250
  autoAssign: false
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: metallb-single-ip-adv
  namespace: metallb-system
spec:
  ipAddressPools:
    - metallb-single-ip
```

The example assigns the following addresses:

|Component|External IP|Port|
|---|---|---|
|NGINX Ingress Controller|`192.168.1.240`|Chart-configured service ports|
|Prometheus|`192.168.1.242`|`9090`|
|Grafana|`192.168.1.242`|`8080`|

Prometheus and Grafana share an IP address using MetalLB's `allow-shared-ip` annotation. This configuration requires compatible service settings and distinct service ports.

Ensure that these addresses are available on the local network and are not assigned to other devices or through DHCP.

If your network uses a different subnet, update `IPPool.yaml`, `prometheus-lb.yaml`, `grafana-lb.yaml`, and the installation script accordingly.

## 3. Installation

Make the scripts executable:

```
chmod +x install.sh uninstall.sh
```

Run the installation:

```
./install.sh
```

The script performs the following operations:

1. Checks the required commands, manifests, and cluster connectivity.
2. Installs MetalLB and waits for its components to become ready.
3. Applies `IPPool.yaml`.
4. Installs NGINX Ingress Controller using Helm and configures its service as `LoadBalancer`.
5. Installs `kube-prometheus-stack` in the `monitoring` namespace.
6. Applies `prometheus-lb.yaml` and `grafana-lb.yaml`.
7. Displays the resulting services and external IP addresses.
    

The script uses Helm's install-or-upgrade behavior for the Helm releases, allowing it to be run again to reconcile the installations.

### Optional kube-proxy Configuration

The script does not modify `kube-proxy` by default.

To configure `kube-proxy` to use IPVS and enable `strictARP`, run:

```
KUBEPROXY_CONFIGURE=true ./install.sh
```

This option requires Python 3 and PyYAML. It saves the original ConfigMap to `kube-proxy-backup.json` before changing the configuration.

**Important:** IPVS kernel modules must be available on all relevant Kubernetes nodes before enabling IPVS mode. The optional `CONFIGURE_LOCAL_NODE=true` setting only configures the machine running the script; it does not configure every cluster node.

```
CONFIGURE_LOCAL_NODE=true ./install.sh
```

Changing `kube-proxy` can affect cluster networking. Use this option only when required by your environment and after reviewing the current configuration.

## 4. Accessing Prometheus

After installation, check the Prometheus service:

```
kubectl get svc prometheus-lb -n monitoring
```

Open the Prometheus interface:

`http://192.168.1.242:9090`

You can also test the endpoint using `curl`:

```
curl http://192.168.1.242:9090
```

To inspect the service endpoints and pod labels:

```
kubectl get endpoints prometheus-lb -n monitoring
kubectl get pods -n monitoring --show-labels
```

The service selector must match the labels of the Prometheus pods created by the installed Helm chart.

## 5. Accessing Grafana

Check the Grafana service:

```
kubectl get svc grafana-lb -n monitoring
```

Open the Grafana interface:

`http://192.168.1.242:8080`

Test access:

```
curl http://192.168.1.242:8080
```

To retrieve the Grafana administrator password, run:

```
kubectl get secret prometheus-grafana -n monitoring \
  -o jsonpath='{.data.admin-password}' | base64 -d
echo
```

The Secret name may vary depending on the Helm release and chart configuration. If necessary, list the available Secrets:

```
kubectl get secrets -n monitoring
```

## 6. Inspecting Metrics

In Prometheus, open **Status → Targets** to inspect the configured scrape targets and their health.

The following PromQL expressions can be used to investigate Kubernetes resource metrics, provided the corresponding metrics are available.

CPU usage by pod:

```
sum by (pod) (
  rate(container_cpu_usage_seconds_total[1m])
)
```

Memory usage by pod:

```
sum by (pod) (
  container_memory_working_set_bytes
)
```

These expressions return data only if the metrics are exposed and scraped by Prometheus. Additional filters may be necessary to restrict results to specific namespaces or workloads.



## 7. Validation

Check the monitoring resources:

```
kubectl get pods -n monitoring
kubectl get svc -n monitoring
helm list -n monitoring
```

Check MetalLB:

```
kubectl get pods -n metallb-system
kubectl get ipaddresspools,l2advertisements -n metallb-system
```

Check the NGINX Ingress Controller:

```
kubectl get pods,svc -n nginx-ingress
```

Verify that Prometheus and Grafana services have the expected external IP address and working endpoints.

## 8. Troubleshooting

### External IP Address Is Pending

```
kubectl get svc -n monitoring
kubectl get ipaddresspools,l2advertisements -n metallb-system
kubectl get pods -n metallb-system
```

Check that the requested address belongs to the configured pool and that MetalLB is operational.

### Service Has No Endpoints

```
kubectl get endpoints prometheus-lb grafana-lb -n monitoring
kubectl get pods -n monitoring --show-labels
```

Verify that the service selectors match the intended pods.

### Metrics Are Missing

Inspect **Status → Targets** in Prometheus and verify that the relevant endpoints are being scraped successfully. Confirm that the exporters or application metrics endpoints are configured.

### Grafana Cannot Display Prometheus Data

Check the Prometheus data source configuration in Grafana. When both applications run in the same cluster, use the internal Kubernetes service address where appropriate.

## 9. Uninstallation

To remove the components installed by this project, run:

```
./uninstall.sh
```

The script requests confirmation before removing resources. To skip the interactive confirmation:

```
./uninstall.sh --yes
```

The script removes the Prometheus and Grafana external services, uninstalls the Helm releases for the monitoring stack and NGINX Ingress Controller, removes the MetalLB pool configuration, and removes the MetalLB installation.

If the original `kube-proxy` configuration was backed up by `install.sh`, the uninstallation script can restore it.

The script does not automatically unload IPVS kernel modules or remove `/etc/modules-load.d/ipvs.conf`.

**Warning:** removing MetalLB can affect other `LoadBalancer` services in the cluster. Only uninstall MetalLB if it is dedicated to this setup or you have verified that other applications do not depend on it.

The `monitoring` and `nginx-ingress` namespaces are not automatically deleted, avoiding accidental removal of unrelated resources.

## 10. Security and Operational Considerations

- The example exposes Prometheus and Grafana over HTTP without TLS.
- Restrict access to monitoring interfaces, particularly in shared or production environments.
- Configure HTTPS and appropriate authentication when required.
- Review Prometheus storage, persistence, and retention settings before running long experiments.
- Confirm that Spark metrics are exposed and scraped before using Prometheus for performance analysis.
- Back up important Kubernetes configuration before making networking changes.
- Review all IP addresses and resource names before deploying the scripts in a different environment.
    

## References

- [Prometheus Community Helm Charts](https://github.com/prometheus-community/helm-charts)
    
- [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
    
- [Prometheus Documentation](https://prometheus.io/docs/)
    
- [Grafana Documentation](https://grafana.com/docs/)
    
- [MetalLB Documentation](https://metallb.io/)
    
- [NGINX Ingress Controller Helm Chart](https://github.com/nginx/kubernetes-ingress)




