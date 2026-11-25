#!/bin/bash
# Installs apptio-mcp (Apptio Cloudability for Claude Desktop) on macOS.
#   curl -fsSL https://wpp-jamie-mills.github.io/apptio-mcp-site/install.sh | bash
# Check an install, or see the next step:   ... | bash -s -- --status
# For an agent or a script: --no-input asks nothing and changes nothing unless --yes is given; --dry-run downloads and
# checks the release, prints what would change and exits 0 without changing anything:
#   curl -fsSL <same url> | bash -s -- --dry-run --no-input
#   curl -fsSL <same url> | bash -s -- --no-input --yes [--install-uv]
#
# What it does, in this order (every question comes before any change):
#   1 checks the Mac, the tools and Claude Desktop; 2 compares versions; 3 finds uv; 4 reads Claude Desktop's config;
#   5 checks the install folder; 6 downloads and checks the release; 7 installs uv if you allowed it; 8 installs the
#   release; 9 adds the "cloudability" entry to Claude Desktop's config; 10 opens Claude Desktop if it isn't
#   running; 11 prints the next steps.
#
# Integrity: the release's SHA-256 comes from the same site as the release. It catches a damaged or half-served
# download. It does not protect against a compromised site.
#
# Test overrides (each one in use prints "test override in use: NAME"); they all start with APPTIO_INSTALL_:
#   BASE           where the release files come from (https, or http://127.0.0.1 | http://localhost | file://)
#   TTY            where questions are read from (default /dev/tty; /dev/null = no terminal)
#   CLAUDE_CONFIG  Claude Desktop's claude_desktop_config.json (default in ~/Library/Application Support/Claude)
#   CLAUDE_APP     the Claude.app folder (default /Applications/Claude.app)
#   UV_PATH        where to look for uv, colon-separated (empty = nowhere)
#   BREW           Homebrew's brew, for installing uv (empty = no Homebrew)
#   UV_BASE        where uv's release tarballs are downloaded from (same URL rules as BASE)
#   UV_SHA256      the uv tarball's expected SHA-256 instead of the pinned one
#   NO_OPEN        1 = don't open Claude Desktop
# This script is for bash (macOS /bin/bash 3.2 is enough). Under another shell, say so before anything else runs.
[ -n "${BASH_VERSION:-}" ] || {
  echo "Run this with bash, for example: curl -fsSL https://wpp-jamie-mills.github.io/apptio-mcp-site/install.sh | bash" >&2
  exit 1
}
set -euo pipefail

# Default download base. Exactly one such line: the site's publish step and the contract tests read it.
SITE_BASE_DEFAULT="https://wpp-jamie-mills.github.io/apptio-mcp-site"

APP_NAME="apptio-mcp"
APP_TITLE="apptio-mcp (Apptio Cloudability for Claude)"
# The mcpServers entry's name in claude_desktop_config.json. Claude Desktop names its log after it.
ENTRY_NAME="cloudability"
# The file that marks an install folder as ours.
MARKER_NAME=".apptio-mcp-home"
# The Keychain item the server keeps the key pair in (apptio_mcp/keychain.py SERVICE and ACCOUNT). --status only
# checks that it is there; it never asks for the secret.
KEYCHAIN_SERVICE="apptio-mcp"
KEYCHAIN_ACCOUNT="key-pair"
# The release files on the site (the CI publishes the same names).
RELEASE_FILE="latest.tar.gz"
RELEASE_SHA_FILE="latest.tar.gz.sha256"
RELEASE_VERSION_FILE="latest.version"
# uv runs the server. When it is missing and you agree (or pass --install-uv), the installer installs it: with
# Homebrew if there is one, else this release from GitHub, hashed before it is unpacked, into ~/.local/bin.
# The same version as CI's setup-uv.
UV_VERSION="0.12.18"
UV_SHA256_AARCH64="cf40e0c6a202190ccd9e0406dcfdd5b2d6668a9a5c779b17948963df32aafe5b"
UV_SHA256_X86_64="2e4108f5395397c8bc5d43bf83d3bdbb2d0e92b90d0efa607756be704905fa33"
# The test overrides, without their APPTIO_INSTALL_ prefix.
OVERRIDE_NAMES="BASE TTY CLAUDE_CONFIG CLAUDE_APP UV_PATH BREW UV_BASE UV_SHA256 NO_OPEN"

# Colour only on a terminal, so agent and CI logs stay plain.
if [[ -t 1 && -t 2 ]]; then
  RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' BLUE='\033[0;34m' NC='\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' NC=''
fi

# printf, not echo -e, so backslashes in paths are shown as typed.
print_error() { printf '%b✗ %s%b\n' "$RED" "$1" "$NC" >&2; }
print_success() { printf '%b✓ %s%b\n' "$GREEN" "$1" "$NC"; }
print_warning() { printf '%b⚠ %s%b\n' "$YELLOW" "$1" "$NC"; }
print_step() { printf '%b→ %s%b\n' "$BLUE" "$1" "$NC"; }
die() {
  print_error "$1"
  exit 1
}

# Run state, set by main.
TMP_DIR=""        # download and scratch folder (never inside the install folder)
BUILD_DIR=""      # the release folder being built; removed if the run stops before the swap
HAVE_TTY=false    # true when answers can be read (from file descriptor 3)
TTY_PATH=""
BASE=""
DIR=""
LAUNCHER=""
CLAUDE_APP="" CFG_PATH="" CFG_PATH_DEFAULT="" CFG_REAL="" CFG_STATE=""
YES=false INSTALL_UV_OK=false ALLOW_DOWNGRADE=false NO_OPEN_FLAG=false DIR_ARG=""
NO_INPUT=false DRY_RUN=false REPLACE_ENTRY=false
LOCK_HELD=false   # true while this run holds $DIR/.lock

cleanup() {
  # BUILD_DIR is only ever a folder this run created (mkdir fails if it exists).
  if [[ -n "$BUILD_DIR" && -d "$BUILD_DIR" ]]; then /bin/rm -rf "$BUILD_DIR"; fi
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then /bin/rm -rf "$TMP_DIR"; fi
  release_lock
}
trap cleanup EXIT
trap 'exit 1' INT TERM HUP

# One install or uninstall at a time per folder: mkdir is atomic, so only one run can create $DIR/.lock. It holds this
# run's process id, so a lock left by a run that was killed outright can be told from a live one.
take_lock() {
  local lock="$DIR/.lock" pid="" tries=0
  while ! mkdir "$lock" 2>/dev/null; do
    pid="$(cat "$lock/pid" 2>/dev/null || true)"
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      die "Another $APP_NAME install or uninstall is running (process $pid), so nothing was changed. Wait for it to finish, then run this again"
    fi
    tries=$((tries + 1))
    # No process id yet: the other run may be between mkdir and writing it, so give it a moment.
    if [[ -z "$pid" && "$tries" -le 5 ]]; then
      sleep 0.2
      continue
    fi
    [[ "$tries" -le 8 ]] || die "Couldn't take the install lock $lock, so nothing was changed. If no install is running, remove that folder and run this again"
    # Stale: its run is gone. rmdir only removes an empty folder, so nothing else is deleted.
    /bin/rm -f "$lock/pid"
    /bin/rmdir "$lock" 2>/dev/null || true
  done
  printf '%s\n' "$$" >"$lock/pid"
  LOCK_HELD=true
}

release_lock() {
  if [[ "$LOCK_HELD" == true ]]; then
    /bin/rm -f "$DIR/.lock/pid"
    /bin/rmdir "$DIR/.lock" 2>/dev/null || true
    LOCK_HELD=false
  fi
}

usage() {
  cat <<'EOF'
apptio-mcp installer (macOS, Claude Desktop)

Usage:
  curl -fsSL https://wpp-jamie-mills.github.io/apptio-mcp-site/install.sh | bash
  curl -fsSL https://wpp-jamie-mills.github.io/apptio-mcp-site/install.sh | bash -s -- --status
  curl -fsSL https://wpp-jamie-mills.github.io/apptio-mcp-site/install.sh | bash -s -- --dry-run --no-input
  curl -fsSL https://wpp-jamie-mills.github.io/apptio-mcp-site/install.sh | bash -s -- --no-input --yes

It downloads the latest release, checks its SHA-256, installs it in ~/.apptio-mcp (using uv and a managed Python),
and adds a "cloudability" entry to Claude Desktop's config (asking first, keeping a backup). Running it again
updates the install and keeps your settings and your Keychain item. It never quits Claude Desktop. The checksum comes
from the same site as the release, so it catches a damaged download, not a compromised site.

With no terminal (or with --no-input) and no --yes it asks nothing and changes nothing.

Options:
  --dir <path>       Install folder (default: ~/.apptio-mcp). It must be new, empty, or an apptio-mcp folder.
                     Use the same folder when you update.
  --status           Print what is installed, the latest version, Claude Desktop's entry, whether the key is
                     stored and setup is complete, and the one step left ("Next:"). Changes nothing; never
                     prints the key.
  --uninstall        Remove the "cloudability" entry (only if it is ours), what the installer put in the install
                     folder (current, versions/, its marker), the cache and the pending setup tokens. The folder
                     itself goes only if the installer made it and nothing else is in it; anything else there is
                     listed and left. Keeps your settings, mapping file and Keychain item, and says how to remove
                     them. Asks first (with no terminal, add --yes). Quit Claude Desktop (⌘Q) first.
  --install-uv       If uv is missing, install it without asking: with Homebrew if there is one, else uv's own
                     release from GitHub (checked against a SHA-256 pinned in this script) into ~/.local/bin.
                     Shell profiles aren't changed; an existing uv is never replaced.
  --allow-downgrade  Install the site's version even though a newer one is installed.
  --no-input         For agents and scripts: never read an answer. Nothing is asked, and nothing changes unless
                     --yes is also given.
  --dry-run          Download the release, check its SHA-256 and version, read Claude Desktop's config, print what
                     a real run would change (including "replace another server's entry") and exit 0. Nothing is
                     changed and nothing is asked.
  --replace-entry    Needed in addition to --yes to replace a "cloudability" entry that runs something else.
                     Without it, --yes stops before changing anything.
  --no-open          Don't open Claude Desktop afterwards (it is only opened when it isn't running).
  --yes              Answer yes to installing, to adding the entry to Claude Desktop's config, and to uninstalling.
                     Installing uv is a separate yes (--install-uv), and so is replacing another server's entry
                     (--replace-entry). With --yes the installer never offers to run the Terminal sign-in.
  --help             Show this help.

Claude Desktop's config is rewritten as JSON (2-space indent). Every other key and server is kept; keys made only
of digits move first, numbers beyond 2^53 lose precision, and a number too big for JavaScript (1e400) becomes null.
A backup (claude_desktop_config.json.bak-<UTC>-<n>,
mode 0600, the 3 newest kept) may hold old keys: remove it when you don't need it.

Test overrides, for the test suite only: APPTIO_INSTALL_BASE, _TTY, _CLAUDE_CONFIG, _CLAUDE_APP, _UV_PATH, _BREW,
_UV_BASE, _UV_SHA256 and _NO_OPEN. Each one in use prints "test override in use: NAME".
EOF
}

