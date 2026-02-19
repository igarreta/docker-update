# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

### Added
- `podman-update.sh` - Sister script for Podman containers in unprivileged LXC environments (uses `sudo podman`)
- `generate-podman-inventory.sh` - Auto-generates `~/etc/podman-inventory` by scanning running Podman containers

### Planned
- Notification support (email/webhook on completion)
- Backup verification before update
- Automated rollback on health check failure
- Update scheduling recommendations
- Integration with container registries for update detection

---

## [0.1.0] - 2025-01-XX

### Added
- Initial release
- Main update script (`docker-update.sh`)
- Inventory-based container management
- Support for pre-built images (`pull` type)
- Support for Dockerfile builds (`build` type)
- `--validate-only` flag for dry runs
- `--stack` flag for single-stack updates
- `ignore-stopped` flag for cron-triggered containers
- Color-coded console output
- Comprehensive logging to `~/docker-logs/`
- Post-update container verification
- Automatic image cleanup
- Health check status reporting
- Example inventory file
- Troubleshooting documentation

### Infrastructure Context
- Designed for Proxmox VE environment
- Tested on docker03 VM (14 containers + 1 cron)
- Complements existing Proxmox update strategy
