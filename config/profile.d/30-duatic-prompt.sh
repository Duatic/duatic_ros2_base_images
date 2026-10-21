# shellcheck shell=bash
# Duatic dev container prompt and colors.
#
#
# The container home is a bind mount, so `useradd -m` never copies /etc/skel/.bashrc into it, and the Ubuntu defaults
# that would normally give a colored prompt and `ls --color` are simply absent. Providing them here keeps every developer's shell
# identical and versioned with the image tag.
[ -n "${_DUATIC_PROMPT_SOURCED:-}" ] && return 0
_DUATIC_PROMPT_SOURCED=1

# Interactive shells only — aliases and a colored PS1 would only corrupt script output.
case $- in
    *i*) ;;
    *) return 0 ;;
esac

if command -v dircolors >/dev/null 2>&1; then
    eval "$(dircolors -b)"
    alias ls='ls --color=auto'
    alias grep='grep --color=auto'
    alias fgrep='fgrep --color=auto'
    alias egrep='egrep --color=auto'
fi

# Show command prompt with user, product, distro, and image version
_duatic_ctx=""
for _duatic_seg in "${DUATIC_PRODUCT:-}" "${ROS_DISTRO:-}" "${DUATIC_IMAGE_VERSION:-}"; do
    [ -n "$_duatic_seg" ] && _duatic_ctx="${_duatic_ctx:+${_duatic_ctx}-}${_duatic_seg}"
done
[ -z "$_duatic_ctx" ] && _duatic_ctx="\h"

case "${TERM:-dumb}" in
    dumb | unknown | "")
        PS1="\u@${_duatic_ctx}:\w\\\$ "
        ;;
    *)
        # Root in red: you are normally your own user in here, so root should look wrong.
        if [ "$(id -u)" = 0 ]; then
            _duatic_user='\[\e[1;31m\]\u\[\e[0m\]'
        else
            _duatic_user='\[\e[1;32m\]\u\[\e[0m\]'
        fi
        PS1="${_duatic_user}@\[\e[1;36m\]${_duatic_ctx}\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\\\$ "
        ;;
esac

# Colored ROS2 messages
export RCUTILS_COLORIZED_OUTPUT=1

unset _duatic_ctx _duatic_seg _duatic_user

return 0