# ---- Small helpers ----

lowercase() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Physical path of $1 with symlinks resolved in the part that already exists, so the folder checks can't be dodged
# with symlinks, double slashes or a different spelling.
canonical_path() {
  local path="$1" rest="" dir
  while [[ ! -d "$path" ]]; do
    rest="/${path##*/}$rest"
    path="${path%/*}"
    [[ -n "$path" ]] || path="/"
  done
  dir="$(cd -P "$path" 2>/dev/null && pwd -P)" || return 1
  [[ "$dir" != "/" ]] || dir=""
  printf '%s%s\n' "$dir" "$rest"
}

# SHA-256 of a file, hashed from stdin (shasum escapes odd file names and prefixes the hash with a backslash).
sha256_of() { shasum -a 256 <"$1" | /usr/bin/awk '{ print $1 }'; }

# Prints -1, 0 or 1 for X.Y.Z version $1 compared with $2.
ver_cmp() {
  /usr/bin/awk -v a="$1" -v b="$2" 'BEGIN {
    n = split(a, x, "."); m = split(b, y, ".")
    if (m > n) n = m
    for (i = 1; i <= n; i++) {
      if (x[i] + 0 > y[i] + 0) { print 1; exit }
      if (x[i] + 0 < y[i] + 0) { print -1; exit }
    }
    print 0
  }'
}

is_version() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

