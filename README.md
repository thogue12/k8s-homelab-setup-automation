# k8s-homelab-setup

One command turns a fresh apt-based Ubuntu VM into a single-node Kubernetes
cluster running a public-facing identity provider. It provisions the node,
brings up a control plane that also schedules workloads, lays down networking,
storage, and image-admission policy, then installs Authentik and a Cloudflare
tunnel on top.

The defining property: **re-runs converge instead of failing.** Running
`./bootstrap.sh` a second time on a healthy cluster changes nothing and reports
`deployment is good - nothing to do`. The same command heals drift, resumes a
half-finished install, and verifies a complete one.

```
prereqs → control-plane → calico → storage → gatekeeper → authentik → cloudflared
```

---

## The idea

Most "set up my cluster" scripts are write-once: they assume a blank machine and
break if anything already exists (`kubeadm init` on a live control plane,
`kubectl create` on an existing object, `helm install` on a present release).
That makes them unsafe to re-run, which makes them unsafe to trust.

This pipeline is built the other way around. It describes a **desired end
state** and, on every run, reconciles the machine toward it:

- A **preflight** scan asks "what is already true?" for ~20 independent checks
  (is the control plane up? is Calico Available? is the Gatekeeper policy in
  deny mode? do the deployed image tags match the pinned versions?).
- Only the stages whose desired state is **unmet** are run.
- Each stage is written to be safe to run against a cluster where its work is
  already partly or fully done.

The result is a tool you can run repeatedly, interrupt, and re-run, and it will
always drive toward the same correct state.

---

## Idempotency: how it's enforced

Idempotency here is not a side effect — every stage earns it with a specific
technique. These are the patterns the code uses:

| Technique | Where | Why it's safe to re-run |
| --- | --- | --- |
| **Desired-state preflight** | `preflight.sh` | A stage runs only if its end state is unmet. Met stages are skipped and (if missing) backfilled into the ledger rather than re-executed. |
| **Guarded `kubeadm init`** | `20-control-plane.sh` | Init is skipped when a control plane is already detected (admin.conf, static manifests, or port 6443). It never re-inits a live cluster. |
| **`kubectl apply` (never `create`)** | calico, storage, gatekeeper | Apply converges: applying the same manifest twice is a no-op, not an error. |
| **Server-side apply `--force-conflicts`** | `30-calico.sh` | Re-asserting operator-owned fields (Tigera) co-owns them instead of failing on conflict. |
| **State-based waits, not timing** | `30-calico.sh` | Polls `tigerastatus` until Available; tolerates objects that don't exist yet instead of racing them. |
| **Declarative patches** | `50-gatekeeper.sh` | The dryrun→deny flip is a `replace` patch that converges to `deny` every time. |
| **`helm upgrade --install`** | authentik, cloudflared | Installs if absent, upgrades if present — same command either way. |
| **Skip-if-healthy + secret reuse** | authentik, cloudflared | A healthy release is left untouched and its secrets are **never regenerated**, so re-runs don't rotate credentials or disrupt a running app. |
| **Resume ledger** | `state/.bootstrap-state` | Records completed stages so interrupted runs resume rather than restart. Preflight remains authoritative over the ledger. |

If you only remember one rule when extending this pipeline: **add work as
`apply`/`upgrade --install`/declarative patches, gate it behind a desired-state
check, and verify the end state afterward.**

---

## What each piece does

### Top-level scripts

| File | Role |
| --- | --- |
| `bootstrap.sh` | **Orchestrator.** Runs preflight, computes the ordered run list, collects inputs up front, dispatches each stage in a subshell, records success in the ledger, and prints the final summary. Handles `--stage`, `--from`, `--only`, `-h`. |
| `preflight.sh` | **Desired-state scanner + input collector.** Runs one `scan_<check>` per desired-state item and emits the stages whose state is unmet. Also collects required `.env` inputs (generate / prompt / confirm) before any stage runs, so nothing blocks mid-dispatch. Refuses to run (rather than guess) if a control plane is live but unreachable. |
| `check.sh` | **Static-analysis gate.** `bash -n` on every script (mandatory), `shellcheck` when installed, `kubectl --dry-run=client` on the policy assets when a cluster is reachable, and the unit tests in `tests/`. Run this before committing. |
| `lib/common.sh` | **Shared library**, sourced by everything. Logging, the ERR trap, version pins, `.env` load/persist helpers, Helm/kubectl idempotency helpers, CIDR math, and the pinned component versions that preflight checks against. |

