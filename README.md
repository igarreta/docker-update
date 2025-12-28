# Docker Update Manager

A manual, inventory-based update strategy for Docker containers running on a Proxmox VM.

## Overview

This project provides a controlled, monthly update process for Docker containers with:

- **Inventory validation** - Ensures consistency between documented and running containers
- **Dockerfile support** - Handles both pre-built images and custom Dockerfile builds
- **Staged updates** - Updates containers by stack with verification between each
- **Warning system** - Alerts on discrepancies (running but undocumented, or documented but stopped)
- **Logging** - Complete audit trail of all update operations

## Context

Designed for a home server environment running:
- **Host**: Proxmox VE on GMTec NucBox G5 (Intel N97, 12GB RAM)
- **VM**: docker03 - Docker host with multiple containers
- **Containers**: 14 running + 1 cron-triggered

This complements existing update strategies for Proxmox and the Docker VM itself.

## Installation

```bash
# Clone the repository
git clone https://github.com/YOUR_USERNAME/docker-update-manager.git
cd docker-update-manager

# Make scripts executable
chmod +x scripts/*.sh

# Option 1: Auto-generate inventory from running containers (recommended)
./scripts/generate-inventory.sh

# Option 2: Manual setup from example
mkdir -p ~/etc
cp examples/inventory.example ~/etc/docker-inventory
# Then edit ~/etc/docker-inventory to add your containers
```

## Configuration

### Inventory File

Edit `~/etc/docker-inventory` to document your containers:

```bash
# Format: container_name|stack_path|notes
# (type is auto-detected from Dockerfile/docker-compose.yml)
#
# Alternative format with explicit type:
# Format: container_name|stack_path|type|notes
# type options:
#   pull  - Uses pre-built images from registry
#   build - Has Dockerfile that needs building

# Type auto-detected (recommended)
portainer|/opt/stacks/portainer|Management UI
traefik|/opt/stacks/traefik|Reverse proxy
my-custom-app|/opt/stacks/custom-app|Built from local Dockerfile

# Or with explicit type (optional)
nginx|/opt/stacks/nginx|pull|Explicit type override
```

### Script Configuration

The script uses these default locations (auto-configured):

```bash
# === CONFIGURATION ===
INVENTORY_FILE="$HOME/etc/docker-inventory"  # Inventory location
LOG_DIR="$PROJECT_DIR/log"                    # Logs stored in project
COMPOSE_BASE="/opt/stacks"                    # Adjust if needed
```

**Note:** Logs are now stored in the project's `log/` subdirectory rather than `~/docker-logs`

## Generating Inventory

### Auto-Generate from Running Containers

The easiest way to create your inventory is to auto-generate it from currently running containers:

```bash
# Generate inventory from running containers
./scripts/generate-inventory.sh

# Preview what would be generated (dry run)
./scripts/generate-inventory.sh --dry-run

# Generate with automatic backup
./scripts/generate-inventory.sh --backup

# Force overwrite without prompting
./scripts/generate-inventory.sh --force
```

**How it works:**
- Scans all running Docker containers
- Extracts stack paths from Docker Compose labels (`com.docker.compose.project.working_dir`)
- Groups containers by stack
- Generates inventory in the 3-field format (type auto-detected)
- Warns about containers without detectable paths (non-Compose containers)

**Limitations:**
- Only detects **running** containers (stopped containers must be added manually)
- Containers not started with Docker Compose will show `UNKNOWN` path
- You'll need to manually edit the file to fix unknown paths and add stopped containers

### Manual Inventory Creation

Alternatively, create the inventory manually:

```bash
mkdir -p ~/etc
cat > ~/etc/docker-inventory << 'EOF'
# Format: container_name|stack_path|notes
portainer|/opt/stacks/portainer|Management UI
traefik|/opt/stacks/traefik|Reverse proxy
EOF
```

## Usage

### Monthly Update Process

```bash
# Run the update script
./docker-update.sh
```

The script will:

1. **Validate inventory** against running containers
2. **Report warnings** for any discrepancies
3. **Prompt to continue** if warnings exist
4. **Update each stack** based on type (pull or build)
5. **Verify** all containers are running post-update
6. **Clean up** unused images
7. **Log** all operations

### Validation Only (Dry Run)

```bash
# Check inventory without updating
./docker-update.sh --validate-only
```

### Update Specific Stack

```bash
# Update a single stack
./docker-update.sh --stack /opt/stacks/portainer
```

