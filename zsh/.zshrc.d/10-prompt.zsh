# Prompt and completion
export ZSH="$HOME/.oh-my-zsh"
DISABLE_AUTO_TITLE="true"
ZSH_THEME="robbyrussell"
plugins=(git sudo zsh-autosuggestions zsh-syntax-highlighting)
export ZSH_DISABLE_COMPFIX=true

if [[ -f "$ZSH/oh-my-zsh.sh" ]]; then
    source "$ZSH/oh-my-zsh.sh"
fi

# On Omarchy, a theme-set hook renders starship.toml with the theme's colors.
# Re-render when starship.toml was edited since, and fall back to the static
# config off Omarchy or if the render is missing.
export STARSHIP_CONFIG="$HOME/.config/starship.toml"
_starship_themed="${XDG_STATE_HOME:-$HOME/.local/state}/starship/omarchy.toml"
_starship_hook="$HOME/.config/omarchy/hooks/theme-set.d/update-starship"
if [[ -x "$_starship_hook" && "$STARSHIP_CONFIG" -nt "$_starship_themed" ]]; then
    "$_starship_hook" >/dev/null 2>&1
fi
[[ -f "$_starship_themed" ]] && export STARSHIP_CONFIG="$_starship_themed"
unset _starship_themed _starship_hook

if [[ -o interactive && "$TERM" != "dumb" ]] && command -v starship >/dev/null 2>&1; then
    eval "$(starship init zsh)"
fi

if command -v zoxide >/dev/null 2>&1; then
    eval "$(zoxide init zsh)"
fi
