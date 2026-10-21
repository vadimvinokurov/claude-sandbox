#!/usr/bin/env bash
# claude-sandbox.sh — Docker sandbox launcher for Claude Code.
#
# Runs Claude Code with --dangerously-skip-permissions inside an isolated,
# disposable container. Run it from ANY project directory; everything lives
# in that directory's .claude-sandbox/.
#
# Subcommands (the first argument; anything else is passed to claude):
#   claude-sandbox.sh           — start Claude Code in the sandbox (default)
#   claude-sandbox.sh clear     — full reset: remove this project's .claude-sandbox/
#                                 dir and its image (caches/toolchains re-download)
#   claude-sandbox.sh rebuild   — rebuild this project's image from scratch
#                                 (--no-cache: apt, node, claude, uv all re-run)
#
# Quick start:
#   1. Install Docker
#   2. Make it callable as `claude-sandbox` from any directory:
#      
#      from the folder where the script saved, run (the shell resolves $PWD itself):
#
#      macOS / Linux:
#        chmod +x "$PWD/claude-sandbox.sh" && sudo ln -sf "$PWD/claude-sandbox.sh" /usr/local/bin/claude-sandbox
#      No sudo rights? Use a user dir on PATH (~/.local/bin usually is):
#          ln -sf "$PWD/claude-sandbox.sh" ~/.local/bin/claude-sandbox
#
#      Windows:
#        [Environment]::SetEnvironmentVariable("Path", [Environment]::GetEnvironmentVariable("Path", "User") + ";" + "$($PWD.Path)", "User")

#      Then run it from a project folder:     claude-sandbox
#      Any extra args are passed to claude, e.g.:   claude-sandbox --resume
#   3. First run: the image builds once (~1-2 min); after that rebuilds are
#      instant (Docker layer cache).
#   4. Closing Claude or the terminal removes the container (--rm). Project
#      state lives in ./.claude-sandbox/ per project:
#        .claude-sandbox/home/     — agent home dir (caches, toolchains).
#                                    Wipe it for a factory reset.
#        .claude-sandbox/builder/  — Dockerfile + entrypoint.sh, rewritten
#                                    from the packaged versions on EVERY
#                                    run: a project keeps no own copies, and
#                                    an in-container agent cannot poison the
#                                    next launch through them.
#   5. Your host ~/.claude and ~/.claude.json are mounted read-write into the
#      container (shared login, sessions, history — BOTH ways).
#   6. macOS note, not a bug here: in the live claude TUI ⌘C may copy
#      nothing — the TUI turns on mouse reporting, a plain mouse drag never
#      becomes a terminal selection (and the constant redraw erases it).
#      Hold Option (or fn) while dragging to force a real selection; ⌘V is
#      unaffected (paste needs no selection). Works with or without Docker.
#
# .claudesandboxignore
#   Use to hide parts of the project from the container.
#   
#   An entry that matches a pattern — file OR folder, at any depth — stays
#   untouched on the host but EMPTY in the container: a dir gets an empty
#   tmpfs mounted over it, a file — an empty read-only placeholder file
#   bound over it.
#
#   Rules:
#   1. Each line is one glob pattern; blank lines and '#' comments are skipped.
#   2. '*' matches anything within ONE path segment — it never crosses '/'.
#   3. A line starting with '!' re-includes a path instead of hiding it.
#   4. A pattern without '/' matches top-level entries only; a pattern with
#      '/' is a full path from the project root (src/generated).
#   5. The LAST matching pattern wins (gitignore-style) — examples below read
#      exactly like a real file, line after line:
#
#   Typical use — sandbox in a big folder, show only two dirs, hide one lib:
#
#     *              ← hide every top-level entry (subtree rides along)
#     !code          ← ...but show code
#     !config        ← ...and config
#     code/lib3d_part  ← ...yet still hide this inside code
#
#   More examples:
#     node_modules       ← hide name (.env — any top-level file)
#     *secret*           ← hide any top-level name containing "secret"
#     */build            ← hide 'build' in every top-level dir (front/build, ...)
#
#   '!' can't reveal anything under an already-hidden folder: the empty tmpfs
#   empties the whole subtree. Hide the children and re-include the wanted:
#   Bad:
#     code/lib           ← hide code/lib
#     !code/lib/src      ← ...try to keep src (and everything under it)
#   Good:
#     code/lib/*         ← hide code/lib's children...
#     !code/lib/src      ← ...but keep src (and everything under it)
#
#   The ignore file itself is ALWAYS hidden from the agent: in the container
#   it reads as empty, and its edits never reach the host copy.
#
# Security notes (accepted trade-offs):
#   - Container is non-root, no sudo, no caps, no-new-privileges, limited
#     pids/cpus/memory, tmpfs on /tmp and /run.
#   - The container has FULL network access (internet + LAN + host ports).
#   - The container runs DIRECTLY on the host's network stack
#     (--network=host): every port a dev server opens inside is immediately
#     on the host — localhost:<same port>, no -p publishing needed — and the
#     host resolver is used (a fixed container DNS breaks a corporate VPN).
#     Cost: no network-stack isolation. Needs the daemon's host networking
#     support (Docker Desktop >= 4.34 with it enabled in the daemon settings,
#     or OrbStack, or plain Linux).
#   - The mounted ~/.claude is writable: an in-container agent could poison
#     host hooks in ~/.claude settings. This is a conscious decision.
#   - Anything Claude deletes in /work is deleted on the host — keep /work
#     under version control.
#
# Structure: constants → helpers → stages → main (at the end; add new stages
# before main).

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# shellcheck disable=SC2034  # used by later stages
BUILDER_DIR=".claude-sandbox/builder"
# shellcheck disable=SC2034
STATE_DIR=".claude-sandbox/home"

