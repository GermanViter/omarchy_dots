#!/usr/bin/env bash

# install.sh - Unified installer for Omarchy dotfiles dependencies and GNU Stow symlinks
#
# Usage:
#   ./install.sh [options] [package ...]
#
# Examples:
#   ./install.sh                     Install core dependencies and stow all dotfiles
#   ./install.sh --dry-run           Simulate dependency installs and symlink actions
#   ./install.sh --deps-only         Only install dependencies (stow, fzf, eza, etc.)
#   ./install.sh --symlinks-only     Only create symlinks using GNU Stow
#   ./install.sh --all               Install extended packages (includes nvim, kitty, tmux)
#   ./install.sh --check             Display status of dependencies and packages
#   ./install.sh --unlink            Unstow (remove) dotfiles symlinks
#   ./install.sh --adopt             Adopt existing files into the dotfiles repo
#   ./install.sh zsh kitty           Install dependencies and stow only zsh and kitty

set -euo pipefail

# ── Path Resolution ────────────────────────────────────────────────────────────
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
    DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"

if [ "$(basename "$SCRIPT_DIR")" = "scripts" ]; then
    DOTFILES_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
else
    DOTFILES_DIR="$SCRIPT_DIR"
fi

# ── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

log_info()    { echo -e "${BLUE}  →${RESET} $*"; }
log_success() { echo -e "${GREEN}  ✓${RESET} $*"; }
log_warn()    { echo -e "${YELLOW}  !${RESET} $*"; }
log_error()   { echo -e "${RED}  ✗${RESET} $*" >&2; }
log_step()    { echo -e "\n${BOLD}${CYAN}=== $* ===${RESET}"; }

# ── State Variables ───────────────────────────────────────────────────────────
DRY_RUN=false
UNLINK=false
ADOPT=false
DEPS_ONLY=false
SYMLINKS_ONLY=false
INSTALL_ALL=false
CHECK_ONLY=false
FAILED=false
TARGET_PACKAGES=()

# ── Package Definitions ───────────────────────────────────────────────────────
CORE_TOOLS=("stow" "fzf" "eza" "bat" "zoxide" "starship" "fastfetch")
EXTENDED_TOOLS=("tmux" "neovim" "kitty" "git" "zsh")

EXCLUDE=("scripts" "assets" "gemini" "brain" "scratch")
is_excluded() {
    local item="$1"
    for ex in "${EXCLUDE[@]}"; do
        [[ "$item" == "$ex" ]] && return 0
    done
    return 1
}

# ── Help ──────────────────────────────────────────────────────────────────────
show_help() {
    echo -e "${BOLD}install.sh${RESET} - Unified installer for Omarchy dotfiles dependencies and GNU Stow symlinks"
    echo ""
    echo -e "${BOLD}Usage:${RESET}"
    echo "  $0 [options] [package ...]"
    echo ""
    echo -e "${BOLD}Options:${RESET}"
    echo "  -n, --dry-run          Simulate installation and symlinks without modifying files"
    echo "  -d, --deps-only        Only install dependencies (skip symlinks)"
    echo "  -s, --symlinks-only    Only create symlinks using GNU Stow (skip dependency install)"
    echo "  -u, --unlink           Remove symlinks (unstow packages)"
    echo "  -a, --adopt            Adopt existing files into the repository during stowing"
    echo "      --all              Include extended tools (neovim, kitty, tmux, git, zsh)"
    echo "  -c, --check            Check status of dependencies and packages"
    echo "  -h, --help             Show this help message"
    echo ""
    echo -e "${BOLD}Packages:${RESET}"
    echo "  Optional name(s) of specific packages to stow or unstow (e.g. zsh kitty fastfetch)."
    echo "  If omitted, all detected packages are processed."
    echo ""
    echo -e "${BOLD}Examples:${RESET}"
    echo "  $0                     Full install (core dependencies + symlinks)"
    echo "  $0 --dry-run           Preview what would happen"
    echo "  $0 --deps-only         Install stow, fzf, eza, bat, zoxide, starship, fastfetch"
    echo "  $0 --symlinks-only     Link dotfiles without installing packages"
    echo "  $0 --all               Install full suite of CLI tools and GUI terminal apps"
    echo "  $0 --check             Inspect installed tools and available stow packages"
    echo "  $0 zsh                 Only stow zsh configuration"
    echo "  $0 -u kitty            Unstow kitty configuration"
}

