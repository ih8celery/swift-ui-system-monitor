#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")"
source ./toolchain.env

# The tests link the same SDK dylib the app does, built by build.sh a moment ago. Everything
# else (host without its @main, each plugin's sources and tests, the test files) is one module.
./build.sh

swiftc \
  -D TESTING \
  -parse-as-library -module-name SystemBarTests \
  -swift-version "$swift_version" -target "$target" -package-name "$package_name" \
  -I build/SDK -L build/Frameworks -lSystemBarKit \
  -Xlinker -rpath -Xlinker @executable_path/Frameworks \
  -framework SwiftUI -framework AppKit \
  -o build/SystemBarTests \
  $(find Sources/Host -name '*.swift' | sort) \
  $(find Plugins -path '*/Sources/*.swift' -o -path '*/Tests/*.swift' | sort) \
  TestSupport.swift \
  SystemBarCapacityTests.swift \
  SystemBarPluginTests.swift \
  SystemBarPerformanceTests.swift

build/SystemBarTests

# The one test that crosses a real dylib boundary: a plugin built from the example, against the
# SDK inside the app that build.sh just produced, loaded by the same code a user's would be.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
./build-plugin.sh Examples/HelloTab "$tmp/HelloTab.bundle" SystemBar.app > /dev/null

cat > "$tmp/plugins.json" <<JSON
{ "plugins": [
  { "name": "Power.bundle" },
  { "path": "$tmp/HelloTab.bundle" },
  { "path": "$tmp/Missing.bundle" },
  { "name": "Power.bundle" }
] }
JSON

expected="ok power Power Power.bundle
ok hello Hello $tmp/HelloTab.bundle
error $tmp/Missing.bundle: nothing at $tmp/Missing.bundle
error Power.bundle: the id \"power\" is already used by \"Power.bundle\", which comes earlier in the list"
actual=$(SYSTEMBAR_PLUGINS_FILE="$tmp/plugins.json" ./SystemBar.app/Contents/MacOS/SystemBar --list-plugins) \
  || { echo "Boundary check failed: SystemBar --list-plugins exited $?" >&2; exit 1; }

if [[ "$actual" != "$expected" ]]; then
  echo "Boundary check failed. Expected:" >&2
  echo "$expected" >&2
  echo "Got:" >&2
  echo "$actual" >&2
  exit 1
fi
echo "Boundary check passed: a bundle built against the shipped SDK loads through the real loader"
