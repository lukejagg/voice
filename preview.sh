#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p build/previews build/module-cache
xcrun swiftc -target "$(uname -m)-apple-macosx14.0" -swift-version 5 -O -module-cache-path "$PWD/build/module-cache" \
  Sources/Core.swift Sources/WorkQueue.swift Sources/Hotkey.swift Sources/SoundCues.swift Sources/App.swift Tests/Visual/main.swift -o build/VoicePreview
build/VoicePreview "$PWD/build/previews"
