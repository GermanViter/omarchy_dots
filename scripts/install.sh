#!/usr/bin/env bash

# install.sh - Unified installer for Omarchy dotfiles dependencies and GNU Stow symlinks
#
# Usage:
#   ./install.sh [options] [package ...]
#
# Examples:
#   ./install.sh                     Install core dependencies, stow dotfiles, migrate to zsh
#   ./install.sh --dry-run           Simulate installation and symlink actions
#   ./install.sh --no-change-shell   Setup dotfiles and zsh without altering default login shell
#   ./install.sh --deps-only         Only install dependencies and zsh tools (skip symlinks)
#   ./install.sh --symlinks-only     Only create symlinks using GNU Stow
#   ./install.sh --all               Install extended packages (includes nvim, kitty, tmux)
#   ./install.sh --check             Display status of dependencies, shell, and packages
#   ./install.sh --plugins-only      Only offer the Omarchy plugins listed in omarchy-plugins.txt
#   ./install.sh --no-plugins        Skip the Omarchy plugin prompts
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
NO_CHANGE_SHELL=false
PLUGINS_ONLY=false
NO_PLUGINS=false
FAILED=false
TARGET_PACKAGES=()

# ── Package & Plugin Definitions ──────────────────────────────────────────────
CORE_TOOLS=("stow" "git" "zsh" "fzf" "eza" "bat" "zoxide" "starship" "fastfetch")
EXTENDED_TOOLS=("tmux" "neovim" "kitty")

CUSTOM_PLUGINS=(
    "zsh-autosuggestions:https://github.com/zsh-users/zsh-autosuggestions.git"
    "zsh-syntax-highlighting:https://github.com/zsh-users/zsh-syntax-highlighting.git"
)

# External Omarchy plugins, one "<plugin-id> <git-url>" per line.
# Maintained by scripts/sync-omarchy-plugins.sh, which runs after `omarchy plugin add`.
OMARCHY_PLUGINS_FILE="$DOTFILES_DIR/scripts/omarchy-plugins.txt"
OMARCHY_PLUGINS_DIR="$HOME/.config/omarchy/plugins"

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
    echo "  -d, --deps-only        Only install dependencies and zsh tools (skip symlinks)"
    echo "  -s, --symlinks-only    Only create symlinks using GNU Stow (skip dependencies and zsh setup)"
    echo "  -u, --unlink           Remove symlinks (unstow packages)"
    echo "  -a, --adopt            Adopt existing files into the repository during stowing"
    echo "                         (without it, conflicting files move to ~/.dotfiles-backup/<timestamp>/)"
    echo "      --all              Include extended tools (neovim, kitty, tmux)"
    echo "      --no-change-shell  Do not change default login shell to zsh"
    echo "  -p, --plugins-only     Only offer the Omarchy plugins listed in scripts/omarchy-plugins.txt"
    echo "      --no-plugins       Skip the Omarchy plugin prompts"
    echo "  -c, --check            Check status of dependencies, shell, and packages"
    echo "  -h, --help             Show this help message"
    echo ""
    echo -e "${BOLD}Packages:${RESET}"
    echo "  Optional name(s) of specific packages to stow or unstow (e.g. zsh kitty fastfetch)."
    echo "  If omitted, all detected packages are processed."
    echo ""
    echo -e "${BOLD}Examples:${RESET}"
    echo "  $0                     Full install (dependencies + symlinks + oh-my-zsh + shell change)"
    echo "  $0 --dry-run           Preview what would happen"
    echo "  $0 --no-change-shell   Setup dotfiles and oh-my-zsh without altering login shell"
    echo "  $0 --deps-only         Install dependencies and setup oh-my-zsh without stowing"
    echo "  $0 --symlinks-only     Link dotfiles without installing packages"
    echo "  $0 --all               Install full suite including extended tools (nvim, kitty, tmux)"
    echo "  $0 --check             Inspect installed tools, shell status, and stow packages"
    echo "  $0 --plugins-only      Choose which external Omarchy plugins to install"
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
    --no-change-shell)
        NO_CHANGE_SHELL=true
        shift
        ;;
    -p|--plugins-only)
        PLUGINS_ONLY=true
        shift
        ;;
    --no-plugins)
        NO_PLUGINS=true
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

