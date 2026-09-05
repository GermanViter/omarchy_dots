# Load modular configuration in lexical order.
ZSH_CONFIG_DIR="${${(%):-%x}:A:h}/.zshrc.d"
if [[ -d "$ZSH_CONFIG_DIR" ]]; then
    for config_file in "$ZSH_CONFIG_DIR"/*.zsh(N); do
        source "$config_file"
    done
fi

# Keep private overrides out of the dotfiles repository.
[[ -r "$HOME/.zshrc.local" ]] && source "$HOME/.zshrc.local"


# Added by Antigravity CLI installer
export PATH="/home/germanviter/.local/bin:$PATH"
