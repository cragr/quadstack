# Rancher Quadlet Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add Rancher Kubernetes management platform to QuadStack with PostgreSQL backend.

**Architecture:** Rancher runs on appnet, connects to PostgreSQL for persistent storage, and is accessed via NPM Plus reverse proxy. No direct host port exposure needed.

**Tech Stack:** Podman Quadlet, PostgreSQL, systemd

---

## Task 1: Create Rancher Quadlet File

**Files:**
- Create: `quadlets/rancher.container`

**Step 1: Create the quadlet file**

Create `quadlets/rancher.container` with this exact content:

```ini
[Unit]
Description=Rancher container
Requires=postgresql.service
After=postgresql.service network-online.target
Wants=network-online.target

[Container]
ContainerName=rancher
Image=docker.io/rancher/rancher:stable
Network=appnet

# Persist Rancher data
Volume={{INSTALL_DIR}}/rancher:/var/lib/rancher:Z,U

# RequiresPostgres:
# Database (PostgreSQL)
Environment=CATTLE_DB_CATTLE_POSTGRES_HOST=postgresql
Environment=CATTLE_DB_CATTLE_POSTGRES_PORT=5432
Environment=CATTLE_DB_CATTLE_POSTGRES_NAME={{RANCHER_DB_NAME}}
Environment=CATTLE_DB_CATTLE_POSTGRES_USER={{RANCHER_DB_USERNAME}}
Environment=CATTLE_DB_CATTLE_POSTGRES_PASSWORD={{RANCHER_DB_PASSWORD}}

# Audit logging (level 1 = basic)
Environment=AUDIT_LEVEL=1

[Service]
Restart=always
TimeoutStartSec=900

[Install]
WantedBy=default.target
```

**Step 2: Verify file syntax**

Run: `cat quadlets/rancher.container`
Expected: File displays without errors, contains all sections

**Step 3: Commit**

```bash
git add quadlets/rancher.container
git commit -m "feat: add rancher quadlet for Kubernetes management"
```

---

## Task 2: Add Rancher to Container Manifest

**Files:**
- Modify: `container-manifest.txt` (add 1 line at end)

**Step 1: Add manifest entry**

Append this line to `container-manifest.txt`:

```
https://raw.githubusercontent.com/cragr/quadstack/refs/heads/main/quadlets/rancher.container
```

**Step 2: Verify manifest**

Run: `tail -3 container-manifest.txt`
Expected: Shows rancher.container as last entry

**Step 3: Commit**

```bash
git add container-manifest.txt
git commit -m "feat: add rancher to container manifest"
```

---

## Task 3: Update README with Rancher

**Files:**
- Modify: `README.md` (services section - not explicitly listed, but implied in docs)

**Step 1: No explicit service list in README**

The README doesn't have a services list to update. Skip this task.

**Step 2: Commit (skip if no changes)**

No commit needed.

---

## Task 4: Final Verification

**Step 1: Verify all files are present**

Run: `ls -la quadlets/rancher.container container-manifest.txt`
Expected: Both files exist

**Step 2: Verify manifest entry format**

Run: `grep rancher container-manifest.txt`
Expected: Shows the rancher.container URL

**Step 3: Verify quadlet has required metadata**

Run: `grep -E "(RequiresPostgres|CATTLE_DB)" quadlets/rancher.container`
Expected: Shows PostgreSQL requirement comment and all CATTLE_DB environment variables

**Step 4: View git log**

Run: `git log --oneline -5`
Expected: Shows recent commits for rancher quadlet and manifest update
