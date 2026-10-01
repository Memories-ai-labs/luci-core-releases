#!/bin/sh
# Luci headless core installer (Linux). POSIX sh, idempotent: re-running upgrades or repairs.
#
#   curl -fsSL https://raw.githubusercontent.com/Memories-ai-labs/luci-core-releases/main/install.sh | sh -s -- [options]
#
# The installer and the release assets live in the public repo Memories-ai-labs/luci-core-releases;
# the source repo (Memories-ai-labs/luci-core, private) keeps this file as scripts/install.sh and
# scripts/promote-release.sh copies it over. Assets: https://github.com/Memories-ai-labs/luci-core-releases/releases
# latest = releases/latest/download/, --version <v> = releases/download/v<v>/.
# Each holds luci-core-linux-<x64|arm64>.tar.gz, ocr-zh-v1.tar.gz and SHA256SUMS.
#
# Options:
#   --version <v>          Core version to install (default: latest)
#   --from-tarball <path>  Install from a local tarball instead of downloading (also: LUCI_CORE_TARBALL).
#                          An https:// URL works too; it must pass --sha256 or have a SHA256SUMS next to it
#   --sha256 <hex>         Expected sha256 of the --from-tarball file
#   --data-dir <dir>       Make ~/.luci a symlink to <dir> (e.g. /workspace/.luci)
#   --no-systemd           Skip the systemd user unit; run 'luci-core serve --detach' instead
#   --linger               loginctl enable-linger, so Luci survives logout
#   --ocr-lang zh          Also install the Chinese OCR pack
#   --no-start             Install only, do not start Luci
#   --dry-run              Print the plan, change nothing
#   --repair               Reinstall the recorded version (used by the shims)
#   --uninstall [--purge]  Remove Luci core; --purge also removes ~/.luci
#
# Environment: LUCI_RELEASE_BASE (directory that holds the release assets, https://; replaces both URLs above),
# LUCI_CORE_VERSION, LUCI_CORE_TARBALL.
# Test-only: LUCI_INSTALL_ALLOW_NON_LINUX=1 lets the script run on macOS to
# exercise its logic with a fake tarball. It does not make the install work there.
# LUCI_INSTALL_ALLOW_HTTP=1 accepts non-https sources (a local test mirror).
set -eu

NODE_VERSION="22.23.3"
NODE_SHA256_X64="1084aa36196bba4c3a5e69a1ee388a6e4ff729dad09445fbcd434b28fe3c24af"
NODE_SHA256_ARM64="5ced2d48d1d7198739b7f86804de0171aefb6823b684b12341d3321afc3cb0b2"
RELEASE_ROOT="https://github.com/Memories-ai-labs/luci-core-releases/releases"
INSTALL_URL="https://raw.githubusercontent.com/Memories-ai-labs/luci-core-releases/main/install.sh"
PORT=8765
UNIT_NAME="luci-core.service"

ACTION="install"
VERSION=""
FROM_TARBALL=""
TARBALL_SHA256=""
DATA_DIR=""
NO_SYSTEMD=0
LINGER=0
OCR_LANG=""
NO_START=0
DRY=0
PURGE=0
TMP=""
STAGE=""

say() { printf '%s\n' "$*"; }
warn() { printf 'Warning: %s\n' "$*" >&2; }
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
plan() { say "[dry-run] $*"; }

cleanup() {
  [ -z "$TMP" ] || rm -rf "$TMP"
  [ -z "$STAGE" ] || rm -rf "$STAGE"
}

unit_text() {
  cat <<'UNIT'
[Unit]
Description=Luci screen memory (headless core)

[Service]
Type=simple
ExecStart=%h/.luci/bin/luci-core serve
Restart=on-failure
RestartSec=5
Nice=10
Environment=LUCI_CORE_SUPERVISED=systemd

[Install]
WantedBy=default.target
UNIT
}

usage() { sed -n '2,/^set -eu/p' "$0" 2>/dev/null | sed '$d;s/^# \{0,1\}//' || true; }

# ---------------------------------------------------------------- helpers

have() { command -v "$1" >/dev/null 2>&1; }

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

ensure_tmp() { [ -n "$TMP" ] || TMP=$(mktemp -d "${TMPDIR:-/tmp}/luci-install.XXXXXX"); }

fetch() { # url dest
  if have curl; then
    curl -fsSL --retry 3 --connect-timeout 15 -o "$2" "$1" </dev/null || die "Couldn't download $1"
  elif have wget; then
    wget -q -O "$2" "$1" </dev/null || die "Couldn't download $1"
  else
    die "Need curl or wget to download files."
  fi
}

sha256_of() {
  if have sha256sum; then sha256sum "$1" | awk '{print $1}'
  elif have shasum; then shasum -a 256 "$1" | awk '{print $1}'
  elif have openssl; then openssl dgst -sha256 "$1" | awk '{print $NF}'
  else die "Need sha256sum, shasum or openssl to verify downloads."
  fi
}

