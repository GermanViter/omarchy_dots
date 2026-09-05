#!/usr/bin/env bash

# setup_symlinks.sh - Set up dotfiles on Omarchy using GNU Stow
# Usage:
#   ./setup_symlinks.sh              → stows packages
#   ./setup_symlinks.sh --dry-run    → simulates without modifying
#   ./setup_symlinks.sh --unlink     → unstows packages
#   ./setup_symlinks.sh --help       → shows help

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DOTFILES_DIR=$(cd "$SCRIPT_DIR/.." && pwd)

DRY_RUN=false
UNLINK=false
FAILED=false

# ── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
RESET='\033[0m'

log_info() { echo -e "${BLUE}  →${RESET} $*"; }
log_success() { echo -e "${GREEN}  ✓${RESET} $*"; }
log_error() { echo -e "${RED}  ✗${RESET} $*" >&2; }

# ── Arguments ──────────────────────────────────────────────────────────────────
for arg in "$@"; do
    case $arg in
    --dry-run)
        DRY_RUN=true
        echo -e "${YELLOW}[DRY RUN — no files will be modified]${RESET}\n"
        ;;
    --unlink)
        UNLINK=true
        echo -e "${CYAN}[UNLINK MODE — removing symlinks]${RESET}\n"
        ;;
    --help)
        echo "Usage: $0 [--dry-run | --unlink]"
        echo ""
        echo "  (no arguments)    Create symlinks using GNU Stow"
        echo "  --dry-run         Simulate the process"
        echo "  --unlink          Remove symlinks (unstow)"
        echo "  --help            Show this help"
        exit 0
        ;;
    *)
        log_error "Unknown argument: $arg"
        echo "Run '$0 --help' for options."
        exit 1
        ;;
    esac
done

# ── Omarchy Check ─────────────────────────────────────────────────────────────
if ! command -v omarchy &>/dev/null || [ ! -d "${OMARCHY_PATH:-/usr/share/omarchy}" ]; then
    log_error "This script is intended to run on an Omarchy installation."
    exit 1
fi

# ── Dependency Check ──────────────────────────────────────────────────────────
# These are the packages used by the configurations in this repository.
DEPENDENCIES=(git stow zsh kitty fastfetch starship)
if omarchy pkg missing "${DEPENDENCIES[@]}"; then
    if [ "$DRY_RUN" = true ]; then
        log_info "Missing packages (not installed in dry-run): ${DEPENDENCIES[*]}"
    else
        log_info "Installing missing Omarchy packages: ${DEPENDENCIES[*]}"
        omarchy pkg add "${DEPENDENCIES[@]}"
        log_success "Dependencies are ready."
    fi
fi

# ── Stow Packages ─────────────────────────────────────────────────────────────
# Packages to exclude (not meant for stowing).
EXCLUDE=("scripts" "assets" "gemini")
packages=()
for dir in "$DOTFILES_DIR"/*/; do
    [ -d "$dir" ] || continue
    name=$(basename "$dir")
    [[ " ${EXCLUDE[@]} " =~ " ${name} " ]] && continue
    [[ "$name" == .* ]] && continue
    packages+=("$name")
done

STOW_FLAGS="-v -t $HOME"
if [ "$DRY_RUN" = true ]; then
    STOW_FLAGS+=" -n"
fi

if [ "$UNLINK" = true ]; then
    STOW_FLAGS+=" -D"
    ACTION_DESC="unstow"
else
    STOW_FLAGS+=" -S"
    ACTION_DESC="stow"
fi

if [ ${#packages[@]} -gt 0 ]; then
    echo -e "${BLUE}Omarchy packages to ${ACTION_DESC}:${RESET} ${packages[*]}"
fi
echo ""
for pkg in "${packages[@]}"; do
    if [ "$UNLINK" = true ]; then
        stow -d "$DOTFILES_DIR" $STOW_FLAGS "$pkg" || {
            log_error "Failed to unstow $pkg"
            FAILED=true
        }
    else
        stow -d "$DOTFILES_DIR" $STOW_FLAGS "$pkg" || {
            log_error "Failed to stow $pkg. Check for existing files."
            FAILED=true
        }
    fi
done

echo ""
if [ "$FAILED" = true ]; then
    log_error "Setup finished with errors."
    exit 1
fi
if [ "$UNLINK" = true ]; then
    log_success "Unlink complete!"
else
    log_success "Stow complete!"
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}(Dry-run mode — run without --dry-run to apply)${RESET}"
    fi
fi

exit 0
