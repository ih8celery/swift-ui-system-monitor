#!/bin/zsh
set -euo pipefail

# Builds one plugin directory into a .bundle against SystemBar's SDK.
#
#   ./build-plugin.sh <plugin dir> <output .bundle> [<SystemBar.app | build dir>]
#
# The plugin dir holds Info.plist (CFBundleExecutable names the binary, NSPrincipalClass names
# the @objc class) and Sources/*.swift. The third argument is where the SDK is: a built
# SystemBar.app (Contents/Resources/SDK and Contents/Frameworks), or this repository's build/
# directory. It defaults to SystemBar.app next to this script.

src="$1"
out="$2"
base="${3:-$(cd "$(dirname "$0")" && pwd)/SystemBar.app}"

if [[ -d "$base/Contents/Resources/SDK" ]]; then
  sdk="$base/Contents/Resources/SDK"
  libs="$base/Contents/Frameworks"
elif [[ -d "$base/SDK" ]]; then
  sdk="$base/SDK"
  libs="$base/Frameworks"
else
  echo "build-plugin.sh: no SDK at $base (expected SystemBar.app or a build/ directory)" >&2
  exit 64
fi

name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$src/Info.plist")

# The interface header records the target and language mode the SDK was built with; building
# the plugin with the same two means the two always agree, whatever toolchain.env says today.
flags=$(grep -m1 '^// swift-module-flags:' "$sdk/SystemBarKit.swiftinterface")
target=$(sed -E 's/.*-target ([^ ]+).*/\1/' <<< "$flags")
swift_version=$(sed -E 's/.*-swift-version ([^ ]+).*/\1/' <<< "$flags")
if [[ -z "$target" || -z "$swift_version" ]]; then
  echo "build-plugin.sh: could not read -target and -swift-version from $sdk/SystemBarKit.swiftinterface" >&2
  exit 65
fi

rm -rf "$out"
mkdir -p "$out/Contents/MacOS"

# An app ships only the textual interface, which the compiler turns into a module on first use;
# it gets its own cache so that never depends on, or pollutes, the system one.
# @executable_path is the app that loads the bundle, so the SDK is found wherever the bundle lives.
# No -package-name here: a plugin sees only the SDK's public interface.
swiftc \
  -emit-library -parse-as-library -module-name "$name" \
  -swift-version "$swift_version" -target "$target" \
  -module-cache-path "${TMPDIR:-/tmp}/systembar-plugin-module-cache" \
  -I "$sdk" -L "$libs" -lSystemBarKit \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -framework SwiftUI -framework AppKit \
  -o "$out/Contents/MacOS/$name" \
  $(find "$src/Sources" -name '*.swift' | sort)
cp -f "$src/Info.plist" "$out/Contents/Info.plist"

echo "Built $out"
