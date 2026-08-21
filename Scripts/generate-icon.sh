#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
repo_root=${script_dir:h}
source_png="$repo_root/Resources/ChatIcon.png"
destination_icns="$repo_root/OpenSuperWhisper/AppIcon.icns"
preview_png="$repo_root/docs/chat-icon.png"

for command_name in sips iconutil; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "Missing required macOS tool: $command_name" >&2
        exit 1
    fi
done

temporary_dir=$(mktemp -d)
trap 'rm -rf "$temporary_dir"' EXIT

rendered_png="$temporary_dir/ChatIcon.png"
sips -z 1024 1024 "$source_png" --out "$rendered_png" >/dev/null
if [[ ! -f "$rendered_png" ]]; then
    echo "Unable to prepare the PNG icon." >&2
    exit 1
fi

iconset="$temporary_dir/Chat.iconset"
mkdir -p "$iconset"

sips -z 16 16 "$rendered_png" --out "$iconset/icon_16x16.png" >/dev/null
sips -z 32 32 "$rendered_png" --out "$iconset/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$rendered_png" --out "$iconset/icon_32x32.png" >/dev/null
sips -z 64 64 "$rendered_png" --out "$iconset/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$rendered_png" --out "$iconset/icon_128x128.png" >/dev/null
sips -z 256 256 "$rendered_png" --out "$iconset/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$rendered_png" --out "$iconset/icon_256x256.png" >/dev/null
sips -z 512 512 "$rendered_png" --out "$iconset/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$rendered_png" --out "$iconset/icon_512x512.png" >/dev/null
cp "$rendered_png" "$iconset/icon_512x512@2x.png"

iconutil -c icns "$iconset" -o "$destination_icns"
cp "$rendered_png" "$preview_png"

echo "Generated $destination_icns"
echo "Generated $preview_png"
