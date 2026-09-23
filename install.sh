#!/bin/bash
set -euo pipefail

BUILD_DMG=0
ENGINE_ONLY=0
case "${1:-}" in
    ""|--no-dmg) ;;
    --app-only-dmg) BUILD_DMG=1 ;;
    --engine-only) ENGINE_ONLY=1 ;;
    *) echo "Usage: $0 [--no-dmg|--app-only-dmg|--engine-only]" >&2; exit 2 ;;
esac

WHISPERMAC_DIR="$HOME/.whispermac"
MODELS_DIR="$WHISPERMAC_DIR/models"
BIN_DIR="$WHISPERMAC_DIR/bin"
APP_DIR="$WHISPERMAC_DIR/WhisperMac.app"
WHISPERCPP_DIR="$WHISPERMAC_DIR/whisper.cpp"
CMAKE_DIR="$WHISPERMAC_DIR/cmake"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
WHISPERCPP_COMMIT="307869af285d7f6f689ba100b3515e2d1b3feb05"
WHISPERCPP_URL="https://github.com/ggml-org/whisper.cpp.git"

if [ "$ENGINE_ONLY" -eq 1 ]; then
    EXISTING_APP=/Applications/WhisperMac.app
    if [ ! -d "$EXISTING_APP" ]; then EXISTING_APP="$HOME/Applications/WhisperMac.app"; fi
    EXISTING_VERSION=$(plutil -extract CFBundleVersion raw -o - "$EXISTING_APP/Contents/Info.plist" 2>/dev/null || true)
    if [[ ! "$EXISTING_VERSION" =~ ^[0-9]+$ ]] || [ "$EXISTING_VERSION" -lt 2 ]; then
        echo "--engine-only requires WhisperMac 1.1 or newer. Run bash install.sh once first." >&2
        exit 1
    fi
fi

