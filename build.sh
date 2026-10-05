#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p build/Voice.app/Contents/MacOS build/module-cache
xcrun swiftc -target "$(uname -m)-apple-macosx14.0" -swift-version 5 -O -module-cache-path "$PWD/build/module-cache" \
  Sources/Core.swift Sources/WorkQueue.swift Sources/Hotkey.swift Sources/SoundCues.swift Sources/App.swift Sources/main.swift \
  -o build/Voice.app/Contents/MacOS/Voice
cp Info.plist build/Voice.app/Contents/Info.plist
mkdir -p build/Voice.app/Contents/Resources/Sounds
cp Assets/Sounds/*.wav build/Voice.app/Contents/Resources/Sounds/
codesign --force --sign - --identifier local.l.voice -r='designated => identifier "local.l.voice"' build/Voice.app
print "Built $PWD/build/Voice.app"