# ── Argument Parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
    -n|--dry-run)
        DRY_RUN=true
        shift
        ;;
    -d|--deps-only)
        DEPS_ONLY=true
        shift
        ;;
    -s|--symlinks-only|--links-only)
        SYMLINKS_ONLY=true
        shift
        ;;
    -u|--unlink)
        UNLINK=true
        shift
        ;;
    -a|--adopt)
        ADOPT=true
        shift
        ;;
    --all)
        INSTALL_ALL=true
        shift
        ;;
    -c|--check)
        CHECK_ONLY=true
        shift
        ;;
    -h|--help)
        show_help
        exit 0
        ;;
    -*)
        log_error "Unknown option: $1"
        echo "Run '$0 --help' for options."
        exit 1
        ;;
    *)
        TARGET_PACKAGES+=("$1")
        shift
        ;;
    esac
done

if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}[DRY RUN — no files or packages will be modified]${RESET}"
fi

# ── Omarchy Check ─────────────────────────────────────────────────────────────
if ! command -v omarchy &>/dev/null || [ ! -d "${OMARCHY_PATH:-/usr/share/omarchy}" ]; then
    log_error "This script is intended to run on an Omarchy installation."
    exit 1
fi

# ── Helper Functions ──────────────────────────────────────────────────────────
is_tool_installed() {
    local tool="$1"
    case "$tool" in
    bat)
        command -v bat &>/dev/null || command -v batcat &>/dev/null
        ;;
    neovim)
        command -v nvim &>/dev/null || command -v neovim &>/dev/null
        ;;
    *)
        command -v "$tool" &>/dev/null
        ;;
    esac
}

get_tool_path() {
    local tool="$1"
    case "$tool" in
    bat)
        command -v bat 2>/dev/null || command -v batcat 2>/dev/null || echo "not installed"
        ;;
    neovim)
        command -v nvim 2>/dev/null || command -v neovim 2>/dev/null || echo "not installed"
        ;;
    *)
        command -v "$tool" 2>/dev/null || echo "not installed"
        ;;
    esac
}

