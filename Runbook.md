# Runbook

## Rebuilding the host cluster from scratch

### Local (kind)

```bash
kind delete cluster --name node-cluster
kind create cluster --name node-cluster --config kind-config.yaml
bash cluster-setup.sh          # cert-manager, Gateway API CRDs, NGINX
                                # Gateway Fabric, ARC controller
kubectl apply -f rbac.yaml
kubectl apply -f gateway.yaml
```

Early in this project, images were loaded manually into the kind node
with `kind load docker-image`, since kind has no registry of its own.
Once the CI pipeline started building and pushing images to a real
registry (Docker Hub), that step became unnecessary: a kind node can
reach the real internet like any other node, so it pulls from the
registry the same way an AKS node does. `kind load` is only worth
knowing about as a one-off manual tool for quick local testing without
running the full pipeline, not as part of the regular rebuild sequence.

### Cloud (AKS)

```bash
az group create --name <rg> --location <region>
az aks create --resource-group <rg> --name <cluster> \
  --node-count 1 --node-vm-size <available-size> --generate-ssh-keys
az aks get-credentials --resource-group <rg> --name <cluster>

bash cluster-setup.sh          # same script as local; nothing here is
                                # kind-specific
kubectl apply -f rbac.yaml
kubectl apply -f gateway.yaml  # nginx.service.type=LoadBalancer, not NodePort
```

No image-loading step, the app image is pushed to a real registry by
CI, and any node pulls it over the network.

## Rotating the GitHub token for ARC

Check **how the scale set was installed** before assuming a `kubectl`
Secret update is enough, see the Helm-vs-kubectl war story below. If
the token was passed as a literal Helm value
(`--set githubConfigSecret.github_token=...`), it must be rotated via
`helm upgrade --reuse-values --set githubConfigSecret.github_token=...`,
not `kubectl create secret`, or the update silently has no effect.

## War stories

Real problems hit during this build, and how they were actually
diagnosed and fixed, kept here because the diagnostic process is more
reusable than the specific fix.

### The four-layer DNS, TLS, and connectivity chain

**Symptom:** a script reading a vcluster's own kubeconfig Secret and
using it to `kubectl apply` inside the vcluster failed with a different
error almost every attempt.

**The actual chain, in the order it was hit:**
1. `localhost:8443` connection refused, the kubeconfig vcluster
   generates assumes a `vcluster connect` tunnel exists; inside a CI
   runner Pod, `localhost` means the runner Pod itself.
   **Fix:** rewrite `server:` to the vcluster's internal Service
   address instead.
2. `could not resolve host`, turned out to be a false alarm: the DNS
   check was run *before* the vcluster (and its Service) existed in
   that particular run. Lesson: "can't resolve X" often means "X
   doesn't exist yet," not "DNS is broken." Confirm the target exists
   (`kubectl get svc`) before suspecting resolution.
3. Once genuinely resolving, TLS handshake succeeded but failed
   validation: `x509: certificate is valid for ... not <fully-qualified
   name>`. The vcluster's self-signed certificate was issued for short
   hostnames (`pr-1`, `pr-1.vcluster-pr-1`), not the fully-qualified
   `...svc.cluster.local` form.
4. Switching to the short hostname reintroduced `connection refused` ,
   Kubernetes' DNS search-domain expansion (`ndots:5`,
   `arc-runners.svc.cluster.local` tried before the target's own
   namespace) resolved the short, ambiguous name incorrectly.

**Final fix:** skip hostname resolution entirely. Fetch the Service's
real ClusterIP directly via `kubectl get svc -o jsonpath`, use that IP
as `server:`, strip `certificate-authority-data`, and set
`insecure-skip-tls-verify: true`, an accepted tradeoff for
cluster-internal automation traffic that never leaves a trusted
network, not something acceptable for public-facing traffic.

**General lesson:** a network failure between two Pods is really three
independent questions, does the name resolve (DNS), does something
respond at that address (Service/Endpoints), and is what responded who
it claims to be (TLS). A fix at one layer can fully resolve its own
symptom while simply exposing the next layer's problem underneath.

### Gateway API: HTTPRoute silently not routing

**Symptom:** an `HTTPRoute` created inside a vcluster showed
`Accepted: True`, but the host's Gateway reported `Attached Routes: 0`,
and requests got a `Connection reset by peer` with completely empty
controller logs, meaning the request never reached the data-plane's
request-handling logic at all.