# The project version in a pyproject.toml ($1), or nothing.
pyproject_version() {
  [[ -f "$1" && -r "$1" ]] || return 0
  /usr/bin/awk '/^\[/ { in_project = ($0 == "[project]") }
       in_project && /^version[ \t]*=/ { v = $0; gsub(/[ \t"\047]/, "", v); sub(/^version=/, "", v); print v; exit }' "$1" 2>/dev/null || true
}

# A random suffix for names that must be unique.
# (The pipe's tr gets SIGPIPE when head is done; || true keeps pipefail from stopping the script.)
rand_suffix() { printf '%s' "$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 8 || true)"; }

ensure_tmp() {
  [[ -n "$TMP_DIR" ]] || TMP_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/apptio-mcp-install.XXXXXX")" || die "Couldn't create a temporary folder"
}

# Runs a command with a time limit and its stdout in a file: run_limited <seconds> <out file> <command...>.
run_limited() {
  local secs="$1" out="$2" pid ticks=0 rc=0
  shift 2
  "$@" >"$out" 2>/dev/null </dev/null &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [[ "$ticks" -ge $((secs * 5)) ]]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 1
    fi
    sleep 0.2
    ticks=$((ticks + 1))
  done
  wait "$pid" || rc=$?
  return "$rc"
}

# ---- Questions: answers come from the terminal (not stdin, which is the script under curl | bash), on fd 3 ----

can_answer() { [[ "$TTY_PATH" != /dev/null ]] && { : <"$TTY_PATH"; } 2>/dev/null; }

# Opens fd 3 on the terminal once, when there is one.
open_tty() {
  if can_answer && { exec 3<"$TTY_PATH"; } 2>/dev/null; then HAVE_TTY=true; fi
}

ask_yes_no() {
  local reply=""
  [[ "$HAVE_TTY" == true ]] || return 1
  printf '%s [y/N] ' "$1" >&2
  read -r reply <&3 || return 1
  [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# ---- Network: https only, TLS 1.2+, with timeouts; the test bases are the only exceptions ----

# Is $1 an allowed base URL? https always; http://127.0.0.1, http://localhost and file:// only when the override
# named in $2 is in use (a test).
base_allowed() {
  local url="$1" override="$2"
  [[ "$url" == https://* ]] && return 0
  [[ -n "${!override+x}" ]] || return 1
  [[ "$url" == file://* ]] && return 0
  [[ "$url" =~ ^http://(127\.0\.0\.1|localhost)(:[0-9]{1,5})?(/[^@]*)?$ ]]
}

# curl_get <url> <output file> <max seconds>
curl_get() {
  local url="$1" out="$2" max="$3"
  case "$url" in
    https://*)
      curl --proto '=https' --tlsv1.2 --fail --connect-timeout 10 --max-time "$max" --silent --show-error \
        --location --max-redirs 5 --output "$out" "$url"
      ;;
    file://*)
      curl --proto '=file' --fail --connect-timeout 10 --max-time "$max" --silent --show-error --output "$out" "$url"
      ;;
    http://127.0.0.1* | http://localhost*)
      curl --proto '=http' --fail --connect-timeout 10 --max-time "$max" --silent --show-error --output "$out" "$url"
      ;;
    *) return 1 ;;
  esac
}

# The site's latest.version, strict X.Y.Z, at most 64 bytes. Prints it, or nothing. $1 = base, $2 = output file.
fetch_latest_version() {
  local file="$2" line size
  [[ -n "$1" ]] || return 0
  curl_get "$1/$RELEASE_VERSION_FILE" "$file" 10 2>/dev/null || return 0
  size="$(wc -c <"$file" | tr -d ' ')"
  [[ "$size" -le 64 ]] || return 0
  line="$(/usr/bin/awk 'NR == 1 { sub(/[ \t\r]+$/, ""); print }' "$file")"
  if is_version "$line"; then printf '%s\n' "$line"; fi
}

# ---- uv ----

# The uv the server runs with, or nothing: APPTIO_INSTALL_UV_PATH (colon-separated), else uv on PATH and the places
# the launcher looks too. Always succeeds.
find_uv() {
  local candidates=() candidate
  if [[ -n "${APPTIO_INSTALL_UV_PATH+set}" ]]; then
    IFS=: read -r -a candidates <<<"$APPTIO_INSTALL_UV_PATH"
  else
    candidates=("$(command -v uv 2>/dev/null || true)" /opt/homebrew/bin/uv /usr/local/bin/uv "${HOME%/}/.local/bin/uv")
  fi
  [[ ${#candidates[@]} -gt 0 ]] || return 0
  for candidate in "${candidates[@]}"; do
    if [[ -n "$candidate" && -f "$candidate" && -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 0
}

# Homebrew's brew, or nothing. Always succeeds.
find_brew() {
  local candidate
  if [[ -n "${APPTIO_INSTALL_BREW+set}" ]]; then
    if [[ -n "$APPTIO_INSTALL_BREW" && -x "$APPTIO_INSTALL_BREW" ]]; then printf '%s\n' "$APPTIO_INSTALL_BREW"; fi
    return 0
  fi
  for candidate in "$(command -v brew 2>/dev/null || true)" /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 0
}

# How install_uv would install uv, in words that follow "install uv" in the question and the refusal.
uv_install_how() {
  if [[ -n "$(find_brew)" ]]; then
    echo "with Homebrew (brew install uv)"
  else
    echo "from its GitHub release (version $UV_VERSION, checked against its SHA-256) into ~/.local/bin"
  fi
}

# Installs uv (only after you agreed, or --install-uv): Homebrew if there is one, else the pinned release, hashed
# before anything is unpacked. Never changes a shell profile and never replaces a uv that is there.
install_uv() {
  local brew arch expected name url tmp actual bin="${HOME%/}/.local/bin" uv_base
  brew="$(find_brew)"
  if [[ -n "$brew" ]]; then
    print_step "Installing uv with Homebrew (brew install uv)..."
    "$brew" install uv || {
      print_error "brew install uv failed (its output is above)"
      return 1
    }
    return 0
  fi
  case "$(uname -m)" in
    arm64 | aarch64) arch=aarch64 expected="$UV_SHA256_AARCH64" ;;
    x86_64) arch=x86_64 expected="$UV_SHA256_X86_64" ;;
    *)
      print_error "uv has no release for this Mac's processor ($(uname -m))"
      return 1
      ;;
  esac
  [[ -z "${APPTIO_INSTALL_UV_SHA256:-}" ]] || expected="$APPTIO_INSTALL_UV_SHA256"
  name="uv-$arch-apple-darwin"
  uv_base="${APPTIO_INSTALL_UV_BASE:-https://github.com/astral-sh/uv/releases/download/$UV_VERSION}"
  base_allowed "$uv_base" APPTIO_INSTALL_UV_BASE || {
    print_error "APPTIO_INSTALL_UV_BASE must be https, http://127.0.0.1, http://localhost or file://"
    return 1
  }
  url="${uv_base%/}/$name.tar.gz"
  print_step "Installing uv $UV_VERSION from its GitHub release into ~/.local/bin..."
  ensure_tmp
  tmp="$(/usr/bin/mktemp -d "$TMP_DIR/uv.XXXXXX")" || return 1
  if ! curl_get "$url" "$tmp/uv.tar.gz" 300; then
    print_error "Download failed: $url"
    return 1
  fi
  actual="$(sha256_of "$tmp/uv.tar.gz")"
  if [[ "$actual" != "$expected" ]]; then
    print_error "uv's checksum doesn't match, so uv wasn't installed"
    print_error "Expected: $expected"
    print_error "Got:      $actual"
    return 1
  fi
  if ! /usr/bin/tar -xzf "$tmp/uv.tar.gz" -C "$tmp" "$name/uv" 2>/dev/null || [[ ! -f "$tmp/$name/uv" ]]; then
    print_error "uv's release didn't hold $name/uv"
    return 1
  fi
  if [[ -e "$bin/uv" ]]; then
    print_error "$bin/uv is there already but can't be run; leaving it alone"
    return 1
  fi
  if ! { mkdir -p "$bin" && install -m 755 "$tmp/$name/uv" "$bin/.uv.$$" && /bin/mv -f "$bin/.uv.$$" "$bin/uv"; }; then
    /bin/rm -f "$bin/.uv.$$"
    print_error "Couldn't put uv in $bin"
    return 1
  fi
  print_success "Installed uv $UV_VERSION in $bin (your shell profiles weren't changed)"
}

# ---- Claude Desktop's config ----

# Whether a file can be read: "ok", "missing" (provably not there) or "unreadable" (there, or perhaps there, behind a
# folder or link that can't be read). Follows links (at most 20). Always succeeds.
probe() {
  local p="$1" n="${2:-0}" t parent up
  if [[ -e "$p" ]]; then
    if [[ -d "$p" ]]; then
      if [[ -r "$p" && -x "$p" ]]; then echo ok; else echo unreadable; fi
    elif [[ -r "$p" ]]; then
      echo ok
    else
      echo unreadable
    fi
    return 0
  fi
  if [[ -L "$p" ]]; then
    if [[ "$n" -ge 20 ]] || ! t="$(readlink "$p" 2>/dev/null)"; then
      echo unreadable
      return 0
    fi
    [[ "$t" == /* ]] || t="${p%/*}/$t"
    probe "$t" $((n + 1))
    return 0
  fi
  parent="${p%/*}"
  [[ -n "$parent" ]] || parent=/
  if [[ "$parent" == "$p" ]]; then
    echo missing
    return 0
  fi
  if [[ -d "$parent" && -x "$parent" ]]; then
    echo missing
    return 0
  fi
  up="$(probe "$parent" "$n")"
  if [[ "$up" == missing || ("$up" == ok && ! -d "$parent") ]]; then echo missing; else echo unreadable; fi
}

# The config followed through symbolic links (a dotfile manager's, say; at most 20 hops), so it is read and changed
# where it really is and the link stays. Prints the real file's path and succeeds; or prints the link where it
# stopped and fails, for a loop, more than 20 links, or a link to nothing (changing it would turn a link into a file
# or create files where the link points).
config_target() {
  local p="$1" t n=0
  while [[ -L "$p" ]]; do
    if [[ "$n" -ge 20 ]] || ! t="$(readlink "$p")"; then
      printf '%s\n' "$p"
      return 1
    fi
    [[ "$t" == /* ]] || t="$(dirname "$p")/$t"
    p="$t"
    n=$((n + 1))
  done
  printf '%s\n' "$p"
  if [[ "$n" -gt 0 && ! -e "$p" ]]; then return 1; fi
  return 0
}

# Reads or changes the entry in Claude Desktop's config, with JavaScript for Automation (no jq, node or python).
# Every value reaches the script through run(argv), never pasted into its text.
#   entry_config state   <config> <launcher>   -> missing | unreadable | encoding (not UTF-8) | invalid | none | ours |
#                                                 other | error
#   entry_config inspect <config> <launcher>   -> lines: command=<path, for an entry that isn't ours>, drop=<NAME>:
#                                                 every env name of an entry that isn't ours (replacing it drops them
#                                                 all), only the APPTIO_*KEY names of ours
#   entry_config env     <config> <launcher>   -> lines NAME=value of our entry's env (never an APPTIO_*KEY)
#   entry_config add     <config> <launcher> <env JSON> <out>
#   entry_config remove  <config> <launcher> <out>
#     -> changed (the whole new file is in <out>) | unchanged | invalid | unreadable | encoding | other (remove leaves an entry
#        that isn't ours alone) | error
# "ours" means the entry's command is exactly <launcher>. add puts a new entry, or replaces one that isn't ours,
# with {command, args: [], env}; every other key and server is kept. JSON.parse and JSON.stringify keep keys in order
# except that keys made only of digits move first, and numbers beyond 2^53 lose precision.
entry_config() {
  osascript -l JavaScript - "$ENTRY_NAME" "$@" <<'JXA' 2>/dev/null || echo error
ObjC.import("Foundation");
const isObject = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
const clean = (s) => String(s).replace(/[\u0000-\u001f\u007f]/g, "?").slice(0, 300);
function run(argv) {
  const [name, action, path, launcher] = argv;
  let config = {};
  if ($.NSFileManager.defaultManager.fileExistsAtPath(path)) {
    const data = $.NSData.dataWithContentsOfFile(path);
    if (data.isNil()) return "unreadable";
    const text = $.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding);
    if (text.isNil()) return "encoding";
    try {
      config = JSON.parse(text.js);
    } catch (e) {
      return "invalid";
    }
    if (!isObject(config)) return "invalid";
  } else if (action === "state") {
    return "missing";
  }
  if (config.mcpServers !== undefined && !isObject(config.mcpServers)) return "invalid";
  const servers = config.mcpServers || {};
  const entry = servers[name];
  const ours = isObject(entry) && entry.command === launcher;
  if (action === "state") return entry === undefined ? "none" : ours ? "ours" : "other";
  const keyName = /^APPTIO_.*KEY$/;
  const envOf = (e) => (isObject(e) && isObject(e.env) ? e.env : {});
  if (action === "inspect") {
    const lines = [];
    if (entry !== undefined && !ours) {
      lines.push("command=" + (isObject(entry) && typeof entry.command === "string" ? clean(entry.command) : "(not a path)"));
    }
    Object.keys(envOf(entry)).filter((k) => !ours || keyName.test(k)).forEach((k) => lines.push("drop=" + clean(k)));
    return lines.join("\n");
  }
  if (action === "env") {
    if (!ours) return "";
    const env = envOf(entry);
    return Object.keys(env)
      .filter((k) => /^[A-Za-z_][A-Za-z0-9_]*$/.test(k) && !keyName.test(k) && typeof env[k] === "string" && env[k].indexOf("\n") < 0)
      .map((k) => k + "=" + env[k])
      .join("\n");
  }
  let out;
  if (action === "remove") {
    if (entry === undefined) return "unchanged";
    if (!ours) return "other";
    delete servers[name];
    out = argv[4];
  } else if (action === "add") {
    if (ours) return "unchanged";
    servers[name] = { command: launcher, args: [], env: JSON.parse(argv[4]) };
    config.mcpServers = servers;
    out = argv[5];
  } else {
    return "error";
  }
  const ok = $(JSON.stringify(config, null, 2) + "\n").writeToFileAtomicallyEncodingError(
    out,
    false,
    $.NSUTF8StringEncoding,
    null,
  );
  return ok ? "changed" : "error";
}
JXA
}

# Sets CFG_PATH (the file Claude Desktop reads), CFG_REAL (where it really is) and CFG_STATE: ours, other, none,
# missing, invalid, unreadable, encoding (not UTF-8) or link (dangling or looping).
resolve_config() {
  CFG_PATH="$CFG_PATH_DEFAULT"
  if CFG_REAL="$(config_target "$CFG_PATH")"; then
    case "$(probe "$CFG_REAL")" in
      missing) CFG_STATE=missing ;;
      unreadable) CFG_STATE=unreadable ;;
      *) CFG_STATE="$(entry_config state "$CFG_REAL" "$LAUNCHER")" ;;
    esac
    [[ "$CFG_STATE" != error ]] || CFG_STATE=unreadable
  else
    CFG_STATE="link"
  fi
}

# Prints why the real config file ($1) can't be changed (read-only, or its immutable flag is set), or nothing.
config_locked_reason() {
  local flags
  [[ -f "$1" ]] || return 0
  if [[ ! -w "$1" ]]; then
    echo "it is read-only"
    return 0
  fi
  flags="$(/usr/bin/stat -f '%Sf' "$1" 2>/dev/null || true)"
  case ",$flags," in *,uchg,* | *,schg,* | *,uappnd,* | *,sappnd,*) echo "it is locked (flags: $flags)" ;; esac
  return 0
}

# Why the config can't be used, for messages. $1 = its state.
config_problem() {
  case "$1" in
    invalid) echo "Claude Desktop's config can't be read as JSON" ;;
    encoding) echo "Claude Desktop's config isn't UTF-8 text, so it can't be read safely" ;;
    link) echo "Claude Desktop's config is a link that can't be followed (a loop, more than 20 links in a row, or a link to nothing)" ;;
    *) echo "Claude Desktop's config can't be read (check its permissions, and its folder's)" ;;
  esac
}

# A string as a JSON string literal.
json_string() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  printf '"%s"' "$s"
}

# The PATH a new entry gets (D16): uv's folder ($1) first, then the folders Claude Desktop doesn't add itself.
entry_path() {
  local d out="" seen=":"
  for d in "$1" /opt/homebrew/bin /usr/local/bin /usr/bin /bin /usr/sbin /sbin; do
    [[ -n "$d" && "$seen" != *":$d:"* ]] || continue
    out="${out:+$out:}$d"
    seen="$seen$d:"
  done
  printf '%s\n' "$out"
}

# A new entry's env as JSON (D16). It never holds an APPTIO_* value. $1 = uv's folder.
entry_env_json() {
  printf '{ "MCP_RUN_MODE": "config", "PATH": %s }\n' "$(json_string "$(entry_path "$1")")"
}

# The config's backups, newest name first (names carry a UTC time, then a random part). $1 = the real config file.
list_backups() {
  local f
  for f in "$1".bak-[0-9]*T[0-9]*Z-*; do
    [[ -f "$f" ]] && printf '%s\n' "$f"
  done | sort -r
  return 0
}

# Makes a backup of the real config ($1): a unique .bak-<UTC>-<random>, filled with cat (not cp -p, which would copy
# an immutable flag onto the backup), mode 600, keeping the 3 newest (the new one always stays). Prints its path.
backup_config() {
  local cfg="$1" bak old kept=0
  bak="$(/usr/bin/mktemp "$cfg.bak-$(/bin/date -u '+%Y%m%dT%H%M%SZ')-XXXXXX")" || return 1
  if ! cat "$cfg" >"$bak" || ! chmod 600 "$bak"; then
    /bin/rm -f "$bak"
    return 1
  fi
  while IFS= read -r old; do
    [[ -n "$old" && "$old" != "$bak" ]] || continue
    kept=$((kept + 1))
    if [[ "$kept" -gt 2 ]]; then /bin/rm -f "$old"; fi
  done <<<"$(list_backups "$cfg")"
  printf '%s\n' "$bak"
}

# Adds or removes our entry ($1 = add | remove) safely. Under umask 077: the new file is written beside the real
# config ($CFG_REAL), re-read to check its state is what we wanted, and renamed over the config, keeping its mode
# (0600 for a new file), after a backup. $2 = the new entry's env JSON (add). Prints the backup's path, if any.
write_config() {
  local action="$1" env_json="${2:-}" cfg="$CFG_REAL" dir new result want backup="" mode=600 old_umask
  old_umask="$(umask)"
  umask 077
  dir="$(dirname "$cfg")"
  if ! mkdir -p "$dir" || ! new="$(/usr/bin/mktemp "$dir/.claude_desktop_config.json.apptio-mcp.XXXXXX")"; then
    umask "$old_umask"
    print_error "Couldn't write beside $cfg; it wasn't changed"
    return 1
  fi
  if [[ "$action" == add ]]; then
    result="$(entry_config add "$cfg" "$LAUNCHER" "$env_json" "$new")"
    want=ours
  else
    result="$(entry_config remove "$cfg" "$LAUNCHER" "$new")"
    want=none
  fi
  if [[ "$result" == unchanged ]]; then
    # Already as wanted (another run got there first, or the entry was never there): nothing to write.
    /bin/rm -f "$new"
    umask "$old_umask"
    printf '\n'
    return 0
  fi
  if [[ "$result" != changed || "$(entry_config state "$new" "$LAUNCHER")" != "$want" ]]; then
    /bin/rm -f "$new"
    umask "$old_umask"
    print_error "Couldn't prepare the new config ($result); $cfg wasn't changed"
    return 1
  fi
  if [[ -f "$cfg" ]]; then
    if ! mode="$(/usr/bin/stat -L -f '%Lp' "$cfg")" || ! backup="$(backup_config "$cfg")"; then
      /bin/rm -f "$new"
      umask "$old_umask"
      print_error "Couldn't back up $cfg; it wasn't changed"
      return 1
    fi
  fi
  if ! chmod "$mode" "$new" || ! /bin/mv -f "$new" "$cfg"; then
    /bin/rm -f "$new"
    umask "$old_umask"
    print_error "Couldn't write $cfg${backup:+ (its backup: $backup)}"
    return 1
  fi
  umask "$old_umask"
  printf '%s\n' "$backup"
}

# The entry as JSON, for adding it by hand. $1 = the env JSON.
print_entry_by_hand() {
  echo "To add it yourself: back up $CFG_PATH, put this inside its \"mcpServers\" object, then quit and reopen"
  echo "Claude Desktop:"
  echo ""
  echo "  $(json_string "$ENTRY_NAME"): {"
  echo "    \"command\": $(json_string "$LAUNCHER"),"
  echo "    \"args\": [],"
  echo "    \"env\": $1"
  echo "  }"
  echo ""
  echo "For Claude Code instead: claude mcp add --scope user $ENTRY_NAME -- $(q_launcher)"
}

# ---- The install folder and versions ----

# The version installed (from current/pyproject.toml), or nothing.
installed_version() {
  local v
  v="$(pyproject_version "$DIR/current/pyproject.toml")"
  if is_version "$v"; then printf '%s\n' "$v"; fi
}

# Resolves and checks the install folder: absolute, no . or .. segments, not $HOME or above it, not a system
# location, symlinks resolved. Sets DIR (as spelt, ~ expanded).
resolve_dir() {
  local dir="$DIR_ARG" canon canon_home canon_p p user_tmp
  [[ -n "$dir" ]] || dir="${HOME%/}/.apptio-mcp"
  if [[ "$dir" == \~ || "$dir" == \~/* ]]; then dir="$HOME${dir:1}"; fi
  dir="${dir%/}"
  [[ "$dir" == /* ]] || die "The install folder must be an absolute path: $dir"
  case "/$dir/" in */../* | */./*) die "The install folder can't contain . or .. parts: $dir" ;; esac
  canon="$(canonical_path "$dir")" || die "Can't resolve the install folder: $dir"
  canon="$(lowercase "$canon")"
  canon_home="$(canonical_path "$HOME")" || die "Can't resolve your home folder"
  canon_home="$(lowercase "$canon_home")"
  [[ "$canon" != "$canon_home" ]] || die "Your home folder itself can't be the install folder"
  [[ "$canon_home/" != "$canon/"* ]] || die "The install folder can't be a folder that holds your home folder: $dir"
  user_tmp="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)"
  if [[ -n "$user_tmp" ]]; then
    user_tmp="$(canonical_path "${user_tmp%/}")" || user_tmp=""
    user_tmp="$(lowercase "$user_tmp")"
  fi
  if [[ -z "$user_tmp" || "$user_tmp" == "/" || ("$canon" != "$user_tmp" && "$canon" != "$user_tmp/"*) ]]; then
    for p in /Applications /System /Library /usr /bin /sbin /etc /private/etc /var /opt; do
      [[ -d "$p" ]] || continue
      canon_p="$(canonical_path "$p")" || continue
      canon_p="$(lowercase "$canon_p")"
      if [[ "$canon" == "$canon_p" || "$canon" == "$canon_p/"* ]]; then die "The install folder can't be in a system location: $dir"; fi
    done
  fi
  DIR="$dir"
  LAUNCHER="$DIR/current/bin/$APP_NAME"
}

# The folder must be new, empty, or ours; `current` must be a link. Dies otherwise. Changes nothing.
check_folder() {
  if [[ -e "$DIR" && ! -d "$DIR" ]]; then die "Not a folder: $DIR"; fi
  if [[ -d "$DIR" ]]; then
    if [[ ! -e "$DIR/$MARKER_NAME" && -n "$(/usr/bin/find "$DIR" -mindepth 1 -maxdepth 1 ! -name .DS_Store ! -name .lock 2>/dev/null)" ]]; then
      die "That folder isn't empty and isn't an $APP_NAME install folder, so nothing was changed: $DIR"
    fi
    [[ -w "$DIR" ]] || die "That folder isn't writable: $DIR"
    if [[ -e "$DIR/current" && ! -L "$DIR/current" ]]; then
      die "$DIR/current is not a link, so nothing was changed. Remove it or use another folder"
    fi
    if [[ -L "$DIR/versions" ]]; then die "$DIR/versions is a link; leaving it alone, so nothing was changed"; fi
  fi
}

# Is a version folder's tree in use by a running process? $1 = its folder name. The launcher resolves its own folder
# with pwd -P, so a running server's command line holds the physical path: look for that and the spelling in DIR.
version_in_use() {
  local spelling physical="" pattern
  spelling="$DIR/versions/$1/"
  physical="$(cd -P "$DIR" 2>/dev/null && pwd -P)" || physical=""
  for pattern in "$spelling" ${physical:+"$physical/versions/$1/"}; do
    pattern="$(printf '%s' "$pattern" | /usr/bin/sed 's/[][\.*^$(){}?+|]/\\&/g')"
    if pgrep -f "$pattern" >/dev/null 2>&1; then return 0; fi
  done
  return 1
}

# The numeric X.Y.Z at the start of a version folder's name, or nothing.
folder_version() {
  if [[ "$1" =~ ^([0-9]+\.[0-9]+\.[0-9]+) ]]; then printf '%s\n' "${BASH_REMATCH[1]}"; fi
}

# Prunes versions/ to the new folder ($1, version $2), the rollback and any folder a running process still uses
# (pgrep -f). The rollback is the folder `current` pointed to before the swap ($3; after a repair that is the repaired
# copy, not the older tree it replaced), else the newest other version. Everything else (older copies, leftovers) goes.
prune_versions() {
  local keep_name="$1" keep_ver="$2" old_name="${3:-}" n v previous="" previous_ver=""
  if [[ -n "$old_name" && "$old_name" != "$keep_name" && -d "$DIR/versions/$old_name" ]]; then previous="$old_name"; fi
  if [[ -z "$previous" ]]; then
    for n in "$DIR/versions"/*; do
      [[ -d "$n" ]] || continue
      n="${n##*/}"
      [[ "$n" != "$keep_name" ]] || continue
      v="$(folder_version "$n")"
      [[ -n "$v" && "$v" != "$keep_ver" ]] || continue
      if [[ -z "$previous_ver" || "$(ver_cmp "$v" "$previous_ver")" -gt 0 ]]; then
        previous="$n" previous_ver="$v"
      fi
    done
  fi
  for n in "$DIR/versions"/*; do
    [[ -d "$n" ]] || continue
    n="${n##*/}"
    [[ "$n" != "$keep_name" && "$n" != "$previous" ]] || continue
    if version_in_use "$n"; then continue; fi
    /bin/rm -rf "${DIR:?}/versions/${n:?}"
  done
}

# Unpacks the release ($1) into the build folder and checks that it holds the launcher. $2 = tar's
# --strip-components count.
unpack_release() {
  /usr/bin/tar -xzf "$1" -C "$BUILD_DIR" --strip-components="$2" || return 1
  [[ -f "$BUILD_DIR/pyproject.toml" && -f "$BUILD_DIR/bin/$APP_NAME" ]] || return 1
  chmod 755 "$BUILD_DIR/bin/$APP_NAME"
}

# Installs the release: builds the folder where it will live (a venv can't be moved, because its scripts and the
# editable install hold absolute paths), then swaps `current` to it per D17. $1 = the tarball, $2 = strip count,
# $3 = version, $4 = uv.
install_release() {
  local tarball="$1" strip="$2" version="$3" uv="$4" versions="$DIR/versions" name old_name="" created=no
  # A folder that was there already keeps its mode: only a folder this run creates is made private (0700).
  if [[ ! -d "$DIR" ]]; then
    mkdir -p "$DIR" && chmod 700 "$DIR" || die "Couldn't create $DIR"
    created=yes
  fi
  take_lock
  # The marker says whether this run made the folder, so --uninstall knows whether it may remove the folder itself.
  if [[ ! -e "$DIR/$MARKER_NAME" ]]; then printf 'created=%s\n' "$created" >"$DIR/$MARKER_NAME" || die "Couldn't write in $DIR"; fi
  mkdir -p "$versions" || die "Couldn't create $versions"
  if [[ -L "$DIR/current" ]]; then old_name="$(basename "$(readlink "$DIR/current")")"; fi
  # Where the release is built: the venv can't be moved afterwards (its scripts hold absolute paths), so it is built
  # where it will live, in a folder only this run creates (mkdir fails if the name is taken). The clean name when it is
  # free, else a name of its own (a repair, a leftover of a killed run, a version still in use). Nothing already there
  # is deleted before the swap, and the lock keeps another run from building beside this one. An old folder that is
  # no longer wanted is removed by prune_versions, after the swap.
  name="$version"
  if [[ -e "$versions/$name" || -L "$versions/$name" ]]; then name="$version.r-$(rand_suffix)"; fi
  BUILD_DIR="$versions/$name"
  mkdir "$BUILD_DIR" || {
    BUILD_DIR=""
    die "Couldn't create $versions/$name"
  }
  print_step "Unpacking $APP_NAME $version..."
  if ! unpack_release "$tarball" "$strip"; then
    /bin/rm -rf "$BUILD_DIR"
    BUILD_DIR=""
    die "The release couldn't be unpacked, so nothing was changed"
  fi
  # A managed Python, so a Homebrew upgrade can't break the venv; then the locked dependencies. Both inside the
  # folder that will be live.
  print_step "Installing Python and the dependencies with uv (the first time can take a minute)..."
  if ! (cd "$BUILD_DIR" && env -u VIRTUAL_ENV -u UV_PROJECT_ENVIRONMENT UV_PYTHON_PREFERENCE=only-managed "$uv" python install) ||
    ! (cd "$BUILD_DIR" && env -u VIRTUAL_ENV -u UV_PROJECT_ENVIRONMENT UV_PYTHON_PREFERENCE=only-managed "$uv" sync --frozen --quiet); then
    /bin/rm -rf "$BUILD_DIR"
    BUILD_DIR=""
    die "uv couldn't set up Python or the dependencies (its output is above). The new folder was removed and the existing install, if any, was left as it was"
  fi
  # The swap (D17): absolute paths, because GNU mv rejects -h; a leftover current.new goes first.
  if [[ -d "$DIR/current.new" && ! -L "$DIR/current.new" ]]; then /bin/rm -rf "$DIR/current.new"; fi
  /bin/rm -f "$DIR/current.new"
  /bin/ln -s "versions/$name" "$DIR/current.new" && /bin/mv -fh "$DIR/current.new" "$DIR/current" ||
    die "Couldn't switch $DIR/current to versions/$name; the existing install was left as it was"
  BUILD_DIR=""
  prune_versions "$name" "$version" "$old_name"
}

# ---- The questions and the work: install ----

claude_running() { pgrep -x Claude >/dev/null 2>&1; }

# Claude Desktop is usually in /Applications; a Mac user without admin rights may have it in ~/Applications.
find_claude_app() {
  local alt="${HOME%/}/Applications/${CLAUDE_APP##*/}"
  if [[ ! -d "$CLAUDE_APP" && -d "$alt" ]]; then CLAUDE_APP="$alt"; fi
  return 0
}

claude_version() { /usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$1/Contents/Info.plist" 2>/dev/null || true; }

# This installer's own command, for messages: the site, --dir when it isn't the default, then the flags given ($@).
# With any flag it is `bash -s -- <flags>`, the form that passes them to the script.
install_cmd() {
  local q_dir flags="" f
  for f in "$@"; do flags="$flags $f"; done
  if [[ -n "$DIR_ARG" ]]; then
    printf -v q_dir '%q' "$DIR"
    flags=" --dir $q_dir$flags"
  fi
  if [[ -n "$flags" ]]; then
    printf '%s\n' "curl -fsSL $BASE/install.sh | bash -s --$flags"
  else
    printf '%s\n' "curl -fsSL $BASE/install.sh | bash"
  fi
}

# The launcher's path, quoted for a shell, for the commands this prints.
q_launcher() {
  local q
  printf -v q '%q' "$LAUNCHER"
  printf '%s\n' "$q"
}

# Prints the entry's env as NAME=value lines to run the launcher with, one per line. For our entry, its own env;
# else the D16 default for uv's folder $1.
launcher_env_lines() {
  local lines=""
  if [[ "$CFG_STATE" == ours ]]; then lines="$(entry_config env "$CFG_REAL" "$LAUNCHER")"; fi
  if [[ -z "$lines" || "$lines" == error ]]; then
    lines="MCP_RUN_MODE=config
PATH=$(entry_path "$1")"
  fi
  printf '%s\n' "$lines"
}

# Runs the launcher with the entry's env: launcher_run <uv folder> <seconds> <out file> <args...>
launcher_run() {
  local uvdir="$1" secs="$2" out="$3" line env_args=()
  shift 3
  while IFS= read -r line; do
    [[ -n "$line" ]] && env_args+=("$line")
  done <<<"$(launcher_env_lines "$uvdir")"
  run_limited "$secs" "$out" env ${env_args[@]+"${env_args[@]}"} "$LAUNCHER" "$@"
}

print_next_steps() {
  local launcher_q example_q
  launcher_q="$(q_launcher)"
  printf -v example_q '%q' "$DIR/current/examples/mapping.example.csv"
  echo ""
  echo "Next steps:"
  echo "  1. Start a new chat in Claude Desktop and ask about cloud spend, for example \"give me a Cloudability summary\"."
  echo "  2. The setup card opens. It asks for your Apptio key pair and environment ID, and shows the defaults for the"
  echo "     Frontdoor URL and region to review. The key goes to your macOS Keychain only."
  echo "  3. After you save in the card, send any message in the chat (the card's prefilled one will do)."
  echo "  4. For spend questions, import a mapping file once (the format is on the site; an example is $example_q):"
  echo "       $launcher_q mapping import <file>"
  echo "  5. Permissions: in Claude Desktop open Customize > Connectors > $ENTRY_NAME. Tools ask \"Allow once\" until you"
  echo "     choose Always allow, and the card needs Interactive tools on. Your organisation's policy may limit these."
  echo "     Start a new chat after reopening."
  echo "  Check any time with: $(install_cmd --status)"
  echo "  (To enter the key in Terminal instead of the card: $launcher_q login)"
}

# The dry run's report: what a real run would do, from the state read so far. Changes nothing.
print_dry_run() {
  local action="$1" installed="$2" latest="$3" need_uv="$4" how="$5" desktop="$6" add_entry="$7" replace_other="$8"
  local other_cmd="$9" drop_names="${10}"
  echo ""
  echo "Dry run: nothing was changed. A real run would:"
  case "$action" in
    install) echo "  - install $APP_NAME $latest in $DIR" ;;
    repair) echo "  - repair $APP_NAME $installed in $DIR (build a fresh copy beside it, then switch)" ;;
    update) echo "  - update $APP_NAME from $installed to $latest in $DIR" ;;
    *) echo "  - install $APP_NAME $latest in $DIR, in place of $installed (--allow-downgrade)" ;;
  esac
  if [[ "$need_uv" == true ]]; then
    echo "  - install uv $how (only with --install-uv)"
  fi
  if [[ "$desktop" != true ]]; then
    echo "  - skip the $ENTRY_NAME entry: Claude Desktop wasn't found"
  elif [[ "$replace_other" == true ]]; then
    echo "  - replace another server's $ENTRY_NAME entry (it runs: ${other_cmd:-(unknown)}) with $APP_NAME in $CFG_PATH, after a backup"
    [[ -z "$drop_names" ]] || echo "    Replacing it drops its env, which holds: $drop_names (names only)."
    echo "    This needs --replace-entry in addition to --yes."
  elif [[ "$add_entry" == true ]]; then
    echo "  - add the $ENTRY_NAME entry to $CFG_PATH, after a backup"
  else
    echo "  - leave the $ENTRY_NAME entry in $CFG_PATH as it is (it already runs this install)"
  fi
  echo "  - open Claude Desktop if it isn't running (never quit it)"
  echo "To go ahead, with the owner's go-ahead: $(install_cmd --no-input --yes)"
}

do_install() {
  local tool uv uv_dir="" need_uv=false app_version="" desktop=false latest installed cmp action
  local replace_other=false add_entry=false cfg_inspect="" other_cmd="" drop_names="" line how="" question entry_q
  local was_running=false locked
  print_step "Installing $APP_TITLE"
  # 1. Check.
  [[ "$(uname -s)" == Darwin ]] || die "This installer is for macOS"
  for tool in curl awk osascript open security shasum; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool isn't available"
  done
  [[ -n "$BASE" ]] || die "There is no site to install from, so nothing was changed"
  ensure_tmp
  latest="$(fetch_latest_version "$BASE" "$TMP_DIR/latest.version")"
  [[ -n "$latest" ]] || die "Couldn't read a version (X.Y.Z) from $BASE/$RELEASE_VERSION_FILE, so nothing was changed"
  if [[ -d "$CLAUDE_APP" ]]; then
    desktop=true
    app_version="$(claude_version "$CLAUDE_APP")"
    print_success "macOS and Claude Desktop ${app_version:-found}"
  elif [[ -d "$(dirname "$CFG_PATH_DEFAULT")" ]]; then
    # Its config folder is there: Desktop is installed somewhere this installer doesn't look.
    desktop=true
    print_success "macOS and Claude Desktop (its config folder is there; the app wasn't found at $CLAUDE_APP)"
  else
    print_warning "Claude Desktop isn't at $CLAUDE_APP. The server will be installed, but the $ENTRY_NAME entry will be skipped."
  fi
  # 2. Compare.
  check_folder
  installed="$(installed_version)"
  action=install
  if [[ -n "$installed" ]]; then
    cmp="$(ver_cmp "$latest" "$installed")"
    if [[ "$cmp" == 0 ]]; then
      action=repair
      print_step "$APP_NAME $installed is already installed; this repairs it."
    elif [[ "$cmp" == -1 ]]; then
      if [[ "$ALLOW_DOWNGRADE" != true ]]; then
        die "$APP_NAME $installed is installed and the site has the older $latest, so nothing was changed. To go back anyway, with the owner's go-ahead, add --allow-downgrade"
      fi
      action=downgrade
      print_warning "Going back from $installed to $latest (--allow-downgrade)."
    else
      action=update
      print_step "Updating $APP_NAME from $installed to $latest."
    fi
  fi
  # 3. uv.
  uv="$(find_uv)"
  if [[ -z "$uv" ]]; then
    how="$(uv_install_how)"
    print_warning "uv isn't installed, and $APP_NAME runs with it."
    need_uv=true
  else
    uv_dir="$(dirname "$uv")"
    print_success "uv: $uv"
  fi
  # 4. Claude Desktop's config.
  resolve_config
  if [[ "$desktop" == true ]]; then
    case "$CFG_STATE" in
      invalid | unreadable | encoding | link)
        die "$(config_problem "$CFG_STATE") ($CFG_PATH), so nothing was changed. Fix it, then run this again"
        ;;
      none | missing | other | ours)
        locked="$(config_locked_reason "$CFG_REAL")"
        if [[ -n "$locked" && "$CFG_STATE" != ours ]]; then
          die "Claude Desktop's config ($CFG_PATH) can't be changed: $locked. Nothing was changed. Change that yourself (for example chmod u+w, or chflags nouchg), then run this again"
        fi
        ;;
    esac
    case "$CFG_STATE" in
      none | missing) add_entry=true ;;
      other)
        add_entry=true
        replace_other=true
        cfg_inspect="$(entry_config inspect "$CFG_REAL" "$LAUNCHER")"
        while IFS= read -r line; do
          case "$line" in
            command=*) other_cmd="${line#command=}" ;;
            drop=*) drop_names="${drop_names:+$drop_names, }${line#drop=}" ;;
          esac
        done <<<"$cfg_inspect"
        ;;
    esac
  fi
  # 5. Questions: all of them, before any change. A dry run asks nothing.
  if [[ "$DRY_RUN" != true ]]; then
    if [[ "$YES" != true ]]; then
      if [[ "$HAVE_TTY" != true ]]; then
        if [[ "$need_uv" == true ]]; then
          die "Nothing was changed: there is no terminal to ask on. With the owner's go-ahead, run again with --yes --install-uv (installs uv $how)"
        fi
        die "Nothing was changed: there is no terminal to ask on. With the owner's go-ahead, run again with --yes"
      fi
      case "$action" in
        install) question="Install $APP_NAME $latest in $DIR?" ;;
        repair) question="Repair $APP_NAME $latest in $DIR?" ;;
        update) question="Update $APP_NAME from $installed to $latest in $DIR?" ;;
        *) question="Install $APP_NAME $latest in $DIR, in place of $installed?" ;;
      esac
      ask_yes_no "$question" || die "Nothing was changed."
    fi
    if [[ "$need_uv" == true && "$INSTALL_UV_OK" != true ]]; then
      if [[ "$HAVE_TTY" == true ]] && ask_yes_no "Install uv now, $how?"; then
        INSTALL_UV_OK=true
      elif [[ "$HAVE_TTY" == true ]]; then
        die "uv wasn't installed, so nothing was changed. Install it yourself (brew install uv, or see https://docs.astral.sh/uv/getting-started/installation/), then run this again"
      else
        die "Nothing was changed. With the owner's go-ahead, run this again with --install-uv to install uv $how; or install it yourself (brew install uv)"
      fi
    fi
    if [[ "$add_entry" == true ]]; then
      if [[ "$replace_other" == true ]]; then
        echo "Claude Desktop already has an entry named '$ENTRY_NAME' that runs something else: ${other_cmd:-(unknown)}"
        [[ -z "$drop_names" ]] || echo "Replacing it drops its env, which holds: $drop_names (names only). A backup of the config keeps them."
        if [[ "$YES" == true && "$REPLACE_ENTRY" != true ]]; then
          die "Nothing was changed: --yes doesn't replace another server's entry. With the owner's go-ahead, add --replace-entry to replace it"
        fi
        entry_q="Replace it with $APP_NAME ($CFG_PATH; a backup is kept)?"
      else
        entry_q="Add the $ENTRY_NAME entry to Claude Desktop's config ($CFG_PATH; a backup is kept)?"
      fi
      if [[ "$YES" == true ]] || ask_yes_no "$entry_q"; then :; else
        add_entry=false
        print_warning "The $ENTRY_NAME entry won't be added. The server will still be installed."
      fi
    fi
  fi
  # 6. Download and check, into a temporary folder.
  print_step "Downloading $APP_NAME $latest..."
  curl_get "$BASE/$RELEASE_FILE" "$TMP_DIR/$RELEASE_FILE" 300 || die "Download failed: $BASE/$RELEASE_FILE. Nothing was changed"
  curl_get "$BASE/$RELEASE_SHA_FILE" "$TMP_DIR/$RELEASE_SHA_FILE" 300 || die "Download failed: $BASE/$RELEASE_SHA_FILE. Nothing was changed"
  local expected actual
  expected="$(/usr/bin/awk 'NR == 1 { print tolower($1) }' "$TMP_DIR/$RELEASE_SHA_FILE")"
  actual="$(sha256_of "$TMP_DIR/$RELEASE_FILE")"
  if [[ ! "$expected" =~ ^[0-9a-f]{64}$ || "$expected" != "$actual" ]]; then
    print_error "Checksum mismatch — nothing was changed."
    print_error "Expected: ${expected:-<none>}"
    print_error "Got:      $actual"
    print_error "A new release can take about 10 minutes to reach everyone; wait and run the installer again."
    exit 1
  fi
  # The tarball's layout (files at the top, or inside one folder), its links and special files (refused) and its
  # version. The listings are tested with here-strings: under pipefail, `printf | grep -q` fails when grep stops early
  # and printf gets SIGPIPE, which let a long listing through.
  local members pyfile lead strip=0 listing tar_version
  listing="$(/usr/bin/tar -tvzf "$TMP_DIR/$RELEASE_FILE" 2>/dev/null)" || die "The download isn't a readable archive. Nothing was changed"
  if grep -q '^[^-d]' <<<"$listing"; then die "The download holds links or special files, which this installer refuses. Nothing was changed"; fi
  members="$(/usr/bin/tar -tzf "$TMP_DIR/$RELEASE_FILE" 2>/dev/null)" || die "The download isn't a readable archive. Nothing was changed"
  if grep -q -E '(^/|(^|/)\.\.(/|$))' <<<"$members"; then die "The download holds unsafe paths. Nothing was changed"; fi
  pyfile="$(grep -E -m 1 '^(\./)?([^/]+/)?pyproject\.toml$' <<<"$members" || true)"
  [[ -n "$pyfile" ]] || die "The download doesn't look like $APP_NAME (no pyproject.toml). Nothing was changed"
  # How many leading folders to drop: none for files at the top (also with a ./ prefix), else the folders before it.
  lead="${pyfile%pyproject.toml}"
  if [[ "$lead" != "" && "$lead" != "./" ]]; then
    strip="$(printf '%s' "$lead" | tr -cd '/' | wc -c | tr -d ' ')"
  fi
  /usr/bin/tar -xzf "$TMP_DIR/$RELEASE_FILE" -O "$pyfile" >"$TMP_DIR/pyproject.toml" 2>/dev/null || die "Couldn't read the download's pyproject.toml. Nothing was changed"
  tar_version="$(pyproject_version "$TMP_DIR/pyproject.toml")"
  if [[ "$tar_version" != "$latest" ]]; then
    die "The download's version (${tar_version:-unknown}) doesn't match $RELEASE_VERSION_FILE ($latest). Nothing was changed"
  fi
  print_success "Downloaded $APP_NAME $latest; its SHA-256 matches the site's checksum"
  if [[ "$DRY_RUN" == true ]]; then
    print_dry_run "$action" "$installed" "$latest" "$need_uv" "$how" "$desktop" "$add_entry" "$replace_other" "$other_cmd" "$drop_names"
    return 0
  fi
  # 7. uv, now that the download is checked.
  if [[ "$need_uv" == true ]]; then
    install_uv || die "uv wasn't installed, so nothing else was changed. Install uv yourself (see https://docs.astral.sh/uv/getting-started/installation/), then run this again"
    uv="$(find_uv)"
    [[ -n "$uv" ]] || die "uv was installed, but the installer can't find it (looked in your PATH, /opt/homebrew/bin, /usr/local/bin and ~/.local/bin)"
    uv_dir="$(dirname "$uv")"
    print_success "uv: $uv"
  fi
  # 8. Install.
  install_release "$TMP_DIR/$RELEASE_FILE" "$strip" "$latest" "$uv"
  print_success "Installed $APP_NAME $latest in $DIR"
  # 9. Claude Desktop's entry.
  local env_json backup
  env_json="$(entry_env_json "$uv_dir")"
  if [[ "$add_entry" == true ]]; then
    if backup="$(write_config add "$env_json")"; then
      print_success "Added the $ENTRY_NAME entry to $CFG_PATH${backup:+ (backup: $backup; it may hold old keys, remove it when not needed)}"
      if [[ "$replace_other" == true && -n "$drop_names" ]]; then
        print_warning "The replaced entry's env held: $drop_names (names only). They are gone from the config; the backup still has them."
      fi
    else
      print_error "The $ENTRY_NAME entry wasn't added; $APP_NAME $latest is installed."
      print_entry_by_hand "$env_json"
      exit 1
    fi
  elif [[ "$desktop" != true ]]; then
    print_entry_by_hand "$env_json"
  elif [[ "$CFG_STATE" == ours ]]; then
    print_success "The $ENTRY_NAME entry in $CFG_PATH already runs this install; it was left as it is"
  else
    print_entry_by_hand "$env_json"
  fi
  release_lock
  # 10. Claude Desktop: open it if it isn't running. Never quit it.
  if [[ "$desktop" == true ]]; then
    if claude_running; then
      was_running=true
    elif [[ ! -d "$CLAUDE_APP" ]]; then
      :
    elif [[ "$NO_OPEN_FLAG" == true || -n "${APPTIO_INSTALL_NO_OPEN:-}" && "${APPTIO_INSTALL_NO_OPEN:-}" != 0 ]]; then
      echo "Not opening Claude Desktop (--no-open)."
    elif open "$CLAUDE_APP" >/dev/null 2>&1; then
      echo "Opened Claude Desktop."
    else
      print_warning "Couldn't open Claude Desktop; open it yourself."
    fi
  fi
  if [[ "$was_running" == true ]]; then echo "Claude Desktop is open: quit it (⌘Q) and reopen it."; fi
  # 11. Next steps.
  print_next_steps
  # The login offer: only to a person at a terminal (never under --yes or --no-input, and never with output going to a
  # file or another program), so an agent can't be left waiting on it.
  if [[ "$HAVE_TTY" == true && "$YES" != true && -t 1 ]] && ! security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" >/dev/null 2>&1; then
    echo ""
    if ask_yes_no "Enter your Apptio key pair here in Terminal now (runs: $(q_launcher) login)? The card in Claude Desktop does the same, so n is fine."; then
      PATH="$uv_dir:$PATH" "$LAUNCHER" login <"$TTY_PATH" || print_warning "login didn't finish. You can run it again: $(q_launcher) login"
    fi
  fi
}

