#!/usr/bin/env bash
#
# install-factory-linux.sh
#
# Unofficial Linux port of the Factory AI desktop app (Electron).
#
# Factory ships official installers only for macOS (.dmg) and Windows (.exe),
# both of which bundle the same platform-agnostic Electron app code
# (resources/app.asar) plus a native `droid` daemon binary for that OS.
#
# This script builds a native Linux installation by combining three pieces,
# all fetched from Factory's first-party sources:
#
#   1. The app.asar (and renderer assets)  -> extracted from the official
#      macOS or Windows installer downloaded from https://factory.ai/product/desktop
#   2. The native `droid` daemon binary     -> the version-matched
#      @factory/cli-linux-<arch> npm package (same binaries Factory ships for
#      Linux via `npm i -g @factory/cli`)
#   3. The Electron runtime for Linux       -> the version-matched `electron`
#      npm package, which downloads Factory's exact Electron build
#      (electron 42.3.3 for desktop 0.124.x)
#
# The result is a self-contained directory at $PREFIX/Factory that you can
# launch via the generated `factory` wrapper script. An XDG .desktop entry
# and icon are installed for app-menu integration.
#
# No binary is redistributed; everything is downloaded at install time from
# Factory's own CDN (downloads.factory.ai / registry.npmjs.org).
#
# Requirements: bash, curl, 7z (p7zip-full), tar, node>=20 (for the droid
# launcher shim), basic XDG utils (optional).
#
# Usage:
#   ./install-factory-linux.sh                 # install to ~/.local/share/Factory
#   PREFIX=/opt/Factory sudo -E ./install-factory-linux.sh
#   FACTORY_SOURCE=dmg   ./install-factory-linux.sh   # force .dmg source
#   FACTORY_SOURCE=exe   ./install-factory-linux.sh   # force .exe source
#   FACTORY_VERSION=0.124.0 ./install-factory-linux.sh # pin a version
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
  x86_64|amd64)  NPM_ARCH="x64";   ELECTRON_ARCH="x64";   SRC_PLATFORM="win32" ;;
  aarch64|arm64) NPM_ARCH="arm64"; ELECTRON_ARCH="arm64"; SRC_PLATFORM="darwin" ;;
  *) echo "Unsupported host architecture: $HOST_ARCH" >&2; exit 1 ;;
esac

# Which official installer to pull app.asar from. Default: dmg on arm64
# (smaller), exe on x64. Override with FACTORY_SOURCE.
: "${FACTORY_SOURCE:=}"
if [[ -z "$FACTORY_SOURCE" ]]; then
  if [[ "$SRC_PLATFORM" == "darwin" ]]; then FACTORY_SOURCE="dmg"; else FACTORY_SOURCE="exe"; fi
fi

# Install prefix. The app lives under $PREFIX/Factory; the launcher is placed
# in $BIN_DIR which defaults to ~/.local/bin (the conventional user PATH dir),
# separate from the app prefix.
: "${PREFIX:=${HOME}/.local/share}"
PREFIX="$(readlink -f "$PREFIX")"
APP_DIR="${PREFIX}/Factory"
: "${BIN_DIR:=${HOME}/.local/bin}"
mkdir -p "$BIN_DIR"
BIN_DIR="$(readlink -f "$BIN_DIR")"

# Version: discovered dynamically from the official download API unless pinned.
: "${FACTORY_VERSION:=}"

# Keep build artifacts?
: "${KEEP_CACHE:=0}"
CACHE_DIR="${HOME}/.cache/factory-linux"
mkdir -p "$CACHE_DIR"

# Logging
log()  { printf '\033[1;34m[factory]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[factory]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[factory]\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Dependency checks
# ---------------------------------------------------------------------------
need() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }
need curl
need tar
need 7z
need node
node --version | grep -qE 'v(2[0-9]|[3-9][0-9])' || die "node >=20 required (found $(node --version))"