# Prints "<plugin-id> <git-url>" for every entry in the plugin list.
read_omarchy_plugins() {
    [ -f "$OMARCHY_PLUGINS_FILE" ] || return 0
    local id url _rest
    while read -r id url _rest || [ -n "$id" ]; do
        [[ -z "$id" || "$id" == \#* ]] && continue
        if [ -z "$url" ]; then
            log_warn "Ignoring plugin '$id' in $OMARCHY_PLUGINS_FILE: no git URL"
            continue
        fi
        echo "$id $url"
    done <"$OMARCHY_PLUGINS_FILE"
}

# Asks a yes/no question that defaults to no. Returns 0 only on an explicit yes.
ask_yes_no() {
    local prompt="$1" reply rc=0
    if command -v gum &>/dev/null; then
        gum confirm --default=false "$prompt" || rc=$?
        # 130 is Ctrl-C: stop the whole script instead of treating it as "no".
        [ "$rc" -eq 130 ] && exit 130
        return "$rc"
    fi
    read -r -p "$prompt [y/N] " reply
    [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# ── Status Check ──────────────────────────────────────────────────────────────
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

    log_step "Shell & Oh My Zsh Status"
    local user_shell
    user_shell=$(getent passwd "$USER" 2>/dev/null | cut -d: -f7 || echo "$SHELL")
    echo -e "  Default Shell: ${BOLD}$user_shell${RESET}"

    local zsh_dir="${ZSH:-$HOME/.oh-my-zsh}"
    local custom_dir="${ZSH_CUSTOM:-$zsh_dir/custom}"
    if [ -d "$zsh_dir" ]; then
        echo -e "  ${GREEN}✓${RESET} $(printf '%-24s' "oh-my-zsh") [$zsh_dir]"
    else
        echo -e "  ${RED}✗${RESET} $(printf '%-24s' "oh-my-zsh") [not installed]"
    fi

    for item in "${CUSTOM_PLUGINS[@]}"; do
        local name="${item%%:*}"
        local target_path="$custom_dir/plugins/$name"
        if [ -d "$target_path" ]; then
            echo -e "  ${GREEN}✓${RESET} $(printf '%-24s' "$name") [$target_path]"
        else
            echo -e "  ${RED}✗${RESET} $(printf '%-24s' "$name") [not installed]"
        fi
    done

    log_step "External Omarchy Plugins"
    local plugin_id plugin_url plugin_count=0
    while read -r plugin_id plugin_url; do
        plugin_count=$((plugin_count + 1))
        if [ -e "$OMARCHY_PLUGINS_DIR/$plugin_id" ]; then
            echo -e "  ${GREEN}✓${RESET} $(printf '%-36s' "$plugin_id") [$plugin_url]"
        else
            echo -e "  ${YELLOW}-${RESET} $(printf '%-36s' "$plugin_id") [not installed]"
        fi
    done < <(read_omarchy_plugins)
    if [ "$plugin_count" -eq 0 ]; then
        echo -e "  ${YELLOW}-${RESET} no plugins listed in $OMARCHY_PLUGINS_FILE"
    fi

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

# ── Step 1: Dependency Installation ───────────────────────────────────────────
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

# ── Step 2: Symlinking with GNU Stow ──────────────────────────────────────────
# Existing files that would block stow are moved here rather than deleted.
BACKUP_DIR="$HOME/.dotfiles-backup/$(date +%Y%m%d-%H%M%S)"
BACKED_UP=0
CONFLICTS=0

# Moves one conflicting path from $HOME into $BACKUP_DIR, keeping its layout.
backup_conflict() {
    local rel="$1"
    local target="$HOME/$rel"
    local dest="$BACKUP_DIR/$rel"
    CONFLICTS=$((CONFLICTS + 1))

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would move ~/$rel to $dest"
        return 0
    fi

    mkdir -p "$(dirname "$dest")"
    if mv "$target" "$dest"; then
        log_warn "Moved existing ~/$rel to $dest"
        BACKED_UP=$((BACKED_UP + 1))
    else
        log_error "Could not move ~/$rel out of the way"
        FAILED=true
    fi
}

# Walks a stow package and clears every path in $HOME that stow would refuse
# to replace. Real directories present on both sides are walked into rather
# than moved, so files the repo does not track (e.g. Omarchy's own
# ~/.config/hypr/hyprland.lua) stay where they are.
clear_conflicts() {
    local src_dir="$1" rel_dir="$2"
    local src name rel target resolved

    while IFS= read -r -d '' src; do
        name="$(basename "$src")"
        # Names stow ignores by default; they are never linked, so never conflict.
        case "$name" in
        .git | .gitignore | .gitmodules | *~) continue ;;
        esac

        rel="${rel_dir:+$rel_dir/}$name"
        target="$HOME/$rel"

        # Nothing there: stow can link it.
        [ -e "$target" ] || [ -L "$target" ] || continue

        if [ -L "$target" ]; then
            # Already points into this repo (stowed earlier): leave it.
            resolved="$(readlink -f "$target" || true)"
            [[ "$resolved" == "$DOTFILES_DIR" || "$resolved" == "$DOTFILES_DIR"/* ]] && continue
            backup_conflict "$rel"
        elif [ -d "$src" ] && [ ! -L "$src" ] && [ -d "$target" ]; then
            clear_conflicts "$src" "$rel"
        else
            backup_conflict "$rel"
        fi
    done < <(find "$src_dir" -mindepth 1 -maxdepth 1 -print0)
}

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
            # --adopt pulls existing files into the repo instead, so keep them.
            CONFLICTS=0
            if [ "$ADOPT" = false ]; then
                clear_conflicts "$DOTFILES_DIR/$pkg" ""
            fi
            if stow -d "$DOTFILES_DIR" "${stow_flags[@]}" "$pkg"; then
                log_success "Stowed $pkg"
            elif [ "$DRY_RUN" = true ] && [ "$CONFLICTS" -gt 0 ]; then
                # The simulated stow still sees the files a real run would move first.
                log_info "[DRY RUN] $pkg would stow once the $CONFLICTS path(s) above are moved"
            else
                log_error "Failed to stow $pkg. Check for existing conflicting files (use --adopt to adopt existing files)."
                FAILED=true
            fi
        fi
    done

    if [ "$BACKED_UP" -gt 0 ]; then
        log_info "Backed up $BACKED_UP existing path(s) to $BACKUP_DIR"
    fi

    if [ "$FAILED" = true ]; then
        log_error "Symlink setup finished with errors."
        exit 1
    fi
}

# ── Step 3: Migrate to Zsh (Oh My Zsh, Plugins & Default Shell) ────────────────
migrate_to_zsh() {
    log_step "Step 3: Migrating to Zsh & Oh My Zsh Setup"

    # 1. Ensure Zsh is installed
    if ! command -v zsh &>/dev/null; then
        if [ "$DRY_RUN" = true ]; then
            log_info "[DRY RUN] Would install zsh package"
        else
            log_info "Installing zsh package..."
            if ! omarchy pkg add zsh; then
                sudo pacman -S --needed --noconfirm zsh
            fi
            log_success "Installed zsh"
        fi
    fi

    # 2. Install Oh My Zsh if not already present
    local zsh_dir="${ZSH:-$HOME/.oh-my-zsh}"
    local custom_dir="${ZSH_CUSTOM:-$zsh_dir/custom}"

    if [ -d "$zsh_dir" ]; then
        log_success "Oh My Zsh is already installed ($zsh_dir)"
    else
        if [ "$DRY_RUN" = true ]; then
            log_info "[DRY RUN] Would clone Oh My Zsh to $zsh_dir"
        else
            log_info "Installing Oh My Zsh..."
            if git clone --depth=1 https://github.com/ohmyzsh/ohmyzsh.git "$zsh_dir"; then
                log_success "Oh My Zsh installed successfully!"
            else
                log_error "Failed to clone Oh My Zsh from GitHub"
                FAILED=true
            fi
        fi
    fi

    # 3. Install Oh My Zsh Custom Plugins
    local plugins_dir="$custom_dir/plugins"
    for item in "${CUSTOM_PLUGINS[@]}"; do
        local name="${item%%:*}"
        local url="${item#*:}"
        local target_path="$plugins_dir/$name"

        if [ -d "$target_path" ]; then
            log_success "Plugin $name is already installed ($target_path)"
        else
            if [ "$DRY_RUN" = true ]; then
                log_info "[DRY RUN] Would clone $name from $url to $target_path"
            else
                log_info "Installing plugin $name..."
                mkdir -p "$plugins_dir"
                if git clone --depth=1 "$url" "$target_path"; then
                    log_success "Plugin $name installed successfully!"
                else
                    log_error "Failed to clone plugin $name from $url"
                    FAILED=true
                fi
            fi
        fi
    done

    # 4. Auto Change Default Login Shell
    if [ "$NO_CHANGE_SHELL" = true ]; then
        log_info "Skipping shell change (--no-change-shell flag specified)"
    else
        local zsh_path
        zsh_path=$(command -v zsh 2>/dev/null || which zsh 2>/dev/null || echo "/usr/bin/zsh")
        local current_shell
        current_shell=$(getent passwd "$USER" 2>/dev/null | cut -d: -f7 || echo "$SHELL")

        if [[ "$current_shell" == "$zsh_path" || "$current_shell" == *"/zsh" ]]; then
            log_success "Zsh is already the default shell ($current_shell)"
        else
            if [ "$DRY_RUN" = true ]; then
                log_info "[DRY RUN] Would change default shell to $zsh_path"
            else
                log_info "Changing default login shell to $zsh_path..."
                if command -v sudo &>/dev/null && [ "$EUID" -ne 0 ]; then
                    sudo chsh -s "$zsh_path" "$USER" || chsh -s "$zsh_path" || {
                        log_warn "Could not change shell automatically. Run: chsh -s $zsh_path"
                    }
                else
                    chsh -s "$zsh_path" || {
                        log_warn "Could not change shell automatically. Run: chsh -s $zsh_path"
                    }
                fi

                local new_shell
                new_shell=$(getent passwd "$USER" 2>/dev/null | cut -d: -f7 || echo "$SHELL")
                if [[ "$new_shell" == "$zsh_path" || "$new_shell" == *"/zsh" ]]; then
                    log_success "Default shell changed to zsh ($zsh_path)"
                fi
            fi
        fi
    fi
}

# ── Step 4: External Omarchy Plugins ──────────────────────────────────────────
# Offers each plugin from scripts/omarchy-plugins.txt in turn. Declining one, or
# one failing to install, never stops the rest of the script.
install_omarchy_plugins() {
    log_step "Step 4: External Omarchy Plugins"

    local plugins=()
    mapfile -t plugins < <(read_omarchy_plugins)

    if [ ${#plugins[@]} -eq 0 ]; then
        log_info "No plugins listed in $OMARCHY_PLUGINS_FILE"
        return 0
    fi

    local entry id url installed=0 skipped=0
    for entry in "${plugins[@]}"; do
        id="${entry%% *}"
        url="${entry#* }"

        if [ -e "$OMARCHY_PLUGINS_DIR/$id" ]; then
            log_success "Plugin $id is already installed"
            continue
        fi

        if [ "$DRY_RUN" = true ]; then
            log_info "[DRY RUN] Would ask to install plugin $id from $url"
            continue
        fi

        # Without a terminal there is nobody to ask, so nothing is installed.
        if [ ! -t 0 ] || [ ! -t 1 ]; then
            log_warn "Skipping plugin $id (no terminal to ask on). Install with: omarchy plugin add $url"
            skipped=$((skipped + 1))
            continue
        fi

        echo -e "\n  ${BOLD}$id${RESET}\n  $url"
        if ! ask_yes_no "Install Omarchy plugin $id?"; then
            log_info "Skipped $id"
            skipped=$((skipped + 1))
            continue
        fi

        # The question above is the consent, so --yes skips omarchy's own prompts.
        if ! omarchy plugin add "$url" --yes; then
            if [ -f "$OMARCHY_PLUGINS_DIR/$id/manifest.json" ]; then
                log_warn "Plugin $id was downloaded but the Omarchy shell did not pick it up. Run: omarchy restart shell"
            else
                log_error "Failed to install plugin $id from $url"
                FAILED=true
            fi
            continue
        fi
        installed=$((installed + 1))
        log_success "Installed plugin $id"

        if ask_yes_no "Enable $id now?"; then
            if omarchy plugin enable "$id"; then
                log_success "Enabled plugin $id"
            else
                log_warn "Could not enable $id. Enable it later with: omarchy plugin enable $id"
            fi
        else
            log_info "Left $id disabled. Enable it later with: omarchy plugin enable $id"
        fi
    done

    if [ "$DRY_RUN" = false ]; then
        log_info "Plugins installed: $installed, skipped: $skipped"
    fi
}

# ── Step 5: Reload Hyprland ───────────────────────────────────────────────────
# Applies the freshly linked configs to the running session. A failed reload
# only warns, since the configs are still applied on the next login.
reload_hyprland() {
    log_step "Step 5: Reloading Hyprland"

    if ! command -v hyprctl &>/dev/null; then
        log_warn "hyprctl not found, skipping Hyprland reload"
        return 0
    fi

    if [ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
        log_warn "Hyprland is not running in this session, skipping reload"
        return 0
    fi

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would run: hyprctl reload"
        return 0
    fi

    if hyprctl reload >/dev/null; then
        log_success "Hyprland reloaded"
    else
        log_warn "hyprctl reload failed. Run it manually: hyprctl reload"
    fi
}

# ── Main Execution ─────────────────────────────────────────────────────────────
if [ "$PLUGINS_ONLY" = true ]; then
    install_omarchy_plugins
    echo ""
    if [ "$FAILED" = true ]; then
        log_error "Plugin setup finished with errors."
        exit 1
    fi
    log_success "Omarchy plugin setup completed!"
    exit 0
fi

if [ "$SYMLINKS_ONLY" = false ] && [ "$UNLINK" = false ]; then
    install_dependencies
fi

if [ "$DEPS_ONLY" = false ]; then
    setup_symlinks
fi

if [ "$SYMLINKS_ONLY" = false ] && [ "$UNLINK" = false ]; then
    migrate_to_zsh
fi

if [ "$SYMLINKS_ONLY" = false ] && [ "$UNLINK" = false ] && [ "$NO_PLUGINS" = false ]; then
    install_omarchy_plugins
fi

if [ "$DEPS_ONLY" = false ]; then
    reload_hyprland
fi

echo ""
if [ "$FAILED" = true ]; then
    log_error "Setup finished with errors."
    exit 1
fi

if [ "$UNLINK" = true ]; then
    log_success "Dotfiles unlinked successfully!"
elif [ "$DEPS_ONLY" = true ]; then
    log_success "Dependencies and Zsh setup completed successfully!"
else
    log_success "Installation & dotfiles setup completed successfully!"
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}(Dry-run mode — run without --dry-run to apply changes)${RESET}"
    fi
fi

exit 0
