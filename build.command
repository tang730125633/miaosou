#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
app_dir="$project_dir/dist/秒搜.app"
icon_source="$project_dir/assets/app-icon.svg"
iconset_dir="$project_dir/dist/AppIcon.iconset"

mkdir -p "$app_dir/Contents/MacOS"
mkdir -p "$app_dir/Contents/Resources"
mkdir -p "$iconset_dir"
render_icon() {
  /usr/bin/sips -z "$2" "$2" -s format png "$icon_source" --out "$iconset_dir/$1" >/dev/null
}
render_icon icon_16x16.png 16
render_icon icon_16x16@2x.png 32
render_icon icon_32x32.png 32
render_icon icon_32x32@2x.png 64
render_icon icon_128x128.png 128
render_icon icon_128x128@2x.png 256
render_icon icon_256x256.png 256
render_icon icon_256x256@2x.png 512
render_icon icon_512x512.png 512
render_icon icon_512x512@2x.png 1024
/usr/bin/iconutil -c icns "$iconset_dir" -o "$app_dir/Contents/Resources/AppIcon.icns"
/usr/bin/swiftc -swift-version 5 -O \
  -framework AppKit -framework Carbon -framework QuickLookUI \
  "$project_dir/main.swift" \
  -o "$app_dir/Contents/MacOS/秒搜"
/usr/bin/plutil -lint "$project_dir/Info.plist"
/usr/bin/ditto "$project_dir/Info.plist" "$app_dir/Contents/Info.plist"
/usr/bin/ditto "$project_dir/bookmarks.json" "$app_dir/Contents/Resources/bookmarks.json"
/usr/bin/codesign --force --deep --sign - "$app_dir"
"$app_dir/Contents/MacOS/秒搜" --self-check
/usr/bin/pkill -x "秒搜" 2>/dev/null || true
for _ in {1..30}; do
  /usr/bin/pgrep -x "秒搜" >/dev/null || break
  /bin/sleep 0.1
done
/usr/bin/ditto "$app_dir" "/Applications/秒搜.app"
/usr/bin/osascript -e 'tell application "System Events" to if name of every login item does not contain "秒搜" then make login item at end with properties {name:"秒搜", path:"/Applications/秒搜.app", hidden:true}'
/usr/bin/open -n "/Applications/秒搜.app"

echo "秒搜已安装到 /Applications/秒搜.app"