verify_sha() { # file expected-hash label
  actual=$(sha256_of "$1")
  [ "$actual" = "$2" ] || die "Checksum mismatch for $3. Nothing was installed."
}

sums_lookup() { # SHA256SUMS-file asset-name
  awk -v f="$2" '{ n = $2; sub(/^\*/, "", n); if (n == f) { print $1; exit } }' "$1"
}

atomic_link() { # target link
  tmp_link="$2.new.$$"
  rm -f "$tmp_link"
  ln -s "$1" "$tmp_link"
  if ! mv -Tf "$tmp_link" "$2" 2>/dev/null; then
    rm -f "$2"
    mv "$tmp_link" "$2"
  fi
}

write_file() { # dest mode  (content on stdin)
  tmp_file="$1.new.$$"
  cat >"$tmp_file"
  chmod "$2" "$tmp_file"
  mv -f "$tmp_file" "$1"
}

as_root() {
  if [ "$(id -u)" = 0 ]; then "$@"; else sudo -n "$@"; fi
}

can_root() {
  [ "$(id -u)" = 0 ] || { have sudo && sudo -n true </dev/null >/dev/null 2>&1; }
}

systemd_ok() {
  have systemctl && systemctl --user show-environment >/dev/null 2>&1
}

valid_version() {
  printf '%s' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$'
}

# ---------------------------------------------------------------- arguments

parse_args() {
  while [ $# -gt 0 ]; do
    case $1 in
      --version) [ $# -ge 2 ] || die "--version needs a value."; VERSION=$2; shift 2 ;;
      --from-tarball) [ $# -ge 2 ] || die "--from-tarball needs a path."; FROM_TARBALL=$2; shift 2 ;;
      --sha256) [ $# -ge 2 ] || die "--sha256 needs a hash."; TARBALL_SHA256=$2; shift 2 ;;
      --data-dir) [ $# -ge 2 ] || die "--data-dir needs a directory."; DATA_DIR=$2; shift 2 ;;
      --ocr-lang) [ $# -ge 2 ] || die "--ocr-lang needs a language."; OCR_LANG=$2; shift 2 ;;
      --no-systemd) NO_SYSTEMD=1; shift ;;
      --linger) LINGER=1; shift ;;
      --no-start) NO_START=1; shift ;;
      --dry-run) DRY=1; shift ;;
      --repair) ACTION="repair"; shift ;;
      --uninstall) ACTION="uninstall"; shift ;;
      --purge) PURGE=1; shift ;;
      --print-unit) unit_text; exit 0 ;;
      -h | --help) usage; exit 0 ;;
      *) die "Unknown option '$1'. Try --help." ;;
    esac
  done
  case $OCR_LANG in "" | zh) ;; *) die "--ocr-lang supports only 'zh'." ;; esac
  [ "$PURGE" = 0 ] || [ "$ACTION" = uninstall ] || die "--purge only works with --uninstall."
  [ -z "$DATA_DIR" ] || case $DATA_DIR in /*) ;; *) die "--data-dir must be an absolute path." ;; esac
  if [ -z "$FROM_TARBALL" ] && [ -n "${LUCI_CORE_TARBALL:-}" ]; then FROM_TARBALL=$LUCI_CORE_TARBALL; fi
  case $FROM_TARBALL in http://* | https://*) require_secure "$FROM_TARBALL" "--from-tarball" ;; esac
  if [ -z "$VERSION" ] && [ -n "${LUCI_CORE_VERSION:-}" ]; then VERSION=$LUCI_CORE_VERSION; fi
  [ -z "$VERSION" ] || valid_version "$VERSION" || die "'$VERSION' is not a valid version."
  if [ -n "$TARBALL_SHA256" ]; then
    [ -n "$FROM_TARBALL" ] || die "--sha256 only works with --from-tarball."
    TARBALL_SHA256=$(printf '%s' "$TARBALL_SHA256" | tr 'A-F' 'a-f')
    printf '%s' "$TARBALL_SHA256" | grep -Eq '^[0-9a-f]{64}$' || die "--sha256 needs a 64-character hex hash."
  fi
  [ -z "${LUCI_RELEASE_BASE:-}" ] || require_secure "$LUCI_RELEASE_BASE" "LUCI_RELEASE_BASE"
}

# Downloads must come over https: a checksum fetched from the same plain-http
# source proves nothing.
require_secure() { # url label
  case $1 in https://*) return 0 ;; esac
  [ "${LUCI_INSTALL_ALLOW_HTTP:-}" = 1 ] || die "$2 must be an https:// address."
}

# ---------------------------------------------------------------- 1. preflight

preflight() {
  if [ -z "${HOME:-}" ] || [ "$HOME" = "/" ]; then die "HOME is not set to a usable directory."; fi
  LUCI_DIR="$HOME/.luci"
  CORE_DIR="$LUCI_DIR/core"
  BIN_DIR="$LUCI_DIR/bin"
  LOCAL_BIN="$HOME/.local/bin"
  UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  if [ "$(uname -s)" != Linux ] && [ "${LUCI_INSTALL_ALLOW_NON_LINUX:-}" != 1 ]; then
    die "Luci core installs on Linux only."
  fi
  case $(uname -m) in
    x86_64 | amd64) ARCH=x64 ;;
    aarch64 | arm64) ARCH=arm64 ;;
    *) die "Unsupported CPU '$(uname -m)'. Luci core supports x86_64 and aarch64." ;;
  esac
}

detect_display() {
  X11_DIR="${LUCI_X11_SOCKET_DIR:-/tmp/.X11-unix}" # override is for tests
  SOCKETS=""
  for sock in "$X11_DIR"/X*; do
    [ -S "$sock" ] || continue
    SOCKETS="$SOCKETS :${sock##*/X}"
  done
  SOCKETS=${SOCKETS# }
  if [ -n "${WAYLAND_DISPLAY:-}" ] || [ "${XDG_SESSION_TYPE:-}" = wayland ]; then
    DISPLAY_KIND="wayland"
  elif [ -n "${DISPLAY:-}" ]; then
    DISPLAY_KIND="x11"
  elif [ -n "$SOCKETS" ]; then
    DISPLAY_KIND="x-sockets"
  else
    DISPLAY_KIND="none"
  fi
  if systemd_ok; then HAVE_SYSTEMD=1; else HAVE_SYSTEMD=0; fi
  if [ "$NO_SYSTEMD" = 1 ]; then USE_SYSTEMD=0; else USE_SYSTEMD=$HAVE_SYSTEMD; fi
}