# ---- --status ----

# The UTC time of the newest "apptio-mcp[<pid>]: started" line in Claude Desktop's log for the entry, as
# 2026-11-24T09:00:00 (no fraction, no Z), or nothing. $1 = the log file.
last_server_start() {
  [[ -f "$1" && -r "$1" ]] || return 0
  # Claude Desktop stamps its own lines but copies our stderr without a time, so a `started` line takes the time of
  # the nearest stamped line above it (found against a real log: the lines have no stamp of their own).
  /usr/bin/awk '
    /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]/ { ts = substr($0, 1, 19) }
    /apptio-mcp\[[0-9]+\]: started / { last = ts }
    END { if (last != "") print last }
  ' "$1" 2>/dev/null || true
}

# When a file or link last changed, as a UTC time like the log's (2026-11-24T09:00:00), or nothing.
changed_at() {
  local epoch
  epoch="$(/usr/bin/stat -f '%m' "$1" 2>/dev/null)" || return 0
  /bin/date -u -r "$epoch" '+%Y-%m-%dT%H:%M:%S'
}

do_status() {
  local installed latest="" latest_text uv uv_dir="" app_version="" desktop_text entry_text key_stored=no
  local setup_text="couldn't check" server_text mapping_text next="" ready=no warn_names="" line
  local started venv_broken=false stale=false switched log_file out installed_ok=false n running=false
  local setup_ok=false setup_complete="" setup_missing="" setup_review="" setup_err="" mapping_file rows
  ensure_tmp
  installed="$(installed_version)"
  # The launcher is only run from a folder this installer made (it has our marker).
  [[ -e "$DIR/$MARKER_NAME" ]] || installed=""
  echo "Install folder: $DIR"
  echo "Installed: ${installed:-none}"
  # Latest.
  if [[ -z "$BASE" ]]; then
    latest_text="none (no site)"
  else
    latest="$(fetch_latest_version "$BASE" "$TMP_DIR/latest.version")"
    if [[ -z "$latest" ]]; then
      latest_text="unknown (couldn't check)"
    elif [[ -z "$installed" || "$(ver_cmp "$latest" "$installed")" -gt 0 ]]; then
      latest_text="$latest (update available)"
    else
      latest_text="$latest (up to date)"
    fi
  fi
  echo "Latest: $latest_text"
  echo "Launcher: $LAUNCHER"
  uv="$(find_uv)"
  if [[ -n "$uv" ]]; then
    uv_dir="$(dirname "$uv")"
    echo "uv: $uv"
  else
    echo "uv: not installed"
  fi
  # Claude Desktop and the entry.
  resolve_config
  if [[ -d "$CLAUDE_APP" ]]; then
    app_version="$(claude_version "$CLAUDE_APP")"
    desktop_text="${app_version:-installed}"
  elif [[ -d "$(dirname "$CFG_PATH_DEFAULT")" ]]; then
    desktop_text="installed"
  else
    desktop_text="not installed"
  fi
  if claude_running; then running=true; fi
  case "$CFG_STATE" in
    ours | other | none) entry_text="entry '$ENTRY_NAME' $CFG_STATE" ;;
    missing) entry_text="config missing" ;;
    invalid) entry_text="config invalid" ;;
    encoding) entry_text="config not UTF-8" ;;
    *) entry_text="config unreadable" ;;
  esac
  echo "Claude Desktop: $desktop_text; $entry_text  ($CFG_PATH)"
  # The entry's server, from Claude Desktop's log.
  log_file="${HOME%/}/Library/Logs/Claude/mcp-server-$ENTRY_NAME.log"
  started="$(last_server_start "$log_file")"
  switched=""
  if [[ -L "$DIR/current" ]]; then switched="$(changed_at "$DIR/current")"; fi
  if [[ -n "$started" && -n "$switched" && "$started" < "$switched" ]]; then stale=true; fi
  # Setup and the mapping file, from the launcher with the entry's env. Names and states only.
  if [[ -n "$installed" && -x "$LAUNCHER" && -n "$uv" ]]; then installed_ok=true; fi
  if [[ "$installed_ok" == true ]]; then
    out="$TMP_DIR/setup.out"
    if launcher_run "$uv_dir" 20 "$out" status --installer; then
      setup_ok=true
      while IFS= read -r line; do
        case "$line" in
          complete=*) setup_complete="${line#complete=}" ;;
          missing=*) setup_missing="${line#missing=}" ;;
          to_review=*) setup_review="${line#to_review=}" ;;
          settings_error=*) setup_err="${line#settings_error=}" ;;
        esac
      done <"$out"
    else
      venv_broken=true
    fi
  fi
  if [[ "$setup_ok" == true ]]; then
    if [[ "$setup_err" == yes ]]; then
      setup_text="couldn't check"
    elif [[ "$setup_complete" == yes ]]; then
      setup_text="complete"
    elif [[ -n "$setup_missing" ]]; then
      setup_text="missing ${setup_missing//,/, }"
    elif [[ -n "$setup_review" ]]; then
      setup_text="defaults not reviewed"
    else
      setup_text="couldn't check"
    fi
  fi
  if [[ "$running" != true ]]; then
    server_text="Claude Desktop isn't running"
  elif [[ "$stale" == true ]]; then
    server_text="stale (installed ${installed:-?} is newer; quit and reopen Claude Desktop)"
  elif [[ "$venv_broken" == true ]]; then
    server_text="venv broken (re-run the install command)"
  elif [[ -n "$started" ]]; then
    server_text="running since ${started}Z"
  else
    server_text="hasn't started"
  fi
  echo "Entry server: $server_text"
  if security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" >/dev/null 2>&1; then key_stored=yes; fi
  echo "Key stored: $key_stored"
  echo "Setup: $setup_text"
  # Mapping file: only needed for the spend tools.
  mapping_file="${HOME%/}/Library/Application Support/apptio-mcp/mapping.csv"
  mapping_text="not imported (needed only for spend tools)"
  if [[ -f "$mapping_file" ]]; then
    rows=""
    if [[ "$installed_ok" == true && "$venv_broken" != true ]] && launcher_run "$uv_dir" 20 "$TMP_DIR/mapping.out" mapping show; then
      rows="$(/usr/bin/sed -n 's/^Mapping file: \([0-9][0-9]*\) rows.*/\1/p' "$TMP_DIR/mapping.out" | head -n 1)"
    fi
    [[ -n "$rows" ]] || rows="$(/usr/bin/awk 'END { print (NR > 0 ? NR - 1 : 0) }' "$mapping_file" 2>/dev/null || echo 0)"
    mapping_text="present ($rows rows)"
  fi
  echo "Mapping file: $mapping_text"
  # Config backups, and a warning about key names in the entry's env (it survives a config it can't read).
  n=0
  if [[ "$CFG_STATE" != link ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] && n=$((n + 1))
    done <<<"$(list_backups "$CFG_REAL")"
  fi
  echo "Config backups: $n (may hold old keys; remove when not needed)"
  if [[ "$CFG_STATE" == ours || "$CFG_STATE" == other ]]; then
    while IFS= read -r line; do
      case "$line" in drop=*) warn_names="${warn_names:+$warn_names, }${line#drop=}" ;; esac
    done <<<"$(entry_config inspect "$CFG_REAL" "$LAUNCHER")"
    if [[ -n "$warn_names" ]]; then
      echo "Warning: the entry's env in $CFG_PATH holds $warn_names (names only). The server ignores them; remove them from the config."
    fi
  fi
  # The one step left: uv, the entry, quit and reopen Desktop, setup, then the mapping file.
  if [[ -z "$uv" ]]; then
    next="install uv (ask first): $(install_cmd --install-uv)"
  elif [[ -z "$installed" ]]; then
    next="run the install command: $(install_cmd)"
  elif [[ "$CFG_STATE" == invalid || "$CFG_STATE" == unreadable || "$CFG_STATE" == encoding || "$CFG_STATE" == link ]]; then
    next="$(config_problem "$CFG_STATE") ($CFG_PATH): fix it, then check again."
  elif [[ "$desktop_text" == "not installed" ]]; then
    next="install Claude Desktop (https://claude.ai/download), or in Claude Code run: claude mcp add --scope user $ENTRY_NAME -- $(q_launcher)"
  elif [[ "$CFG_STATE" != ours ]]; then
    next="add the $ENTRY_NAME entry to Claude Desktop's config: $(install_cmd)"
  elif [[ "$venv_broken" == true ]]; then
    next="re-run the install command: $(install_cmd)"
  elif [[ "$running" != true ]]; then
    next="open Claude Desktop"
  elif [[ "$stale" == true || -z "$started" ]]; then
    next="quit Claude Desktop (⌘Q) and reopen it, so it starts the $ENTRY_NAME entry"
  elif [[ "$setup_text" != complete ]]; then
    if [[ "$key_stored" == no || "$setup_text" == "missing "* || "$setup_text" == "defaults not reviewed" ]]; then
      next="finish setup: start a new chat in Claude Desktop (the card asks for the key and environment ID), or run: $(q_launcher) login"
    else
      next="check the setup: $(q_launcher) status"
    fi
  fi
  if [[ -z "$next" ]]; then
    ready=yes
    if [[ "$mapping_text" == not\ imported* ]]; then
      next="optional, for spend questions: import the mapping file: $(q_launcher) mapping import <file>"
    fi
  fi
  echo "Ready: $ready"
  echo "Next: ${next:-nothing}"
}

