# Ephemeral Kubernetes PR Environments

Give every pull request its own live, isolated Kubernetes environment —
automatically, on demand, torn down when it's no longer needed.

Add a `test` label to a PR and a pipeline spins up a lightweight virtual
cluster, builds and deploys the PR's actual code, routes traffic to it
through a real domain with trusted HTTPS, and posts the live link back
as a comment on the PR. Remove the label or close the PR, and the whole
environment is destroyed , no orphaned infrastructure, no manual cleanup.

## Why this exists

The traditional way to give every PR a live preview is to provision a
full, dedicated Kubernetes cluster per environment. That's slow (cluster
provisioning commonly takes 30–45 minutes) and expensive (every cluster
bills its own control plane and worker nodes, whether or not anyone is
actually looking at it).

This project takes a different approach: one persistent, always-on host
cluster runs many lightweight **virtual clusters** ([vcluster](https://www.vcluster.com/)),
one per PR. Each virtual cluster is a fully isolated Kubernetes API
surface with its own namespaces, its own resources , while its actual
workloads run for real on the shared host. The result: environments
that spin up in under two minutes instead of tens of minutes, sharing
infrastructure instead of duplicating it.

See [ARCHITECTURE.md](./ARCHITECTURE.md) for how it fits together, and
[RUNBOOK.md](./RUNBOOK.md) for how to run and rebuild it , including the
real problems hit along the way and how they were solved.

## Quick start

**Prerequisites:** Docker, [kind](https://kind.sigs.k8s.io/), `kubectl`,
[Helm](https://helm.sh/), the [vcluster CLI](https://www.vcluster.com/docs/get-started),
a GitHub repo with Actions enabled, and a domain if you want real TLS.

```bash
# 1. Create the host cluster
kind create cluster --name node-cluster --config kind-config.yaml

# 2. Install the supporting stack (cert-manager, Gateway API, NGINX
#    Gateway Fabric, Actions Runner Controller) , see RUNBOOK.md for
#    the full sequence and why each piece is needed
bash cluster-setup.sh

# 3. Apply shared, persistent infrastructure
kubectl apply -f rbac.yaml
kubectl apply -f gateway.yaml

# 4. Add a `test` label to any PR in the repo , the pipeline takes it
#    from there
```

## Two working snapshots

This project was built in two deliberate stages, each tagged as a
complete, working milestone:

- [`local-kind-complete`](../../tree/local-kind-complete) , the full
  system running locally on `kind`: Ingress-based routing, `/etc/hosts`
  for local hostnames, self-signed internal traffic.
- [`cloud-aks-working`](../../tree/cloud-aks-working) , migrated to
  Azure AKS: Gateway API routing, real wildcard DNS, trusted
  Let's-Encrypt-issued HTTPS on every environment.

`main` reflects the current, cloud-based state.

## Tech stack

Kubernetes · AKS · vcluster · Gateway API · NGINX Gateway Fabric ·
GitHub Actions · Actions Runner Controller (ARC) · Helm · Docker/Buildx ·
cert-manager · Let's Encrypt · Cloudflare DNS · RBAC