report_environment() {
  say "Platform: linux-$ARCH"
  case $DISPLAY_KIND in
    wayland) say "Display: Wayland session. Screen capture isn't supported on Wayland yet; search still works on saved data." ;;
    x11) say "Display: X11 (DISPLAY=$DISPLAY)" ;;
    x-sockets) say "Display: X servers found ($SOCKETS). Each one is captured as its own screen." ;;
    none) say "Display: none found. Luci will run without capture. Start a display (e.g. 'Xvfb :1 -screen 0 1280x800x24 &') and re-run this installer to restart Luci." ;;
  esac
  if [ "$USE_SYSTEMD" = 1 ]; then say "Service: systemd user unit"
  elif [ "$NO_SYSTEMD" = 1 ]; then say "Service: background process (--no-systemd)"
  else say "Service: background process (no systemd user session here)"
  fi
}

# ---------------------------------------------------------------- 2. runtime libraries

apt_install() {
  as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@" </dev/null >/dev/null 2>&1
}

# What luci-grab really links (ldd in CI, linux-core.yml `build`): libxcb and
# libwayland-client, plus their own deps (libXau, libXdmcp, libbsd, libmd, libffi)
# and glibc. No PipeWire, EGL, gbm, Xrandr or wayland-server symbol from xcap
# survive linking, so those libraries are not needed. at-spi2-core is for accessibility
# text. Keep this list, packaging/linux/Dockerfile and docs/linux-headless.md
# section 1 in step.
LIB_PACKAGES="libxcb1 libwayland-client0 at-spi2-core"
LIB_SONAMES="libxcb.so.1 libwayland-client.so.0"

install_libs() {
  ldcache=$( { ldconfig -p 2>/dev/null || /sbin/ldconfig -p 2>/dev/null; } || true)
  if [ -z "$ldcache" ]; then
    say "Libraries: can't check (ldconfig not available), skipping."
    return 0
  fi
  missing=""
  for lib in $LIB_SONAMES; do
    printf '%s\n' "$ldcache" | grep -q "$lib" || missing="$missing $lib"
  done
  if [ -z "$missing" ]; then
    say "Libraries: ok"
    return 0
  fi
  pkgs="$LIB_PACKAGES"
  if [ "$DRY" = 1 ]; then plan "install missing libraries:$missing"; return 0; fi
  if have apt-get && can_root; then
    say "Installing libraries:$missing"
    # shellcheck disable=SC2086 # $pkgs is a deliberate word list
    if ! apt_install $pkgs && ! { as_root apt-get update </dev/null >/dev/null 2>&1 && apt_install $pkgs; }; then
      warn "apt-get failed. Install them by hand: sudo apt-get install -y $pkgs"
    fi
  else
    warn "Missing libraries:$missing. Screen capture won't work until you run: sudo apt-get install -y $pkgs"
  fi
}

# ---------------------------------------------------------------- 3. node

node_major() { "$1" -p 'Number(process.versions.node.split(".")[0])' 2>/dev/null || echo 0; }

record_node() { # path; lets the shims find Node when the service PATH is minimal
  [ "$DRY" = 1 ] || { mkdir -p "$CORE_DIR" && printf '%s\n' "$1" >"$CORE_DIR/node-path"; }
}