# ---- --uninstall ----

# The entry alone, when the install folder is gone but Claude Desktop's config still has our entry.
uninstall_entry_only() {
  local backup locked
  if [[ "$CFG_STATE" != ours ]]; then die "Nothing to remove: $DIR doesn't exist"; fi
  echo "$DIR doesn't exist, but Claude Desktop's config still has the $ENTRY_NAME entry that ran it."
  if [[ "$YES" != true ]]; then
    ask_yes_no "Remove just that entry from $CFG_PATH (a backup is kept)?" ||
      die "Not removed$([[ "$HAVE_TTY" == true ]] || echo " (with no terminal, add --yes)")."
  fi
  locked="$(config_locked_reason "$CFG_REAL")"
  [[ -z "$locked" ]] || die "Claude Desktop's config ($CFG_PATH) can't be changed: $locked. Nothing was changed"
  backup="$(write_config remove)" || die "Couldn't remove the $ENTRY_NAME entry, so nothing was changed"
  print_success "Removed the $ENTRY_NAME entry from $CFG_PATH${backup:+ (backup: $backup)}"
}

do_uninstall() {
  local backup remaining=0 data_dir cache_dir locked left item created=yes
  resolve_config
  case "$CFG_STATE" in
    invalid | unreadable | encoding | link)
      die "$(config_problem "$CFG_STATE") ($CFG_PATH), so nothing was changed. Fix it, or remove the $ENTRY_NAME entry by hand, then run this again"
      ;;
  esac
  if [[ ! -d "$DIR" ]]; then
    uninstall_entry_only
    return 0
  fi
  [[ -e "$DIR/$MARKER_NAME" ]] || die "$DIR isn't an $APP_NAME install folder; leaving it alone"
  if [[ "$CFG_STATE" == ours ]]; then
    locked="$(config_locked_reason "$CFG_REAL")"
    [[ -z "$locked" ]] || die "Claude Desktop's config ($CFG_PATH) can't be changed: $locked. Nothing was changed"
  fi
  if [[ "$YES" != true ]]; then
    if claude_running; then
      echo "Claude Desktop is open. Quit it (⌘Q) before you go on."
    fi
    ask_yes_no "Remove $APP_NAME (what it installed in $DIR), its cache and pending setup tokens, and the $ENTRY_NAME entry from Claude Desktop's config?" ||
      die "Not removed$([[ "$HAVE_TTY" == true ]] || echo " (with no terminal, add --yes)")."
  elif claude_running; then
    print_warning "Claude Desktop is open. Quit it (⌘Q) so it stops running $APP_NAME."
  fi
  take_lock
  data_dir="${HOME%/}/Library/Application Support/apptio-mcp"
  cache_dir="${HOME%/}/Library/Caches/apptio-mcp"
  if [[ "$CFG_STATE" == ours ]]; then
    backup="$(write_config remove)" || die "Couldn't remove the $ENTRY_NAME entry, so nothing else was removed"
    print_success "Removed the $ENTRY_NAME entry from $CFG_PATH${backup:+ (backup: $backup)}"
  elif [[ "$CFG_STATE" == other ]]; then
    print_warning "The $ENTRY_NAME entry in $CFG_PATH runs something else, so it was left alone."
  fi
  # Only what the installer made goes: `current`, `current.new`, `versions/`, its marker and Finder's .DS_Store. The
  # folder is removed only if the installer created it and nothing else is left in it (it may be a folder of yours).
  /bin/rm -f "$DIR/current"
  if [[ -d "$DIR/current.new" && ! -L "$DIR/current.new" ]]; then /bin/rm -rf "$DIR/current.new"; else /bin/rm -f "$DIR/current.new"; fi
  if [[ -L "$DIR/versions" ]]; then
    print_warning "$DIR/versions is a link; it was left alone."
  else
    /bin/rm -rf "${DIR:?}/versions"
  fi
  grep -q 'created=no' "$DIR/$MARKER_NAME" 2>/dev/null && created=no
  /bin/rm -f "$DIR/$MARKER_NAME" "$DIR/.DS_Store"
  release_lock
  left="$(/usr/bin/find "$DIR" -mindepth 1 -maxdepth 1 2>/dev/null || true)"
  if [[ -z "$left" && "$created" == yes ]]; then
    /bin/rmdir "$DIR" 2>/dev/null || true
    print_success "Removed $DIR"
  elif [[ -z "$left" ]]; then
    print_success "Removed what $APP_NAME installed in $DIR (the folder was there before, so it was kept)"
  else
    print_success "Removed what $APP_NAME installed in $DIR"
    echo "Left in $DIR (not ours; remove it yourself if you don't need it):"
    while IFS= read -r item; do
      echo "  ${item##*/}"
    done <<<"$left"
  fi
  if [[ -d "$cache_dir" ]]; then
    /bin/rm -rf "${cache_dir:?}"
    print_success "Removed the cache ($cache_dir)"
  fi
  if [[ -d "$data_dir/settings-tokens" ]]; then
    /bin/rm -rf "${data_dir:?}/settings-tokens"
    print_success "Removed the pending setup tokens"
  fi
  echo ""
  echo "Kept: your settings and mapping file in \"$data_dir\"."
  echo "  To remove them: rm -rf \"$data_dir\""
  echo "Kept: the Keychain item (service $KEYCHAIN_SERVICE, account $KEYCHAIN_ACCOUNT)."
  echo "  To remove it: security delete-generic-password -s $KEYCHAIN_SERVICE -a $KEYCHAIN_ACCOUNT"
  echo "  (To revoke the key itself, use Apptio Access Administration.)"
  if [[ "$CFG_STATE" != link ]]; then
    while IFS= read -r backup; do
      [[ -n "$backup" ]] || continue
      if [[ "$remaining" == 0 ]]; then echo "Config backups left behind (they may hold old keys; remove them when you don't need them):"; fi
      remaining=$((remaining + 1))
      echo "  $backup"
    done <<<"$(list_backups "$CFG_REAL")"
  fi
  echo "In Claude Code, if you added it there: claude mcp remove $ENTRY_NAME -s user"
}

