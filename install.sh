#!/bin/bash
set -e

BUILD_DMG=1
case "${1:-}" in
    "") ;;
    --no-dmg) BUILD_DMG=0 ;;
    *) echo "Usage: $0 [--no-dmg]" >&2; exit 2 ;;
esac

WHISPERMAC_DIR="$HOME/.whispermac"
MODELS_DIR="$WHISPERMAC_DIR/models"
BIN_DIR="$WHISPERMAC_DIR/bin"
APP_DIR="$WHISPERMAC_DIR/WhisperMac.app"
WHISPERCPP_DIR="$WHISPERMAC_DIR/whisper.cpp"
CMAKE_DIR="$WHISPERMAC_DIR/cmake"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

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
echo "[1/5] OK"

mkdir -p "$MODELS_DIR" "$BIN_DIR" "$CMAKE_DIR"

# ─── Step 2: cmake ──────────────────────────────────────────────
CMAKE_BIN=""
if command -v cmake &>/dev/null; then
    CMAKE_BIN="cmake"
    echo "[2/5] cmake: system"
elif [ -x "$CMAKE_DIR/CMake.app/Contents/bin/cmake" ]; then
    CMAKE_BIN="$CMAKE_DIR/CMake.app/Contents/bin/cmake"
    echo "[2/5] cmake: cached"
else
    echo "[2/5] Downloading cmake..."
    CMAKE_VERSION="3.30.6"
    curl -fL "https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/cmake-${CMAKE_VERSION}-macos-universal.tar.gz" \
         -o /tmp/cmake.tar.gz
    rm -rf "$CMAKE_DIR"
    mkdir -p "$CMAKE_DIR"
    tar xzf /tmp/cmake.tar.gz -C "$CMAKE_DIR" --strip-components=1
    CMAKE_BIN="$CMAKE_DIR/CMake.app/Contents/bin/cmake"
    chmod +x "$CMAKE_BIN"
    echo "[2/5] cmake: OK"
fi

# ─── Step 3: Build whisper.cpp ──────────────────────────────────
echo "[3/5] Building whisper.cpp..."
if [ -d "$WHISPERCPP_DIR" ] && [ ! -f "$WHISPERCPP_DIR/ggml/include/ggml.h" ]; then
    rm -rf "$WHISPERCPP_DIR"
fi
if [ ! -d "$WHISPERCPP_DIR" ]; then
    git clone --depth 1 https://github.com/ggerganov/whisper.cpp.git "$WHISPERCPP_DIR"
fi

cd "$WHISPERCPP_DIR"
BUILD_LOG="$WHISPERMAC_DIR/build.log"
CPU_COUNT=$(sysctl -n hw.ncpu 2>/dev/null || getconf NPROCESSORS_ONLN 2>/dev/null || echo 4)
if ! "$CMAKE_BIN" -B build -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="$(uname -m)" \
    -DWHISPER_NO_AVX=ON -DWHISPER_NO_AVX2=ON \
    -DWHISPER_NO_FMA=ON -DWHISPER_NO_F16C=ON \
    -DWHISPER_COREML=OFF \
    -DBUILD_SHARED_LIBS=OFF \
    -DGGML_METAL=OFF \
    -DGGML_ACCELERATE=ON \
    > "$BUILD_LOG" 2>&1; then
    tail -40 "$BUILD_LOG" >&2
    exit 1
fi
if ! "$CMAKE_BIN" --build build -j"$CPU_COUNT" --target whisper-cli >> "$BUILD_LOG" 2>&1; then
    tail -40 "$BUILD_LOG" >&2
    exit 1
fi
cp build/bin/whisper-cli "$BIN_DIR/whisper-cli"
cd "$REPO_DIR"
echo "[3/5] whisper-cli OK"

# ─── Step 4: Download model ─────────────────────────────────────
MODEL_NAME="ggml-medium.bin"
MODEL_PATH="$MODELS_DIR/$MODEL_NAME"
MODEL_MIN_BYTES=1400000000
echo "[4/5] Downloading model $MODEL_NAME (~1.5 GB)..."
if [ -f "$MODEL_PATH" ]; then
    ACTUAL_SIZE=$(stat -f%z "$MODEL_PATH" 2>/dev/null || echo 0)
    HEADER=$(od -An -tx1 -N4 "$MODEL_PATH" | tr -d ' \n')
    if [ "$ACTUAL_SIZE" -lt "$MODEL_MIN_BYTES" ] || [ "$HEADER" != "6c6d6767" ]; then
        rm -f "$MODEL_PATH"
    fi
fi
if [ ! -f "$MODEL_PATH" ]; then
    curl -fL -C - "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$MODEL_NAME" \
         -o "$MODEL_PATH" --retry 3 --retry-delay 5
fi
ACTUAL_SIZE=$(stat -f%z "$MODEL_PATH")
HEADER=$(od -An -tx1 -N4 "$MODEL_PATH" | tr -d ' \n')
if [ "$ACTUAL_SIZE" -lt "$MODEL_MIN_BYTES" ] || [ "$HEADER" != "6c6d6767" ]; then
    echo "Model download is incomplete or invalid" >&2
    exit 1
fi
echo "[4/5] Model OK"

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
    Sources/main.swift

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
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>WhisperMac needs microphone access to transcribe your voice.</string>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>LSUIElement</key>
    <true/>
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
fi

echo "[5/5] WhisperMac.app OK"

# ─── Install to /Applications ───────────────────────────────────
STAGED_APP="/Applications/.WhisperMac.app.new"
BACKUP_APP="/Applications/.WhisperMac.app.previous"
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
rm -rf "$BACKUP_APP"
if [ -d /Applications/WhisperMac.app ]; then
    mv /Applications/WhisperMac.app "$BACKUP_APP"
fi
if ! mv "$STAGED_APP" /Applications/WhisperMac.app; then
    if [ -d "$BACKUP_APP" ]; then
        mv "$BACKUP_APP" /Applications/WhisperMac.app
    fi
    exit 1
fi
rm -rf "$BACKUP_APP"

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
        <string>/Applications/WhisperMac.app/Contents/MacOS/WhisperMac</string>
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
    echo "The app was installed, but macOS did not start its login agent." >&2
    echo "Run 'launchctl bootstrap gui/$(id -u) $PLIST_PATH' from Terminal or log out and back in." >&2
    exit 1
fi

echo ""
echo "================================================"
echo "         WhisperMac — INSTALLED"
echo "================================================"
echo ""
echo "  App:      /Applications/WhisperMac.app"
if [ "$BUILD_DMG" -eq 1 ]; then
    echo "  DMG:      $REPO_DIR/WhisperMac.dmg"
fi
echo "  whisper:  $BIN_DIR/whisper-cli"
echo "  Model:    $MODEL_PATH"
echo "  Logs:     $WHISPERMAC_DIR/stdout.log and stderr.log"
echo ""
echo "=== USAGE ==="
echo "  Hold Right ⌘ → speak → release → text appears"
echo "  Click menu bar icon → Preferences → change model"
echo "  Cmd+, = open Preferences"
echo ""
echo "=== PERMISSIONS (one time) ==="
echo "  Settings → Privacy → Microphone → enable WhisperMac"
echo "  Settings → Privacy → Input Monitoring → enable WhisperMac"
echo ""
echo "  Settings → Privacy → Accessibility → enable WhisperMac"
echo ""