# ---------------------------------------------------------------------------
# Resolve the desktop version + official installer URL
# ---------------------------------------------------------------------------
resolve_version() {
  # The official API returns a redirect to an S3 URL like:
  #   https://s3.../factory-desktop/releases/<ver>/<plat>/<arch>/<file>?<sig>
  # We follow the redirect and parse the version out of the path, so we always
  # install the same version Factory is shipping today, even with no Linux build.
  local plat arch url location
  plat="$SRC_PLATFORM"
  if [[ "$plat" == "darwin" ]]; then arch="$ELECTRON_ARCH"; else arch="x64"; fi
  url="https://app.factory.ai/api/desktop?platform=${plat}&architecture=${arch}"
  location="$(curl -sI -o /dev/null -w '%{redirect_url}' "$url")" || die "desktop API unreachable"
  [[ -n "$location" ]] || die "desktop API did not redirect; cannot resolve version"
  # Extract /releases/<version>/
  local ver
  ver="$(printf '%s' "$location" | grep -oE 'releases/[0-9]+\.[0-9]+\.[0-9]+' | head -1 | cut -d/ -f2)"
  [[ -n "$ver" ]] || die "could not parse version from $location"
  FACTORY_VERSION="${FACTORY_VERSION:-$ver}"
  INSTALLER_URL="$location"
}

# ---------------------------------------------------------------------------
# Download helpers
# ---------------------------------------------------------------------------
download() { # url out
  local url="$1" out="$2"
  log "Downloading $url"
  curl -fL --retry 3 --retry-delay 2 -o "$out" "$url"
}

npm_tarball_url() { # pkg@ver
  npm view "$1" dist.tarball 2>/dev/null || die "npm view failed for $1"
}

