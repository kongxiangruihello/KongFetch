#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_root="$repo_root/build"
app="$build_root/KongFetch.app"
mkdir -p "$build_root" "$app/Contents/MacOS" "$app/Contents/Resources"
for arch in arm64 x86_64; do
  xcrun swiftc "$repo_root/Sources/main.swift" "$repo_root/Sources/Features30.swift" "$repo_root/Sources/Features31.swift" \
    -o "$build_root/KongFetch-$arch" -target "$arch-apple-macosx13.0" \
    -framework Cocoa -framework Quartz -framework Carbon \
    -framework ServiceManagement -framework UniformTypeIdentifiers \
    -framework PDFKit -framework CoreServices -framework CryptoKit \
    -framework Vision -framework IOKit -lcompression \
    -module-cache-path "$build_root/module-cache-$arch"
done
lipo -create "$build_root/KongFetch-arm64" "$build_root/KongFetch-x86_64" -output "$app/Contents/MacOS/KongFetch"
cp "$repo_root/app/Info.plist" "$app/Contents/Info.plist"
cp "$repo_root/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
chmod +x "$app/Contents/MacOS/KongFetch"
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"
printf 'Built: %s\n' "$app"
