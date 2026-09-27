#!/bin/bash
set -euo pipefail
source .env



#cert manager
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm install \
  cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set config.apiVersion="controller.config.cert-manager.io/v1alpha1" \
  --set config.kind="ControllerConfiguration" \
  --set config.enableGatewayAPI=true \
  --set crds.enabled=true

#gateway controller
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.1/standard-install.yaml
kubectl kustomize "https://github.com/nginx/nginx-gateway-fabric/config/crd/gateway-api/standard?ref=v2.7.2" | kubectl apply -f -
helm install ngf oci://ghcr.io/nginx/charts/nginx-gateway-fabric --create-namespace -n nginx-gateway --set nginx.service.type=NodePort
kubectl wait --timeout=5m -n nginx-gateway deployment/ngf-nginx-gateway-fabric --for=condition=Available

#vcluster
curl -L -o vcluster "https://github.com/loft-sh/vcluster/releases/latest/download/vcluster-linux-amd64" && sudo install -c -m 0755 vcluster /usr/local/bin && rm -f vcluster
vcluster --version
#arc
ARC_NS="github-runner"
helm install arc \
--namespace "${ARC_NS}" \
--create-namespace \
oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller
#secret
RUNNER_NS="arc-runners"
GITHUB_PAT=$GITHUB_TOKEN
kubectl create namespace $RUNNER_NS
kubectl create secret generic arc-github-config \
--namespace ${RUNNER_NS} \
--from-literal=github_token="${GITHUB_PAT}"

#runner replica set
INSTALLATION_NAME="runner-set"
NAMESPACE="${RUNNER_NS}"
GITHUB_CONFIG_URL="https://github.com/NIHAL-TP/Ephermal-Kubernetes"
helm install "${INSTALLATION_NAME}" \
-n "${NAMESPACE}" \
--set githubConfigUrl="${GITHUB_CONFIG_URL}" \
--set githubConfigSecret.github_token="${GITHUB_PAT}" \
oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set

kubectl apply -f rbac.yaml
kubectl apply -f gateway.yaml