### Stages (run in order)

| Stage | File | What it does | How it stays idempotent |
| --- | --- | --- | --- |
| **prereqs** | `10-prereqs.sh` | Kernel modules, sysctl, swap off, containerd (systemd cgroup), `kubelet`/`kubeadm`/`kubectl`, `git`. | Package installs are no-ops when present; config is rewritten to the same desired content. |
| **control-plane** | `20-control-plane.sh` | `kubeadm init` with the resolved pod CIDR, installs your kubeconfig, removes the control-plane taint so the single node schedules pods. | Skips `init` when a control plane already exists; backs up any existing kubeconfig before replacing it. |
| **calico** | `30-calico.sh` | Installs the Calico CNI (Tigera operator) matched to the cluster's K8s version, with the pod CIDR injected. | `--server-side --force-conflicts`; waits on `tigerastatus` by polling. |
| **storage** | `40-storage.sh` | Rancher local-path provisioner as the default StorageClass. | Skips when the provisioner (at the pinned version) and the default annotation are already present; asserts exactly one default StorageClass. |
| **gatekeeper** | `50-gatekeeper.sh` | OPA Gatekeeper + a Chainguard image allowlist, applied at `dryrun` then flipped to `deny`. | All `apply`; the enforcement flip is a declarative patch that converges to `deny`. |
| **authentik** | `60-authentik.sh` | Authentik via the goauthentik Helm chart, with its bundled PostgreSQL enabled. | `helm upgrade --install`; skips when healthy; secrets reused, never regenerated. |
| **cloudflared** | `70-cloudflared.sh` | Cloudflare tunnel connector via the damienjburks cloudflared chart; the token lives only in a k8s Secret. Verifies the connector actually **registers** with Cloudflare, not just that Helm reports `deployed`. | `helm upgrade --install`; skips when healthy; creates its own namespace so it doesn't depend on the authentik stage. |

### Assets & policy

| File | Role |
| --- | --- |
| `assets/allowed-images-template.yaml` | Gatekeeper `ConstraintTemplate` (Rego) that checks every container image in Pods and Deployments against an allowlist. |
| `assets/only-chainguard-images.yaml` | The constraint: allow `cgr.dev/chainguard/*` plus **exact-tag** exceptions for the pipeline's own workloads (Authentik, its Postgres, cloudflared, local-path, busybox). System namespaces (kube-system, Calico, Gatekeeper) are excluded. |

### Tests & teardown

| File | Role |
| --- | --- |
| `tests/test-cidr-overlap.sh` | Unit tests for the pure-bash CIDR math (`_ip_to_int`, `cidr_overlap`, `intended_pod_cidr`). Runs offline; wired into `check.sh`. |
| `completly-whip-k8s.bash` *(separate dir)* | Destructive teardown: `kubeadm reset`, clears CNI/Calico/etcd/containerd state and the ledger, so a fresh rebuild is possible. Preserves `.env`. Prompts for confirmation. |

---

## Prerequisites

- An **apt-based Ubuntu VM** — this is the machine the pipeline provisions.
  **Do not run `bootstrap.sh` on your workstation**; it runs `kubeadm init`,
  installs containerd, disables swap, etc. Run it on a target VM.
- A user with **sudo** (prereqs and control-plane make node-level changes).
- **Outbound internet** (apt, container images, Helm charts, Cloudflare).
- A **Cloudflare tunnel token** from the Zero Trust dashboard (starts with `eyJ`).

---

## Quick start

```bash
git clone <your-repo-url> k8s-homelab-setup
cd k8s-homelab-setup
cp .env.example .env          # then edit values — see "Configuration" below
./bootstrap.sh
```

What happens on a fresh VM:

1. **Preflight** scans the node and (if present) the cluster, and prints which
   stages are needed.