ensure_node() {
  if have node && [ "$(node_major node)" -ge 22 ]; then
    say "Node: using $(command -v node) ($(node -v))"
    record_node "$(command -v node)"
    return 0
  fi
  if [ -x "$CORE_DIR/node/bin/node" ] && [ "$(node_major "$CORE_DIR/node/bin/node")" -ge 22 ]; then
    say "Node: using bundled $("$CORE_DIR/node/bin/node" -v)"
    return 0
  fi
  if [ "$DRY" = 1 ]; then plan "download Node $NODE_VERSION to $CORE_DIR/node"; return 0; fi
  case $ARCH in x64) want=$NODE_SHA256_X64 ;; *) want=$NODE_SHA256_ARM64 ;; esac
  name="node-v$NODE_VERSION-linux-$ARCH.tar.gz"
  say "Node: downloading $NODE_VERSION"
  ensure_tmp
  fetch "https://nodejs.org/dist/v$NODE_VERSION/$name" "$TMP/$name"
  verify_sha "$TMP/$name" "$want" "Node"
  mkdir -p "$CORE_DIR/node.new.$$"
  tar -xzf "$TMP/$name" -C "$CORE_DIR/node.new.$$" --strip-components=1
  rm -rf "$CORE_DIR/node"
  mv "$CORE_DIR/node.new.$$" "$CORE_DIR/node"
}

# ---------------------------------------------------------------- 4. tarball

release_base() { # [version]  (empty = latest)
  if [ -n "${LUCI_RELEASE_BASE:-}" ]; then
    printf '%s' "${LUCI_RELEASE_BASE%/}"
  elif [ -z "${1:-}" ] || [ "$1" = "<latest>" ]; then
    printf '%s/latest/download' "$RELEASE_ROOT"
  else
    printf '%s/download/v%s' "$RELEASE_ROOT" "$1"
  fi
}

resolve_version() {
  [ -z "$VERSION" ] || return 0
  if [ "$ACTION" = repair ] && [ -f "$CORE_DIR/version" ]; then
    VERSION=$(tr -d ' \r\n' <"$CORE_DIR/version")
    valid_version "$VERSION" || die "The recorded version is damaged. Reinstall: curl -fsSL $INSTALL_URL | sh"
    return 0
  fi
  # Latest: the asset names carry no version (releases/latest/download/...);
  # the tarball's VERSION file says which one arrived.
  if [ "$DRY" = 1 ]; then VERSION="<latest>"; fi
  return 0
}

fetch_tarball() { # sets TARBALL; dies unless it verifies (a local tarball without sums only warns)
  TARBALL=""
  if [ -n "$FROM_TARBALL" ]; then
    case $FROM_TARBALL in
      http://* | https://*)
        require_secure "$FROM_TARBALL" "--from-tarball"
        name=${FROM_TARBALL%%\?*}
        name=${name##*/}
        ensure_tmp
        TARBALL="$TMP/luci-core.tar.gz"
        fetch "$FROM_TARBALL" "$TARBALL"
        if [ -n "$TARBALL_SHA256" ]; then
          verify_sha "$TARBALL" "$TARBALL_SHA256" "$name"
        else
          sums_url="${FROM_TARBALL%%\?*}"
          sums_url="${sums_url%/*}/SHA256SUMS"
          if have curl; then
            curl -fsSL --retry 3 --connect-timeout 15 -o "$TMP/SHA256SUMS.url" "$sums_url" </dev/null 2>/dev/null || true
          elif have wget; then
            wget -q -O "$TMP/SHA256SUMS.url" "$sums_url" </dev/null 2>/dev/null || true
          fi
          [ -s "$TMP/SHA256SUMS.url" ] || die "No checksum for $name. Pass --sha256 <hash>, or put a SHA256SUMS next to it."
          expected=$(sums_lookup "$TMP/SHA256SUMS.url" "$name")
          [ -n "$expected" ] || die "SHA256SUMS has no entry for $name."
          verify_sha "$TARBALL" "$expected" "$name"
        fi
        say "Checksum: ok"
        ;;
      *)
        [ -f "$FROM_TARBALL" ] || die "Tarball not found: $FROM_TARBALL"
        TARBALL=$FROM_TARBALL
        verify_local "$TARBALL" "$TARBALL_SHA256"
        ;;
    esac
    return 0
  fi
  base=$(release_base "$VERSION")
  asset="luci-core-linux-$ARCH.tar.gz"
  ensure_tmp
  say "Downloading $asset"
  fetch "$base/$asset" "$TMP/$asset"
  fetch "$base/SHA256SUMS" "$TMP/SHA256SUMS"
  TARBALL="$TMP/$asset"
  expected=$(sums_lookup "$TMP/SHA256SUMS" "$asset")
  [ -n "$expected" ] || die "SHA256SUMS has no entry for $asset."
  verify_sha "$TARBALL" "$expected" "$asset"
}