**Root cause, found in two parts:**
- vcluster does not sync Gateway API's `HTTPRoute` objects to the host
  by default; this must be explicitly enabled
  (`sync.toHost.gatewayApi.httpRoutes.enabled: true`).
- A `Gateway` created on the host is invisible to objects *inside* a
  vcluster (proven isolation working as intended), an `HTTPRoute`
  referencing it via `parentRefs` needs that Gateway explicitly
  **imported** into the vcluster (`sync.fromHost.gateways`), and even
  then, vcluster performs its own separate authorization check before
  allowing the reference, an explicit `allowedRoutes.overrides` entry
  is required in `vcluster.yaml`, on top of the real Gateway's own
  `allowedRoutes` field.

**Lesson:** an object showing `Accepted: True` on its own status only
confirms it validated structurally, it says nothing about whether it
actually attached to anything real. Check the *parent's* view
(`Attached Routes` count on the Gateway) as the actual source of truth.

### RBAC: permissions discovered incrementally, not designed upfront

The CI runner's `ClusterRole` was built by running the pipeline and
fixing each `forbidden` error as it appeared, in this order:

1. `namespaces`, `secrets`, and other core resources
2. `list`/`watch`, distinct from `get`, since a tool checking "does X
   already exist" needs `list`, not just `get`
3. `patch`, distinct from `update`, since Helm-based tools use partial
   patches rather than full replacements
4. `escalate`/`bind` on RBAC resources, needed because a tool that
   provisions another tool's RBAC must already hold every permission
   it's about to grant (Kubernetes' privilege-escalation prevention
   check)
5. `pods/exec`, a genuinely separate permission from `pods` itself,
   needed once Buildx's Kubernetes driver required executing commands
   inside its builder Pod

**Lesson:** Kubernetes RBAC subresources (`pods/exec`, `pods/log`,
`pods/portforward`) are entirely separate grants from their parent
resource, even though they're "about" the same object, broad access
to `pods` never implies access to `pods/exec`.

### Helm-managed secrets vs. `kubectl`-managed secrets

**Symptom:** ARC's listener failed with `401 Unauthorized: Bad
credentials` on every attempt, even after deleting and recreating the
Kubernetes Secret with a freshly-verified, working token (confirmed
directly against the GitHub API via `curl`).

**Root cause:** the scale set was originally installed with
`--set githubConfigSecret.github_token="$TOKEN"`, a **literal value**
passed through Helm, which Helm then owns and manages as part of the
release's own state. `kubectl create secret` updates a completely
different object that the deployed Pods were never actually reading
from.

**Fix:** `helm upgrade --reuse-values --set githubConfigSecret.github_token=<new>`,
updating the value through the tool that actually owns it.

**Lesson:** when a `kubectl`-level fix has no effect despite being
verifiably correct, check whether a higher-level tool (Helm, an
operator) owns that object instead and is silently overwriting or
ignoring out-of-band changes.

### Git: recovering from a corrupted submodule across multiple branches

A test-app directory was accidentally tracked as a nested git
repository (an unintentional submodule). Flattening it on one branch,
then merging/resetting across several other branches while mid-project,
produced a state where an entire working directory appeared to lose
every file except two git-ignored ones.

**Diagnosis path:** `git status` confirmed the working tree was clean
relative to the current branch's own last commit, meaning nothing was
lost from disk, only misunderstood which branch's history was actually
checked out. `git ls-tree -r <branch> --name-only` against each branch
individually revealed which ones had the real, flattened file content
and which still had an empty submodule "gitlink" placeholder.

**Fix:** identified the one branch with confirmed-complete, correct
history (`multiple-pr-test`), and used `git reset --hard <that-branch>`
on the others, rather than attempting to merge divergent, partially-
broken histories together.

**Lesson:** `git status` showing "clean" only means the working
directory matches *the currently checked-out commit*, it says nothing
about whether that commit itself is the one you meant to be on. When
files appear to vanish, check `git log --oneline` and `git ls-tree`
across every relevant branch before assuming data loss; `git reset`
(without `--hard`) never deletes commits, only moves what a branch
pointer refers to, and unreferenced commits remain recoverable via
`git reflog` for a considerable window afterward.
