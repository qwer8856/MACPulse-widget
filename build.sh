#!/bin/zsh
set -euo pipefail

SOURCE_DIR="${0:A:h}"
BUILD_DIR="${2:-${TMPDIR:-/tmp}/macpulse-widget-build}"
OUTPUT_DIR="${1:-${BUILD_DIR}/dist}"
APP_PATH="$OUTPUT_DIR/系统状态.app"
WIDGET_PATH="$APP_PATH/Contents/PlugIns/SystemStatusWidget.appex"

mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources" "$WIDGET_PATH/Contents/MacOS" "$BUILD_DIR"
COMPILER_FLAGS=()
if [[ -n "${MONITOR_VFS_OVERLAY:-}" ]]; then
    COMPILER_FLAGS+=(-vfsoverlay "$MONITOR_VFS_OVERLAY")
elif [[ -f /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap && \
        -f /Library/Developer/CommandLineTools/usr/include/swift/bridging.modulemap ]]; then
    COMPILER_FLAGS+=(-vfsoverlay "$SOURCE_DIR/Compatibility/toolchain-overlay.json")
fi
for architecture in arm64 x86_64; do
    ARCH_BUILD_DIR="$BUILD_DIR/$architecture"
    mkdir -p "$ARCH_BUILD_DIR"
    xcrun swiftc -O -parse-as-library -swift-version 5 -target "$architecture-apple-macos14.0" \
    "${COMPILER_FLAGS[@]}" \
    -module-cache-path "$ARCH_BUILD_DIR/ModuleCache" \
    -framework AppKit -framework WidgetKit -framework IOKit -framework ServiceManagement \
    "$SOURCE_DIR/Metrics.swift" "$SOURCE_DIR/MenuBarMonitor.swift" "$SOURCE_DIR/LoginItem.swift" \
    "$SOURCE_DIR/ResourceMonitorWindow.swift" "$SOURCE_DIR/MenuBarStyle.swift" "$SOURCE_DIR/DetailedMetrics.swift" \
    "$SOURCE_DIR/ResourceDetailsView.swift" "$SOURCE_DIR/StatusDetailView.swift" "$SOURCE_DIR/StatusMenuView.swift" "$SOURCE_DIR/UpdateChecker.swift" "$SOURCE_DIR/NativeHost.swift" \
    -o "$ARCH_BUILD_DIR/DesktopMonitor"
    xcrun swiftc -O -parse-as-library -swift-version 5 -target "$architecture-apple-macos14.0" -D WIDGET_EXTENSION -application-extension \
    "${COMPILER_FLAGS[@]}" \
    -module-cache-path "$ARCH_BUILD_DIR/ModuleCache" \
    -Xlinker -e -Xlinker _NSExtensionMain \
    -framework AppKit -framework IOKit -framework SwiftUI -framework WidgetKit \
    "$SOURCE_DIR/Metrics.swift" "$SOURCE_DIR/NativeWidget.swift" \
    -o "$ARCH_BUILD_DIR/SystemStatusWidget"
done
xcrun lipo -create "$BUILD_DIR/arm64/DesktopMonitor" "$BUILD_DIR/x86_64/DesktopMonitor" \
    -output "$APP_PATH/Contents/MacOS/DesktopMonitor"
xcrun lipo -create "$BUILD_DIR/arm64/SystemStatusWidget" "$BUILD_DIR/x86_64/SystemStatusWidget" \
    -output "$WIDGET_PATH/Contents/MacOS/SystemStatusWidget"
xcrun lipo "$APP_PATH/Contents/MacOS/DesktopMonitor" -verify_arch arm64 x86_64
xcrun lipo "$WIDGET_PATH/Contents/MacOS/SystemStatusWidget" -verify_arch arm64 x86_64
cp "$SOURCE_DIR/Info.plist" "$APP_PATH/Contents/Info.plist"
cp "$SOURCE_DIR/WidgetInfo.plist" "$WIDGET_PATH/Contents/Info.plist"
if [[ -f "$SOURCE_DIR/AppIcon.icns" ]]; then
    cp "$SOURCE_DIR/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"
fi
xattr -cr "$APP_PATH"
codesign --force --sign - --entitlements "$SOURCE_DIR/Widget.entitlements" "$WIDGET_PATH"
codesign --force --sign - "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"
plutil -lint "$APP_PATH/Contents/Info.plist"
print -r -- "$APP_PATH"