# Files materialized into the per-project dir (image Dockerfile + entrypoint.
# Both are seeded into builder/ — the build's build-context, where COPY picks
# up the entrypoint from).
# shellcheck disable=SC2016  # deliberately leave $ unexpanded in heredoc vars
read -r -d '' DOCKERFILE_MAIN <<'EOF_PLACEHOLDER' || true
# Dockerfile — claude-sandbox image (layers; edit per project as you like).
FROM ubuntu:26.04

# apt must not ask interactive questions — nobody inside the build answers them.
ENV DEBIAN_FRONTEND=noninteractive

# Package set in one layer, with the apt cache cleaned afterwards:
#   curl+ca-certificates+zsh+less — plumbing for claude/uv/shell;
#   build-essential — g++, make, libc headers (the baseline C++ toolchain);
#   cmake + ninja-build — build system, ninja as the fast CMake generator;
#   pkg-config + ccache — dependency lookup and fast rebuilds;
#   clang + lldb + gdb — second compiler and debuggers (lldb for clang, gdb for g++);
#   clang-tidy + clang-format — static analysis and formatting the agent can run;
#   libgtest-dev + libgmock-dev — googletest/googlemock: headers, static libs
#     and CMake configs (/usr/include/gtest, libgtest*.a, gtest::gtest target);
#   elfutils — readelf/nm/strip/addr2line: inspecting ELF binaries and core
#     dumps during debugging;
#   libdw-dev — libdw headers: DWARF/debug-info tooling (e.g. for custom
#     unwinding/profiling tooling the agent may build or link).
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      curl ca-certificates git zsh less \
      build-essential cmake ninja-build pkg-config ccache \
      clang lldb gdb clang-tidy clang-format \
      libgtest-dev libgmock-dev elfutils libdw-dev && \
    rm -rf /var/lib/apt/lists/*

# User with host UID/GID (build-args) — files in /work don't change owner.
# The host GID may be held by any system group (macOS: GID 20 = staff, while
# in ubuntu GID 20 = dialout), so drop whoever owns the target GID, not just ubuntu.
ARG UID=1000
ARG GID=1000
ARG USERNAME=proj
RUN userdel -r ubuntu || true && \
    groupdel ubuntu || true && \
    existing="$(getent group ${GID} | cut -d: -f1)" && \
    if [ -n "$existing" ] && [ "$existing" != "${USERNAME}" ]; then \
      groupdel "$existing"; \
    fi && \
    groupadd -g ${GID} ${USERNAME} && \
    useradd -m -u ${UID} -g ${GID} -s /bin/bash ${USERNAME}

# Node LTS (deb.nodesource.com) with cache cleanup.
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Claude Code and uv as system binaries (root, outside the mount-shadowed home).
# At runtime /home/<user> is shadowed by the per-project state mount, so any
# binary baked into ~/.local is invisible in the container: install to /usr/local/bin.
# claude.ai/install.sh installs per-user into ~/.local/bin — hence the npm package;
# the npm cache is cleaned in the same layer.
RUN npm install -g @anthropic-ai/claude-code && npm cache clean --force

# uv — the agent's Python environment manager; UV_INSTALL_DIR moves it to /usr/local/bin.
RUN curl -LsSf https://astral.sh/uv/install.sh | UV_INSTALL_DIR=/usr/local/bin sh -

USER ${USERNAME}
# ~/.local/bin still on PATH — for user-space tools the agent installs into
# the state dir at container runtime.
ENV PATH="/home/${USERNAME}/.local/bin:${PATH}"

# Entrypoint is copied executable: the seed file in builder/ is mode 644,
# COPY preserves the source mode, hence --chmod=555 (BuildKit).
COPY --chmod=555 entrypoint.sh /entrypoint.sh

# No CMD — the launcher always passes the command.
WORKDIR /work
EOF_PLACEHOLDER

# shellcheck disable=SC2016  # deliberately leave $ unexpanded in heredoc vars
read -r -d '' ENTRYPOINT_SH <<'EOF_PLACEHOLDER' || true
#!/bin/sh
# entrypoint.sh — initialize the state dir ($HOME), then exec the command.
# The $HOME mount shadows what's baked into the image: files are seeded only
# if missing.
set -eu
umask 022
export PATH="$HOME/.local/bin:$PATH"

# ~/.zshrc: PATH with ~/.local/bin (claude and uv live there) + umask 022
# (644 files / 755 dirs — otherwise /work files become foreign to the host).
[ -f "$HOME/.zshrc" ] || cat > "$HOME/.zshrc" <<'INNER'
export PATH="$HOME/.local/bin:$PATH"
umask 022
INNER

# ~/.gitconfig: without an identity git rejects the first commit.
[ -f "$HOME/.gitconfig" ] || {
  git config --global user.name "Claude Agent"
  git config --global user.email "agent@claude.ai"
}

exec "$@"
EOF_PLACEHOLDER

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

die() { # die msg — stderr + exit 1
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

info() { # info msg — stdout
  printf '%s\n' "$*"
}

# Git Bash (MSYS): its automatic path rewriting turns container paths into
# Windows ones (/work, /tmp, /entrypoint.sh become "C:\Program Files\Git\..."),
# which breaks -v, --tmpfs and --entrypoint — hence "invalid mount path: 'C'".
# So rewriting is disabled and host paths are pre-translated here into the
# drive-letter form cygpath gives ("C:/..."), which docker on Windows accepts;
# container-only paths (/:/work, /tmp, /home/...) pass through untouched.
# On Linux / WSL2 cygpath may not exist and rewriting doesn't happen anyway.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    export MSYS_NO_PATHCONV=1
    hostpath() { cygpath -m "$1"; } ;;
  *)
    hostpath() { printf '%s' "$1"; } ;;
esac

# read_ignore_patterns file — reads a .claudesandboxignore file and prints its
# patterns one per line: leading/trailing whitespace is trimmed, blank lines and
# whole-line # comments are skipped. A missing file is not an error — the
# output is just empty (no ignore rules → plain launch).
read_ignore_patterns() { # read_ignore_patterns file → stdout: patterns
  local file="${1:-}"
  [ -f "$file" ] || return 0
  local line=""
  while read -r line; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    printf '%s\n' "$line"
  done < "$file"
  # The file may lack a trailing newline: on the last EOF pass read still
  # fills the variable but returns false, so the while loop skipped the line.
  # Nothing here to re-filter that the loop above hasn't done.
  [ -n "$line" ] || return 0
  case "$line" in
    '#'*) return 0 ;;
  esac
  printf '%s\n' "$line"
}

# glob_ere pattern — converts a glob pattern to an ERE body: '*' becomes
# [^/]* (any characters within ONE path segment — so a pattern never sneaks
# past a '/'), every other character is literal (regex specials are escaped).
# A single 'sed' pass: escape the specials first, then turn the escaped '*'s.
glob_ere() { # glob_ere pattern → stdout: ERE body
  printf '%s' "$1" | sed -e 's,[][\.*+(){}?^$|\\],\\&,g' -e 's,\\\*,[^/]*,g'
}

# ignore_match pattern relpath — true (exit 0) when glob pattern matches the
# path relative to the project root. Anchored on both ends: 'node_modules'
# matches only an entry named exactly that; a pattern without '/' therefore
# can only reach top-level entries, one with '/' — an entire relative path.
ignore_match() { # ignore_match pattern relpath → exit 0 iff match
  local ere
  ere="$(glob_ere "$1")"
  [[ "$2" =~ ^${ere}$ ]]
}

# ignore_scan project_dir — walks the project tree and prints the paths that
# match the project's .claudesandboxignore patterns, relative to project_dir,
# one per line (line-based: a filename containing a newline is not supported).
# A line starting with '!' is a negation: it re-includes instead of hiding,
# and the LAST matching pattern decides (gitignore-style), so lists read top
# to bottom. The walk stops at the depth of the deepest pattern;
# .claude-sandbox and .git are never traversed or matched — the agent's own
# state and the repo metadata are out of scope. No ignore file → no output,
# exit 0.
ignore_scan() { # ignore_scan project_dir → stdout: shadowed rel paths
  local root="${1:-}"
  local file="$root/.claudesandboxignore"
  [ -f "$file" ] || return 0

  # Patterns, their precompiled EREs and the match decision each pattern
  # forces (plain → 1 = hide, '!' → 0 = re-include) in parallel arrays; the
  # walk's -maxdepth is the pattern with the most '/'-separated segments.
  local -a patterns=() eres=() forces=()
  local p force slashes nsegs maxdepth=1
  while IFS= read -r p; do # read_ignore_patterns has cleaned: no blanks/comments
    force=1
    case "$p" in
      '!'*) force=0; p="${p#!}" ;;
    esac
    slashes="${p//[!\/]/}" # keep only the '/'s, count them
    nsegs=$(( ${#slashes} + 1 ))
    [ "$nsegs" -gt "$maxdepth" ] && maxdepth="$nsegs"
    patterns+=("$p")
    eres+=("$(glob_ere "$p")")
    forces+=("$force")
  done < <(read_ignore_patterns "$file")
  [ "${#patterns[@]}" -gt 0 ] || return 0

  # All patterns are evaluated per path (no early break: a later match
  # overrides an earlier one); what survives as matched-and-not-negated
  # is shadowed. A negated path inside an already-shadowed folder stays
  # hidden — the empty tmpfs over the folder hides its whole subtree;
  # ignore the children instead ('dir/*') to keep one of them visible.
  local d rel i decision
  while IFS= read -r -d '' d; do
    rel="${d#"$root"/}"
    decision=0
    for i in "${!patterns[@]}"; do
      if [[ "$rel" =~ ^${eres[i]}$ ]]; then
        decision=${forces[i]} # last matching pattern decides (gitignore-style)
      fi
    done
    if [ "$decision" = 1 ]; then
      printf '%s\n' "$rel"
    fi
  done < <(find "$root" -mindepth 1 -maxdepth "$maxdepth" \
             \( -name .claude-sandbox -o -name .git \) -prune -o -print0)
}

# ---------------------------------------------------------------------------
# Stages
# ---------------------------------------------------------------------------

require_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    die 'Docker is not installed or the daemon is not running — install Docker (OrbStack/Docker Desktop on macOS, docker-ce/Docker Desktop on Linux and in WSL2)'
  fi
  if ! docker info >/dev/null 2>&1; then
    die 'Docker is not installed or the daemon is not running — install Docker (OrbStack/Docker Desktop on macOS, docker-ce/Docker Desktop on Linux and in WSL2)'
  fi
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

# image_tag cwd — deterministic image tag for a project directory:
# claude-sandbox:proj-<crc32>. cksum is stable on one host, the tag characters
# are safe for docker (lowercase name + digits), the tag is unique per directory.
image_tag() { # image_tag cwd → stdout: claude-sandbox:proj-<crc>
  local cwd="${1:-}"
  if [ -z "$cwd" ]; then
    die 'image_tag: no project directory given'
  fi
  printf 'claude-sandbox:proj-%s' "$(printf '%s' "$cwd" | cksum | cut -d' ' -f1)"
}

# build_images — builds the per-project image from $BUILDER_DIR. Always: docker
# build reuses the cache itself, a repeat run takes seconds. UID/GID/USERNAME
# are host values so files in /work don't change owner (Dockerfile build-args).
build_images() {
  local tag
  tag=$(image_tag "$(pwd -P)")
  info "Building image $tag from $BUILDER_DIR ..."
  docker build \
    --build-arg UID="$(id -u)" \
    --build-arg GID="$(id -g)" \
    --build-arg USERNAME="$(id -un)" \
    -t "$tag" "$BUILDER_DIR"
}

# clamp_mem total_bytes — container memory limit: floor(total/1048576) MiB,
# clamped at 8192m (8 GB) at the top: a daemon with headroom never raises the limit.
clamp_mem() { # clamp_mem total_bytes → stdout: ${N}m, N = min(8192, floor(bytes/1048576))
  local total_bytes="${1:-0}"
  printf '%dm' $(( total_bytes / 1048576 > 8192 ? 8192 : total_bytes / 1048576 ))
}

# mem_limit — the memory limit as it will actually apply: from the daemon's
# MemTotal (host headroom stays untouched).
mem_limit() { # mem_limit → stdout: ${N}m
  clamp_mem "$(docker info --format '{{.MemTotal}}')"
}

# shadow_args project_dir — prints the hiding recipe for every entry matched
# by .claudesandboxignore, one entry per line, TAB-separated:
#   tmpfs<TAB>/work/<dir>   a dir is hidden with an empty tmpfs;
#   bind<TAB><src>:<target> a file can't take a tmpfs — runc refuses a mount
#                           over a non-directory ("not a directory", which
#                           killed the container at start) — so it hides
#                           behind an EMPTY placeholder file, created under
#                           .claude-sandbox/shadows/ mirroring the path and
#                           bind-mounted over it, READ-ONLY: the agent can
#                           see the path and nothing more, its writes bounce
#                           (review item 7; without :ro the agent could
#                           "re-hide" content mid-session via
#                           .claude-sandbox/shadows/<path>). Placeholders
#                           live in
#                           .claude-sandbox/ (never scanned), wiped by "clear".
shadow_args() { # shadow_args project_dir → stdout: tmpfs/bind recipes
  local root="${1:-}"
  local shadows="$root/.claude-sandbox/shadows"
  local p f
  # The placeholder tree is regenerated from scratch on EVERY run: leftovers
  # from an older ignore layout can sit here with the OPPOSITE entry type (a
  # directory where a file is now matched, or vice versa). A failed
  # `: >` in a stale shape dies silently (redirection failures don't raise
  # errexit) and drops the bind recipe from the output — the container then
  # half-launches or dies with "not a directory". Wipe first, heal always.
  rm -rf "$shadows" 2>/dev/null || true
  mkdir -p "$shadows"
  while IFS= read -r p; do
    # The ignore file itself: skipped here, appended below unconditionally.
    [ "$p" = ".claudesandboxignore" ] && continue
    # Hide only plain files and plain dirs. A symlink/junction (even to a
    # valid dir) gets SKIPPED with a warning: bash and the container file
    # system may disagree on what a reparse point is (virtiofs/drvfs on
    # Windows does), a mount target resolves THROUGH the link, and a
    # mismatch dies at container start with "not a directory" — warning and
    # leaving the entry visible beats a session that doesn't launch.
    if [ -d "$root/$p" ] && [ ! -L "$root/$p" ]; then
      printf 'tmpfs\t/work/%s\n' "$p"
    elif [ -f "$root/$p" ] && [ ! -L "$root/$p" ]; then
      f="$shadows/$p"
      mkdir -p "$(dirname "$f")"
      : > "$f"
      printf 'bind\t%s:/work/%s:ro\n' "$(hostpath "$f")" "$p"
    else
      printf 'WARN: .claudesandboxignore: entry "%s" is a symbolic link, junction or missing — not hidden, shown as is\n' "$p" >&2
    fi
  done < <(ignore_scan "$root")
  # .claudesandboxignore is ALWAYS shadowed, pattern or no pattern: it is
  # user-writable policy the in-container agent must neither read nor tamper
  # with — the shadow leaves an empty file in the container and routes the
  # agent's writes into the disposable placeholder, not into the host file
  # (security review item 5). No file → nothing to hide.
  if [ -f "$root/.claudesandboxignore" ]; then
    mkdir -p "$shadows"
    f="$shadows/.claudesandboxignore"
    : > "$f"
    printf 'bind\t%s:/work/.claudesandboxignore:ro\n' "$(hostpath "$f")"
  fi
}

# shadow_mounts project_dir — shadow_args turned into docker argv words, one
# per line (each line is exactly ONE word; the consumer reads with IFS= so
# paths with spaces survive).
shadow_mounts() { # shadow_mounts project_dir → stdout: docker argv words
  local kind val
  while IFS=$'\t' read -r kind val; do
    case "$kind" in
      tmpfs) printf '%s\n' "--tmpfs=$val" ;;
      bind)  printf '%s\n%s\n' -v "$val" ;;
    esac
  done < <(shadow_args "$1")
}

# run_container — launches the container with args passed through to claude.
# Exact call per contract: no-new-privileges + cap-drop=ALL + pids/cpus/memory,
# --init, tmpfs on /tmp and /run, fixed DNS, TERM passed through,
# /work = project (pwd -P), claude state = per-project home + host ~/.claude*.
# No exec: docker run -it replaces the terminal session itself; the exit code
# arrives through the plain command.
run_container() {
  local project root
  root=$(pwd -P)
  project=$(hostpath "$root")
  # Hiding mounts over every entry matched by .claudesandboxignore — empty
  # tmpfs for dirs, empty placeholder files for files (see shadow_mounts):
  # the host content stays untouched, inside the container the entry is
  # visible but empty. The ${shadows[@]+...} guard is for the empty-array
  # expansion on bash 3.2.
  local -a shadows=()
  local word
  while IFS= read -r word; do
    shadows+=("$word")
  done < <(shadow_mounts "$root")
  # Network: --network=host, always. The container shares the host's network
  # stack, so a dev server the agent starts inside is immediately reachable
  # as localhost:<same port> on the host — no -p publishing and no port
  # contract the agent would have to know; the host resolver answers
  # LAN/VPN names (a fixed container DNS breaks a corporate VPN). Cost: no
  # network-stack isolation. Needs the daemon's host networking support
  # (Docker Desktop >= 4.34 with it enabled in the daemon settings, or
  # OrbStack, or plain Linux).
  docker run -it --rm \
    --cap-drop=ALL --security-opt=no-new-privileges \
    --pids-limit=512 --cpus=4.0 --memory "$(mem_limit)" \
    --init --tmpfs /tmp --tmpfs /run \
    --network=host \
    -e TERM="${TERM:-xterm-256color}" \
    --entrypoint /entrypoint.sh \
    -v "$project:/work" \
    -v "$project/.claude-sandbox/home:/home/$USERNAME" \
    -v "$(hostpath "$HOME")/.claude:/home/$USERNAME/.claude" \
    -v "$(hostpath "$HOME")/.claude.json:/home/$USERNAME/.claude.json" \
    ${shadows[@]+"${shadows[@]}"} \
    "$(image_tag "$(pwd -P)")" \
    claude --dangerously-skip-permissions "$@"
}

# deploy_files — per-project deployment. The dirs are created if missing; the
# home state (mount targets) is seeded-if-missing and never rewritten. The
# builder files, on the contrary, are REWRITTEN from the launcher's packaged
# versions on EVERY run: an in-container agent can write into /work, so it
# must not be able to poison the next build through builder/ — whatever it
# tampers with there is wiped on the next start (security review item 4;
# per-project Dockerfile customization is consciously given up for this).
# Idempotent.
deploy_files() {
  mkdir -p "$BUILDER_DIR" "$STATE_DIR"

  # Mount targets for the nested file mounts of run_container ($HOME/.claude and
  # $HOME/.claude.json): Docker Desktop (virtiofs) requires the mount target to
  # exist on the host BEFORE the run — otherwise the first start fails with
  # "mountpoint ... is outside of rootfs", exit 125. In the container both are
  # shadowed by nested mounts from the host, so these are targets only:
  # seed-if-missing, contents of existing files are not touched.
  mkdir -p "$STATE_DIR/.claude"
  [ -e "$STATE_DIR/.claude.json" ] || : > "$STATE_DIR/.claude.json"

  # Builder files: always from the packaged versions. entrypoint.sh lands in
  # builder/ (the build's build-context) so COPY entrypoint.sh /entrypoint.sh
  # picks it up.
  printf '%s' "$DOCKERFILE_MAIN" > "$BUILDER_DIR/Dockerfile"
  printf '%s' "$ENTRYPOINT_SH" > "$BUILDER_DIR/entrypoint.sh"
}

# clear_project — full reset for the current project: kill any container on
# the project's image, remove the image and the whole .claude-sandbox/ dir.
# The image tag is per-directory (hashed from cwd), so this clears exactly
# this project's image — other projects are untouched.
clear_project() {
  local tag
  tag=$(image_tag "$(pwd -P)")

  # A running session holds the script open, so normally there is nothing to
  # kill; force-remove leftovers (e.g. a detached container) just in case.
  docker ps -aq --filter "ancestor=$tag" | xargs docker rm -f >/dev/null 2>&1 || true
  docker rmi -f "$tag" >/dev/null 2>&1 || true

  rm -rf "$(pwd -P)/.claude-sandbox"
  info "Cleared: container, image $tag and .claude-sandbox/ removed."
}

# rebuild_project — rebuild this project's image from scratch (--no-cache):
# every layer re-runs (apt, node, claude, uv). Use when a Dockerfile edit
# didn't take effect or the image drifted. Project state in .claude-sandbox/
# is NOT touched.
rebuild_project() {
  require_docker
  deploy_files
  local tag
  tag=$(image_tag "$(pwd -P)")
  info "Rebuilding image $tag from $BUILDER_DIR (no cache) ..."
  docker build \
    --no-cache \
    --build-arg UID="$(id -u)" \
    --build-arg GID="$(id -g)" \
    --build-arg USERNAME="$(id -un)" \
    -t "$tag" "$BUILDER_DIR"
}

main() {
  if [ $# -gt 0 ]; then
    case "$1" in
      clear)   shift; clear_project; return 0 ;;
      rebuild) shift; rebuild_project; return 0 ;;
    esac
  fi
  require_docker
  deploy_files
  build_images
  USERNAME="$(id -un)"
  run_container "$@"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi