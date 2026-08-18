---
name: k8s_apply
description: Kubernetes apply deployment
---

# Kubernetes Apply Deployment

Deploy or update resources in Kubernetes clusters.

1. Validate manifests: `kubectl apply --dry-run=client -f deployment.yaml`
2. Apply: `kubectl apply -f deployment.yaml`
3. Monitor rollout: `kubectl rollout status deployment/app`
4. If rollout fails, run deploy_rollback immediately
5. For new images, ensure docker_build was run first

Always apply to staging first, then production.