## Container Types

### Pre-built Images (`type: pull`)

For containers using images from Docker Hub, GHCR, etc:

```yaml
# docker-compose.yml
services:
  app:
    image: nginx:latest  # or nginx:1.25
```

Update process:
```bash
docker compose pull
docker compose up -d
```

### Dockerfile Builds (`type: build`)

For containers built from local Dockerfiles:

```yaml
# docker-compose.yml
services:
  app:
    build:
      context: .
      dockerfile: Dockerfile
```

Update process:
```bash
docker compose build --pull  # Pulls fresh base images
docker compose up -d --build
```

## Validation Logic

| Scenario | Status | Action |
|----------|--------|--------|
| In inventory + Running | ✓ OK | Updated |
| In inventory + Not running | ⚠ Warning | Skipped, logged |
| Running + Not in inventory | ⚠ Warning | Not updated, logged |
| Stack directory missing | ✗ Error | Logged, continues |
| Container fails post-update | ✗ Error | Logged in summary |

## Cron-Triggered Containers

For containers that run on a schedule (not always running):

1. Add a comment in inventory:
   ```bash
   # Cron-triggered (expected to be stopped)
   backup-runner|/opt/stacks/backup|pull|Triggered by cron - OK if stopped
   ```

2. Or use a separate inventory file for scheduled containers

3. Or add `--ignore` flag (TODO: implement):
   ```bash
   backup-runner|/opt/stacks/backup|pull|ignore-stopped
   ```

## Logging

Logs are stored in the project's `log/` subdirectory:

```
docker-update-manager/
└── log/
    ├── update-20250119-1400.log
    ├── update-20250218-1400.log
    └── update-20250319-1400.log
```

Each log contains:
- Timestamp of update
- Inventory validation results
- Pull/build output for each stack
- Post-update container status
- Cleanup operations
- Final summary

## Rollback

If an update causes issues:

### Quick Rollback (Recent Update)

```bash
cd /opt/stacks/problem-stack

# For pre-built images - specify previous tag
docker compose down
# Edit docker-compose.yml to pin previous version
docker compose up -d
```

### Using Image History

```bash
# List available local images
docker images | grep container-name

# Run with specific image
docker compose down
docker compose up -d --no-build  # Uses cached image
```

## Project Structure

```
docker-update-manager/
├── README.md
├── LICENSE
├── scripts/
│   ├── docker-update.sh         # Main update script
│   ├── generate-inventory.sh    # Auto-generate inventory
│   └── validate-inventory.sh    # Validation only
├── examples/
│   ├── inventory.example        # Sample inventory file
│   └── docker-compose/          # Example compose configurations
│       ├── pull-based/
│       └── build-based/
├── docs/
│   ├── CHANGELOG.md
│   └── troubleshooting.md
└── log/                         # Update logs (created on first run)
    └── update-*.log
```

## Roadmap / TODO

- [ ] `--validate-only` flag for dry runs
- [ ] `--stack <path>` flag for single-stack updates
- [ ] `ignore-stopped` inventory option for cron containers
- [ ] Health check integration (wait for healthy status)
- [ ] Notification support (email/webhook on completion)
- [ ] Backup verification before update
- [ ] Rollback automation
- [ ] Update scheduling recommendations based on image release frequency

## Related Documentation

This project is part of a broader infrastructure management strategy:

- **Proxmox Updates**: See `Proxmox_8.4_to_9.1_Upgrade_Summary.md`
- **LXC Container Setup**: See `IPv6_Only_LXC_Container_Setup.md`
- **USB Storage**: See `WD_Elements_4TB_USB_Fix.md`

## Contributing

This is a personal infrastructure project, but suggestions are welcome via issues.

## License

MIT License - See LICENSE file

---

## Quick Reference

```bash
# Initial setup - auto-generate inventory
cd docker-update-manager
./scripts/generate-inventory.sh

# Monthly update
./scripts/docker-update.sh

# Check current state
docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}"

# View recent logs
tail -100 log/update-*.log | less

# Regenerate inventory after adding new containers
./scripts/generate-inventory.sh --backup

# Manual stack update
cd /opt/stacks/mystack
docker compose pull && docker compose up -d

# Manual build update
cd /opt/stacks/mystack
docker compose build --pull && docker compose up -d --build

# Cleanup old images
docker image prune -a --filter "until=720h" -f
```
