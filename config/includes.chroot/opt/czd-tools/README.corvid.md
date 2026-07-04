# /opt/czd-tools — pointer, not payload

This directory is intentionally almost empty in the Corvid OS git repo. The real
CZD-Tools suite is **not vendored** here (SPEC.md, rule 3). It is fetched at
**build time** by the live-build hook:

    config/hooks/live/0500-czd-tools.hook.chroot

That hook runs inside the build chroot and populates `/opt/czd-tools` on the
finished image. Keeping the payload out of git keeps this repo lean and avoids
shipping a stale, duplicated copy of a tool that evolves on its own.

## How the payload gets here (at build time)

The hook, in order:

1. Installs the runtime deps the launcher relies on: `python3`, `git`, `pip`,
   `pipx`, and the optional `pystyle` (colored TUI; has a no-color fallback).
2. Populates `/opt/czd-tools` with the suite:
   - **Preferred:** `git clone https://github.com/CamoRageaholic1/CZD-Tools.git`
   - **Fallback:** copy from a locally-staged tree at `/opt/czd-tools-src`
     (rsynced onto the build VM out-of-band; still not committed to git).
3. Installs `/usr/local/bin/czd`, a small wrapper that runs the newest
   `CZD-Tools_v*.py` under `python3`.
4. Drops `/usr/share/applications/czd-tools.desktop` so it shows up in the
   Plasma application launcher (opens in a terminal, since it is a TUI).

## Runtime layout on the installed system

The launcher is **relocatable**. Internally it sets `ROOT = ~/CZD-Tools`
(derived from `$HOME`, not from the script's path), so:

| Path | Role | Writable |
|---|---|---|
| `/opt/czd-tools` | read-only program (the `.py` launcher) | no (system) |
| `~/CZD-Tools` | per-user state: `check.json`, `theme.json`, on-demand `tools/` | yes (per user) |

On first run for a user, the launcher creates `~/CZD-Tools/` and installs each
selected tool on demand (via apt / pip / pipx / git). Nothing is pre-installed
beyond the launcher itself, which keeps the image lean and lets each user pull
only the tools they want.

## Heads-up for maintainers

At the time this was written, `CamoRageaholic1/CZD-Tools` did **not** exist as a
public GitHub repo — the suite lived only on the author's workstation at
`~/CZD-Tools`. Until that repo is published (or a local source is staged on the
build VM), the hook logs a warning and continues, and `czd` reports that the
payload is missing. See the INVESTIGATION NOTE at the top of the hook.
