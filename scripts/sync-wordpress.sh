#!/usr/bin/env bash
#
# WordPress Single Version Sync Script
# Downloads a specific WordPress version and prepares it for release.
#
# Usage:
#   ./scripts/sync-wordpress.sh <version> [--commit] [--tag] [--push]
#
# Examples:
#   ./scripts/sync-wordpress.sh 6.4.3              # Download and prepare
#   ./scripts/sync-wordpress.sh 6.4.3 --commit     # Download, prepare, commit
#   ./scripts/sync-wordpress.sh 6.4.3 --tag        # Download, prepare, commit, tag
#   ./scripts/sync-wordpress.sh 6.4.3 --push       # Download, prepare, commit, tag, push
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(dirname "$SCRIPT_DIR")"
TEMPLATES_DIR="$PACKAGE_DIR/templates"
TEMP_DIR=$(mktemp -d)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

usage() {
    echo "Usage: $0 <version> [--commit] [--tag] [--push]"
    echo ""
    echo "Arguments:"
    echo "  version     WordPress version to sync (e.g., 6.4.3)"
    echo ""
    echo "Options:"
    echo "  --commit    Create a git commit"
    echo "  --tag       Create a git tag (implies --commit)"
    echo "  --push      Push to remote (implies --tag)"
    echo ""
    echo "Examples:"
    echo "  $0 6.4.3"
    echo "  $0 6.4.3 --tag"
    echo "  $0 6.4.3 --push"
    exit 1
}

# Parse arguments
if [[ $# -lt 1 ]]; then
    usage
fi

VERSION="$1"
shift

DO_COMMIT=false
DO_TAG=false
DO_PUSH=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --commit)
            DO_COMMIT=true
            shift
            ;;
        --tag)
            DO_TAG=true
            DO_COMMIT=true
            shift
            ;;
        --push)
            DO_PUSH=true
            DO_TAG=true
            DO_COMMIT=true
            shift
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            ;;
    esac
done

# Validate version format
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    log_error "Invalid version format: $VERSION"
    log_error "Expected format: X.Y or X.Y.Z (e.g., 6.4 or 6.4.3)"
    exit 1
fi

# Extract major version
MAJOR_VERSION=$(echo "$VERSION" | cut -d. -f1)

log_info "Syncing WordPress version: $VERSION"
log_info "Major version: $MAJOR_VERSION"

# Step 1: Download WordPress
log_step "Downloading WordPress $VERSION..."
DOWNLOAD_URL="https://wordpress.org/wordpress-${VERSION}.tar.gz"

if ! curl -sL "$DOWNLOAD_URL" -o "$TEMP_DIR/wordpress.tar.gz"; then
    log_error "Failed to download WordPress $VERSION from $DOWNLOAD_URL"
    exit 1
fi

# Step 2: Extract WordPress
log_step "Extracting WordPress..."
tar -xzf "$TEMP_DIR/wordpress.tar.gz" -C "$TEMP_DIR"

if [[ ! -d "$TEMP_DIR/wordpress" ]]; then
    log_error "Extraction failed - wordpress directory not found"
    exit 1
fi

# Step 3: Clean package directory (remove old WordPress files, keep scripts/templates)
log_step "Cleaning package directory..."
cd "$PACKAGE_DIR"

# Remove WordPress directories and files from root (but keep scripts, templates, README, .git)
rm -rf wp-admin wp-includes wp-content 2>/dev/null || true
rm -f wp-*.php index.php xmlrpc.php license.txt readme.html htaccess robots.txt 2>/dev/null || true
rm -f composer.json 2>/dev/null || true

# Step 4: Copy WordPress core files to package root
log_step "Copying WordPress core files to root..."

# Copy directories
cp -r "$TEMP_DIR/wordpress/wp-admin" "$PACKAGE_DIR/"
cp -r "$TEMP_DIR/wordpress/wp-includes" "$PACKAGE_DIR/"

# Create wp-content directory
mkdir -p "$PACKAGE_DIR/wp-content"

# Copy PHP files from root (except index.php and wp-config-sample.php - we use our own)
for file in "$TEMP_DIR/wordpress/"*.php; do
    if [[ -f "$file" ]]; then
        filename=$(basename "$file")
        if [[ "$filename" != "index.php" && "$filename" != "wp-config-sample.php" ]]; then
            cp "$file" "$PACKAGE_DIR/"
        fi
    fi
done

# Copy other files
cp "$TEMP_DIR/wordpress/license.txt" "$PACKAGE_DIR/"
cp "$TEMP_DIR/wordpress/readme.html" "$PACKAGE_DIR/"

# Step 5: Copy scaffold override files (our customized versions)
log_step "Copying scaffold override files..."
cp "$TEMPLATES_DIR/scaffold-overrides/index.php" "$PACKAGE_DIR/"
cp "$TEMPLATES_DIR/scaffold-overrides/wp-config-sample.php" "$PACKAGE_DIR/"
cp "$TEMPLATES_DIR/scaffold-overrides/htaccess" "$PACKAGE_DIR/"
cp "$TEMPLATES_DIR/scaffold-overrides/robots.txt" "$PACKAGE_DIR/"
cp "$TEMPLATES_DIR/scaffold-overrides/wp-content/index.php" "$PACKAGE_DIR/wp-content/"

# Step 6: Generate composer.json from template
log_step "Generating composer.json..."
sed -e "s/{{VERSION}}/$VERSION/g" \
    -e "s/{{MAJOR_VERSION}}/$MAJOR_VERSION/g" \
    "$TEMPLATES_DIR/composer.json.template" > "$PACKAGE_DIR/composer.json"

# Verify version.php exists
if [[ ! -f "$PACKAGE_DIR/wp-includes/version.php" ]]; then
    log_error "version.php not found - sync may have failed"
    exit 1
fi

# Extract and verify the synced version
SYNCED_VERSION=$(grep -o "\\\$wp_version = '[^']*'" "$PACKAGE_DIR/wp-includes/version.php" | cut -d"'" -f2)
log_info "Successfully synced WordPress $SYNCED_VERSION"

# Step 7: Git operations
if [[ "$DO_COMMIT" == true ]]; then
    log_step "Creating git commit..."
    cd "$PACKAGE_DIR"
    git add -A
    git commit -m "WordPress $VERSION" || log_warn "Nothing to commit"
fi

if [[ "$DO_TAG" == true ]]; then
    log_step "Creating git tag..."
    TAG_NAME="$VERSION"
    git tag -a "$TAG_NAME" -m "WordPress $VERSION" 2>/dev/null || {
        log_warn "Tag $TAG_NAME already exists, skipping"
    }
fi

if [[ "$DO_PUSH" == true ]]; then
    log_step "Pushing to remote..."
    CURRENT_BRANCH=$(git branch --show-current)
    git push origin "$CURRENT_BRANCH" --tags
fi

# Count files
FILE_COUNT=$(find "$PACKAGE_DIR" -type f \( -name "*.php" -o -name "*.txt" -o -name "*.html" -o -name "*.css" -o -name "*.js" \) | wc -l | tr -d ' ')

# Summary
echo ""
echo "========================================"
echo "  Sync Complete"
echo "========================================"
echo "  WordPress Version: $SYNCED_VERSION"
echo "  Package Directory: $PACKAGE_DIR"
echo "  Files synced: $FILE_COUNT"
echo ""
if [[ "$DO_TAG" == true ]]; then
    echo "  Git tag created: $VERSION"
fi
if [[ "$DO_PUSH" == true ]]; then
    echo "  Changes pushed to remote"
else
    echo "  Run 'git push origin <branch> --tags' to publish"
fi
echo "========================================"
