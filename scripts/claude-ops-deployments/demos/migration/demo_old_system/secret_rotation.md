---
name: secret_rotation
description: Secret rotation procedure
---

# Secret Rotation Procedure

Rotate secrets and credentials on a regular cadence.

1. Generate new secret value: `openssl rand -base64 32`
2. Update the secret in Vault using the Vault CLI
3. If the secret is in Kubernetes: `kubectl create secret generic <name> --from-literal=key=value -o yaml --dry-run=client | kubectl apply -f -`
4. For app-level secrets, consider using deploy_rollback if a bad rotation breaks things
5. Notify the team of the rotation via slack_notify
6. Commit updated manifests following git_workflow

Keep a rotation log with dates and which services were affected.
