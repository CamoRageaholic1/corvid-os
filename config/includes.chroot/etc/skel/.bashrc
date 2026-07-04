# ===========================================================================
# Corvid OS — default ~/.bashrc  (/etc/skel, copied to every new user)
# ---------------------------------------------------------------------------
# Advanced-user oriented but restrained. Shared PATH/editor/toolchain config
# lives in ~/.config/corvid/env.sh so bash and zsh stay in sync.
# ===========================================================================

# If not running interactively, do nothing.
case $- in
    *i*) ;;
      *) return ;;
esac

# --- History ----------------------------------------------------------------
HISTCONTROL=ignoreboth        # no dupes, no lines starting with a space
HISTSIZE=50000
HISTFILESIZE=100000
HISTTIMEFORMAT='%F %T '
shopt -s histappend           # append, don't clobber, on shell exit
shopt -s checkwinsize         # keep LINES/COLUMNS correct after resize
shopt -s globstar 2>/dev/null # ** recursive glob

# --- Prompt (git-aware-ish, colored) ----------------------------------------
if [ -x /usr/bin/dircolors ]; then
    eval "$(dircolors -b)"
fi
# Corvid: cyan user@host, blue cwd, red '#' for root.
if [ "$(id -u)" -eq 0 ]; then
    PS1='\[\e[1;31m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\n\[\e[1;31m\]#\[\e[0m\] '
else
    PS1='\[\e[1;36m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\n\[\e[1;32m\]\$\[\e[0m\] '
fi

# --- Common aliases ---------------------------------------------------------
alias ls='ls --color=auto'
alias ll='ls -alFh'
alias la='ls -A'
alias l='ls -CF'
alias grep='grep --color=auto'
alias ..='cd ..'
alias ...='cd ../..'
alias df='df -h'
alias free='free -h'
# Ubuntu ships fd/bat under prefixed names to avoid clashes — restore the nice names.
command -v batcat >/dev/null 2>&1 && alias bat='batcat'
command -v fdfind >/dev/null 2>&1 && alias fd='fdfind'

# --- Completion -------------------------------------------------------------
if ! shopt -oq posix; then
    if [ -f /usr/share/bash-completion/bash_completion ]; then
        . /usr/share/bash-completion/bash_completion
    elif [ -f /etc/bash_completion ]; then
        . /etc/bash_completion
    fi
fi

# --- Shared Corvid environment (PATH, editor, toolchains) -------------------
[ -f "${HOME}/.config/corvid/env.sh" ] && . "${HOME}/.config/corvid/env.sh"

# --- Friendly note ----------------------------------------------------------
# Welcome to Corvid OS. Security-hardened, coding-friendly.
#   * CZD-Tools are on your PATH (/opt/czd-tools).
#   * Dev stack: python3/pipx, go, rustc/cargo, node/npm, ruby, clang/gcc, docker,
#     podman, distrobox. VS Code = `code`, editor default = nvim.
#   * Prefer `distrobox` for throwaway build environments; `docker`/`podman` for services.
# Edit ~/.config/corvid/env.sh to change PATH/editor/toolchain settings globally.