# ---------------------------------------------------------------------------
# Step 1: fetch + extract app.asar from the official installer
# ---------------------------------------------------------------------------
fetch_app_asar() {
  log "Step 1/4: extracting app.asar from official $FACTORY_SOURCE installer"

  local installer="$CACHE_DIR/Factory-${FACTORY_VERSION}.${FACTORY_SOURCE}"
  if [[ ! -f "$installer" ]]; then
    download "$INSTALLER_URL" "$installer"
  else
    log "  cached: $installer"
  fi

  local work="$CACHE_DIR/src-${FACTORY_SOURCE}"
  rm -rf "$work"; mkdir -p "$work"

  if [[ "$FACTORY_SOURCE" == "exe" ]]; then
    # NSIS/Squirrel: the .exe wraps a zip containing <name>-<ver>-full.nupkg
    7z e "$installer" -o"$work" "*-full.nupkg" -y >/dev/null \
      || die "7z could not read installer"
    local nupkg
    nupkg="$(find "$work" -name '*-full.nupkg' | head -1)"
    [[ -n "$nupkg" ]] || die "nupkg not found inside installer"
    # The nupkg is a zip; pull resources/app.asar
    7z e "$nupkg" -o"$work/nup" "lib/*/resources/app.asar" -y >/dev/null \
      || die "could not extract app.asar from nupkg"
    mv "$work"/nup/*/app.asar "$work/app.asar" 2>/dev/null \
      || mv "$work/nup/app.asar" "$work/app.asar"
  else
    # macOS .dmg: use 7z (handles HFS+/UDZO/lzfse dmg images) to reach the
    # .app bundle, then pull Resources/app.asar. The .app ships a symlink to
    # /Applications which 7z flags as "dangerous" and returns non-zero for;
    # the actual files we need still extract, so we don't bail on the exit code.
    7z x "$installer" -o"$work/dmg" -y -snl >/dev/null 2>&1 || true
    local asar
    asar="$(find "$work/dmg" -path '*Resources/app.asar' | head -1)"
    [[ -n "$asar" ]] || die "app.asar not found inside dmg"
    cp "$asar" "$work/app.asar"
  fi

  [[ -s "$work/app.asar" ]] || die "extracted app.asar is empty"
  EXTRACTED_ASAR="$work/app.asar"
  log "  app.asar: $(du -h "$EXTRACTED_ASAR" | cut -f1)"
}

# ---------------------------------------------------------------------------
# Step 2: fetch the version-matched Linux `droid` binary from npm
# ---------------------------------------------------------------------------
fetch_droid_binary() {
  log "Step 2/4: fetching native droid binary for linux/${NPM_ARCH}"
  # The desktop app and the @factory/cli npm package are released independently,
  # so their version numbers don't always line up (e.g. desktop 0.124.1 has no
  # matching cli-linux-arm64@0.124.1). The daemon wire protocol is stable across
  # patch versions, so we pick the closest available cli version to the desktop
  # version: exact match first, then same major.minor, then latest.
  local pkg url work droid_ver
  droid_ver="$(resolve_cli_version "$FACTORY_VERSION" "$NPM_ARCH")"
  pkg="@factory/cli-linux-${NPM_ARCH}@${droid_ver}"
  log "  desktop=${FACTORY_VERSION} -> cli=${droid_ver}"
  url="$(npm_tarball_url "$pkg")"
  work="$CACHE_DIR/droid-${droid_ver}"; rm -rf "$work"; mkdir -p "$work"
  download "$url" "$work/droid.tgz"
  tar xzf "$work/droid.tgz" -C "$work"
  DROID_BIN="$(find "$work/package" -type f -name droid ! -name '*.js' | head -1)"
  if [[ -z "$DROID_BIN" || ! -x "$DROID_BIN" ]]; then
    # Some releases ship a node shim; locate the real ELF binary under dist/.
    DROID_BIN="$(find "$work/package" -path "*/dist/linux/${NPM_ARCH}/*" -type f -name droid | head -1)"
  fi
  [[ -n "$DROID_BIN" && -x "$DROID_BIN" ]] || die "native droid binary not found in $pkg"
  file "$DROID_BIN" | grep -q ELF || die "$DROID_BIN is not a Linux ELF binary"
  log "  droid binary: $(du -h "$DROID_BIN" | cut -f1) ($(file -b "$DROID_BIN" | cut -d, -f1))"
}

# Pick the best available @factory/cli-linux-<arch> version for a desktop ver.
resolve_cli_version() { # desktop_ver arch
  local desktop="$1" arch="$2"
  local all exact major_minor best
  all="$(npm view "@factory/cli-linux-${arch}" versions --json 2>/dev/null \
        | tr -d '[]" ' | tr ',' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' || true)"
  [[ -n "$all" ]] || die "could not list @factory/cli-linux-${arch} versions"
  exact="$(printf '%s\n' "$all" | grep -xF "$desktop" | head -1)"
  [[ -n "$exact" ]] && { echo "$exact"; return; }
  major_minor="${desktop%.*}"
  best="$(printf '%s\n' "$all" | grep -E "^${major_minor}\.[0-9]+$" | sort -V | tail -1)"
  [[ -n "$best" ]] && { echo "$best"; return; }
  # Fallback: newest stable (strip any pre-release tags already filtered out).
  printf '%s\n' "$all" | sort -V | tail -1
}

# ---------------------------------------------------------------------------
# Step 3: fetch the matching Electron Linux runtime
# ---------------------------------------------------------------------------
fetch_electron() {
  log "Step 3/4: fetching Electron runtime (linux/${ELECTRON_ARCH})"
  # The desktop app pins its Electron version. We read it from the asar's
  # package.json so the runtime always matches the app, even across versions.
  # @electron/asar extract-file writes the entry to a file in cwd.
  local electron_ver tmpdir
  tmpdir="$(mktemp -d)"
  electron_ver="$(
    cd "$tmpdir" &&
    npx --yes @electron/asar extract-file "$EXTRACTED_ASAR" package.json >/dev/null 2>&1 &&
    node -e 'const p=require("./package.json"); const d=(p.devDependencies&&p.devDependencies.electron)||(p.dependencies&&p.dependencies.electron)||process.env.ELECTRON_FALLBACK; console.log(d||"42.3.3");' ELECTRON_FALLBACK="42.3.3"
  )"
  rm -rf "$tmpdir"
  electron_ver="${electron_ver#^}"
  electron_ver="${electron_ver:-42.3.3}"
  log "  Electron version from app.asar: $electron_ver"

  local url work
  url="$(npm_tarball_url "electron@${electron_ver}")"
  work="$CACHE_DIR/electron-${electron_ver}"; rm -rf "$work"; mkdir -p "$work"
  download "$url" "$work/electron.tgz"
  tar xzf "$work/electron.tgz" -C "$work"
  # The `electron` npm package is just a launcher; the real runtime zip is
  # hosted on the Electron GitHub releases. We fetch the linux build directly.
  local electron_zip_url
  electron_zip_url="https://github.com/electron/electron/releases/download/v${electron_ver}/electron-v${electron_ver}-linux-${ELECTRON_ARCH}.zip"
  local zip_cache="$CACHE_DIR/electron-${electron_ver}-linux-${ELECTRON_ARCH}.zip"
  [[ -f "$zip_cache" ]] || download "$electron_zip_url" "$zip_cache"
  ELECTRON_DIR="$CACHE_DIR/electron-runtime-${electron_ver}"
  if [[ ! -d "$ELECTRON_DIR" || ! -x "$ELECTRON_DIR/electron" ]]; then
    rm -rf "$ELECTRON_DIR"; mkdir -p "$ELECTRON_DIR"
    ( cd "$ELECTRON_DIR" && 7z x "$zip_cache" -y >/dev/null ) \
      || die "could not unzip electron runtime"
  fi
  [[ -x "$ELECTRON_DIR/electron" ]] || die "electron binary missing after unzip"
  log "  electron: $(du -h "$ELECTRON_DIR/electron" | cut -f1)"
}

# ---------------------------------------------------------------------------
# Step 4: assemble the Linux app tree
# ---------------------------------------------------------------------------

# Patch the titlebar decision in the minified main bundle so Linux gets a
# native titlebar instead of a frameless macOS-style window.
patch_asar_titlebar() { # asar_path
  local asar="$1"
  log "  patching app.asar: native titlebar on linux"
  local work tmpdir
  tmpdir="$(mktemp -d)"
  ( cd "$tmpdir" && npx --yes @electron/asar extract "$asar" unpacked >/dev/null 2>&1 ) \
    || { rm -rf "$tmpdir"; die "asar extract failed"; }
  local bundle
  bundle="$(grep -rl 'titleBarStyle:e?"default":"hidden"' "$tmpdir/unpacked/.vite/build/" | head -1)"
  if [[ -z "$bundle" ]]; then
    warn "  titleBarStyle pattern not found; skipping patch (app may have changed)"
    rm -rf "$tmpdir"; return 0
  fi
  sed -i 's/titleBarStyle:e?"default":"hidden"/titleBarStyle:(e||process.platform==="linux")?"default":"hidden"/' "$bundle"
  ( cd "$tmpdir" && npx --yes @electron/asar pack unpacked "$asar" >/dev/null 2>&1 ) \
    || { rm -rf "$tmpdir"; die "asar repack failed"; }
  rm -rf "$tmpdir"
}

assemble() {
  log "Step 4/4: assembling Linux app at $APP_DIR"
  rm -rf "$APP_DIR"; mkdir -p "$APP_DIR"

  # 4a. Electron runtime -> APP_DIR/runtime
  mkdir -p "$APP_DIR/runtime"
  cp -a "$ELECTRON_DIR/." "$APP_DIR/runtime/"
  chmod +x "$APP_DIR/runtime/electron" 2>/dev/null || true

  # 4b. App resources -> APP_DIR/runtime/resources
  #
  # This is the key layout decision. Electron hardcodes process.resourcesPath
  # to the "resources/" directory that sits next to the electron binary, i.e.
  # APP_DIR/runtime/resources/ -- and the Factory app resolves its droid daemon
  # via join(process.resourcesPath, "bin", "droid"). So app.asar AND bin/droid
  # MUST live under runtime/resources/, not under a separate resources/ dir.
  # This matches the standard packaged-Electron layout:
  #   <app>/electron  +  <app>/resources/app.asar  +  <app>/resources/bin/...
  # (On mac/win the installer places app.asar in Electron's own resources/.)
  local RES="$APP_DIR/runtime/resources"
  mkdir -p "$RES/bin"
  cp "$EXTRACTED_ASAR" "$RES/app.asar"

  # 4b.1 Patch app.asar: force a native titlebar on Linux.
  #
  # The window is created with:
  #     const e = process.platform === "win32";
  #     titleBarStyle: e ? "default" : "hidden"
  # So Windows gets a native titlebar, but mac AND linux get "hidden" (frameless
  # with macOS traffic-light buttons). On Linux that means no titlebar at all
  # and no window decorations. We rewrite the ternary so Linux also gets
  # "default". This is a single-string substitution in the minified main bundle.
  patch_asar_titlebar "$RES/app.asar"

  # 4c. Native droid binary + desktop-flag wrapper -> resources/bin/
  #
  # The desktop app spawns its daemon as:
  #     droid daemon --enable-child-ipc [--listen ipc] --droid-path <p> ...
  # But the publicly-published @factory/cli builds (the only Linux droid binary
  # available) don't understand the desktop-only --enable-child-ipc / --listen ipc
  # flags, so the daemon exits with "unknown option" and the UI hangs. The
  # bundled mac/win droid binaries DO have these flags, but Factory ships no
  # Linux desktop droid build.
  #
  # Fix: install the real npm droid as bin/droid.real, and a wrapper at
  # bin/droid that strips the unsupported desktop-only flags before delegating.
  # We also force WebSocket transport (FACTORY_FEATURE_FLAGS_OVERRIDES) so the
  # daemon runs on a TCP port instead of Node IPC, which the public build fully
  # supports.
  cp "$DROID_BIN" "$RES/bin/droid.real"
  chmod +x "$RES/bin/droid.real"
  cat > "$RES/bin/droid" <<'WRAPPER'
#!/usr/bin/env bash
# Auto-generated by install-factory-linux.sh
# Strips desktop-only daemon flags unsupported by the public droid CLI build,
# then delegates to the real binary (droid.real) sitting next to this wrapper.
REAL="$(dirname "$(readlink -f "$0")")/droid.real"
args=()
skip_next=0
for a in "$@"; do
  if [[ "$skip_next" == "1" ]]; then skip_next=0; continue; fi
  case "$a" in
    --enable-child-ipc) continue ;;          # desktop-supervision flag, unsupported
    --listen) skip_next=1; continue ;;       # --listen ipc -> IPC transport, unsupported
  esac
  args+=("$a")
done
exec "$REAL" "${args[@]}"
WRAPPER
  chmod +x "$RES/bin/droid"

  # 4d. Launcher.
  #
  # Flags/env address four Linux-specific failure modes observed during porting:
  #   * ELECTRON_FORCE_IS_PACKAGED=1 : without it, app.isPackaged is false when
  #     running an unpackaged electron, so the renderer tries to load the Vite
  #     dev server (http://localhost:5173) instead of the bundled index.html
  #     and the window hangs on ERR_CONNECTION_REFUSED.
  #   * FACTORY_FEATURE_FLAGS_OVERRIDES : disables the "desktop_daemon_ipc"
  #     Statsig gate so the daemon uses WebSocket (TCP) transport instead of
  #     Node IPC, which the public droid binary supports (see 4c).
  #   * --no-sandbox : the chrome-sandbox helper requires SUID root (mode 4755),
  #     which is impossible in an unprivileged user install; without this the
  #     app aborts with a FATAL setuid-sandbox error.
  #   * GPU flags : on systems where the GPU process can't initialize (e.g. this
  #     NVIDIA/GBM box throws "GPU process launch failed" x3 then FATAL), we
  #     fall back to SwiftShader software GL + disable gpu compositing so the
  #     renderer still paints. Overridable via FACTORY_GPU_FLAGS.
  mkdir -p "$BIN_DIR"
  cat > "$BIN_DIR/factory" <<LAUNCHER
#!/usr/bin/env bash
# Auto-generated by install-factory-linux.sh
export ELECTRON_FORCE_IS_PACKAGED="\${ELECTRON_FORCE_IS_PACKAGED:-1}"
export ELECTRON_ENABLE_LOGGING="\${ELECTRON_ENABLE_LOGGING:-1}"
export FACTORY_FEATURE_FLAGS_OVERRIDES="\${FACTORY_FEATURE_FLAGS_OVERRIDES:-{\"desktop_daemon_ipc\":false}}"
: "\${FACTORY_GPU_FLAGS:=--disable-gpu-compositing --use-gl=angle --angle-backend=swiftshader --disable-gpu}"
exec "$APP_DIR/runtime/electron" \\
  --no-sandbox \\
  \$FACTORY_GPU_FLAGS \\
  "$APP_DIR/runtime/resources/app.asar" "\$@"
LAUNCHER
  chmod +x "$BIN_DIR/factory"

  # 4e. XDG desktop entry + icon, for app menus.
  install_desktop_entry

  log "Installed: $BIN_DIR/factory"
}

install_desktop_entry() {
  local apps="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
  local icons="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor"
  mkdir -p "$apps" \
           "$icons/512x512/apps" \
           "$icons/256x256/apps" \
           "$icons/128x128/apps" \
           "$icons/48x48/apps"
  # Extract the app icon from whichever source is available. We try, in order:
  #   1. .icns inside the macOS dmg extraction (multi-size PNG container)
  #   2. .ico inside the Windows exe/nupkg extraction
  #   3. PNG assets bundled inside app.asar (renderer ships icon PNGs)
  # Then install every size we can find and reference it by name in the
  # .desktop entry so the desktop environment resolves it via the icon theme.
  local icon_tmp; icon_tmp="$(mktemp -d)"
  local found_icon=0

  # 1. .icns from dmg source
  if [[ "$FACTORY_SOURCE" == "dmg" ]]; then
    local icns
    icns="$(find "$CACHE_DIR/src-${FACTORY_SOURCE}" -path '*Resources*' -name '*.icns' 2>/dev/null | head -1 || true)"
    if [[ -n "$icns" ]]; then
      7z e "$icns" -o"$icon_tmp/icns" -y >/dev/null 2>&1 || true
      # icns files contain PNGs named by size; copy each into the right dir.
      local png
      for png in "$icon_tmp/icns"/*.png; do
        [[ -s "$png" ]] || continue
        local sz; sz="$(identify_png_size "$png")"
        [[ -n "$sz" ]] || continue
        local dir="$icons/${sz}x${sz}/apps"
        mkdir -p "$dir"
        cp "$png" "$dir/factory.png"
        found_icon=1
      done
    fi
  fi

  # 2. .ico from exe source
  if [[ "$found_icon" == "0" && "$FACTORY_SOURCE" == "exe" ]]; then
    local ico
    ico="$(find "$CACHE_DIR/src-${FACTORY_SOURCE}" -name '*.ico' 2>/dev/null | head -1 || true)"
    if [[ -n "$ico" ]]; then
      # ico is also a container 7z can unpack into individual PNGs/BMPs.
      7z e "$ico" -o"$icon_tmp/ico" -y >/dev/null 2>&1 || true
      local png
      for png in "$icon_tmp/ico"/*.png; do
        [[ -s "$png" ]] || continue
        local sz; sz="$(identify_png_size "$png")"
        [[ -n "$sz" ]] || continue
        local dir="$icons/${sz}x${sz}/apps"
        mkdir -p "$dir"
        cp "$png" "$dir/factory.png"
        found_icon=1
      done
    fi
  fi

  # 3. Fallback: extract PNG icons from app.asar renderer assets.
  if [[ "$found_icon" == "0" ]]; then
    local asar_tmp; asar_tmp="$(mktemp -d)"
    if ( cd "$asar_tmp" && npx --yes @electron/asar extract "$EXTRACTED_ASAR" unpacked >/dev/null 2>&1 ); then
      # The renderer ships logo/icon PNGs under the assets directory.
      local best_png="" best_sz=0 png
      while IFS= read -r png; do
        [[ -s "$png" ]] || continue
        local sz; sz="$(identify_png_size "$png")"
        [[ -n "$sz" ]] || continue
        # Pick the largest available; also install each standard size.
        for want in 48 128 256 512; do
          if [[ "$sz" == "$want" ]]; then
            local dir="$icons/${sz}x${sz}/apps"
            mkdir -p "$dir"
            cp "$png" "$dir/factory.png"
            found_icon=1
          fi
        done
        if [[ "$sz" -gt "$best_sz" ]]; then best_sz="$sz"; best_png="$png"; fi
      done < <(find "$asar_tmp/unpacked" -type f \( -iname '*icon*.png' -o -iname '*logo*.png' -o -iname 'factory*.png' \) 2>/dev/null)
      # If no exact standard size matched, install the largest as 512.
      if [[ "$found_icon" == "0" && -n "$best_png" ]]; then
        cp "$best_png" "$icons/512x512/apps/factory.png"
        found_icon=1
      fi
    fi
    rm -rf "$asar_tmp"
  fi

  [[ "$found_icon" == "1" ]] \
    && log "  icon installed to $icons" \
    || warn "  no icon found; .desktop will use a generic application icon"

  rm -rf "$icon_tmp"

  cat > "$apps/factory.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Factory
Comment=Desktop app for Factory Droids (Linux port)
Exec=$BIN_DIR/factory %U
Icon=factory
Terminal=false
Categories=Development;Utility;
StartupWMClass=Factory
MimeType=x-scheme-handler/factory;
DESKTOP
  update-desktop-database "$apps" 2>/dev/null || true
  gtk-update-icon-cache -f -t "${icons%/hicolor}" 2>/dev/null || true
}

# Read the dimensions of a PNG file and echo "WxH" (e.g. "512x512"). We only
# need the size for sorting into the right hicolor dir. Reads the IHDR chunk
# directly so we don't depend on file/ImageMagick being installed.
identify_png_size() { # file
  local f="$1"
  # PNG signature is 8 bytes, then IHDR (length=13, "IHDR", width, height).
  # Width/height are big-endian 32-bit ints at file offsets 16 and 20.
  [[ -s "$f" ]] || return 0
  # Verify PNG signature (first 8 bytes: 89 50 4E 47 0D 0A 1A 0A)
  local sig; sig="$(head -c 8 "$f" | od -An -tx1 | tr -d ' \n')"
  [[ "$sig" == "89504e470d0a1a0a" ]] || return 0
  local w h
  w="$(head -c 24 "$f" | tail -c 8 | od -An -N4 -tx1 | tr -d ' \n')"
  h="$(head -c 28 "$f" | tail -c 4 | od -An -N4 -tx1 | tr -d ' \n')"
  # Convert hex to decimal
  w=$((16#$w))
  h=$((16#$h))
  # Square icons only; non-square images aren't app-menu icons.
  [[ "$w" == "$h" ]] && echo "$w"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
  log "Factory desktop -> Linux  (arch=${NPM_ARCH}, source=${FACTORY_SOURCE})"
  resolve_version
  log "Target version: $FACTORY_VERSION"
  fetch_app_asar
  fetch_droid_binary
  fetch_electron
  assemble
  echo
  log "Done. Launch with: $BIN_DIR/factory"
  if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    warn "Note: $BIN_DIR is not on your PATH. Add it, or run:"
    warn "  $BIN_DIR/factory"
  fi
  [[ "$KEEP_CACHE" == "1" ]] || warn "Cache kept at $CACHE_DIR (set KEEP_CACHE=1 to keep across runs)."
}

main "$@"
