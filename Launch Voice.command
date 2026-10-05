#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
if [[ ! -x build/Voice.app/Contents/MacOS/Voice ]]; then ./build.sh; fi
open "$PWD/build/Voice.app"
