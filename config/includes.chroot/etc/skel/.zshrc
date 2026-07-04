# ===========================================================================
# Corvid OS — default ~/.zshrc  (/etc/skel, copied to every new user)
# ---------------------------------------------------------------------------
# Self-contained: uses only zsh built-ins plus the two zsh plugins shipped in
# the image (zsh-autosuggestions, zsh-syntax-highlighting from devstack.list).
# NO framework (oh-my-zsh/powerlevel10k) is bootstrapped here — that would need
# a network fetch on first login, which the live image must not depend on.
# Shared PATH/editor/toolchain config lives in ~/.config/corvid/env.sh.
# ===========================================================================

# --- History ----------------------------------------------------------------
HISTFILE="${HOME}/.zsh_history"
HISTSIZE=50000
SAVEHIST=100000
setopt SHARE_HISTORY          # share history live across sessions
setopt HIST_IGNORE_ALL_DUPS   # drop older duplicate entries
setopt HIST_IGNORE_SPACE      # a leading space keeps a command out of history
setopt HIST_REDUCE_BLANKS
setopt EXTENDED_HISTORY       # record timestamps

# --- Behavior ---------------------------------------------------------------
setopt AUTO_CD                # `foo/` cd's into foo
setopt AUTO_PUSHD             # cd maintains a directory stack
setopt PUSHD_IGNORE_DUPS
setopt INTERACTIVE_COMMENTS   # allow # comments at the prompt
setopt NO_BEEP
setopt EXTENDED_GLOB

# --- Completion -------------------------------------------------------------
autoload -Uz compinit && compinit -d "${HOME}/.cache/zcompdump"
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'   # case-insensitive
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"

# --- Keybindings (emacs-style; Ctrl-R history search) -----------------------
bindkey -e

# --- Prompt (VCS-aware, colored; no external framework) ---------------------
autoload -Uz vcs_info
zstyle ':vcs_info:git:*' formats ' %F{yellow}(%b)%f'
precmd() { vcs_info }
setopt PROMPT_SUBST
if [ "$(id -u)" -eq 0 ]; then
    PROMPT='%F{red}%n@%m%f:%F{blue}%~%f${vcs_info_msg_0_}
%F{red}#%f '
else
    PROMPT='%F{cyan}%n@%m%f:%F{blue}%~%f${vcs_info_msg_0_}
%F{green}%%%f '
fi

# --- Aliases ----------------------------------------------------------------
alias ls='ls --color=auto'
alias ll='ls -alFh'
alias la='ls -A'
alias l='ls -CF'
alias grep='grep --color=auto'
alias ..='cd ..'
alias ...='cd ../..'
alias df='df -h'
alias free='free -h'
command -v batcat >/dev/null 2>&1 && alias bat='batcat'
command -v fdfind >/dev/null 2>&1 && alias fd='fdfind'

# --- zsh plugins (packaged in the image; load only if present) --------------
# Syntax highlighting must be sourced LAST to wrap the command line correctly.
[ -f /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh ] \
    && . /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh
[ -f /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ] \
    && . /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh

# --- Shared Corvid environment (PATH, editor, toolchains) -------------------
[ -f "${HOME}/.config/corvid/env.sh" ] && . "${HOME}/.config/corvid/env.sh"

# --- Friendly note ----------------------------------------------------------
# Welcome to Corvid OS. Security-hardened, coding-friendly.
#   * CZD-Tools are on your PATH (/opt/czd-tools).
#   * Dev stack: python3/pipx, go, rustc/cargo, node/npm, ruby, clang/gcc, docker,
#     podman, distrobox. VS Code = `code`, editor default = nvim.
#   * Prefer `distrobox` for throwaway build environments; `docker`/`podman` for services.
# Edit ~/.config/corvid/env.sh to change PATH/editor/toolchain settings globally.
