#!/bin/bash
# ~/scripts/docker-update.sh
# Monthly Docker container update with inventory validation

set -e

# === CONFIGURATION ===
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
INVENTORY_FILE="$HOME/etc/docker-inventory"
LOG_DIR="$PROJECT_DIR/log"
LOG_FILE="$LOG_DIR/update-$(date +%Y%m%d-%H%M).log"
COMPOSE_BASE="/path/to/your/compose/files"  # Adjust this

# Pushover credentials (optional - for failure alerts)
# Option 1: Source from credentials file (recommended)
PUSHOVER_ENV_FILE="/home/rsi/etc/pushover.env"
if [[ -f "$PUSHOVER_ENV_FILE" ]]; then
    source "$PUSHOVER_ENV_FILE"
    # Map variables from env file to script variables
    PUSHOVER_USER_KEY="${PUSHOVER_USER}"
    PUSHOVER_API_TOKEN="${PUSHOVER_TOKEN}"
    PUSHOVER_DEVICE="${DEFAULT_DEVICE}"
fi

# Option 2: Set in environment or uncomment and set here:
# PUSHOVER_USER_KEY="your_user_key_here"
# PUSHOVER_API_TOKEN="your_api_token_here"
# PUSHOVER_DEVICE="your_device_name"  # Optional

# === COLOR OUTPUT ===
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# === FUNCTIONS ===
log() {
    echo -e "$1" | tee -a "$LOG_FILE"
}

warn() {
    log "${YELLOW}⚠ WARNING: $1${NC}"
}

error() {
    log "${RED}✗ ERROR: $1${NC}"
}

success() {
    log "${GREEN}✓ $1${NC}"
}

info() {
    log "${BLUE}ℹ $1${NC}"
}

# === HELPER FUNCTIONS ===
detect_stack_type() {
    local stack_path="$1"

    # Check if directory exists
    if [[ ! -d "$stack_path" ]]; then
        echo "pull"  # Default to pull if directory doesn't exist
        return
    fi

    # Check for Dockerfile
    if [[ -f "$stack_path/Dockerfile" ]]; then
        echo "build"
        return
    fi

    # Check docker-compose.yml for build: section
    local compose_file=""
    if [[ -f "$stack_path/docker-compose.yml" ]]; then
        compose_file="$stack_path/docker-compose.yml"
    elif [[ -f "$stack_path/docker-compose.yaml" ]]; then
        compose_file="$stack_path/docker-compose.yaml"
    elif [[ -f "$stack_path/compose.yml" ]]; then
        compose_file="$stack_path/compose.yml"
    elif [[ -f "$stack_path/compose.yaml" ]]; then
        compose_file="$stack_path/compose.yaml"
    fi

    if [[ -n "$compose_file" ]] && grep -q "^\s*build:" "$compose_file"; then
        echo "build"
        return
    fi

    # Default to pull
    echo "pull"
}

send_pushover() {
    local title="$1"
    local message="$2"
    local priority="${3:-0}"  # Default priority: normal

    # Check if Pushover credentials are configured
    if [[ -z "$PUSHOVER_USER_KEY" ]] || [[ -z "$PUSHOVER_API_TOKEN" ]]; then
        warn "Pushover credentials not configured - skipping notification"
        warn "Configure credentials in $PUSHOVER_ENV_FILE or set environment variables"
        return 1
    fi

    # Build curl command with optional device parameter
    local curl_cmd="curl -s --form-string \"token=$PUSHOVER_API_TOKEN\" \
        --form-string \"user=$PUSHOVER_USER_KEY\" \
        --form-string \"title=$title\" \
        --form-string \"message=$message\" \
        --form-string \"priority=$priority\""

    # Add device if specified
    if [[ -n "$PUSHOVER_DEVICE" ]]; then
        curl_cmd+=" --form-string \"device=$PUSHOVER_DEVICE\""
    fi

    curl_cmd+=" https://api.pushover.net/1/messages.json 2>&1"

    # Send notification
    local response=$(eval "$curl_cmd")

    if echo "$response" | grep -q '"status":1'; then
        info "Pushover notification sent successfully"
        return 0
    else
        warn "Failed to send Pushover notification: $response"
        return 1
    fi
}

