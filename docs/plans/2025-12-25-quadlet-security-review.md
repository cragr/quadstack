# QuadStack Quadlet Security & Best Practices Review

**Date:** 2025-12-25
**Scope:** All 14 container quadlets in `quadlets/` directory

---

## Executive Summary

This review analyzes all QuadStack quadlets for security hardening opportunities and systemd/quadlet best practices. Key findings:

- **10 of 14 containers can run unprivileged** with minimal or no changes
- **13 of 14 containers lack health checks** (only `postgresql` has one)
- **12 of 14 use `:latest` tags** instead of pinned versions
- **No containers use security hardening directives** (NoNewPrivileges, ReadOnly, etc.)
- **Inconsistent systemd unit configurations** across containers

---

## Part 1: Security Analysis

### Unprivileged Container Assessment

| Container | Can Run Unprivileged | Notes |
|-----------|---------------------|-------|
| cloudflared | **YES** | Tunnel client, no privileged operations |
| guacamole | **YES** | Web app, runs internally as non-root |
| guacd | **YES** | Connection proxy, no privileged ops |
| heimdall | **YES** | Dashboard, LinuxServer image handles user |
| keycloak | **YES** | Runs as non-root by default (UID 1000) |
| minecraft-bedrock | **YES** | Game server, no privileged ops |
| minecraft-java | **YES** | Game server, no privileged ops |
| n8n | **YES** | Runs as `node` user internally |
| npmplus | **PARTIAL** | Binds port 443 (privileged), needs `NET_BIND_SERVICE` or port remap |
| pgadmin | **YES** | Web app, runs as pgadmin user |
| pihole | **NO** | DNS server on port 53, needs `NET_BIND_SERVICE` + `NET_RAW` |
| postgresql | **YES** | Database runs as postgres user |
| pwpush | **YES** | Web app, runs as non-root |

**Recommendation:** Add `UserNS=auto` to all containers marked "YES" to enable user namespace isolation.

### Missing Security Directives

All containers are missing these security hardening options:

```ini
# Recommended additions for all containers:
[Service]
NoNewPrivileges=true      # Prevent privilege escalation

# For containers where applicable:
[Container]
ReadOnly=true             # Read-only root filesystem
```

### Capability Analysis

Current state: No containers drop or restrict capabilities.

**Recommended capability restrictions:**

| Container | Recommended CapabilityBoundingSet |
|-----------|----------------------------------|
| cloudflared | `CAP_NET_BIND_SERVICE` only (or none if not binding low ports) |
| guacamole | None needed |
| guacd | None needed |
| heimdall | None needed |
| keycloak | None needed |
| minecraft-* | None needed |
| n8n | None needed |
| npmplus | `CAP_NET_BIND_SERVICE` (for port 443) |
| pgadmin | None needed |
| pihole | `CAP_NET_BIND_SERVICE`, `CAP_NET_RAW`, `CAP_CHOWN`, `CAP_SETUID`, `CAP_SETGID` |
| postgresql | None needed |
| pwpush | None needed |

---

## Part 2: Quadlet Best Practices Analysis

### Image Version Pinning

| Container | Current Tag | Status |
|-----------|-------------|--------|
| cloudflared | `:latest` | **NEEDS PINNING** |
| guacamole | `:1.6.0` | OK |
| guacd | `:latest` | **NEEDS PINNING** |
| heimdall | `:latest` | **NEEDS PINNING** |
| keycloak | `:26.3.5` | OK |
| minecraft-bedrock | `:latest` | **NEEDS PINNING** |
| minecraft-java | `:latest` | **NEEDS PINNING** |
| n8n | (no tag) | **NEEDS PINNING** |
| npmplus | `:latest` | **NEEDS PINNING** |
| pgadmin | `:latest` | **NEEDS PINNING** |
| pihole | `:latest` | **NEEDS PINNING** |
| postgresql | `:latest` | **NEEDS PINNING** |
| pwpush | `:latest` | **NEEDS PINNING** |

**Recommendation:** Pin all images to specific versions for reproducibility.

### Health Checks

| Container | Has HealthCheck | Recommendation |
|-----------|-----------------|----------------|
| cloudflared | NO | `HealthCmd=["cloudflared", "tunnel", "info"]` |
| guacamole | NO | HTTP check on /guacamole |
| guacd | NO | TCP check on port 4822 |
| heimdall | NO | HTTP check on / |
| keycloak | NO | HTTP check on /health/ready |
| minecraft-bedrock | NO | Custom script or process check |
| minecraft-java | NO | Custom script or process check |
| n8n | NO | HTTP check on /healthz |
| npmplus | NO | HTTP check on admin port |
| pgadmin | NO | HTTP check |
| pihole | NO | DNS query test |
| postgresql | **YES** | Already configured |
| pwpush | NO | HTTP check |

### Systemd Unit Configuration

**Containers missing proper `[Unit]` section:**
- cloudflared, guacamole, guacd, heimdall, keycloak, npmplus, pgadmin, postgresql, pwpush

**Recommended `[Unit]` template:**
```ini
[Unit]
Description=<ServiceName>
After=network-online.target
Wants=network-online.target
```

