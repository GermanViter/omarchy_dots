# Omarchy environment and shell defaults
if [[ -r /usr/share/omarchy/default/bash/env-bootstrap ]]; then
    source /usr/share/omarchy/default/bash/env-bootstrap
fi
if [[ -n "$OMARCHY_PATH" && -r "$OMARCHY_PATH/default/bash/envs" ]]; then
    source "$OMARCHY_PATH/default/bash/envs"
fi

export EDITOR="${EDITOR:-omarchy-launch-editor --inline}"
export SUDO_EDITOR="${SUDO_EDITOR:-$EDITOR}"
export BROWSER="${BROWSER:-omarchy-launch-browser}"
export BAT_THEME="${BAT_THEME:-ansi}"
export MANROFFOPT="${MANROFFOPT:--c}"
export MANPAGER="${MANPAGER:-sh -c 'col -bx | bat -l man -p'}"

if command -v mise >/dev/null 2>&1; then
    eval "$(mise activate zsh)"
fi
