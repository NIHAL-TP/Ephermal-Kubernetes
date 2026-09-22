#!/bin/bash
set -euo pipefail
source .env
#cert manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.19.4/cert-manager.yaml
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

