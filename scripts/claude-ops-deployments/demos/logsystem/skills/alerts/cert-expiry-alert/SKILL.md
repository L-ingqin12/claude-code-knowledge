---
name: cert-expiry-alert
description: Respond to TLS certificate expiry warnings with renewal guidance
namespace: logs/alerts
paths:
  - "**/alerts/**"
  - "**/certs/**"
---

# Certificate Expiry Alert

Responds to TLS/SSL certificate expiry warnings and alerts. Accepts domain name, certificate serial number, current expiry date, and issuer information. Returns the days remaining before expiry, certificate chain validation status, auto-renewal eligibility (Let's Encrypt, cert-manager), renewal commands or API calls, and a checklist for post-renewal verification including OCSP stapling check and certificate transparency log verification. Does not perform actual renewal, only provides guidance.