# A local file: --sha256 wins; else a SHA256SUMS beside it must list it; with
# neither, install with a warning (offline and image builds).
verify_local() { # file [expected-hash]
  name=$(basename "$1")
  if [ -n "${2:-}" ]; then
    verify_sha "$1" "$2" "$name"
    say "Checksum: ok"
    return 0
  fi
  sums="$(dirname "$1")/SHA256SUMS"
  if [ -f "$sums" ]; then
    expected=$(sums_lookup "$sums" "$name")
    [ -n "$expected" ] || die "SHA256SUMS next to $name has no entry for it."
    verify_sha "$1" "$expected" "$name"
    say "Checksum: ok"
    return 0
  fi
  warn "No SHA256SUMS next to $name; installing it without a checksum."
}

stop_running() {
  if systemd_ok && systemctl --user is-active --quiet "$UNIT_NAME" 2>/dev/null; then
    say "Stopping Luci"
    systemctl --user stop "$UNIT_NAME" </dev/null || warn "Couldn't stop the Luci service."
  fi
  pidfile="$CORE_DIR/run/serve.pid"
  [ -f "$pidfile" ] || return 0
  pid=$(tr -d ' \r\n' <"$pidfile")
  case $pid in '' | *[!0-9]*) return 0 ;; esac
  kill -0 "$pid" 2>/dev/null || return 0
  case $(ps -p "$pid" -o args= 2>/dev/null || true) in *luci-core*) ;; *) return 0 ;; esac
  say "Stopping Luci"
  kill -TERM "$pid" 2>/dev/null || return 0
  i=0
  while [ $i -lt 20 ] && kill -0 "$pid" 2>/dev/null; do sleep 0.5 2>/dev/null || sleep 1; i=$((i + 1)); done
  ! kill -0 "$pid" 2>/dev/null || warn "Luci is still shutting down."
}

check_grab_libs() { # warn about shared libraries luci-grab can't resolve
  grab="$CORE_DIR/$VERSION/resources/bin/luci-grab"
  [ -f "$grab" ] && have ldd || return 0
  missing_libs=$(ldd "$grab" </dev/null 2>&1 | awk '/not found/ { printf "%s ", $1 }')
  [ -z "$missing_libs" ] || warn "Screen capture needs libraries that are missing: ${missing_libs}Try: sudo apt-get install -y $LIB_PACKAGES"
}

install_tarball() {
  mkdir -p "$CORE_DIR"
  STAGE="$CORE_DIR/.stage.$$"
  rm -rf "$STAGE"
  mkdir -p "$STAGE"
  tar -xzf "$TARBALL" -C "$STAGE" || die "Couldn't unpack the tarball."
  top=""
  for d in "$STAGE"/*/; do [ -d "$d" ] && top=${d%/}; done
  [ -n "$top" ] || die "The tarball is empty."
  if [ ! -f "$top/luci-core.cjs" ] || [ ! -f "$top/cli/luci-cli.cjs" ]; then die "The tarball doesn't look like a Luci core build."; fi
  if [ -f "$top/VERSION" ]; then
    found=$(tr -d ' \r\n' <"$top/VERSION")
  else
    found=${top##*/luci-core-}
  fi
  valid_version "$found" || die "The tarball has no valid version."
  if [ -n "$VERSION" ] && [ "$VERSION" != "<latest>" ] && [ "$VERSION" != "$found" ] && [ -z "$FROM_TARBALL" ]; then
    die "Downloaded version $found, expected $VERSION."
  fi
  VERSION=$found
  PREV=""
  if [ -L "$CORE_DIR/current" ]; then PREV=$(readlink "$CORE_DIR/current"); PREV=${PREV##*/}; fi
  stop_running
  rm -rf "${CORE_DIR:?}/$VERSION"
  mv "$top" "$CORE_DIR/$VERSION"
  chmod +x "$CORE_DIR/$VERSION/luci-core.cjs" "$CORE_DIR/$VERSION/cli/luci-cli.cjs" 2>/dev/null || true
  [ ! -f "$CORE_DIR/$VERSION/resources/bin/luci-grab" ] || chmod +x "$CORE_DIR/$VERSION/resources/bin/luci-grab"
  atomic_link "$VERSION" "$CORE_DIR/current"
  printf '%s\n' "$VERSION" >"$CORE_DIR/version"
  check_grab_libs
  # Keep the new and the previous version (rollback); drop older ones.
  for d in "$CORE_DIR"/[0-9]*/; do
    [ -d "$d" ] || continue
    b=${d%/}
    b=${b##*/}
    [ "$b" = "$VERSION" ] || [ "$b" = "$PREV" ] || rm -rf "${CORE_DIR:?}/$b"
  done
  # Self-repair copy: prefer the one shipped in the tarball, else this script if it's a real file.
  # (When this run *is* the self-repair copy, cp would fail on identical files; that is fine.)
  if [ -f "$CORE_DIR/$VERSION/install.sh" ]; then
    cp "$CORE_DIR/$VERSION/install.sh" "$CORE_DIR/install.sh" 2>/dev/null || true
  elif [ -f "$0" ] && [ "$(basename "$0")" != sh ] && [ "$0" != "$CORE_DIR/install.sh" ]; then
    cp "$0" "$CORE_DIR/install.sh" 2>/dev/null || true
  fi
  [ ! -f "$CORE_DIR/install.sh" ] || chmod 0755 "$CORE_DIR/install.sh"
  record_source
  say "Installed Luci core $VERSION"
}

# A local tarball install (offline, a CI build, a build from source) can't repair
# itself by download. Remember the file: --repair reuses it, and the shims print it.
record_source() {
  case $FROM_TARBALL in
    "" | http://* | https://*) rm -f "$CORE_DIR/install-source" ;;
    *)
      src_abs="$(cd "$(dirname "$FROM_TARBALL")" && pwd)/$(basename "$FROM_TARBALL")"
      printf '%s\n' "$src_abs" >"$CORE_DIR/install-source"
      ;;
  esac
}

