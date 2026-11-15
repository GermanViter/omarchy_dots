# Keep the dotfiles plugin list in step with `omarchy plugin add`.
# After a successful add, the sync script records the new plugin in
# scripts/omarchy-plugins.txt, commits that file and pushes it.
_omarchy_plugins_sync="${${(%):-%x}:A:h:h:h}/scripts/sync-omarchy-plugins.sh"

omarchy() {
    command omarchy "$@" || return

    if [[ "$1" == plugin && ( "$2" == add || "$2" == install ) && -x "$_omarchy_plugins_sync" ]]; then
        "$_omarchy_plugins_sync" || true
    fi
}
