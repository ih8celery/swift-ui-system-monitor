#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")"
source ./toolchain.env

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
#    person building one points build-plugin.sh at this app to find Resources/SDK. Only the
#    textual interface ships: a plugin compiles against the public interface only, the way it
#    will on any other compiler version; the binary .swiftmodule would expose package members
#    to anyone passing -package-name, and .swiftsourceinfo carries this machine's source paths.
#    The .swiftdoc ships beside it: the interface carries no doc comments, and the compiler
#    reads a module's comments from a .swiftdoc next to its interface. It holds only the public
#    declarations' comments, no package members and no source paths.
mkdir -p SystemBar.app/Contents/MacOS SystemBar.app/Contents/Frameworks \
         SystemBar.app/Contents/Resources/SDK SystemBar.app/Contents/PlugIns
cp -f Info.plist SystemBar.app/Contents/Info.plist
cp -f build/SystemBar SystemBar.app/Contents/MacOS/SystemBar
chmod 755 SystemBar.app/Contents/MacOS/SystemBar
cp -f build/Frameworks/libSystemBarKit.dylib SystemBar.app/Contents/Frameworks/
cp -f build/SDK/SystemBarKit.swiftinterface build/SDK/SystemBarKit.swiftdoc SystemBar.app/Contents/Resources/SDK/

# 4. build-plugin.sh, so a plugin project outside this repository can build against the app
#    it has installed without a checkout of this one. The app ships no tabs of its own: they
#    live in system-monitor-core-plugins and are installed by path like any other plugin.
cp -f build-plugin.sh SystemBar.app/Contents/Resources/build-plugin.sh
chmod 755 SystemBar.app/Contents/Resources/build-plugin.sh

echo "Built $(pwd)/SystemBar.app"
