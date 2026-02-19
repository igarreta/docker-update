#!/bin/bash
# generate-podman-inventory.sh
# Auto-generate Podman inventory from running containers

set -e

# === SUDO CREDENTIAL CACHE ===
echo "Sudo access is required for podman commands."
sudo -v

# === CONFIGURATION ===
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
INVENTORY_FILE="$HOME/etc/podman-inventory"
BACKUP_SUFFIX=".backup-$(date +%Y%m%d-%H%M%S)"

# === COLOR OUTPUT ===
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# === FUNCTIONS ===
info() {
    echo -e "${BLUE}ℹ $1${NC}"
}

success() {
    echo -e "${GREEN}✓ $1${NC}"
}

warn() {
    echo -e "${YELLOW}⚠ WARNING: $1${NC}"
}

error() {
    echo -e "${RED}✗ ERROR: $1${NC}"
}

show_help() {
    cat << EOF
Podman Inventory Generator

USAGE:
    $0 [OPTIONS]

OPTIONS:
    -h, --help          Show this help message
    -o, --output FILE   Output file (default: $INVENTORY_FILE)
    -f, --force         Overwrite existing inventory without prompting
    -b, --backup        Create backup before overwriting
    --dry-run           Show what would be generated without writing

DESCRIPTION:
    Automatically generates a Podman inventory file by scanning running containers.
    Extracts container names and stack paths from Podman Compose labels.

EXAMPLES:
    # Generate inventory (prompts if file exists)
    $0

    # Generate with automatic backup
    $0 --backup

    # Preview what would be generated
    $0 --dry-run

    # Force overwrite without prompting
    $0 --force
EOF
}

# === PARSE ARGUMENTS ===
DRY_RUN=false
FORCE=false
BACKUP=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -o|--output)
            INVENTORY_FILE="$2"
            shift 2
            ;;
        -f|--force)
            FORCE=true
            shift
            ;;
        -b|--backup)
            BACKUP=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        *)
            error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# === MAIN ===
info "Scanning running Podman containers..."
echo ""

# Check if Podman is accessible
if ! sudo podman ps &>/dev/null; then
    error "Podman is not running or you don't have permission to access it"
    exit 1
fi

# Get running containers
RUNNING_CONTAINERS=$(sudo podman ps --format '{{.Names}}' | sort)

if [[ -z "$RUNNING_CONTAINERS" ]]; then
    warn "No running containers found"
    exit 1
fi

CONTAINER_COUNT=$(echo "$RUNNING_CONTAINERS" | wc -l)
info "Found $CONTAINER_COUNT running container(s)"
echo ""

# Collect container information
declare -A CONTAINER_PATHS
declare -A CONTAINER_IMAGES
UNKNOWN_PATHS=()

