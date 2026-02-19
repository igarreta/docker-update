# Docker & Podman Update Manager

A manual, inventory-based update strategy for Docker and Podman containers running on a Proxmox VM or unprivileged LXC.

## Overview

This project provides a controlled, monthly update process for containers with:

- **Inventory validation** - Ensures consistency between documented and running containers
- **Dockerfile/Containerfile support** - Handles both pre-built images and custom builds
- **Staged updates** - Updates containers by stack with verification between each
- **Warning system** - Alerts on discrepancies (running but undocumented, or documented but stopped)
- **Logging** - Complete audit trail of all update operations
- **Podman support** - Sister scripts for unprivileged LXC environments running Podman

## Context

Designed for a home server environment running:
- **Host**: Proxmox VE on GMTec NucBox G5 (Intel N97, 12GB RAM)
- **VM**: docker03 - Docker host with multiple containers
- **LXC**: Unprivileged containers running Podman (via `sudo podman`)
- **Containers**: 14 running + 1 cron-triggered (Docker); additional Podman containers in LXC

This complements existing update strategies for Proxmox and the Docker VM itself.

## Installation

```bash
# Clone the repository
git clone https://github.com/igarreta/docker-update.git
cd docker-update

# Make scripts executable
chmod +x scripts/*.sh
```

### Docker setup

```bash
# Option 1: Auto-generate inventory from running containers (recommended)
./scripts/generate-inventory.sh

# Option 2: Manual setup from example
mkdir -p ~/etc
cp examples/inventory.example ~/etc/docker-inventory
# Then edit ~/etc/docker-inventory to add your containers
```

### Podman setup (unprivileged LXC)

```bash
# Auto-generate inventory from running Podman containers
./scripts/generate-podman-inventory.sh

# Or create manually
mkdir -p ~/etc
# Edit ~/etc/podman-inventory to add your containers
```

## Configuration

### Inventory File

Edit `~/etc/docker-inventory` to document your containers:

```bash
# Format: container_name|stack_path|notes
# (type is auto-detected from Dockerfile/docker-compose.yml)
#
# Alternative formats:
#   container_name|stack_path|type|notes          # Explicit type
#   container_name|stack_path|notes|flags         # With flags
#   container_name|stack_path|type|notes|flags    # All fields
#
# Type options:
#   pull  - Uses pre-built images from registry
#   build - Has Dockerfile that needs building
#
# Flag options:
#   update-stopped - Update even if container is not running

# Type auto-detected (recommended)
portainer|/opt/stacks/portainer|Management UI
traefik|/opt/stacks/traefik|Reverse proxy
my-custom-app|/opt/stacks/custom-app|Built from local Dockerfile

# Cron-triggered container (not expected to be running)
backup-runner|/opt/stacks/backup|Nightly backups|update-stopped

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

### Pushover Notifications (Optional)

The script can send push notifications via [Pushover](https://pushover.net/) when containers fail post-update.

**Setup:**

1. Create a Pushover account at https://pushover.net/
2. Get your User Key from the dashboard
3. Create an Application/API Token

**Configure credentials:**

```bash
# Option 1: Use credentials file (recommended)
# Create /home/rsi/etc/pushover.env with:
PUSHOVER_TOKEN="your_api_token_here"
PUSHOVER_USER="your_user_key_here"
DEFAULT_DEVICE="your_device_name"  # Optional - target specific device

# Option 2: Set environment variables
export PUSHOVER_USER_KEY="your_user_key_here"
export PUSHOVER_API_TOKEN="your_api_token_here"
export PUSHOVER_DEVICE="your_device_name"  # Optional

# Option 3: Edit the script directly
# Uncomment and set in scripts/docker-update.sh:
# PUSHOVER_USER_KEY="your_user_key_here"
# PUSHOVER_API_TOKEN="your_api_token_here"
# PUSHOVER_DEVICE="your_device_name"  # Optional
```

**What you'll get:**
- High-priority alerts when containers fail to start after an update
- Notification includes failed container names and log file location
- Optional device targeting (send to specific device only)
- Warnings in the log if credentials are not configured

## Generating Inventory

### Docker — Auto-Generate from Running Containers

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

**Output:** `~/etc/docker-inventory`

### Podman — Auto-Generate from Running Containers

```bash
# Generate inventory from running Podman containers (requires sudo)
./scripts/generate-podman-inventory.sh

# Preview what would be generated (dry run)
./scripts/generate-podman-inventory.sh --dry-run

# Generate with automatic backup
./scripts/generate-podman-inventory.sh --backup

# Force overwrite without prompting
./scripts/generate-podman-inventory.sh --force
```

**How it works:**
- Uses `sudo podman` to scan running containers
- Extracts stack paths from Podman Compose labels (`com.docker.compose.project.working_dir`)
- Groups containers by stack
- Generates inventory in the 3-field format (type auto-detected from `Containerfile`/`Dockerfile`)
- Warns about containers without detectable paths (not managed by Podman Compose)

**Output:** `~/etc/podman-inventory`

**Limitations (both generators):**
- Only detects **running** containers (stopped containers must be added manually)
- Containers not started with Compose will show `UNKNOWN` path
- You'll need to manually edit the file to fix unknown paths and add stopped containers

### Manual Inventory Creation

```bash
mkdir -p ~/etc

# Docker
cat > ~/etc/docker-inventory << 'EOF'
# Format: container_name|stack_path|notes
portainer|/opt/stacks/portainer|Management UI
traefik|/opt/stacks/traefik|Reverse proxy
EOF

