#!/usr/bin/env bash
#
# install-macos.sh — build and install the projectMSDL fork with native macOS
# system-audio capture, from a fresh clone, on any Apple-silicon/Intel Mac.
#
# What it does:
#   1. Installs Homebrew build dependencies.
#   2. Builds libprojectM 4 from source into a local prefix (Homebrew only ships v3).
#   3. Builds this frontend against it.
#   4. Stages a runnable, ad-hoc-signed projectM.app and installs it to ~/Applications.
#   5. Points the app at Homebrew's preset library.
#
# Re-running is safe/idempotent. Pass --force-projectm to rebuild libprojectM 4.
#
# Requirements: macOS 14.4+ (Core Audio process-tap API), Xcode Command Line Tools,
# and Homebrew.

set -euo pipefail

# --- configuration (override via environment) ---------------------------------
PROJECTM_PREFIX="${PROJECTM_PREFIX:-$HOME/.local/projectM4}"
APP_INSTALL_DIR="${APP_INSTALL_DIR:-$HOME/Applications}"
# libprojectM 4 git ref to build. Pinned to the exact commit this fork was
# developed and verified against (reports version 4.2.0; master is ahead of the
# latest v4.1.7 release tag). Accepts a full SHA, tag, or branch name.
PROJECTM_REF="${PROJECTM_REF:-2f244141320f6b97b09bf99964cc72a4efdfcfd3}"
BUILD_JOBS="$(sysctl -n hw.ncpu)"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="projectM.app"
BUNDLE_ID="org.projectm.frontend.sdl2"

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# --- preflight ----------------------------------------------------------------
[ "$(uname -s)" = "Darwin" ] || die "This installer is macOS-only."

macos_major="$(sw_vers -productVersion | cut -d. -f1)"
macos_minor="$(sw_vers -productVersion | cut -d. -f2)"
if [ "$macos_major" -lt 14 ] || { [ "$macos_major" -eq 14 ] && [ "$macos_minor" -lt 4 ]; }; then
    die "macOS 14.4+ required for the Core Audio process-tap API (found $(sw_vers -productVersion))."
fi

command -v brew >/dev/null 2>&1 || die "Homebrew not found. Install it from https://brew.sh first."
xcode-select -p >/dev/null 2>&1 || die "Xcode Command Line Tools not found. Run: xcode-select --install"

# The Core Audio process-tap API needs an SDK that ships AudioHardwareTapping.h.
# A macOS 14.4+ machine with outdated Command Line Tools can lack it; fail clearly.
sdk_path="$(xcrun --show-sdk-path 2>/dev/null || true)"
if [ -z "$sdk_path" ] || [ ! -f "$sdk_path/System/Library/Frameworks/CoreAudio.framework/Headers/AudioHardwareTapping.h" ]; then
    die "Your SDK lacks the Core Audio process-tap headers. Update the Command Line Tools (Software Update, or 'sudo rm -rf /Library/Developer/CommandLineTools && xcode-select --install')."
fi

BREW_PREFIX="$(brew --prefix)"

# --- 1. Homebrew dependencies -------------------------------------------------
log "Installing Homebrew build dependencies"
# 'projectm' (v3) is installed only for its bundled preset library; the frontend
# links against the v4 library we build below.
brew install cmake pkg-config poco glm sdl2 freetype projectm

PRESET_PATH="$BREW_PREFIX/share/projectM/presets"

# --- 2. Build libprojectM 4 from source --------------------------------------
if [ -f "$PROJECTM_PREFIX/include/projectM-4/projectM.h" ] && [ "${1:-}" != "--force-projectm" ]; then
    log "libprojectM 4 already present at $PROJECTM_PREFIX (use --force-projectm to rebuild)"
else
    log "Building libprojectM 4 from source (ref: $PROJECTM_REF)"
    src_dir="$(mktemp -d)/libprojectM4"
    # Shallow fetch by ref so a pinned commit SHA (as well as a tag or branch)
    # resolves reproducibly. GitHub allows fetching an unadvertised SHA directly.
    git init -q "$src_dir"
    git -C "$src_dir" remote add origin https://github.com/projectM-visualizer/projectm.git
    git -C "$src_dir" fetch -q --depth 1 origin "$PROJECTM_REF"
    git -C "$src_dir" checkout -q FETCH_HEAD
    git -C "$src_dir" submodule update -q --init --recursive --depth 1
    cmake -S "$src_dir" -B "$src_dir/build" -G "Unix Makefiles" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PROJECTM_PREFIX" \
        -DCMAKE_PREFIX_PATH="$BREW_PREFIX" \
        -DENABLE_PLAYLIST=ON \
        -DBUILD_TESTING=OFF \
        -DBUILD_SHARED_LIBS=ON
    cmake --build "$src_dir/build" --parallel "$BUILD_JOBS"
    cmake --install "$src_dir/build"
    rm -rf "$(dirname "$src_dir")"
fi

# --- 3. Build the frontend ----------------------------------------------------
log "Configuring and building the frontend"
cmake -S "$REPO_ROOT" -B "$REPO_ROOT/build" -G "Unix Makefiles" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_PREFIX_PATH="$BREW_PREFIX;$PROJECTM_PREFIX" \
    -DENABLE_FLAT_PACKAGE=OFF
cmake --build "$REPO_ROOT/build" --parallel "$BUILD_JOBS"

# --- 4. Stage, fix up, sign, and install the .app -----------------------------
log "Staging the application bundle"
staged="$REPO_ROOT/dist/$APP_NAME"
rm -rf "$REPO_ROOT/dist"
cmake --install "$REPO_ROOT/build" --prefix "$REPO_ROOT/dist" >/dev/null

bin="$staged/Contents/MacOS/projectM"

# Let the bundle find libprojectM 4 in the local prefix.
if ! otool -l "$bin" | grep -q "$PROJECTM_PREFIX/lib"; then
    install_name_tool -add_rpath "$PROJECTM_PREFIX/lib" "$bin"
fi

# Point the app at Homebrew's preset library.
props="$staged/Contents/Resources/projectM.properties"
if [ -f "$props" ] && ! grep -q "install-macos.sh" "$props"; then
    {
        printf '\n# Added by install-macos.sh: use the Homebrew-provided preset library\n'
        printf 'projectM.presetPath = %s\n' "$PRESET_PATH"
    } >> "$props"
fi

# Ad-hoc code signing is REQUIRED: macOS keys the system-audio-capture (TCC)
# permission to a signing identity. Unsigned bundles get silence, no prompt.
log "Ad-hoc code signing the bundle"
codesign --force --deep --sign - "$staged"

log "Installing to $APP_INSTALL_DIR/$APP_NAME"
mkdir -p "$APP_INSTALL_DIR"
rm -rf "${APP_INSTALL_DIR:?}/$APP_NAME"
cp -R "$staged" "$APP_INSTALL_DIR/$APP_NAME"
# Re-sign in place so the signature matches the final on-disk location.
codesign --force --deep --sign - "$APP_INSTALL_DIR/$APP_NAME"

# --- done ---------------------------------------------------------------------
cat <<EOF

$(log "Done.")

Launch it with:

    open "$APP_INSTALL_DIR/$APP_NAME"

On first launch, macOS will ask to record this computer's audio — click Allow.
Then play any audio and it will visualize your system output (no BlackHole needed).

If audio never reacts, re-arm the permission prompt and relaunch:

    tccutil reset SystemAudioCaptureRequests $BUNDLE_ID
    open "$APP_INSTALL_DIR/$APP_NAME"
EOF