2. **Inputs are collected up front** — Authentik's secret key and Postgres
   password are generated automatically; you're prompted once for the Cloudflare
   tunnel token; you confirm or override the pod CIDR. Nothing prompts
   mid-dispatch.
3. **Stages run in order.** Each success is recorded in the ledger.
4. On a healthy cluster a re-run prints:
   ```
   deployment is good - nothing to do
   ```

---

## Configuration (`.env`)

Secrets and tunable inputs live in a **gitignored** `.env` beside
`bootstrap.sh` (created at mode `0600`). Copy `.env.example` to `.env` and fill
it in. Existing values are **reused and never regenerated**.

| Key | Required? | How it's handled if blank | Notes |
| --- | --- | --- | --- |
| `AUTHENTIK_SECRET_KEY` | auto | Generated via `openssl rand -hex 32` | Authentik's signing key. |
| `AUTHENTIK_POSTGRES_PASSWORD` | auto | Generated via `openssl rand -hex 32` | Used for both the Authentik DB user and the bundled Postgres. |
| `CLOUDFLARE_TUNNEL_TOKEN` | **you provide** | Prompted interactively | From the Cloudflare Zero Trust dashboard; starts with `eyJ`. Stored only in a k8s Secret. |
| `POD_CIDR` | recommended | Confirmed/defaulted at init | **Must not overlap your LAN.** See below. |

### Set `POD_CIDR` carefully

The pod network is fixed at `kubeadm init` and **cannot be changed in place** —
getting it wrong means a full teardown and rebuild. The default is
`10.244.0.0/16`.

> **Do not use `192.168.0.0/16`** (Calico's upstream default) if your LAN is a
> `192.168.x.x` network. The pod CIDR would swallow your router/DNS, so pods
> can't reach the LAN and **all external DNS from pods breaks** (the Cloudflare
> tunnel never connects). Preflight guards against this and refuses to proceed.

If you run multiple clusters that might ever connect, give each a **distinct**
pod CIDR (e.g. `10.244.0.0/16`, `10.245.0.0/16`) so their networks don't collide.

Quoting note: `.env` is sourced by bash, so values use **single quotes**
(`KEY='value'`). This preserves `$`, backticks, etc. literally — important for
tokens. The persist helper escapes embedded quotes for you.

---

## Format of `.env` values

```dotenv
AUTHENTIK_SECRET_KEY='...'
AUTHENTIK_POSTGRES_PASSWORD='...'
POD_CIDR='10.244.0.0/16'
CLOUDFLARE_TUNNEL_TOKEN='eyJ...'
```

Leave a key blank in `.env` (or absent) to have the pipeline generate/prompt for
it. To **change** an already-set value, edit `.env` directly — the pipeline will
not overwrite a value that's already present.

---

## Running specific stages

```bash
./bootstrap.sh                    # reconcile everything that's unmet
./bootstrap.sh --stage calico     # run only one stage (alias: --only)
./bootstrap.sh --from storage     # run storage and everything after it
./bootstrap.sh -h                 # usage + stage list
```

Targeting flags always run the named stage(s), even if the ledger marks them
complete. Each stage is also runnable directly: `./stages/30-calico.sh`.

---

## Version pins & upgrades

Component versions are pinned in `lib/common.sh`
(`KB_GATEKEEPER_VERSION`, `KB_LOCAL_PATH_PROVISIONER_VERSION`,
`KB_AUTHENTIK_CHART_VERSION`, `KB_CLOUDFLARED_IMAGE_TAG`) and the Calico version
is resolved from the cluster's K8s minor. Preflight verifies the **running**
image tags match these pins, so drift shows up as an unmet check.

Because the Gatekeeper policy allows images by **exact tag**, upgrading a
component is a two-step change:

1. Bump the pin in `lib/common.sh`.
2. Update the matching exact-tag entry in `assets/only-chainguard-images.yaml`.
3. Re-apply the policy: `./bootstrap.sh --stage gatekeeper`.

Change only one and admission will reject the new image.

You can also override at runtime:

```bash
K8S_MINOR=v1.33 ./bootstrap.sh
CALICO_VERSION=v3.31.0 ./bootstrap.sh
POD_CIDR=10.245.0.0/16 ./bootstrap.sh
```

---

## Static analysis & tests

