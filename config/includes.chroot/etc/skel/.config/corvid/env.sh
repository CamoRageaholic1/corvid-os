# ===========================================================================
# Corvid OS — shared shell environment (POSIX; sourced by .bashrc AND .zshrc)
# ---------------------------------------------------------------------------
# Keep this shell-agnostic (no bashisms/zshisms) so both shells can source it.
# It centralizes PATH + editor + toolchain env so there is one place to edit.
# ===========================================================================

# --- Default editor: Neovim (set at the system level too, via update-alternatives)
export EDITOR="nvim"
export VISUAL="nvim"
export PAGER="less"

# --- PATH helper: append a dir only if it exists and is not already present.
_corvid_path_append() {
    case ":${PATH}:" in
        *":$1:"*) ;;                      # already present, do nothing
        *) [ -d "$1" ] && PATH="${PATH}:$1" ;;
    esac
}
_corvid_path_prepend() {
    case ":${PATH}:" in
        *":$1:"*) ;;
        *) [ -d "$1" ] && PATH="$1:${PATH}" ;;
    esac
}

# --- CZD-Tools (installed to /opt/czd-tools by hook 0500) ------------------
# The hook also drops a launcher on PATH, but exposing the dir makes ad-hoc tools
# and any bin/ subdir reachable too.
_corvid_path_append "/opt/czd-tools"
_corvid_path_append "/opt/czd-tools/bin"

# --- Per-user tool bins -----------------------------------------------------
_corvid_path_prepend "${HOME}/.local/bin"     # pipx + pip --user installs
_corvid_path_append  "${HOME}/.cargo/bin"     # per-user cargo installs
_corvid_path_append  "/opt/cargo/bin"         # system-wide rust toolchain (hook 0400)
_corvid_path_append  "${HOME}/go/bin"         # go install targets

export PATH

# --- Rust: point rustup at the system-wide toolchain if present -------------
[ -d /opt/rust ] && export RUSTUP_HOME="/opt/rust"

# --- Go: keep a conventional per-user workspace -----------------------------
export GOPATH="${GOPATH:-${HOME}/go}"

unset -f _corvid_path_append _corvid_path_prepend
