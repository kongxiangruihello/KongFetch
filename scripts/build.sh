#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_root="$repo_root/build"
app="$build_root/KongFetch.app"
mkdir -p "$build_root" "$app/Contents/MacOS" "$app/Contents/Resources"
for arch in arm64 x86_64; do
  xcrun swiftc "$repo_root/Sources/main.swift" "$repo_root/Sources/Features30.swift" "$repo_root/Sources/Features31.swift" "$repo_root"/Sources/Features32*.swift \
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
# Input Monitoring (double Control) is granted to the app's designated requirement. An ad hoc signature's
# requirement is its cdhash, which changes on every build, so each update silently loses the permission.
# Signing with a stable identity (a self-signed "Code Signing" certificate is enough) keeps it across builds.
identity="${KONGFETCH_SIGN_IDENTITY:-KongFetch Local Signing}"
if security find-identity -p codesigning | grep -Fq "\"$identity\""; then
  codesign --force --deep --sign "$identity" --identifier com.kongfetch.mac "$app"
  printf 'Signed with stable identity: %s\n' "$identity"
else
  codesign --force --deep --sign - "$app"
  printf 'WARNING: identity "%s" not found; using ad hoc signing. Input Monitoring must be re-granted after every build.\n' "$identity" >&2
fi
codesign --verify --deep --strict "$app"
codesign --display -r - "$app" 2>/dev/null | grep designated || true
printf 'Built: %s\n' "$app"
