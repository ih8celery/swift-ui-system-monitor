#!/bin/zsh
set -euo pipefail

# Builds one plugin directory into a .bundle against SystemBar's SDK.
#
#   ./build-plugin.sh <plugin dir> <output .bundle> [<SystemBar.app | build dir>]
#
# The plugin dir holds Info.plist (CFBundleExecutable names the binary, NSPrincipalClass names
# the @objc class) and Sources/*.swift. The third argument is where the SDK is: a built
# SystemBar.app (Contents/Resources/SDK and Contents/Frameworks), or this repository's build/
# directory. It defaults to the app this script sits in, when it is the copy shipped in an app's
# Contents/Resources, and otherwise to SystemBar.app next to this script.

(( $# >= 2 )) || {
  echo "usage: build-plugin.sh <plugin dir> <out.bundle> [SystemBar.app | build dir]" >&2
  exit 64
}

src="$1"
out="$2"
here=$(cd "$(dirname "$0")" && pwd)
if [[ "$here" == */Contents/Resources && -d "$here/SDK" ]]; then
  default_base="${here:h:h}"
else
  default_base="$here/SystemBar.app"
fi
base="${3:-$default_base}"

[[ -f "$src/Info.plist" ]] || {
  echo "build-plugin.sh: no Info.plist at $src/Info.plist" >&2
  exit 64
}

# A zsh array, not a bare $(...) word-split, so a source path with a space in it survives.
sources=(${(f)"$(find "$src/Sources" -name '*.swift' 2>/dev/null | sort)"})
(( ${#sources[@]} > 0 )) || {
  echo "build-plugin.sh: no *.swift files under $src/Sources" >&2
  exit 64
}

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
# grep finding nothing leaves flags empty rather than aborting (the `|| true`); sed's -n with a
# trailing `p` prints only a successful substitution, so a line that does not match also leaves
# the variable empty instead of sed's substitute silently echoing the whole input line back, as
# a plain `s/.../.../ ` does when nothing matches.
flags=$(grep -m1 '^// swift-module-flags:' "$sdk/SystemBarKit.swiftinterface" || true)
target=$(sed -nE 's/.* -target ([^ ]+).*/\1/p' <<< "$flags")
swift_version=$(sed -nE 's/.* -swift-version ([^ ]+).*/\1/p' <<< "$flags")
if [[ -z "$target" ]]; then
  echo "build-plugin.sh: could not read -target from $sdk/SystemBarKit.swiftinterface" >&2
  exit 65
fi
if [[ -z "$swift_version" ]]; then
  echo "build-plugin.sh: could not read -swift-version from $sdk/SystemBarKit.swiftinterface" >&2
  exit 65
fi

rm -rf "$out"
mkdir -p "$out/Contents/MacOS"

# An app ships only the textual interface, which the compiler turns into a module on first use;
# it gets its own cache so that never depends on, or pollutes, the system one.
# @executable_path is the app that loads the bundle, so the SDK is found wherever the bundle lives.
# install_name is @rpath-relative too, so the binary never carries this machine's absolute build
# path: otool -L on it, from wherever it ends up, says where to look, not where it was built.
# No -package-name here: a plugin sees only the SDK's public interface.
swiftc \
  -emit-library -parse-as-library -module-name "$name" \
  -swift-version "$swift_version" -target "$target" \
  -module-cache-path "${TMPDIR:-/tmp}/systembar-plugin-module-cache" \
  -I "$sdk" -L "$libs" -lSystemBarKit \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -Xlinker -install_name -Xlinker "@rpath/$name" \
  -framework SwiftUI -framework AppKit \
  -o "$out/Contents/MacOS/$name" \
  "${sources[@]}"
cp -f "$src/Info.plist" "$out/Contents/Info.plist"

echo "Built $out"
