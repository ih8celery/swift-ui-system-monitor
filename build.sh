#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")"

swiftc \
  -parse-as-library \
  -framework SwiftUI \
  -framework AppKit \
  -o SystemBar \
  $(find Sources -name '*.swift' | sort)

rm -rf SystemBar.app
mkdir -p SystemBar.app/Contents/MacOS
cp -f Info.plist SystemBar.app/Contents/Info.plist
cp -f SystemBar SystemBar.app/Contents/MacOS/SystemBar
chmod 755 SystemBar.app/Contents/MacOS/SystemBar

echo "Built $(pwd)/SystemBar"
echo "Built $(pwd)/SystemBar.app"