repair_source() { # --repair: prefer the recorded local tarball while it still exists
  [ "$ACTION" = repair ] && [ -z "$FROM_TARBALL" ] && [ -f "$CORE_DIR/install-source" ] || return 0
  src=$(sed -n 1p "$CORE_DIR/install-source")
  if [ -n "$src" ] && [ -f "$src" ]; then
    say "Repairing from $src"
    FROM_TARBALL=$src
  fi
}

# ---------------------------------------------------------------- 5. data dir

setup_data_dir() {
  if [ -n "$DATA_DIR" ]; then
    if [ -L "$LUCI_DIR" ]; then
      current=$(readlink "$LUCI_DIR")
      [ "$current" = "$DATA_DIR" ] || die "$LUCI_DIR already points to $current. Remove that link first."
    elif [ -e "$LUCI_DIR" ]; then
      die "$LUCI_DIR already exists. Move it to $DATA_DIR by hand, then re-run."
    else
      if [ "$DRY" = 1 ]; then plan "create $DATA_DIR and link $LUCI_DIR to it"; return 0; fi
      mkdir -p "$DATA_DIR"
      ln -s "$DATA_DIR" "$LUCI_DIR"
    fi
  fi
  if [ "$DRY" = 1 ]; then plan "create $LUCI_DIR (mode 0700)"; return 0; fi
  mkdir -p "$LUCI_DIR"
  chmod 700 "$LUCI_DIR"
}

# ---------------------------------------------------------------- 6. shims

# shellcheck disable=SC2016 # the shim must expand $HOME at run time, not here
SHIM_TEMPLATE='#!/bin/sh
# Managed by the Luci installer. Changes are overwritten on upgrade.
core="$HOME/.luci/core"
target="$core/@TARGET@"
pick_node() {
  node=""
  if [ -x "$core/node/bin/node" ]; then node="$core/node/bin/node"
  else
    [ ! -f "$core/node-path" ] || node=$(cat "$core/node-path")
    if [ -z "$node" ] || [ ! -x "$node" ]; then node=$(command -v node 2>/dev/null || true); fi
  fi
}
reinstall_hint() {
  if [ -f "$core/install-source" ]; then
    echo "Reinstall from a Luci core tarball: sh $core/install.sh --from-tarball <file>" >&2
    echo "The last install used $(sed -n 1p "$core/install-source")" >&2
  else
    echo "Reinstall with: curl -fsSL @INSTALL_URL@ | sh" >&2
  fi
}
pick_node
if [ -z "$node" ] || [ ! -f "$target" ]; then
  if [ -f "$core/install.sh" ]; then
    echo "Luci core is missing or damaged. Repairing..." >&2
    sh "$core/install.sh" --repair >&2 </dev/null || { echo "Repair failed." >&2; reinstall_hint; exit 1; }
    pick_node
  fi
  if [ -z "$node" ] || [ ! -f "$target" ]; then
    echo "Luci core is missing." >&2
    reinstall_hint
    exit 1
  fi
fi
exec "$node" "$target" "$@"
'

write_shim() { # name target
  printf '%s' "$SHIM_TEMPLATE" | sed "s|@TARGET@|$2|; s|@INSTALL_URL@|$INSTALL_URL|g" | write_file "$BIN_DIR/$1" 0755
}

link_local_bin() { # name
  link="$LOCAL_BIN/$1"
  if [ -e "$link" ] && [ ! -L "$link" ]; then
    warn "$link exists and isn't a link. Left alone; use $BIN_DIR/$1."
    return 0
  fi
  atomic_link "$BIN_DIR/$1" "$link"
}

install_shims() {
  if [ "$DRY" = 1 ]; then
    plan "write shims $BIN_DIR/luci and $BIN_DIR/luci-core; link them into $LOCAL_BIN"
    return 0
  fi
  mkdir -p "$BIN_DIR" "$LOCAL_BIN"
  write_shim luci "current/cli/luci-cli.cjs"
  write_shim luci-core "current/luci-core.cjs"
  link_local_bin luci
  link_local_bin luci-core
  case ":$PATH:" in *":$LOCAL_BIN:"*) ;; *) say "Add to PATH: export PATH=\"$LOCAL_BIN:\$PATH\"" ;; esac
}