cmake_is_compatible() {
    local version major minor remainder
    version=$("$1" --version | awk 'NR == 1 { print $3 }') || return 1
    major=${version%%.*}
    remainder=${version#*.}
    minor=${remainder%%.*}
    [[ $major =~ ^[0-9]+$ && $minor =~ ^[0-9]+$ ]] || return 1
    (( major > 3 || (major == 3 && minor >= 14) ))
}

echo "================================================"
echo "         WhisperMac Installer"
echo "================================================"
echo ""

# ─── Step 1: Xcode Command Line Tools ──────────────────────────
echo "[1/5] Checking Xcode Command Line Tools..."
if ! xcode-select -p &>/dev/null; then
    echo "      Not found. Installing..."
    xcode-select --install
    echo "      Click Install in the popup, wait, then run ./install.sh again."
    exit 1
fi
for tool in git swiftc clang curl codesign shasum; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Missing $tool. Finish installing Xcode Command Line Tools, then run ./install.sh again." >&2
        exit 1
    fi
done
echo "[1/5] OK"

mkdir -p "$MODELS_DIR" "$BIN_DIR" "$CMAKE_DIR"

# ─── Step 2: cmake ──────────────────────────────────────────────
CMAKE_BIN=""
if command -v cmake &>/dev/null && cmake_is_compatible cmake; then
    CMAKE_BIN="cmake"
    echo "[2/5] cmake: system"
elif [ -x "$CMAKE_DIR/CMake.app/Contents/bin/cmake" ] && cmake_is_compatible "$CMAKE_DIR/CMake.app/Contents/bin/cmake"; then
    CMAKE_BIN="$CMAKE_DIR/CMake.app/Contents/bin/cmake"
    echo "[2/5] cmake: cached"
else
    echo "[2/5] Downloading cmake..."
    CMAKE_VERSION="3.30.6"
    CMAKE_ARCHIVE="$CMAKE_DIR/cmake-${CMAKE_VERSION}-macos-universal.tar.gz"
    curl -fL "https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/cmake-${CMAKE_VERSION}-macos-universal.tar.gz" \
         --retry 3 --retry-delay 3 -o "$CMAKE_ARCHIVE"
    tar xzf "$CMAKE_ARCHIVE" -C "$CMAKE_DIR" --strip-components=1
    CMAKE_BIN="$CMAKE_DIR/CMake.app/Contents/bin/cmake"
    chmod +x "$CMAKE_BIN"
    if ! cmake_is_compatible "$CMAKE_BIN"; then
        echo "Downloaded cmake cannot run on this Mac." >&2
        exit 1
    fi
    echo "[2/5] cmake: OK"
fi

# ─── Step 3: Build whisper.cpp ──────────────────────────────────
echo "[3/5] Building whisper.cpp..."
if [ ! -e "$WHISPERCPP_DIR" ]; then
    mkdir -p "$WHISPERCPP_DIR"
    git -C "$WHISPERCPP_DIR" init -q
elif [ ! -d "$WHISPERCPP_DIR/.git" ]; then
    echo "$WHISPERCPP_DIR exists but is not a Git checkout. Move it aside and retry." >&2
    exit 1
fi
if [ "$(git -C "$WHISPERCPP_DIR" rev-parse HEAD 2>/dev/null || true)" != "$WHISPERCPP_COMMIT" ]; then
    git -C "$WHISPERCPP_DIR" fetch --depth 1 "$WHISPERCPP_URL" "$WHISPERCPP_COMMIT"
    git -C "$WHISPERCPP_DIR" checkout --detach -q FETCH_HEAD
fi
test "$(git -C "$WHISPERCPP_DIR" rev-parse HEAD)" = "$WHISPERCPP_COMMIT"

cd "$WHISPERCPP_DIR"
BUILD_LOG="$WHISPERMAC_DIR/build.log"
CPU_COUNT=$(sysctl -n hw.ncpu 2>/dev/null || getconf NPROCESSORS_ONLN 2>/dev/null || echo 4)
if [ "$CPU_COUNT" -gt 4 ]; then CPU_COUNT=4; fi
METAL_MODE=OFF
if [ "$(uname -m)" = arm64 ]; then METAL_MODE=ON; fi
if ! "$CMAKE_BIN" -B build -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="$(uname -m)" \
    -DWHISPER_COREML=OFF \
    -DBUILD_SHARED_LIBS=OFF \
    -DGGML_METAL="$METAL_MODE" \
    -DGGML_METAL_EMBED_LIBRARY=ON \
    -DGGML_ACCELERATE=ON \
    > "$BUILD_LOG" 2>&1; then
    tail -40 "$BUILD_LOG" >&2
    exit 1
fi
if ! "$CMAKE_BIN" --build build -j"$CPU_COUNT" --target whisper-cli >> "$BUILD_LOG" 2>&1; then
    tail -40 "$BUILD_LOG" >&2
    exit 1
fi
install -m 755 build/bin/whisper-cli "$BIN_DIR/.whisper-cli.new"
mv -f "$BIN_DIR/.whisper-cli.new" "$BIN_DIR/whisper-cli"
cd "$REPO_DIR"
echo "[3/5] whisper-cli OK (Metal: $METAL_MODE)"

# ─── Step 4: Download model ─────────────────────────────────────
MODEL_NAME="ggml-medium.bin"
MODEL_PATH="$MODELS_DIR/$MODEL_NAME"
MODEL_SHA256="6c14d5adee5f86394037b4e4e8b59f1673b6cee10e3cf0b11bbdbee79c156208"
MODEL_DOWNLOAD="$MODEL_PATH.download"
echo "[4/5] Downloading model $MODEL_NAME (~1.5 GB)..."
if [ ! -f "$MODEL_PATH" ] || [ "$(shasum -a 256 "$MODEL_PATH" | awk '{ print $1 }')" != "$MODEL_SHA256" ]; then
    curl -fL -C - "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$MODEL_NAME" \
         -o "$MODEL_DOWNLOAD" --retry 3 --retry-delay 5
    ACTUAL_HASH=$(shasum -a 256 "$MODEL_DOWNLOAD" | awk '{ print $1 }')
    if [ "$ACTUAL_HASH" != "$MODEL_SHA256" ]; then
        echo "Model checksum mismatch. Remove $MODEL_DOWNLOAD and retry." >&2
        exit 1
    fi
    mv -f "$MODEL_DOWNLOAD" "$MODEL_PATH"
fi
echo "[4/5] Model OK"

if [ "$ENGINE_ONLY" -eq 1 ]; then
    echo "Engine updated at $BIN_DIR/whisper-cli. The installed app was not replaced."
    echo "This mode requires an app version that reads the external engine."
    exit 0
fi

# ─── Step 5: Build WhisperMac.app ───────────────────────────────
echo "[5/5] Building WhisperMac.app..."
cd "$REPO_DIR"

rm -rf build
mkdir -p build/WhisperMac.app/Contents/MacOS
mkdir -p build/WhisperMac.app/Contents/Resources

swiftc -o "build/WhisperMac.app/Contents/MacOS/WhisperMac" \
    -module-name WhisperMac \
    -framework Cocoa -framework AVFoundation \
    -module-cache-path "$WHISPERMAC_DIR/swift-module-cache" \
    -Xcc "-fmodules-cache-path=$WHISPERMAC_DIR/clang-module-cache" \
    -O -whole-module-optimization \
    Sources/*.swift

cp "$BIN_DIR/whisper-cli" "build/WhisperMac.app/Contents/Resources/whisper-cli"
chmod +x "build/WhisperMac.app/Contents/Resources/whisper-cli"

cat > "build/WhisperMac.app/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>WhisperMac</string>
    <key>CFBundleIdentifier</key>
    <string>com.whispermac</string>
    <key>CFBundleName</key>
    <string>WhisperMac</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>3</string>
    <key>CFBundleShortVersionString</key>
    <string>1.2</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>WhisperMac needs microphone access to transcribe your voice.</string>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
</dict>
</plist>
PLIST

codesign --force --sign - "build/WhisperMac.app/Contents/Resources/whisper-cli" > /dev/null 2>&1
codesign --force --sign - --entitlements entitlements.plist \
    "build/WhisperMac.app" \
    > /dev/null 2>&1
codesign --verify --deep --strict "build/WhisperMac.app"

rm -rf "$APP_DIR"
cp -R "build/WhisperMac.app" "$APP_DIR"

# ─── DMG ────────────────────────────────────────────────────────
if [ "$BUILD_DMG" -eq 1 ]; then
    hdiutil create -volname WhisperMac -srcfolder build/WhisperMac.app -ov -format UDZO "$REPO_DIR/WhisperMac.dmg" > /dev/null
    echo "This app-only DMG does not include the model. Use install.sh on another Mac." >&2
fi

echo "[5/5] WhisperMac.app OK"

# ─── Install to /Applications ───────────────────────────────────
if [ -w /Applications ]; then
    INSTALL_DIR="/Applications"
else
    INSTALL_DIR="$HOME/Applications"
    mkdir -p "$INSTALL_DIR"
fi
INSTALLED_APP="$INSTALL_DIR/WhisperMac.app"
STAGED_APP="$INSTALL_DIR/.WhisperMac.app.new"
BACKUP_APP="$INSTALL_DIR/.WhisperMac.app.previous.$(date +%Y%m%d%H%M%S).$$"
SERVICE_TARGET="gui/$(id -u)/com.whispermac"
rm -rf "$STAGED_APP"
cp -R "$APP_DIR" "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"
if launchctl print "$SERVICE_TARGET" >/dev/null 2>&1; then
    if ! launchctl bootout "$SERVICE_TARGET"; then
        echo "Could not stop the running WhisperMac login agent; the installed app was not replaced." >&2
        rm -rf "$STAGED_APP"
        exit 1
    fi
fi
killall WhisperMac 2>/dev/null || true
# Keep the previous app until the new build is verified in a normal user session.
if [ -d "$INSTALLED_APP" ]; then
    mv "$INSTALLED_APP" "$BACKUP_APP"
fi
if ! mv "$STAGED_APP" "$INSTALLED_APP"; then
    if [ -d "$BACKUP_APP" ]; then
        mv "$BACKUP_APP" "$INSTALLED_APP"
    fi
    exit 1
fi
# ─── LaunchAgent ─────────────────────────────────────────────────
PLIST_PATH="$HOME/Library/LaunchAgents/com.whispermac.plist"
mkdir -p "$HOME/Library/LaunchAgents"

cat > "$PLIST_PATH" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.whispermac</string>
    <key>ProgramArguments</key>
    <array>
        <string>${INSTALLED_APP}/Contents/MacOS/WhisperMac</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${WHISPERMAC_DIR}/stdout.log</string>
    <key>StandardErrorPath</key>
    <string>${WHISPERMAC_DIR}/stderr.log</string>
</dict>
</plist>
EOF

launchctl enable "$SERVICE_TARGET"
if ! launchctl bootstrap gui/"$(id -u)" "$PLIST_PATH"; then
    echo "The login agent could not start in this session; trying to open WhisperMac normally." >&2
    if ! open "$INSTALLED_APP"; then
        echo "Installed but could not start. Open $INSTALLED_APP in Finder; the login agent remains installed for the next login." >&2
        exit 1
    fi
fi

echo ""
echo "================================================"
echo "         WhisperMac — INSTALLED"
echo "================================================"
echo ""
echo "  App:      $INSTALLED_APP"
if [ -d "$BACKUP_APP" ]; then
    echo "  Backup:   $BACKUP_APP"
fi
if [ "$BUILD_DMG" -eq 1 ]; then
    echo "  DMG:      $REPO_DIR/WhisperMac.dmg"
fi
echo "  whisper:  $BIN_DIR/whisper-cli"
echo "  Model:    $MODEL_PATH"
echo "  Logs:     $WHISPERMAC_DIR/stdout.log and stderr.log"
echo ""
echo "=== USAGE ==="
echo "  Hold Right ⌘ → speak → release → text appears"
echo "  Open WhisperMac from the Dock → see status or change model"
echo "  Cmd+, = open Preferences"
echo ""
echo "=== PERMISSIONS (one time) ==="
echo "  Settings → Privacy → Microphone → enable WhisperMac"
echo "  Settings → Privacy → Input Monitoring → enable WhisperMac"
echo ""
echo "  Settings → Privacy → Accessibility → enable WhisperMac"
echo ""
