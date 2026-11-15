#!/usr/bin/env bash

# sync-omarchy-plugins.sh - Record externally installed Omarchy plugins in the dotfiles repo
#
# Scans ~/.config/omarchy/plugins for plugins that were added from git
# (`omarchy plugin add <url>`), appends any that are missing to
# scripts/omarchy-plugins.txt, then commits and pushes that file.
#
# It only ever adds entries: a plugin that is listed but not installed on this
# machine stays listed, so declining a plugin during install.sh does not drop it.
# Built-in plugins, clones of built-ins and plugins shipped by a package have no
# git origin and are ignored.
#
# Usage:
#   ./sync-omarchy-plugins.sh [--no-commit] [--no-push]
#
# Runs automatically after `omarchy plugin add` through the wrapper in
# zsh/.zshrc.d/96-omarchy-plugins.zsh.

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
DOTFILES_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGINS_FILE="$SCRIPT_DIR/omarchy-plugins.txt"
PLUGINS_DIR="$HOME/.config/omarchy/plugins"

COMMIT=true
PUSH=true

while [[ $# -gt 0 ]]; do
    case "$1" in
    --no-commit)
        COMMIT=false
        PUSH=false
        ;;
    --no-push)
        PUSH=false
        ;;
    -h | --help)
        echo "Usage: $0 [--no-commit] [--no-push]"
        exit 0
        ;;
    *)
        echo "sync-omarchy-plugins: unknown option: $1" >&2
        exit 1
        ;;
    esac
    shift
done

if [ ! -f "$PLUGINS_FILE" ]; then
    cat >"$PLUGINS_FILE" <<'EOF'
# Omarchy plugins installed from outside the Omarchy package.
# Read by scripts/install.sh, maintained by scripts/sync-omarchy-plugins.sh.
#
# Format: <plugin-id> <git-url>
EOF
fi

is_listed() {
    local id="$1" listed_id _rest
    while read -r listed_id _rest; do
        [[ "$listed_id" == "$id" ]] && return 0
    done <"$PLUGINS_FILE"
    return 1
}

added=()
for dir in "$PLUGINS_DIR"/*/; do
    dir="${dir%/}"
    [ -f "$dir/manifest.json" ] || continue
    # Only plugins that are their own git checkout came from `omarchy plugin add`.
    [ -e "$dir/.git" ] || continue

    id="$(basename "$dir")"
    is_listed "$id" && continue

    url="$(git -C "$dir" remote get-url origin 2>/dev/null || true)"
    if [ -z "$url" ]; then
        echo "sync-omarchy-plugins: $id has no git origin, skipping" >&2
        continue
    fi

    printf '%s %s\n' "$id" "$url" >>"$PLUGINS_FILE"
    added+=("$id")
    echo "Recorded Omarchy plugin $id ($url)"
done

[ "$COMMIT" = true ] || exit 0

rel_file="${PLUGINS_FILE#"$DOTFILES_DIR"/}"
git -C "$DOTFILES_DIR" add -- "$rel_file"

# Nothing new on disk and nothing left over from an earlier run: stay quiet.
if git -C "$DOTFILES_DIR" diff --cached --quiet -- "$rel_file"; then
    exit 0
fi

if [ ${#added[@]} -gt 0 ]; then
    message="Add Omarchy plugin(s): ${added[*]}"
else
    message="Update Omarchy plugin list"
fi

# The pathspec limits the commit to the plugin list, whatever else is staged.
git -C "$DOTFILES_DIR" commit --quiet -m "$message" -- "$rel_file"
echo "Committed $rel_file to $DOTFILES_DIR"

[ "$PUSH" = true ] || exit 0

if ! git -C "$DOTFILES_DIR" rev-parse --abbrev-ref --symbolic-full-name '@{u}' &>/dev/null; then
    echo "sync-omarchy-plugins: current branch has no upstream, not pushing" >&2
    exit 0
fi

if git -C "$DOTFILES_DIR" push --quiet; then
    echo "Pushed the plugin list to $(git -C "$DOTFILES_DIR" rev-parse --abbrev-ref '@{u}')"
else
    echo "sync-omarchy-plugins: push failed; the commit is kept locally, push it with: git -C $DOTFILES_DIR push" >&2
    exit 1
fi