write_discovery() {
  if [ "$DRY" = 1 ]; then plan "write $LUCI_DIR/cli.json and cli-token (mode 0600)"; return 0; fi
  # Luci rewrites both on start; these let the CLI find and launch the core before then.
  if [ ! -s "$LUCI_DIR/cli-token" ]; then
    token=$(od -An -tx1 -N32 /dev/urandom | tr -d ' \n')
    (umask 077 && printf '%s' "$token" >"$LUCI_DIR/cli-token.new.$$") && chmod 600 "$LUCI_DIR/cli-token.new.$$" && mv -f "$LUCI_DIR/cli-token.new.$$" "$LUCI_DIR/cli-token"
  fi
  chmod 600 "$LUCI_DIR/cli-token"
  {
    printf '{\n'
    printf '  "appPath": "%s",\n' "$(json_escape "$BIN_DIR/luci-core")"
    printf '  "cliJs": "%s",\n' "$(json_escape "$CORE_DIR/current/cli/luci-cli.cjs")"
    printf '  "shim": "%s",\n' "$(json_escape "$BIN_DIR/luci")"
    printf '  "port": %s,\n' "$PORT"
    printf '  "version": "%s",\n' "$(json_escape "$VERSION")"
    printf '  "platform": "linux",\n'
    printf '  "writtenAt": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '  "target": "core"\n'
    printf '}\n'
  } | write_file "$LUCI_DIR/cli.json" 0600
}

# ---------------------------------------------------------------- 7. service

install_unit() {
  mkdir -p "$UNIT_DIR"
  xauth=${XAUTHORITY:-}
  case $xauth in *\"* | *\\*) xauth="" ;; esac
  unit_text | awk -v x="$xauth" '{ print } /^Environment=LUCI_CORE_SUPERVISED/ && x != "" { print "Environment=\"XAUTHORITY=" x "\"" }' | write_file "$UNIT_DIR/$UNIT_NAME" 0644
  systemctl --user daemon-reload </dev/null
  systemctl --user enable "$UNIT_NAME" </dev/null >/dev/null 2>&1 || warn "Couldn't enable the Luci service."
}

setup_service() {
  if [ "$DRY" = 1 ]; then
    if [ "$USE_SYSTEMD" = 1 ]; then plan "install $UNIT_DIR/$UNIT_NAME and enable it"; else plan "no systemd unit; Luci runs via 'luci-core serve --detach'"; fi
    [ "$LINGER" = 0 ] || plan "loginctl enable-linger $(id -un)"
    [ "$NO_START" = 1 ] || plan "start Luci and wait for it to answer"
    return 0
  fi
  if [ "$USE_SYSTEMD" = 1 ]; then install_unit; fi
  if [ "$LINGER" = 1 ]; then
    loginctl enable-linger "$(id -un)" </dev/null 2>/dev/null || warn "Couldn't enable linger. Run: sudo loginctl enable-linger $(id -un)"
  fi
  [ "$NO_START" = 0 ] || return 0
  if [ "$USE_SYSTEMD" = 1 ]; then
    systemctl --user restart "$UNIT_NAME" </dev/null || warn "Couldn't start the Luci service."
  else
    rc=0
    "$BIN_DIR/luci-core" serve --detach </dev/null || rc=$?
    case $rc in 0) ;; 4) say "Luci is already running." ;; *) warn "Luci didn't start (exit $rc)." ;; esac
  fi
}

wait_ready() {
  [ "$NO_START" = 0 ] || return 0
  [ "$DRY" = 0 ] || return 0
  i=0
  while [ $i -lt 30 ]; do
    if "$BIN_DIR/luci-core" status --json </dev/null >/dev/null 2>&1; then return 0; fi
    sleep 1
    i=$((i + 1))
  done
  say "Installed, but Luci didn't answer within 30 seconds. Run 'luci-core status' to see why." >&2
  exit 1
}

# ---------------------------------------------------------------- 8. Chinese OCR pack

install_ocr_zh() {
  [ "$OCR_LANG" = zh ] || return 0
  if [ "$DRY" = 1 ]; then plan "install the Chinese OCR pack into $LUCI_DIR/models/ocr-zh-v1"; return 0; fi
  asset="ocr-zh-v1.tar.gz"
  ensure_tmp
  if [ -n "$FROM_TARBALL" ] && [ -f "$(dirname "$FROM_TARBALL")/$asset" ]; then
    pack="$(dirname "$FROM_TARBALL")/$asset"
    verify_local "$pack"
  else
    base=$(release_base "$VERSION")
    fetch "$base/$asset" "$TMP/$asset"
    fetch "$base/SHA256SUMS" "$TMP/SHA256SUMS.zh"
    expected=$(sums_lookup "$TMP/SHA256SUMS.zh" "$asset")
    [ -n "$expected" ] || die "SHA256SUMS has no entry for $asset."
    verify_sha "$TMP/$asset" "$expected" "$asset"
    pack="$TMP/$asset"
  fi
  mkdir -p "$LUCI_DIR/models" "$TMP/zh"
  tar -xzf "$pack" -C "$TMP/zh" || die "Couldn't unpack the Chinese OCR pack."
  src="$TMP/zh"
  [ ! -d "$TMP/zh/ocr-zh-v1" ] || src="$TMP/zh/ocr-zh-v1"
  rm -rf "$LUCI_DIR/models/ocr-zh-v1"
  mv "$src" "$LUCI_DIR/models/ocr-zh-v1"
  say "Chinese OCR pack installed."
}

