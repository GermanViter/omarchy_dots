# Personal aliases and functions
alias ssh-german='ssh true_ssh_container'
alias .....='cd ../../../..'
alias nv='nvim'
alias preview_sddm='sddm-greeter-qt6 --test-mode --theme /usr/share/sddm/themes/sddm-astronaut-theme/'
alias gsw='git update-index --skip-worktree'
alias gnsw='git update-index --no-skip-worktree'
alias gh='open https://github.com/GermanViter/'
alias ll='eza --icons=always -la --group-directories-first'
alias la='eza --icons=always -a --group-directories-first'
alias tms='tmux attach-session -t $1'
alias claude='ollama launch claude --model gemma4:31b-cloud'
alias claw='ollama launch openclaw --model glm-5:cloud'
alias gsync='python3 $HOME/.gemini/scripts/obsidian_sync.py'

if [[ -f /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
elif [[ -f /usr/local/bin/brew ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
elif [[ -f /home/linuxbrew/.linuxbrew/bin/brew ]]; then
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
fi

if [[ -x /usr/libexec/java_home ]]; then
    export JAVA_HOME=$(/usr/libexec/java_home -v 25 2>/dev/null || /usr/libexec/java_home)
fi
export PATH="$PATH:$HOME/go/bin"
export PATH="$PATH:$HOME/.local/bin"
export WEBKIT_DISABLE_DMABUF_RENDERER=1

cmdhist() {
    fc -l 1 | awk '{print $2}' | sort | uniq -c | sort -nr | head -${1:-10}
}

linec() {
    find . -type f -not -path '*/.*' -exec wc -l {} + | awk '{total += $1} END {print total}'
}

fcd() {
    local dir
    dir=$(find ${1:-.} -type d -not -path '*/\.*' 2>/dev/null | fzf +m) && z "$dir"
}
