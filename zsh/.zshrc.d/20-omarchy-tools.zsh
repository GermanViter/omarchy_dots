# Omarchy filesystem, navigation, and tool aliases
if command -v eza >/dev/null 2>&1; then
    alias ls='eza -lh --group-directories-first --icons=auto'
    alias lsa='ls -a'
    alias lt='eza --tree --level=2 --long --icons --git'
    alias lta='lt -a'
fi

if command -v zoxide >/dev/null 2>&1; then
    zd() {
        if (( $# == 0 )); then
            builtin cd ~ || return
        elif [[ -d "$1" ]]; then
            builtin cd "$1" || return
        else
            if ! z "$@"; then
                echo "Error: Directory not found"
                return 1
            fi
            printf "\U000F17A9 "
            pwd
        fi
    }
    alias cd='zd'
fi

alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias a='omarchy-agent --inline'
alias c='opencode --auto'
alias cx='printf "\033[2J\033[3J\033[H" && claude --permission-mode auto'
alias cy='codex --approve-for-me'
alias d='docker'
alias g='git'
alias gcm='git commit -m'
alias gcam='git commit -a -m'
alias gcad='git commit -a --amend'
alias t='tmux attach || tmux new -s Work'
alias mup='MISE_MINIMUM_RELEASE_AGE=0 mise up'
n() { (( $# == 0 )) && command nvim . || command nvim "$@"; }

if command -v fzf >/dev/null 2>&1; then
    source <(fzf --zsh)
    alias ff='fzf --preview "bat --style=numbers --color=always {}"'
    alias eff='$EDITOR "$(ff)"'
fi
