# shellcheck shell=bash
# Duatic dev container command history.
#
[ -n "${_DUATIC_HISTORY_SOURCED:-}" ] && return 0
_DUATIC_HISTORY_SOURCED=1

# Interactive shells only — history and key bindings mean nothing to a script.
case $- in
    *i*) ;;
    *) return 0 ;;
esac

HISTSIZE=100000
HISTFILESIZE=200000
HISTCONTROL=ignoreboth
shopt -s histappend

# Append each command as it runs
case ";${PROMPT_COMMAND:-};" in
    *";history -a;"*) ;;
    *) PROMPT_COMMAND="history -a;${PROMPT_COMMAND:-}" ;;
esac

# Up/Down search the history for entries starting with what is already typed.
bind '"\e[A": history-search-backward'
bind '"\e[B": history-search-forward'
bind '"\eOA": history-search-backward'
bind '"\eOB": history-search-forward'

return 0
