#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_root="$repo_root/build"
app="$build_root/KongFetch.app"
if [[ ! -d "$app" ]]; then bash "$repo_root/scripts/build.sh"; fi
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
package="$build_root/package-$version"
output="$build_root/dist"
mkdir -p "$package" "$output"
ditto "$app" "$package/KongFetch.app"
cp "$repo_root/docs/开始使用-$version.txt" "$package/开始使用.txt"
if [[ ! -e "$package/Applications" && ! -L "$package/Applications" ]]; then ln -s /Applications "$package/Applications"; fi
hdiutil create -volname KongFetch -srcfolder "$package" -ov -format UDZO "$output/KongFetch-$version-Mac.dmg"
zip_package="$build_root/zip-$version"
mkdir -p "$zip_package"
ditto "$app" "$zip_package/KongFetch.app"
cp "$repo_root/docs/开始使用-$version.txt" "$zip_package/开始使用.txt"
ditto -c -k --sequesterRsrc --keepParent "$zip_package" "$output/KongFetch-$version-Mac.zip"
(cd "$output" && shasum -a 256 "KongFetch-$version-Mac.dmg" "KongFetch-$version-Mac.zip" > "KongFetch-$version-SHA256.txt")
printf 'Packaged: %s\n' "$output"