**Containers with database dependencies missing systemd ordering:**
- guacamole (has `# RequiresPostgres` comment but no `Requires=`/`After=`)
- keycloak (has `# RequiresPostgres` comment but no `Requires=`/`After=`)
- pwpush (has `# RequiresPostgres` comment but no `Requires=`/`After=`)

**Correctly configured:** n8n has proper `Requires=postgresql.service` and `After=postgresql.service`

### Restart Configuration

| Container | Restart | RestartSec | Recommendation |
|-----------|---------|------------|----------------|
| cloudflared | always | 2 | OK |
| All others | always | (none) | Add `RestartSec=5` for rate limiting |

### Timeout Configuration

| Container | TimeoutStartSec | TimeoutStopSec | Notes |
|-----------|-----------------|----------------|-------|
| cloudflared | default | default | OK for lightweight service |
| guacamole | default | default | Consider 120s start timeout |
| guacd | default | default | OK |
| heimdall | default | default | OK |
| keycloak | 900 | default | OK |
| minecraft-bedrock | default | default | **NEEDS 180s+ start, 60s stop** |
| minecraft-java | 900 | 70 | OK |
| n8n | 900 | default | OK |
| npmplus | default | default | Consider 120s start |
| pgadmin | 120 | default | OK |
| pihole | default | default | Consider 60s start |
| postgresql | 180 | default | OK |
| pwpush | default | default | Consider 60s start |

---

## Part 3: Recommended Changes

### Priority 1: Security Hardening (Unprivileged)

Add to containers that can run unprivileged:

```ini
[Container]
UserNS=auto

[Service]
NoNewPrivileges=true
```

**Applies to:** cloudflared, guacamole, guacd, heimdall, keycloak, minecraft-bedrock, minecraft-java, n8n, pgadmin, postgresql, pwpush

### Priority 2: Database Dependency Ordering

Add to containers with PostgreSQL dependencies:

```ini
[Unit]
Requires=postgresql.service
After=postgresql.service
```

**Applies to:** guacamole, keycloak, pwpush

### Priority 3: Health Checks

Add appropriate health checks to all containers. Example for web applications:

```ini
[Container]
HealthCmd=["CMD-SHELL", "curl -f http://localhost:PORT/health || exit 1"]
HealthInterval=30s
HealthTimeout=10s
HealthRetries=3
HealthStartPeriod=60s
```

### Priority 4: Consistent Unit Configuration

Add `[Unit]` section to all containers:

```ini
[Unit]
Description=<ContainerName> container
After=network-online.target
Wants=network-online.target
```

### Priority 5: Restart Rate Limiting

Add to all containers:

```ini
[Service]
RestartSec=5
```

---

## Container-Specific Recommendations

### cloudflared.container
```ini
[Unit]
Description=Cloudflare Tunnel
After=network-online.target
Wants=network-online.target

[Container]
UserNS=auto
# Consider pinning version: Image=docker.io/cloudflare/cloudflared:2024.12.0

[Service]
NoNewPrivileges=true
RestartSec=5
```

### npmplus.container
```ini
# Cannot use UserNS=auto due to privileged port 443
# Option A: Remap to unprivileged ports (recommended)
PublishPort=8443:443
PublishPort=8081:81

# Option B: Keep privileged port, add capability
[Container]
AddCapability=CAP_NET_BIND_SERVICE
```

### pihole.container
```ini
# Requires privileged operations for DNS
[Container]
AddCapability=CAP_NET_BIND_SERVICE
AddCapability=CAP_NET_RAW
# Note: Cannot run fully unprivileged due to DNS requirements
```

---

## Summary Table

| Container | Unprivileged | Health Check | Unit Section | DB Deps | Image Pin |
|-----------|:------------:|:------------:|:------------:|:-------:|:---------:|
| cloudflared | ADD | ADD | ADD | N/A | ADD |
| guacamole | ADD | ADD | ADD | FIX | OK |
| guacd | ADD | ADD | ADD | N/A | ADD |
| heimdall | ADD | ADD | ADD | N/A | ADD |
| keycloak | ADD | ADD | ADD | FIX | OK |
| minecraft-bedrock | ADD | ADD | OK | N/A | ADD |
| minecraft-java | ADD | ADD | OK | N/A | ADD |
| n8n | ADD | ADD | OK | OK | ADD |
| npmplus | PARTIAL | ADD | ADD | N/A | ADD |
| pgadmin | ADD | ADD | ADD | N/A | ADD |
| pihole | NO | ADD | OK | N/A | ADD |
| postgresql | ADD | OK | ADD | N/A | ADD |
| pwpush | ADD | ADD | ADD | FIX | ADD |

**Legend:** ADD = needs to be added, FIX = needs correction, OK = already good, N/A = not applicable, PARTIAL = limited support, NO = not possible

---

## Next Steps

1. Review this analysis and confirm approach
2. Decide on image version pinning strategy (specific versions vs. semver tags)
3. Implement changes incrementally, testing each container
4. Consider adding a pre-commit hook to validate quadlet files