# === ARGUMENT PARSING ===
TARGET_CONTAINER=""
TARGET_STACK=""
VALIDATE_ONLY=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --container)
            TARGET_CONTAINER="$2"
            shift 2
            ;;
        --stack)
            TARGET_STACK="$2"
            shift 2
            ;;
        --validate-only)
            VALIDATE_ONLY=true
            shift
            ;;
        -h|--help)
            cat << EOF
Docker Update Script

USAGE:
    $0 [OPTIONS]

OPTIONS:
    --container NAME    Update only the specified container
    --stack PATH        Update only the specified stack
    --validate-only     Run validation without performing updates
    -h, --help          Show this help message

EXAMPLES:
    # Update all containers
    $0

    # Update only one container
    $0 --container portainer

    # Update all containers in a stack
    $0 --stack /opt/stacks/monitoring

    # Validate inventory without updating
    $0 --validate-only
EOF
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# === INITIALIZATION ===
mkdir -p "$LOG_DIR"
mkdir -p "$(dirname "$INVENTORY_FILE")"

# === INVENTORY FILE FORMAT ===
# Create if doesn't exist with example format
if [[ ! -f "$INVENTORY_FILE" ]]; then
    cat > "$INVENTORY_FILE" << 'EOF'
# Docker Container Inventory
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
#   update-stopped - Update even if container is not running (for cron jobs, etc.)
#
# Examples:
# homeassistant|/opt/stacks/homeassistant|Home automation
# custom-app|/opt/stacks/custom-app|Custom built from Dockerfile
# nginx-proxy|/opt/stacks/proxy|pull|Reverse proxy (explicit type)
# backup-runner|/opt/stacks/backup|Nightly backups|update-stopped
#
# Add your containers below:
EOF
    error "Inventory file created at $INVENTORY_FILE"
    error "Please populate it before running updates."
    exit 1
fi

# === LOAD INVENTORY ===
declare -A INVENTORY_STACKS
declare -A INVENTORY_TYPES
declare -A INVENTORY_FLAGS
INVENTORY_CONTAINERS=()

