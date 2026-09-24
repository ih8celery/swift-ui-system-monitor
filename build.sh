#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")"

# One toolchain setting for every part, so the SDK's stable interface and the plugins built
# against it agree on the language mode and the oldest macOS they run on.
target=arm64-apple-macos14
swift_version=5
# `package` members (the host's side of a Feed) are visible to the app and the tests, never to a plugin.
package_name=SystemBar

rm -rf build SystemBar.app
mkdir -p build/Frameworks build/SDK

# 1. The SDK: one dylib with a stable interface, so a plugin built against it today still
#    loads after the app is rebuilt, as long as nothing it uses was removed.
swiftc \
  -emit-library -parse-as-library -module-name SystemBarKit \
  -enable-library-evolution -swift-version "$swift_version" -target "$target" \
  -package-name "$package_name" \
  -emit-module -emit-module-path build/SDK/SystemBarKit.swiftmodule \
  -emit-module-interface-path build/SDK/SystemBarKit.swiftinterface \
  -Xlinker -install_name -Xlinker @rpath/libSystemBarKit.dylib \
  -framework SwiftUI -framework AppKit \
  -o build/Frameworks/libSystemBarKit.dylib \
  $(find Sources/Kit -name '*.swift' | sort)

# 2. The app, linked against the SDK it will carry.
swiftc \
  -parse-as-library -module-name SystemBar \
  -swift-version "$swift_version" -target "$target" -package-name "$package_name" \
  -I build/SDK -L build/Frameworks -lSystemBarKit \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -framework SwiftUI -framework AppKit \
  -o build/SystemBar \
  $(find Sources/Host -name '*.swift' | sort)

# 3. The bundle layout. Plugins find the SDK through @executable_path/../Frameworks, and a
#    person building one points build-plugin.sh at this app to find Resources/SDK.
mkdir -p SystemBar.app/Contents/MacOS SystemBar.app/Contents/Frameworks \
         SystemBar.app/Contents/Resources/SDK SystemBar.app/Contents/PlugIns
cp -f Info.plist SystemBar.app/Contents/Info.plist
cp -f build/SystemBar SystemBar.app/Contents/MacOS/SystemBar
chmod 755 SystemBar.app/Contents/MacOS/SystemBar
cp -f build/Frameworks/libSystemBarKit.dylib SystemBar.app/Contents/Frameworks/
cp -f build/SDK/SystemBarKit.* SystemBar.app/Contents/Resources/SDK/

echo "Built $(pwd)/SystemBar.app"
