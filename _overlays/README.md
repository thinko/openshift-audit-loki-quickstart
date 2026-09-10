# Private Cluster Overlays

This directory is gitignored. It contains cluster-specific configurations
that are applied on top of the generic gitops manifests when syncing to
an internal ArgoCD-watched repository.

## Directory structure

```
_overlays/
  _template/             # Copy this to create a new cluster overlay
    clusters.yaml
    values.yaml
    .env.cluster
    deploy-checklist.md
  homelab/               # Homelab testing overlay (S3/MinIO + LVMS + 1x.demo)
    argocd-application.yaml   # ArgoCD Application pointing at homelab-gitops branch
    argocd-ytt-cmp.yaml       # ytt CMP sidecar ConfigMap for ArgoCD
    argocd-ytt-patch.yaml     # Repo-server strategic merge patch for ytt sidecar
    clusters.yaml             # homelab01 cluster key
    values.yaml               # 1x.demo quota, no node placement (per-component)
    lokistack.yaml            # Full override: s3 + lvms-vg1 + 1x.demo + pinning
    clusterlogforwarder.yaml  # Full override: no node journals, 2Gi Vector
    minio.yaml                # MinIO deployment (bootstrap prerequisite)
    deploy-minio.sh           # Bootstrap: MinIO + secrets (run once before ArgoCD)
    .env.homelab              # Grafana credentials
    deploy-checklist.md       # Full deployment sequence
  <cluster-name>/        # e.g. prod-east/
    clusters.yaml        # Pre-filled with the cluster key
    values.yaml          # Pre-filled quota, AD groups, annotations
    .env.<cluster>       # Azure resource names (secrets left blank)
    deploy-checklist.md  # Cluster-specific deployment sequence
```

## Automated sync

Use the sync script to push generic manifests + overlay to the internal repo:

```bash
scripts/sync-gitops-to-internal.sh <overlay-name> <target-dir>

# Example:
scripts/sync-gitops-to-internal.sh my-cluster \
  ~/repos/internal-namespaces/namespaces/openshift-logging
```

The script:
1. Copies all `*.yaml` and `README.md` from `gitops/namespaces/openshift-logging/`
2. Overwrites `values.yaml` and `clusters.yaml` with the overlay versions
3. Shows `git diff --stat` if the target is a git repo

## Manual sync

If you prefer to do it manually:

```bash
# 1. Copy generic manifests (overwrite)
cp gitops/namespaces/openshift-logging/*.yaml <target>/
cp gitops/namespaces/openshift-logging/README.md <target>/

# 2. Apply overlay
cp _overlays/<cluster>/values.yaml <target>/
cp _overlays/<cluster>/clusters.yaml <target>/

# 3. Review and commit
cd <internal-repo>
git diff
git add namespaces/openshift-logging/
git commit -m 'chore: update openshift-logging manifests from upstream'
```

## Creating a new cluster overlay

```bash
cp -r _overlays/_template _overlays/<new-cluster-name>
# Edit the files to fill in cluster-specific values
```

## What goes in the overlay vs. what stays generic

| Content | Where | Why |
|---------|-------|-----|
| LokiStack, CLF, alerting manifests | `gitops/` (generic) | No customer-specific content |
| Grafana, UIPlugin, RBAC | `gitops/` (generic) | No customer-specific content |
| Cluster key, AD groups | `_overlays/<cluster>/` | Identifies the customer/cluster |
| Quota values | `_overlays/<cluster>/values.yaml` | May vary per cluster |
| Azure resource names | `_overlays/<cluster>/.env.*` | Identifies Azure resources |
| SP credentials, storage keys | `.env` files | Secrets, never committed |