# Podman
cat > ~/etc/podman-inventory << 'EOF'
# Format: container_name|stack_path|notes
homeassistant|/opt/stacks/homeassistant|Home automation
EOF
```

## Usage

### Docker — Monthly Update Process

```bash
~/docker-update/scripts/docker-update.sh
```

### Podman — Monthly Update Process

```bash
~/docker-update/scripts/podman-update.sh
```

Both scripts will:

1. **Validate inventory** against running containers
2. **Report warnings** for any discrepancies
3. **Update each stack** based on type (pull or build)
4. **Verify** all containers are running post-update
5. **Clean up** unused images
6. **Log** all operations

### Validation Only

```bash
# Docker
~/docker-update/scripts/docker-update.sh --validate-only

# Podman
~/docker-update/scripts/podman-update.sh --validate-only
```

### Update Specific Container

```bash
# Docker
~/docker-update/scripts/docker-update.sh --container portainer

# Podman
~/docker-update/scripts/podman-update.sh --container homeassistant
```

**Note:** This updates the container's entire stack. If multiple containers share the same stack, they'll all be updated.

### Update Specific Stack

```bash
# Docker
~/docker-update/scripts/docker-update.sh --stack /opt/stacks/monitoring

# Podman
~/docker-update/scripts/podman-update.sh --stack /opt/stacks/homeassistant
```

### Help

```bash
~/docker-update/scripts/docker-update.sh --help
~/docker-update/scripts/podman-update.sh --help
```

## Container Types

### Pre-built Images (`type: pull`)

For containers using images from Docker Hub, GHCR, etc:

```yaml
# compose.yaml
services:
  app:
    image: nginx:latest
```

### Dockerfile/Containerfile Builds (`type: build`)

For containers built from local files. Both `Dockerfile` (Docker/Podman) and `Containerfile` (Podman) are detected automatically:

```yaml
# compose.yaml
services:
  app:
    build:
      context: .
      dockerfile: Containerfile  # or Dockerfile
```

Type auto-detection checks (in order):
1. `Dockerfile` or `Containerfile` present in the stack directory → `build`
2. `build:` section in the compose file → `build`
3. Otherwise → `pull`

## Validation Logic

| Scenario | Status | Action |
|----------|--------|--------|
| In inventory + Running | ✓ OK | Updated |
| In inventory + Not running | ⚠ Warning | Skipped, logged |
| Running + Not in inventory | ⚠ Warning | Not updated, logged |
| Stack directory missing | ✗ Error | Logged, continues |
| Container fails post-update | ✗ Error | Logged in summary |

## Cron-Triggered Containers

For containers that run on a schedule (not always running), use the `update-stopped` flag:

```bash
# Format: container_name|stack_path|notes|update-stopped
backup-runner|/opt/stacks/backup|Nightly backups|update-stopped
db-backup|/opt/stacks/db-backup|Database backups|update-stopped
```

**What this does:**
- Skips the "not running" warning during validation
- Updates the container's stack even when stopped
- Skips post-update verification (won't fail if container is stopped)

**Use cases:**
- Cron-triggered containers
- One-off job containers
- Maintenance containers that run periodically

## Logging

Logs are stored in the project's `log/` subdirectory:

```
docker-update/
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
docker-update/
├── README.md
├── LICENSE
├── scripts/
│   ├── docker-update.sh              # Main Docker update script
│   ├── generate-inventory.sh         # Auto-generate Docker inventory
│   ├── validate-inventory.sh         # Docker validation only (wrapper)
│   ├── podman-update.sh              # Podman update script (unprivileged LXC)
│   └── generate-podman-inventory.sh  # Auto-generate Podman inventory
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

- [x] `--validate-only` flag for dry runs
- [x] `--stack <path>` flag for single-stack updates
- [x] `--container <name>` flag for single-container updates
- [x] `update-stopped` flag for cron-triggered containers
- [x] Pushover notification support for failures
- [x] Podman support (`podman-update.sh`, `generate-podman-inventory.sh`)
- [ ] Health check integration (wait for healthy status)
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

### Docker

```bash
# Initial setup - auto-generate inventory
cd docker-update
./scripts/generate-inventory.sh

# Update all containers (monthly)
./scripts/docker-update.sh

# Update only one container
./scripts/docker-update.sh --container portainer

# Update all containers in a stack
./scripts/docker-update.sh --stack /opt/stacks/monitoring

# Validate inventory without updating
./scripts/docker-update.sh --validate-only

# Regenerate inventory after adding new containers
./scripts/generate-inventory.sh --backup

# Check current state
docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}"
```

### Podman

```bash
# Initial setup - auto-generate inventory (requires sudo)
cd docker-update
./scripts/generate-podman-inventory.sh

# Update all containers (monthly)
./scripts/podman-update.sh

# Update only one container
./scripts/podman-update.sh --container homeassistant

# Update all containers in a stack
./scripts/podman-update.sh --stack /opt/stacks/homeassistant

# Validate inventory without updating
./scripts/podman-update.sh --validate-only

# Regenerate inventory after adding new containers
./scripts/generate-podman-inventory.sh --backup

# Check current state
sudo podman ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}"
```

### Logs and Cleanup

```bash
# View recent logs
tail -100 log/update-*.log | less

# Cleanup old Docker images
docker image prune -a --filter "until=720h" -f

# Cleanup old Podman images
sudo podman image prune -f
```