run_status_check() {
    log_step "Dependency Status Check (Omarchy)"
    echo -e "${BOLD}Core Dependencies:${RESET}"
    for tool in "${CORE_TOOLS[@]}"; do
        if is_tool_installed "$tool"; then
            echo -e "  ${GREEN}✓${RESET} $(printf '%-12s' "$tool") [$(get_tool_path "$tool")]"
        else
            echo -e "  ${RED}✗${RESET} $(printf '%-12s' "$tool") [not installed]"
        fi
    done

    echo -e "\n${BOLD}Extended Tools:${RESET}"
    for tool in "${EXTENDED_TOOLS[@]}"; do
        if is_tool_installed "$tool"; then
            echo -e "  ${GREEN}✓${RESET} $(printf '%-12s' "$tool") [$(get_tool_path "$tool")]"
        else
            echo -e "  ${YELLOW}-${RESET} $(printf '%-12s' "$tool") [not installed]"
        fi
    done

    log_step "Dotfiles Stow Packages"
    echo -e "${BOLD}Omarchy Packages ($DOTFILES_DIR):${RESET}"
    for dir in "$DOTFILES_DIR"/*/; do
        [ -d "$dir" ] || continue
        local name
        name=$(basename "$dir")
        [[ "$name" == .* ]] && continue
        is_excluded "$name" && continue
        echo -e "  ${BLUE}•${RESET} $name"
    done
    echo ""
}

if [ "$CHECK_ONLY" = true ]; then
    run_status_check
    exit 0
fi

# ── Dependency Installation ───────────────────────────────────────────────────
install_dependencies() {
    log_step "Step 1: Checking & Installing Dependencies"

    local tools_to_check=("${CORE_TOOLS[@]}")
    if [ "$INSTALL_ALL" = true ]; then
        tools_to_check+=("${EXTENDED_TOOLS[@]}")
    fi

    local missing_tools=()
    for tool in "${tools_to_check[@]}"; do
        if is_tool_installed "$tool"; then
            log_success "$tool is already installed ($(get_tool_path "$tool"))"
        else
            missing_tools+=("$tool")
        fi
    done

    if [ ${#missing_tools[@]} -eq 0 ]; then
        log_success "All dependencies are satisfied!"
        return 0
    fi

    log_warn "Missing dependencies: ${missing_tools[*]}"

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would install via omarchy pkg add: ${missing_tools[*]}"
    else
        log_info "Installing missing packages with omarchy..."
        if ! omarchy pkg add "${missing_tools[@]}"; then
            log_warn "Standard package install had errors. Attempting omarchy pkg aur add..."
            omarchy pkg aur add "${missing_tools[@]}"
        fi
        log_success "Dependency installation completed!"
    fi
}

# ── Symlinking with GNU Stow ──────────────────────────────────────────────────
setup_symlinks() {
    log_step "Step 2: Symlinking Dotfiles with GNU Stow"

    if ! command -v stow &>/dev/null; then
        log_error "GNU Stow is not installed. Please install it with: omarchy pkg add stow"
        exit 1
    fi

    local packages=()
    if [ ${#TARGET_PACKAGES[@]} -gt 0 ]; then
        for pkg in "${TARGET_PACKAGES[@]}"; do
            pkg="${pkg%/}"
            if [ -d "$DOTFILES_DIR/$pkg" ]; then
                packages+=("$pkg")
            else
                log_error "Package '$pkg' does not exist in $DOTFILES_DIR"
                FAILED=true
            fi
        done
        if [ "$FAILED" = true ] && [ ${#packages[@]} -eq 0 ]; then
            log_error "No valid target packages found to process."
            exit 1
        fi
    else
        for dir in "$DOTFILES_DIR"/*/; do
            [ -d "$dir" ] || continue
            local name
            name=$(basename "$dir")
            [[ "$name" == .* ]] && continue
            is_excluded "$name" && continue
            packages+=("$name")
        done
    fi

    if [ ${#packages[@]} -eq 0 ]; then
        log_warn "No packages found to stow."
        return 0
    fi

    local stow_flags=("-v" "-t" "$HOME")
    if [ "$DRY_RUN" = true ]; then
        stow_flags+=("-n")
    fi

    local action_desc
    if [ "$UNLINK" = true ]; then
        stow_flags+=("-D")
        action_desc="unstow"
    else
        stow_flags+=("-S")
        if [ "$ADOPT" = true ]; then
            stow_flags+=("--adopt")
        fi
        action_desc="stow"
    fi

    echo -e "${BLUE}Packages to ${action_desc}:${RESET} ${packages[*]}\n"

    for pkg in "${packages[@]}"; do
        if [ "$UNLINK" = true ]; then
            if stow -d "$DOTFILES_DIR" "${stow_flags[@]}" "$pkg"; then
                log_success "Unstowed $pkg"
            else
                log_error "Failed to unstow $pkg"
                FAILED=true
            fi
        else
            if stow -d "$DOTFILES_DIR" "${stow_flags[@]}" "$pkg"; then
                log_success "Stowed $pkg"
            else
                log_error "Failed to stow $pkg. Check for existing conflicting files (use --adopt to adopt existing files)."
                FAILED=true
            fi
        fi
    done

    if [ "$FAILED" = true ]; then
        log_error "Symlink setup finished with errors."
        exit 1
    fi
}

# ── Main Execution ─────────────────────────────────────────────────────────────
if [ "$SYMLINKS_ONLY" = false ] && [ "$UNLINK" = false ]; then
    install_dependencies
fi

if [ "$DEPS_ONLY" = false ]; then
    setup_symlinks
fi

echo ""
if [ "$UNLINK" = true ]; then
    log_success "Dotfiles unlinked successfully!"
elif [ "$DEPS_ONLY" = true ]; then
    log_success "All dependencies installed successfully!"
else
    log_success "Installation & dotfiles setup completed successfully!"
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}(Dry-run mode — run without --dry-run to apply changes)${RESET}"
    fi
fi

exit 0
