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
  TestFakes.swift \
  SystemBarConfigTests.swift \
  SystemBarLoaderTests.swift \
  SystemBarSchedulerTests.swift \
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

# A new user's first launch: no plugins.json yet. The app writes the default list, and every
# entry in it loads from a bundle inside the app, in the order a new user sees.
expected_fresh="ok power Power Power.bundle
ok dev Dev Dev.bundle
ok memory Memory Memory.bundle
ok disk Disk Disk.bundle
ok network Network Network.bundle
ok cpu CPU CPU.bundle"
actual_fresh=$(SYSTEMBAR_PLUGINS_FILE="$tmp/fresh/plugins.json" ./SystemBar.app/Contents/MacOS/SystemBar --list-plugins) \
  || { echo "Fresh-file check failed: SystemBar --list-plugins exited $?" >&2; exit 1; }

if [[ "$actual_fresh" != "$expected_fresh" ]]; then
  echo "Fresh-file check failed. Expected:" >&2
  echo "$expected_fresh" >&2
  echo "Got:" >&2
  echo "$actual_fresh" >&2
  exit 1
fi
if [[ ! -f "$tmp/fresh/plugins.json" ]]; then
  echo "Fresh-file check failed: no plugins.json was written at $tmp/fresh/plugins.json" >&2
  exit 1
fi
echo "Fresh-file check passed: a new plugins.json loads all six tabs from the app's bundles"

# The old central sampler, its job type, the compiled-in tab table and the five adapter tabs are gone;
# nothing may bring their names back. The brackets keep this pattern from matching its own line.
deleted_names='Unified[M]onitor|Monitor[M]ode|Monitor[J]ob|Monitor[S]amplingPlan|Monitor[B]ackedTab|Builtin[T]abSource|Host[T]abSource|(Dev|Memory|Disk|Network|CPU)[T]ab([^A-Za-z]|$)'
found_names=$(grep -rnE "$deleted_names" Sources Plugins *.swift *.sh) && grep_status=0 || grep_status=$?
if (( grep_status == 0 )); then
  echo "Name check failed: a deleted name is back:" >&2
  echo "$found_names" >&2
  exit 1
elif (( grep_status != 1 )); then
  echo "Name check failed: grep exited $grep_status" >&2
  exit 1
fi
echo "Name check passed: no source names the deleted sampler or the compiled-in tab table"