# ---- main ----

announce_overrides() {
  local name var
  for name in $OVERRIDE_NAMES; do
    var="APPTIO_INSTALL_$name"
    if [[ -n "${!var+x}" ]]; then echo "test override in use: $var"; fi
  done
}

main() {
  local status_only=false uninstall=false
  [[ -n "${HOME:-}" ]] || die "HOME isn't set"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dir)
        [[ $# -ge 2 && -n "$2" ]] || die "--dir needs a folder path"
        DIR_ARG="$2"
        shift 2
        ;;
      --dir=*)
        DIR_ARG="${1#--dir=}"
        [[ -n "$DIR_ARG" ]] || die "--dir needs a folder path"
        shift
        ;;
      --status) status_only=true; shift ;;
      --uninstall) uninstall=true; shift ;;
      --install-uv) INSTALL_UV_OK=true; shift ;;
      --allow-downgrade) ALLOW_DOWNGRADE=true; shift ;;
      --no-input) NO_INPUT=true; shift ;;
      --dry-run) DRY_RUN=true; shift ;;
      --replace-entry) REPLACE_ENTRY=true; shift ;;
      --no-open) NO_OPEN_FLAG=true; shift ;;
      --yes | -y) YES=true; shift ;;
      --help | -h) usage; exit 0 ;;
      *) die "Unknown argument: $1 (try --help)" ;;
    esac
  done
  [[ "$status_only" != true || "$uninstall" != true ]] || die "--status and --uninstall can't be used together"
  [[ "$DRY_RUN" != true || ("$status_only" != true && "$uninstall" != true) ]] || die "--dry-run is for the install; it can't be used with --status or --uninstall"
  announce_overrides
  TTY_PATH="${APPTIO_INSTALL_TTY:-/dev/tty}"
  # --no-input (and --dry-run, which asks nothing) never reads from a terminal.
  if [[ "$NO_INPUT" == true || "$DRY_RUN" == true ]]; then TTY_PATH=/dev/null; fi
  BASE="${APPTIO_INSTALL_BASE-$SITE_BASE_DEFAULT}"
  BASE="${BASE%/}"
  if [[ -n "$BASE" ]]; then
    base_allowed "$BASE" APPTIO_INSTALL_BASE || die "APPTIO_INSTALL_BASE must be https, http://127.0.0.1, http://localhost or file://"
  fi
  CLAUDE_APP="${APPTIO_INSTALL_CLAUDE_APP:-/Applications/Claude.app}"
  CFG_PATH_DEFAULT="${APPTIO_INSTALL_CLAUDE_CONFIG:-${HOME%/}/Library/Application Support/Claude/claude_desktop_config.json}"
  find_claude_app
  resolve_dir
  if [[ "$status_only" == true ]]; then
    do_status
    return 0
  fi
  open_tty
  if [[ "$uninstall" == true ]]; then
    do_uninstall
    return 0
  fi
  do_install
}

# One compound command, so a download cut off anywhere (even right after `main`) can't run a half script.
{ main "$@"; exit $?; }
