# k8s-homelab-setup-automation

Automation for standing up a single-node Kubernetes control plane on an
apt-based Ubuntu VM (Proxmox homelab) and installing a core set of services on
top of it — reproducibly, and safe to re-run.

The repo contains **two parallel implementations** of the same pipeline: the
original Bash version and an Ansible port. They do the same work and target the
same outcome; pick whichever fits how you want to run it.

```
k8s-homelab-setup-automation/
├── Bash-K8s-Automation/        # original: orchestrated, idempotent bash stages
└── Ansible-K8s-Automation/     # port: the same pipeline as Ansible playbooks
```

Each subproject has its own detailed README — start there to actually run it:

- [`Bash-K8s-Automation/README.md`](Bash-K8s-Automation/README.md)
- [`Ansible-K8s-Automation/README.md`](Ansible-K8s-Automation/README.md)

## What it does

Both implementations run the same ordered stages to take a bare Ubuntu VM to a
working, workload-scheduling single-node cluster with core services:

| Stage | Purpose |
| --- | --- |
| **prereqs** | Kernel modules, sysctl, swap off, containerd (systemd cgroup), kubelet/kubeadm/kubectl |
| **control-plane** | `kubeadm init`, install the user kubeconfig, remove the control-plane taint so the node schedules workloads |
| **calico** | Calico CNI (Tigera operator + custom resources), pod CIDR injected |
| **storage** | Rancher local-path provisioner as the default StorageClass |
| **gatekeeper** | OPA Gatekeeper + a Chainguard image allowlist (applied at `dryrun`, flipped to `deny`) |
| **authentik** | Authentik via the goauthentik Helm chart, with bundled PostgreSQL |
| **cloudflared** | Cloudflare tunnel via the `cloudflared` Helm chart, token held only in a k8s Secret |

> In the Bash version, authentik and cloudflared are separate stages
> (`60-authentik.sh`, `70-cloudflared.sh`). In the Ansible version they're
> combined in `Stages/apps.yaml`.

## Design principles

The whole project is built around re-runs being **safe and convergent** —
most "set up my cluster" scripts assume a blank machine and break on anything
that already exists. This one doesn't:

- **Apply, don't create** — `kubectl apply` / `helm upgrade --install`, never
  `create` / `install`, so existing objects are reconciled, not errored on.
- **Skip-if-healthy + secret reuse** — a healthy release is left untouched and
  its secrets are never regenerated, so re-runs don't rotate credentials.
- **State-based waits** — poll for actual readiness (e.g. Calico `tigerastatus`)
  rather than racing fixed sleeps.
- **Secrets out of version control** — real secrets live in a gitignored `.env`
  (Bash) or an `ansible-vault`-encrypted file (Ansible); only templates and
  schema are committed.
- **Pinned component versions** — Calico, Gatekeeper, local-path, Helm, and the
  Authentik chart are pinned for reproducibility.

## Bash vs. Ansible — which to use

| | Bash | Ansible |
| --- | --- | --- |
| Run model | Orchestrator (`bootstrap.sh`) runs stage scripts | `playbook.yml` imports stage playbooks |
| Idempotency | Hand-written (preflight diff + resume ledger) | Native to the modules |
| Secrets | gitignored `.env` (generate / prompt) | `ansible-vault` |
| Remote execution | Run on the VM | Local **or** remote over SSH from a control node |
| Extra concepts | Preflight desired-state scan, resume ledger | Inventory groups, `group_vars`, collections |

Both are complete and produce the same cluster. The Bash version is the
reference implementation; the Ansible version is the direction the project is
heading.

## Requirements (either implementation)

- An apt-based **Ubuntu Server** VM, single node, with a sudo-capable user.
- Outbound internet (apt, container images, Helm charts, Cloudflare).
- A **Cloudflare tunnel token** from the Zero Trust dashboard (starts with `eyJ`).

See the subproject READMEs for the exact tool/version setup each one needs.

## Possible future enhancements

Ideas on the roadmap, roughly in order of impact:

- **Multi-node support** — add worker nodes that join the control plane. Cleanly
  modeled as inventory groups (`control_plane` / `workers`) plus a worker-join
  stage; the core stages stay unchanged whether it's 1 node or many.
- **App catalog / pick-and-choose installs** — turn the hardcoded app stages
  into a selectable catalog (e.g. Authentik, WordPress, nginx), each app
  self-contained in its own folder with its chart/values and declared secrets.
  The engineer enables apps via a list in a vars file; a generic installer loops
  over the selections. Namespaces become a per-app choice.
- **HA control plane** — multiple control-plane nodes behind a load balancer
  (a larger step than worker-join; only if the homelab grows into it).
- **GitOps / CI integration** — drive the pipeline from Git (GitHub Actions,
  Jenkins, or an Argo/Flux-style flow): the engineer edits the enabled-apps list
  and inventory in Git, and a pipeline runs the automation. This sits *on top of*
  the app catalog rather than replacing it.
- **OIDC-based cluster access** — instead of distributing the admin kubeconfig,
  issue scoped, SSO-backed access via Authentik (which the pipeline already
  installs) with RBAC per user/team.
- **Secret backend** — graduate from `.env` / vault files to Sealed Secrets or
  an external store (e.g. Vault) for secrets reproducible across rebuilds.
- **Expanded testing** — more unit coverage for pure helpers and run-twice
  idempotency checks as part of CI.

## Repo notes

- Two implementations are kept in parallel intentionally during the migration;
  the Bash version remains the functional baseline until the Ansible version is
  validated end-to-end.
- Secrets are never committed — only `.env.example` / `vault.yml` templates are.
