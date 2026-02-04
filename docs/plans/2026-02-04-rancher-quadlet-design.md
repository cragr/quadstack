# Rancher Quadlet Design

## Overview

Add Rancher to QuadStack for managing external Kubernetes clusters (RKE2, K3s, etc.).

## Configuration

**Image:** `docker.io/rancher/rancher:stable`

**Backend:** External PostgreSQL via QuadStack's `# RequiresPostgres:` mechanism

**Network:** Behind NPM Plus reverse proxy (HTTP only internally, TLS at proxy)

**Tokens:** Standard only (`{{INSTALL_DIR}}`, `{{HOST_PORT}}`)

## Quadlet Configuration

**File:** `quadlets/rancher.container`

```ini
# Name: Rancher
# Description: Kubernetes management platform for managing external clusters
# DefaultPort: 8080
# RequiresPostgres: rancher
# Requires: Network

[Container]
Image=docker.io/rancher/rancher:stable
ContainerName=rancher
Network=appnet
PublishPort={{HOST_PORT}}:80
Environment=CATTLE_DB_CATTLE_POSTGRES_HOST=postgres
Environment=CATTLE_DB_CATTLE_POSTGRES_PORT=5432
Environment=CATTLE_DB_CATTLE_POSTGRES_NAME=rancher
Environment=CATTLE_DB_CATTLE_POSTGRES_USER=rancher
Environment=CATTLE_DB_CATTLE_POSTGRES_PASSWORD={{POSTGRES_RANCHER_PASSWORD}}
Environment=AUDIT_LEVEL=1
Volume={{INSTALL_DIR}}/rancher:/var/lib/rancher:Z,U

[Service]
Restart=always

[Install]
WantedBy=default.target
```

## Manifest Entry

**File:** `manifest.txt`

```
rancher|Rancher|Kubernetes management platform|8080
```

## Installation Behavior

1. QuadStack checks for `# RequiresPostgres: rancher` metadata
2. If PostgreSQL quadlet isn't already selected, it's auto-added
3. Installer prompts for `HOST_PORT` (default: 8080)
4. PostgreSQL password for the `rancher` database is auto-generated and injected
5. Creates `{{INSTALL_DIR}}/rancher/` directory with proper SELinux context
6. Installs quadlet to `/etc/containers/systemd/rancher.container`
7. Runs `systemctl daemon-reload` and starts the service

## Post-Install Note

```
Rancher is starting up (this takes 1-2 minutes on first run).
Access via your reverse proxy or http://<host>:8080
Default admin user: admin
Retrieve bootstrap password: podman logs rancher 2>&1 | grep "Bootstrap Password"
```

## Dependencies

- **Required:** PostgreSQL quadlet (auto-selected via `# RequiresPostgres:`)
- **Required:** Network quadlet (for `appnet`)
- **Optional:** NPM Plus for TLS termination (user configures separately)

## Files to Create/Modify

1. `quadlets/rancher.container` - new file
2. `manifest.txt` - add entry
3. `README.md` - add to services list
