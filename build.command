#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
app_dir="$project_dir/dist/秒搜.app"

mkdir -p "$app_dir/Contents/MacOS"
mkdir -p "$app_dir/Contents/Resources"
/usr/bin/swiftc -swift-version 5 -O \
  -framework AppKit -framework Carbon \
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