# ---------------------------------------------------------------- uninstall

do_uninstall() {
  if [ "$DRY" = 1 ]; then
    plan "stop and disable $UNIT_NAME; remove $CORE_DIR, $BIN_DIR/luci*, $LOCAL_BIN/luci*"
    [ "$PURGE" = 0 ] || plan "remove $LUCI_DIR"
    return 0
  fi
  stop_running
  if systemd_ok; then
    systemctl --user disable "$UNIT_NAME" </dev/null >/dev/null 2>&1 || true
    if [ -f "$UNIT_DIR/$UNIT_NAME" ]; then
      rm -f "$UNIT_DIR/$UNIT_NAME"
      systemctl --user daemon-reload </dev/null || true
    fi
  fi
  for name in luci luci-core; do
    link="$LOCAL_BIN/$name"
    if [ -L "$link" ]; then
      case $(readlink "$link") in "$BIN_DIR/$name") rm -f "$link" ;; esac
    fi
    rm -f "$BIN_DIR/$name"
  done
  rmdir "$BIN_DIR" 2>/dev/null || true
  if [ -f "$LUCI_DIR/cli.json" ] && grep -q '"target": *"core"' "$LUCI_DIR/cli.json"; then
    rm -f "$LUCI_DIR/cli.json" "$LUCI_DIR/cli-token"
  fi
  rm -rf "$CORE_DIR"
  if [ "$PURGE" = 1 ]; then
    if [ -L "$LUCI_DIR" ]; then
      say "Removed the $LUCI_DIR link. Data in $(readlink "$LUCI_DIR") is kept; delete it by hand if you want it gone."
    fi
    rm -rf "$LUCI_DIR"
    say "Luci core and its data were removed."
  else
    say "Luci core removed. Your data in $LUCI_DIR is kept. Add --purge to delete it."
  fi
}

# ---------------------------------------------------------------- final message

print_summary() {
  [ "$DRY" = 0 ] || return 0
  say ""
  if [ "$NO_START" = 1 ]; then say "Luci core is installed (not started)."; else say "Luci is running."; fi
  say "Register it with your agent as a stdio MCP server:"
  say "  command: $BIN_DIR/luci"
  say '  args:    ["mcp"]'
  say "  env:     LUCI_CLIENT=grokbot:<bot-name>"
  say "As one JSON block:"
  say "  {\"command\": \"$(json_escape "$BIN_DIR/luci")\", \"args\": [\"mcp\"], \"env\": {\"LUCI_CLIENT\": \"grokbot:<bot-name>\"}}"
  say "Or use the CLI (Muse, OpenClaw, any terminal agent):"
  say "  luci now                       what is on the screen right now"
  say "  luci search \"invoice\" --tr 24h   search the last 24 hours"
  say "  luci --help                    every command"
  say "Skill for agents that read SKILL.md:  npx skills add Memories-ai-labs/Luci-skills"
  case $DISPLAY_KIND in
    wayland) say "Note: Wayland sessions aren't captured yet." ;;
    none) say "Note: no display found, so nothing is captured until one exists." ;;
  esac
}

# ---------------------------------------------------------------- main

main() {
  trap cleanup EXIT
  trap 'exit 1' INT TERM HUP
  parse_args "$@"
  preflight
  detect_display
  if [ "$ACTION" = uninstall ]; then
    do_uninstall
    return 0
  fi
  if [ "$ACTION" = repair ]; then NO_START=1; fi
  repair_source
  report_environment
  setup_data_dir
  install_libs
  ensure_node
  if [ -z "$FROM_TARBALL" ]; then resolve_version; fi
  if [ "$DRY" = 1 ]; then
    say "Version: ${VERSION:-from the tarball}"
    if [ -n "$FROM_TARBALL" ]; then plan "unpack $FROM_TARBALL into $CORE_DIR/<version> and point 'current' at it"; else plan "download and verify $(release_base "$VERSION")/luci-core-linux-$ARCH.tar.gz, unpack into $CORE_DIR/<version>"; fi
  else
    fetch_tarball
    install_tarball
  fi
  install_shims
  write_discovery
  # Before the service starts: the OCR engine picks its pack once, at start.
  install_ocr_zh
  setup_service
  wait_ready
  if [ "$ACTION" = repair ]; then
    [ "$DRY" = 1 ] || say "Luci core repaired."
    return 0
  fi
  print_summary
}

main "$@"
