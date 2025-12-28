# Troubleshooting Guide

## Common Issues

### 1. Container Won't Start After Update

**Symptoms:**
- Container shows as `exited` or `restarting`
- Health check fails

**Diagnosis:**
```bash
# Check container logs
docker logs <container_name> --tail 100

# Check container state
docker inspect <container_name> | jq '.[0].State'

# Check if port is already in use
netstat -tlnp | grep <port>
```

**Solutions:**
- Check for breaking changes in new image version
- Verify volume permissions haven't changed
- Check environment variables are still valid
- Review compose file for deprecated options

### 2. Build Fails for Dockerfile-Based Container

**Symptoms:**
- `docker compose build --pull` fails
- Error messages about missing packages or dependencies

**Diagnosis:**
```bash
# Try building with no cache
docker compose build --no-cache --pull

# Check Dockerfile syntax
docker build --check .
```

**Solutions:**
- Base image may have breaking changes - pin to specific version
- Update Dockerfile for new base image requirements
- Check if build dependencies are still available

### 3. Inventory Validation Shows Many Warnings

**Symptoms:**
- Multiple "running but NOT in inventory" warnings
- Multiple "in inventory but NOT running" warnings

**Solutions:**

For untracked containers:
```bash
# List all running containers with their compose project
docker ps --format "{{.Names}}\t{{.Label \"com.docker.compose.project.working_dir\"}}"

# Add missing containers to inventory
echo "container_name|/path/to/stack|pull|Description" >> ~/.docker-inventory
```

For stopped containers:
```bash
# Check why container stopped
docker logs <container_name>

# If it's a cron job, add ignore-stopped flag
# Edit inventory: container|/path|pull|ignore-stopped - runs via cron
```

### 4. Disk Space Issues

**Symptoms:**
- Pull fails with "no space left on device"
- Build fails during image layer creation

**Diagnosis:**
```bash
# Check Docker disk usage
docker system df -v

# Find largest images
docker images --format "{{.Size}}\t{{.Repository}}:{{.Tag}}" | sort -h
```

**Solutions:**
```bash
# Remove all unused images (not just dangling)
docker image prune -a --filter "until=168h"  # Older than 1 week

# Remove unused volumes (CAREFUL - check first)
docker volume ls -f dangling=true
docker volume prune

# Full cleanup (removes everything unused)
docker system prune -a --volumes
```

### 5. Network Connectivity Issues After Update

**Symptoms:**
- Container can't reach other containers
- External access to container fails

**Diagnosis:**
```bash
# Check container networks
docker network ls
docker inspect <container> | jq '.[0].NetworkSettings.Networks'

# Test connectivity from inside container
docker exec <container> ping <other_container>
```

**Solutions:**
- Recreate the network: `docker network rm <network> && docker compose up -d`
- Check if network mode changed in new image
- Verify DNS resolution: `docker exec <container> cat /etc/resolv.conf`

### 6. Permission Denied on Volumes

**Symptoms:**
- Application can't write to mounted volumes
- Logs show "permission denied" errors

**Diagnosis:**
```bash
# Check volume ownership
ls -la /path/to/volume

# Check container user
docker exec <container> id
```

**Solutions:**
- New image may run as different UID/GID
- Add `user: "1000:1000"` to compose file
- Fix host permissions: `chown -R 1000:1000 /path/to/volume`

### 7. Health Check Failures

**Symptoms:**
- Container shows as `unhealthy`
- Service works but health check fails

**Diagnosis:**
```bash
# Check health check configuration
docker inspect <container> | jq '.[0].Config.Healthcheck'

# Check health check logs
docker inspect <container> | jq '.[0].State.Health'
```

**Solutions:**
- Health check endpoint may have changed in new version
- Increase health check timeout/retries
- Update health check command in compose file

---

## Rollback Procedures

### Quick Rollback (Same Session)

If you notice issues immediately after update:

```bash
cd /path/to/stack

# If you have the previous image cached locally
docker compose down
docker compose up -d --no-pull
```

### Rollback to Specific Version

```bash
cd /path/to/stack

# Edit docker-compose.yml to pin version
# Change: image: nginx:latest
# To:     image: nginx:1.24

docker compose up -d
```

### Rollback Build-Based Container

```bash
cd /path/to/stack

# Check git history for previous working Dockerfile
git log --oneline Dockerfile

# Checkout previous version
git checkout <commit> -- Dockerfile

# Rebuild
docker compose build
docker compose up -d
```

### Emergency: Restore from Backup

If container data is corrupted:

```bash
# Stop the container
docker compose down

# Restore volume data from backup
rsync -av /backup/container-data/ /path/to/volume/

# Restart with previous image version
docker compose up -d
```

---

## Preventive Measures

### 1. Pin Image Versions

Instead of:
```yaml
image: postgres:latest
```

Use:
```yaml
image: postgres:16.2
```

### 2. Test Updates on Non-Critical Containers First

Update order recommendation:
1. Monitoring/logging containers
2. Development/testing services
3. Non-critical applications
4. Critical services (databases, core apps)

### 3. Maintain Backups

Before major updates:
```bash
# Backup volumes
tar -czf backup-$(date +%Y%m%d).tar.gz /path/to/volumes

# Backup compose files
cp -r /opt/stacks /opt/stacks.backup.$(date +%Y%m%d)
```

### 4. Review Release Notes

Before updating, check:
- Docker Hub page for the image
- GitHub releases/changelog
- Breaking changes documentation

### 5. Use Health Checks

Add health checks to compose files:
```yaml
services:
  app:
    image: myapp:latest
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
```

---

## Getting Help

### Collect Diagnostic Information

When reporting issues, gather:

```bash
# System info
docker version
docker compose version
uname -a

# Container state
docker ps -a
docker compose ps

# Recent logs
docker compose logs --tail 200 > container-logs.txt

# Update log
cat ~/docker-logs/update-*.log | tail -500
```

### Useful Commands Reference

```bash
# View all container resource usage
docker stats --no-stream

# Find container by partial name
docker ps -a --filter "name=partial"

# Execute command in running container
docker exec -it <container> /bin/sh

# Copy files from container
docker cp <container>:/path/to/file ./local-file

# View container changes from image
docker diff <container>
```
