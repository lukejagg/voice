#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p build/module-cache
xcrun swiftc -swift-version 5 -module-cache-path "$PWD/build/module-cache" Sources/Core.swift Tests/main.swift -o build/VoiceTests
build/VoiceTests

xcrun swiftc -target "$(uname -m)-apple-macosx14.0" -swift-version 5 -module-cache-path "$PWD/build/module-cache" \
  Sources/Core.swift Sources/WorkQueue.swift Sources/Hotkey.swift Sources/SoundCues.swift Sources/App.swift Tests/Overlap/main.swift -o build/VoiceOverlapTests
build/VoiceOverlapTests
