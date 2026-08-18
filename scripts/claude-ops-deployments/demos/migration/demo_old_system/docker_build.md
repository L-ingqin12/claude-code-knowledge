---
name: docker_build
description: Docker build and push
---

# Docker Build and Push

Build and publish Docker images to the registry.

1. Build: `docker build -t registry.internal.example.com/app:latest .`
2. Tag with version: `docker tag registry.internal.example.com/app:latest registry.internal.example.com/app:v1.2.3`
3. Push: `docker push registry.internal.example.com/app:latest`
4. Verify the image manifest: `docker buildx imagetools inspect registry.internal.example.com/app:latest`

Best practices:
- Use multi-stage builds to minimise image size
- Pin base image digests, not tags
- Scan images for vulnerabilities before pushing
