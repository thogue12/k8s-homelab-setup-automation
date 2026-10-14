# Ansible K8s Homelab Automation

Ansible port of the bash `k8s-homelab-setup-automation` pipeline. One playbook
provisions a single-node Kubernetes control plane (that also schedules
workloads) on an apt-based Ubuntu VM, then installs the core services on top.

Each stage uses native Ansible modules (`apt`, `sysctl`, `kubernetes.core.k8s`,
`kubernetes.core.helm`), so re-runs converge instead of failing — no custom
idempotency logic needed.

## Stages

`playbook.yaml` runs these six in order:

| Stage | File | What it does |
| --- | --- | --- |
| prereqs | `Stages/install-prereqs.yaml` | Kernel modules, sysctl, swap off, containerd, kubelet/kubeadm/kubectl |
| control-plane | `Stages/control-plane.yaml` | `kubeadm init`, installs the user kubeconfig, removes the control-plane taint |
| calico | `Stages/calico.yaml` | Calico CNI (CRDs + Tigera operator + custom resources) |
| storage | `Stages/storage.yaml` | Rancher local-path provisioner as the default StorageClass |
| gatekeeper | `Stages/gatekeeper.yaml` | OPA Gatekeeper + Chainguard image allowlist (dryrun → deny) |
| apps | `Stages/apps.yaml` | Helm, Authentik (+ bundled PostgreSQL), Cloudflare tunnel |

## Layout

```
Ansible-K8s-Automation/
├── ansible.cfg                     # points at inventory.ini, enables sudo
├── inventory.ini                   # defines the k8s_nodes group
├── playbook.yml                    # orchestrator — imports the six stages
├── group_vars/
│   └── k8s_nodes/
│       ├── vars.yml                # non-secret tunables (auto-loaded)
│       └── vault.yml               # secrets (encrypt with ansible-vault)
└── Stages/                         # the six stage playbooks
```

`group_vars/k8s_nodes/` is auto-loaded for every play (they all target
`hosts: k8s_nodes`), so the stage files don't reference it directly.

## Prerequisites

### Control node (where you run `ansible-playbook`)

```bash
# Ansible + the collections the playbooks use
sudo apt install -y ansible            # or: brew install ansible
ansible-galaxy collection install kubernetes.core ansible.posix community.general
```

### Target VM

- apt-based **Ubuntu Server**, Python 3 (pre-installed), SSH enabled.
- A user with sudo (`become: true` is used throughout).
- `python3-kubernetes` installed — the `kubernetes.core` modules need it:
  ```bash
  sudo apt install -y python3-kubernetes
  ```
- **A Cloudflare tunnel token** (Zero Trust dashboard, starts with `eyJ`).

> Running Ansible **on the VM against itself**? Then the control node and target
> are the same box — install everything above there.

## Configure

### 1. Inventory

Edit `inventory.ini` for your setup.

Local (running on the VM, targeting itself):
```ini
[k8s_nodes]
localhost ansible_connection=local

[k8s_nodes:vars]
ansible_become=true
```

Remote (driving the VM over SSH from another machine):
```ini
[k8s_nodes]
k8s-cp-1 ansible_host=192.168.1.226 ansible_user=tim

[k8s_nodes:vars]
ansible_become=true
```

### 2. Variables (`group_vars/k8s_nodes/vars.yml`)

Review these — they're the single edit point for tunables:

| Variable | Purpose |
| --- | --- |
| `k8s_minor` | Kubernetes minor version (apt repo + tools) |
| `pod_cidr` | Pod network CIDR (shared by control-plane + calico) |
| `kube_user` | User who owns `~/.kube/config` and runs kubectl |
| `calico_version`, `local_path_version`, `gatekeeper_version`, `helm_version`, `authentik_chart_version` | Pinned component versions |
| `assets_dir` | Path on the node holding the Gatekeeper policy YAML |
| `apps_ns` | Namespace for Authentik + cloudflared |
| `cloudflared_repo_*`, `cloudflared_chart` | cloudflared Helm chart source |

### 3. Secrets (`group_vars/k8s_nodes/vault.yml`)

Fill in the three values, then encrypt the file:

```bash
# edit the file — set real values
#   vault_authentik_secret_key        (openssl rand -hex 32)
#   vault_authentik_postgres_password (openssl rand -hex 32)
#   vault_cloudflare_tunnel_token     (Cloudflare dashboard, starts with eyJ)

ansible-vault encrypt group_vars/k8s_nodes/vault.yml
```

`vars.yml` bridges these `vault_*` names to the ones the plays use, so the
encrypted file stays the only place real secrets live.

Edit later with: `ansible-vault edit group_vars/k8s_nodes/vault.yml`.

## Run

Full pipeline:

```bash
cd Ansible-K8s-Automation
ansible-playbook playbook.yml --ask-vault-pass --ask-become-pass
```

- `--ask-vault-pass` — decrypts `vault.yml` (omit if it isn't encrypted yet)
- `--ask-become-pass` — your VM user's sudo password (omit if passwordless sudo)

A single stage, by tag:

```bash
ansible-playbook playbook.yml --tags calico --ask-vault-pass --ask-become-pass
```

Preview without changing anything:

```bash
ansible-playbook playbook.yml --check --ask-vault-pass --ask-become-pass
```

Sanity-check connectivity first:

```bash
ansible k8s_nodes -m ping
```

## Verify a run

| Stage | Check |
| --- | --- |
| prereqs | `systemctl is-active containerd`; `grep 'SystemdCgroup = true' /etc/containerd/config.toml` |
| control-plane | `kubectl get nodes` — one `Ready`, schedulable node |
| calico | `kubectl get tigerastatus` — all `Available` |
| storage | `kubectl get sc` — exactly one `(default)` |
| gatekeeper | `kubectl get k8sallowedreposv2 only-chainguard-images -o jsonpath='{.spec.scopedEnforcementActions[0].action}'` → `deny` |
| apps | `helm status authentik -n authentik` and `helm status cloudflared -n authentik` → `deployed` |

## Notes & gotchas

- **Run stages in order the first time.** The calico/storage/gatekeeper/apps
  stages read the user kubeconfig that the control-plane stage installs, so
  control-plane must run first.
- **The apps stage is slow.** `wait: true` with a 15-minute timeout blocks until
  Authentik + PostgreSQL are Ready (image pulls, PVC bind, DB init). Watch with
  `kubectl get pods -n authentik -w`. If a pod is stuck `Pending`, check the PVC
  (`kubectl get pvc -n authentik`) — usually the default StorageClass.
- **Re-runs are safe.** Every stage is idempotent; there's no resume ledger
  because the modules simply converge and skip what's already done.
- **Gatekeeper policy assets** must exist on the node at `assets_dir`
  (`allowed-images-template.yaml`, `only-chainguard-images.yaml`).