```bash
./check.sh
```

Runs (in order): `bash -n` on every script (mandatory), `shellcheck` when
installed, `kubectl --dry-run=client` on the policy assets when a cluster is
reachable, and the unit tests in `tests/`. Run it before committing.

---

## Verifying a run

| Stage | Check |
| --- | --- |
| prereqs | `systemctl is-active containerd` and `grep 'SystemdCgroup = true' /etc/containerd/config.toml` |
| control-plane | `kubectl get nodes` (one `Ready`, schedulable node) |
| calico | `kubectl get tigerastatus` (all Available) |
| storage | `kubectl get sc` (exactly one `(default)`) |
| gatekeeper | `kubectl get k8sallowedreposv2 only-chainguard-images -o jsonpath='{.spec.scopedEnforcementActions[0].action}'` → `deny` |
| authentik | `helm status authentik -n authentik` → `deployed` |
| cloudflared | tunnel shows **HEALTHY** in the Cloudflare dashboard; cloudflared pods `Ready` |

---

## Teardown & rebuild

To wipe the cluster back to a clean slate (e.g. to change the pod CIDR):

```bash
./completly-whip-k8s.bash        # type "whip" to confirm — DESTRUCTIVE
cd k8s-homelab-setup && ./bootstrap.sh
```

The teardown preserves `.env`, so secrets survive and the rebuild won't
re-prompt. It clears the resume ledger so every stage re-runs.

To only reset the resume ledger (without destroying the cluster):

```bash
rm -f state/.bootstrap-state
```

Preflight still skips stages whose desired state is met, so this is safe.

---

## Layout

```
k8s-homelab-setup/
├── bootstrap.sh                     # orchestrator
├── preflight.sh                     # desired-state scan + input collection
├── check.sh                         # static-analysis + unit-test gate
├── lib/common.sh                    # shared helpers + version pins
├── stages/
│   ├── 10-prereqs.sh
│   ├── 20-control-plane.sh
│   ├── 30-calico.sh
│   ├── 40-storage.sh
│   ├── 50-gatekeeper.sh
│   ├── 60-authentik.sh
│   └── 70-cloudflared.sh
├── assets/                          # Gatekeeper ConstraintTemplate + allowlist
├── tests/test-cidr-overlap.sh       # unit tests (offline)
├── .env.example                     # config schema (copy to .env)
├── .gitignore                       # keeps .env + runtime state out of git
└── state/                           # resume ledger (gitignored)
```

---

## Third-party components & attribution

This pipeline installs software it does not own. The one piece it pulls as
source (rather than a published image/chart) is the **cloudflared** Helm chart:

- Chart origin: [damienjburks/homelab-helm-charts](https://github.com/damienjburks/homelab-helm-charts),
  **MIT License, © 2025 Damien Burks**.
- `stages/70-cloudflared.sh` clones it from a personal fork
  ([thogue12/homelab-helm-charts](https://github.com/thogue12/homelab-helm-charts))
  at the ref pinned in `CLOUDFLARED_REPO_REF`, then installs the `cloudflared`
  chart with `helm upgrade --install`.
- The chart is **not vendored** into this repository; it is fetched at runtime.
  The upstream MIT `LICENSE` is retained in the fork.

Other components are pulled from their own upstream sources under their
respective licenses: Kubernetes, Calico (Tigera), Rancher local-path-provisioner,
OPA Gatekeeper, Authentik (goauthentik chart), PostgreSQL, and the
`cloudflare/cloudflared` image.

To pin the chart to a specific release instead of a branch, set the ref:

```bash
CLOUDFLARED_REPO_REF=v1.2.3 ./bootstrap.sh --stage cloudflared
```

## Security notes

- **`.env` is secret** (Authentik keys, Cloudflare token) and is gitignored.
  Never commit it. Only `.env.example` belongs in the repo.
- The Cloudflare tunnel makes Authentik **publicly reachable**. Finish the
  Authentik admin setup promptly, and consider putting **Cloudflare Access** in
  front of the hostname before treating it as live.
- The public-hostname → service route is configured in the **Cloudflare
  dashboard**, not by this pipeline, so it persists across rebuilds and is not
  reproduced by `bootstrap.sh`.