while IFS= read -r container; do
    # Try to get the compose project working directory
    working_dir=$(sudo podman inspect "$container" \
        --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' 2>/dev/null || echo "")

    # Get image name for additional context
    image=$(sudo podman inspect "$container" --format '{{.Config.Image}}' 2>/dev/null || echo "unknown")

    if [[ -n "$working_dir" && "$working_dir" != "<no value>" ]]; then
        CONTAINER_PATHS["$container"]="$working_dir"
        success "$container → $working_dir"
    else
        CONTAINER_PATHS["$container"]="UNKNOWN"
        UNKNOWN_PATHS+=("$container")
        warn "$container → Path not found (not managed by Podman Compose?)"
    fi

    CONTAINER_IMAGES["$container"]="$image"
done <<< "$RUNNING_CONTAINERS"

echo ""

# Warn about unknown paths
if [[ ${#UNKNOWN_PATHS[@]} -gt 0 ]]; then
    warn "${#UNKNOWN_PATHS[@]} container(s) without detectable stack path"
    info "These containers may not be managed by Podman Compose"
    info "You'll need to manually set their paths in the inventory file"
    echo ""
fi

# === GENERATE INVENTORY CONTENT ===
INVENTORY_CONTENT="# ~/etc/podman-inventory
# Auto-generated on $(date)
# Format: container_name|stack_path|notes
# (type is auto-detected from Containerfile/Dockerfile/compose file)

"

# Group containers by stack path
declare -A STACKS
for container in $(echo "$RUNNING_CONTAINERS"); do
    path="${CONTAINER_PATHS[$container]}"
    if [[ -n "${STACKS[$path]}" ]]; then
        STACKS[$path]="${STACKS[$path]},$container"
    else
        STACKS[$path]="$container"
    fi
done

# Generate entries grouped by stack
for path in $(printf '%s\n' "${!STACKS[@]}" | sort); do
    containers="${STACKS[$path]}"

    if [[ "$path" == "UNKNOWN" ]]; then
        INVENTORY_CONTENT+="# Containers with unknown paths (manually set the path)
"
        IFS=',' read -ra CONTAINER_LIST <<< "$containers"
        for container in "${CONTAINER_LIST[@]}"; do
            image="${CONTAINER_IMAGES[$container]}"
            INVENTORY_CONTENT+="$container|/opt/stacks/FIXME|Image: $image
"
        done
        INVENTORY_CONTENT+="
"
    else
        # Get stack name from path
        stack_name=$(basename "$path")

        IFS=',' read -ra CONTAINER_LIST <<< "$containers"
        if [[ ${#CONTAINER_LIST[@]} -gt 1 ]]; then
            INVENTORY_CONTENT+="# Stack: $stack_name (${#CONTAINER_LIST[@]} containers)
"
        fi

        for container in "${CONTAINER_LIST[@]}"; do
            image="${CONTAINER_IMAGES[$container]}"
            # Simplify image name for notes
            image_short=$(echo "$image" | sed 's/:latest$//' | sed 's/^.*\///')
            INVENTORY_CONTENT+="$container|$path|$image_short
"
        done
        INVENTORY_CONTENT+="
"
    fi
done

# Add helpful comment at the end
INVENTORY_CONTENT+="# To add stopped containers, add them manually above
# Format examples:
#   container-name|/opt/stacks/mystack|Description
#   container-name|/opt/stacks/mystack|pull|Explicit type (optional)
#   container-name|/opt/stacks/mystack|Description|update-stopped
"

# === OUTPUT ===
if [[ "$DRY_RUN" == true ]]; then
    info "DRY RUN - Generated inventory (would be written to: $INVENTORY_FILE):"
    echo "========================================"
    echo "$INVENTORY_CONTENT"
    echo "========================================"
    exit 0
fi

# Check if file exists and handle accordingly
if [[ -f "$INVENTORY_FILE" ]]; then
    if [[ "$FORCE" == false ]]; then
        warn "Inventory file already exists: $INVENTORY_FILE"
        read -p "Overwrite? (y/N): " -r
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            info "Cancelled. No changes made."
            exit 0
        fi
    fi

    if [[ "$BACKUP" == true || "$FORCE" == false ]]; then
        backup_file="${INVENTORY_FILE}${BACKUP_SUFFIX}"
        cp "$INVENTORY_FILE" "$backup_file"
        success "Created backup: $backup_file"
    fi
fi

# Create directory if needed
mkdir -p "$(dirname "$INVENTORY_FILE")"

# Write inventory file
echo "$INVENTORY_CONTENT" > "$INVENTORY_FILE"

success "Inventory generated: $INVENTORY_FILE"
success "Found ${#STACKS[@]} unique stack(s) with $CONTAINER_COUNT container(s)"

if [[ ${#UNKNOWN_PATHS[@]} -gt 0 ]]; then
    echo ""
    warn "Action required: ${#UNKNOWN_PATHS[@]} container(s) need manual path configuration"
    info "Edit $INVENTORY_FILE and replace '/opt/stacks/FIXME' with actual paths"
fi

echo ""
info "Next steps:"
echo "  1. Review the generated inventory: cat $INVENTORY_FILE"
echo "  2. Fix any UNKNOWN paths if present"
echo "  3. Add any stopped containers you want to track"
echo "  4. Run update: $SCRIPT_DIR/podman-update.sh --validate-only"