while IFS= read -r line; do
    # Skip comments and empty lines
    [[ "$line" =~ ^#.*$ ]] && continue
    [[ -z "$line" ]] && continue

    # Count the number of pipe separators to determine format
    pipe_count=$(echo "$line" | tr -cd '|' | wc -c)

    flags=""
    if [[ $pipe_count -eq 2 ]]; then
        # 3-field format: container_name|stack_path|notes
        IFS='|' read -r name stack notes <<< "$line"
        type=""  # Will be auto-detected
    elif [[ $pipe_count -eq 3 ]]; then
        # Could be: container_name|stack_path|type|notes OR container_name|stack_path|notes|flags
        IFS='|' read -r name stack field3 field4 <<< "$line"
        # Check if field3 looks like a type (pull/build) or contains flags
        if [[ "$field3" =~ ^(pull|build)$ ]]; then
            type="$field3"
            notes="$field4"
        else
            type=""
            notes="$field3"
            flags="$field4"
        fi
    elif [[ $pipe_count -eq 4 ]]; then
        # 5-field format: container_name|stack_path|type|notes|flags
        IFS='|' read -r name stack type notes flags <<< "$line"
    else
        warn "Invalid inventory line (expected 2-4 pipes): $line"
        continue
    fi

    # Trim whitespace
    name=$(echo "$name" | xargs)
    stack=$(echo "$stack" | xargs)
    type=$(echo "$type" | xargs)
    flags=$(echo "$flags" | xargs)

    # Auto-detect type if not specified
    if [[ -z "$type" ]]; then
        type=$(detect_stack_type "$stack")
    fi

    INVENTORY_CONTAINERS+=("$name")
    INVENTORY_STACKS["$name"]="$stack"
    INVENTORY_TYPES["$name"]="$type"
    INVENTORY_FLAGS["$name"]="$flags"
done < "$INVENTORY_FILE"

# === VALIDATE TARGET CONTAINER/STACK ===
if [[ -n "$TARGET_CONTAINER" ]]; then
    found=false
    for container in "${INVENTORY_CONTAINERS[@]}"; do
        if [[ "$container" == "$TARGET_CONTAINER" ]]; then
            found=true
            break
        fi
    done
    if [[ "$found" == false ]]; then
        error "Container '$TARGET_CONTAINER' not found in inventory"
        exit 1
    fi
    info "Targeting single container: $TARGET_CONTAINER"
fi

if [[ -n "$TARGET_STACK" ]]; then
    found=false
    for container in "${INVENTORY_CONTAINERS[@]}"; do
        if [[ "${INVENTORY_STACKS[$container]}" == "$TARGET_STACK" ]]; then
            found=true
            break
        fi
    done
    if [[ "$found" == false ]]; then
        error "Stack '$TARGET_STACK' not found in inventory"
        exit 1
    fi
    info "Targeting single stack: $TARGET_STACK"
fi

# === VALIDATION ===
log "========================================"
log "Docker Update - $(date)"
log "========================================"
log ""
info "Validating container inventory..."
log ""

# Get currently running containers
RUNNING_CONTAINERS=$(docker ps --format '{{.Names}}' | sort)
WARNINGS=0
ERRORS=0
INVENTORY_WARNINGS=()

# Check 1: Containers in inventory but NOT running
log "--- Checking inventory containers ---"
for container in "${INVENTORY_CONTAINERS[@]}"; do
    flags="${INVENTORY_FLAGS[$container]}"
    if echo "$RUNNING_CONTAINERS" | grep -q "^${container}$"; then
        success "$container: in inventory and running"
    else
        if [[ "$flags" == *"update-stopped"* ]]; then
            info "$container: stopped (will update anyway - update-stopped flag)"
        else
            warn "$container: in inventory but NOT running"
            INVENTORY_WARNINGS+=("$container: in inventory but NOT running")
            ((++WARNINGS))
        fi
    fi
done

log ""

# Check 2: Running containers NOT in inventory
log "--- Checking for untracked containers ---"
while IFS= read -r running; do
    [[ -z "$running" ]] && continue
    
    found=0
    for inv in "${INVENTORY_CONTAINERS[@]}"; do
        if [[ "$inv" == "$running" ]]; then
            found=1
            break
        fi
    done
    
    if [[ $found -eq 0 ]]; then
        warn "$running: running but NOT in inventory"
        ((++WARNINGS))
    fi
done <<< "$RUNNING_CONTAINERS"

log ""
log "========================================"
log "Validation Summary: $WARNINGS warnings, $ERRORS errors"
log "========================================"
log ""

# === EXIT IF VALIDATE-ONLY ===
if [[ "$VALIDATE_ONLY" == true ]]; then
    info "Validation complete (--validate-only mode)"
    exit 0
fi

# === CONTINUE DESPITE WARNINGS ===
if [[ $WARNINGS -gt 0 ]]; then
    warn "There are discrepancies between inventory and running state. Continuing anyway..."
fi

# === UPDATE PROCESS ===
log ""
info "Starting update process..."
log ""

# Group containers by stack for efficient updates
declare -A STACKS_TO_UPDATE
for container in "${INVENTORY_CONTAINERS[@]}"; do
    # Skip if targeting specific container and this isn't it
    if [[ -n "$TARGET_CONTAINER" ]] && [[ "$container" != "$TARGET_CONTAINER" ]]; then
        continue
    fi

    flags="${INVENTORY_FLAGS[$container]}"
    stack="${INVENTORY_STACKS[$container]}"

    # Skip if targeting specific stack and this container's stack doesn't match
    if [[ -n "$TARGET_STACK" ]] && [[ "$stack" != "$TARGET_STACK" ]]; then
        continue
    fi

    is_running=$(echo "$RUNNING_CONTAINERS" | grep -q "^${container}$" && echo "yes" || echo "no")

    # Update if container is running OR has update-stopped flag
    if [[ "$is_running" == "yes" ]] || [[ "$flags" == *"update-stopped"* ]]; then
        type="${INVENTORY_TYPES[$container]}"
        # Mark stack for update (avoid duplicates if multiple containers per stack)
        STACKS_TO_UPDATE["$stack"]="$type"
    fi
done

# Update each stack
for stack in "${!STACKS_TO_UPDATE[@]}"; do
    type="${STACKS_TO_UPDATE[$stack]}"
    
    log "----------------------------------------"
    info "Updating stack: $stack (type: $type)"
    log "----------------------------------------"
    
    if [[ ! -d "$stack" ]]; then
        error "Stack directory not found: $stack"
        ((++ERRORS))
        continue
    fi
    
    cd "$stack"
    
    if [[ "$type" == "build" ]]; then
        # Dockerfile-based stack
        info "Rebuilding from Dockerfile (pulling fresh base images)..."
        if docker compose build --pull 2>&1 | tee -a "$LOG_FILE"; then
            info "Recreating containers..."
            docker compose up -d --build 2>&1 | tee -a "$LOG_FILE"
            success "Stack updated successfully"
        else
            error "Build failed for $stack"
            ((++ERRORS))
        fi
    else
        # Pre-built image stack
        info "Pulling latest images..."
        if docker compose pull 2>&1 | tee -a "$LOG_FILE"; then
            info "Recreating containers..."
            docker compose up -d 2>&1 | tee -a "$LOG_FILE"
            success "Stack updated successfully"
        else
            error "Pull failed for $stack"
            ((++ERRORS))
        fi
    fi
    
    # Brief pause between stacks
    sleep 2
done

# === POST-UPDATE VERIFICATION ===
log ""
log "========================================"
info "Post-update verification"
log "========================================"

sleep 5  # Give containers time to stabilize

FAILED_CONTAINERS=()
for container in "${INVENTORY_CONTAINERS[@]}"; do
    # Skip if targeting specific container and this isn't it
    if [[ -n "$TARGET_CONTAINER" ]] && [[ "$container" != "$TARGET_CONTAINER" ]]; then
        continue
    fi

    # Skip if targeting specific stack and this container's stack doesn't match
    if [[ -n "$TARGET_STACK" ]] && [[ "${INVENTORY_STACKS[$container]}" != "$TARGET_STACK" ]]; then
        continue
    fi

    flags="${INVENTORY_FLAGS[$container]}"
    status=$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || echo "not_found")

    # Skip verification for containers with update-stopped flag (they're not expected to be running)
    if [[ "$flags" == *"update-stopped"* ]]; then
        info "$container: skipped verification (update-stopped flag)"
        continue
    fi

    if [[ "$status" == "running" ]]; then
        success "$container: running"
    else
        error "$container: status=$status"
        FAILED_CONTAINERS+=("$container")
        ((++ERRORS))
    fi
done

# Send Pushover alert if any containers failed
if [[ ${#FAILED_CONTAINERS[@]} -gt 0 ]]; then
    alert_title="Docker Update Failed"
    alert_message="Failed containers (${#FAILED_CONTAINERS[@]}): ${FAILED_CONTAINERS[*]}"
    alert_message+="\n\nCheck logs: $LOG_FILE"
    send_pushover "$alert_title" "$alert_message" 1  # Priority 1 (high)
fi

# === CLEANUP ===
log ""
info "Cleaning up old images..."
docker image prune -f 2>&1 | tee -a "$LOG_FILE"

# === FINAL SUMMARY ===
log ""
log "========================================"
log "UPDATE COMPLETE - $(date)"
log "========================================"
log "Warnings: $WARNINGS"
log "Errors: $ERRORS"

if [[ ${#INVENTORY_WARNINGS[@]} -gt 0 ]]; then
    log ""
    warn "Inventory warnings (containers not running at update time):"
    for w in "${INVENTORY_WARNINGS[@]}"; do
        warn "  $w"
    done
fi

if [[ ${#FAILED_CONTAINERS[@]} -gt 0 ]]; then
    error "Failed containers: ${FAILED_CONTAINERS[*]}"
    log "Check logs: $LOG_FILE"
    exit 1
fi

if [[ $ERRORS -eq 0 ]]; then
    success "All updates completed successfully!"
else
    warn "Completed with $ERRORS errors. Review log: $LOG_FILE"
fi
