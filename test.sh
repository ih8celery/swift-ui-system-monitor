#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")"
source ./toolchain.env

# The tests link the same SDK dylib the app does, built by build.sh a moment ago. Everything
# else (host without its @main, the test files) is one module. The tabs live in their own
# repository, system-monitor-core-plugins, with their own tests.
./build.sh

# The SDK's doc comments ship beside its interface, where the compiler looks for a module's
# documentation, so a plugin author's editor can show them.
[[ -s SystemBar.app/Contents/Resources/SDK/SystemBarKit.swiftdoc ]] || {
  echo "Doc check failed: SystemBar.app/Contents/Resources/SDK/SystemBarKit.swiftdoc is missing or empty" >&2
  exit 1
}

swiftc \
  -D TESTING \
  -parse-as-library -module-name SystemBarTests \
  -swift-version "$swift_version" -target "$target" -package-name "$package_name" \
  -I build/SDK -L build/Frameworks -lSystemBarKit \
  -Xlinker -rpath -Xlinker @executable_path/Frameworks \
  -framework SwiftUI -framework AppKit \
  -o build/SystemBarTests \
  $(find Sources/Host -name '*.swift' | sort) \
  TestSupport.swift \
  TestFakes.swift \
  SystemBarConfigTests.swift \
  SystemBarLoaderTests.swift \
  SystemBarSchedulerTests.swift \
  SystemBarPreviewTests.swift \
  SystemBarPerformanceTests.swift

build/SystemBarTests

# The one test that crosses a real dylib boundary: a plugin built from the example, against the
# SDK inside the app that build.sh just produced, loaded by the same code a user's would be.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
./build-plugin.sh Examples/HelloTab "$tmp/HelloTab.bundle" SystemBar.app > /dev/null

cat > "$tmp/plugins.json" <<JSON
{ "plugins": [
  { "path": "$tmp/HelloTab.bundle" },
  { "path": "$tmp/Missing.bundle" },
  { "name": "Missing.bundle" },
  { "path": "$tmp/HelloTab.bundle" }
] }
JSON

expected="ok hello Hello $tmp/HelloTab.bundle
error $tmp/Missing.bundle: nothing at $tmp/Missing.bundle
error Missing.bundle: nothing at $PWD/SystemBar.app/Contents/PlugIns/Missing.bundle
error $tmp/HelloTab.bundle: the id \"hello\" is already used by \"$tmp/HelloTab.bundle\", which comes earlier in the list"
actual=$(SYSTEMBAR_PLUGINS_FILE="$tmp/plugins.json" SYSTEMBAR_PLUGIN_DATA_ROOT="$tmp/plugin-data" ./SystemBar.app/Contents/MacOS/SystemBar --list-plugins) \
  || { echo "Boundary check failed: SystemBar --list-plugins exited $?" >&2; exit 1; }

if [[ "$actual" != "$expected" ]]; then
  echo "Boundary check failed. Expected:" >&2
  echo "$expected" >&2
  echo "Got:" >&2
  echo "$actual" >&2
  exit 1
fi
echo "Boundary check passed: a bundle built against the shipped SDK loads through the real loader"

# The preview: one bundle outside the menu bar, from the built app, with fake answers, never
# reading or writing plugins.json.
cat > "$tmp/replies.json" <<'JSON'
{ "replies": [ { "path": "/bin/date", "arguments": ["+%H:%M:%S"], "output": "12:34:56\n" } ] }
JSON
SYSTEMBAR_PLUGINS_FILE="$tmp/untouched/plugins.json" ./SystemBar.app/Contents/MacOS/SystemBar \
  --preview "$tmp/HelloTab.bundle" --png "$tmp/hello.png" --replies "$tmp/replies.json" \
  || { echo "Preview check failed: --preview --png exited $?" >&2; exit 1; }
[[ -s "$tmp/hello.png" ]] || { echo "Preview check failed: no picture at $tmp/hello.png" >&2; exit 1; }
[[ ! -e "$tmp/untouched/plugins.json" ]] || { echo "Preview check failed: the preview wrote plugins.json" >&2; exit 1; }

missing_out=$(./SystemBar.app/Contents/MacOS/SystemBar --preview "$tmp/Missing.bundle" --png "$tmp/missing.png" 2>&1) \
  && missing_status=0 || missing_status=$?
if (( missing_status != 1 )) || [[ "$missing_out" != "error $tmp/Missing.bundle: nothing at $tmp/Missing.bundle" ]]; then
  echo "Preview check failed: a missing bundle should exit 1 with the loader's line; got $missing_status: $missing_out" >&2
  exit 1
fi
echo "Preview check passed: a bundle previews to a picture from the built app, and a missing one says why"

# An outside project runs the copy of build-plugin.sh inside an installed app, from its own
# directory, with no SDK argument; the script must find the app it sits in. build.sh puts that
# copy in the app; the copy of the app has no SystemBar.app beside the script, so only the
# enclosing-app default can succeed.
cmp -s build-plugin.sh SystemBar.app/Contents/Resources/build-plugin.sh \
  || { echo "Shipped-script check failed: the app does not carry this build-plugin.sh" >&2; exit 1; }
repo=$PWD
shipped="$tmp/Shipped.app"
cp -R SystemBar.app "$shipped"
(cd "$tmp" && "$shipped/Contents/Resources/build-plugin.sh" "$repo/Examples/HelloTab" "$tmp/FromApp.bundle" > /dev/null) \
  || { echo "Shipped-script check failed: the copy inside an app could not build with two arguments" >&2; exit 1; }
if [[ ! -x "$tmp/FromApp.bundle/Contents/MacOS/HelloTab" ]]; then
  echo "Shipped-script check failed: no binary at $tmp/FromApp.bundle/Contents/MacOS/HelloTab" >&2
  exit 1
fi
echo "Shipped-script check passed: build-plugin.sh inside an app builds against that app"

# A new user's first launch: no plugins.json yet. The app ships no tabs, so it writes an empty
# list and loads nothing; a tab repository's installer adds its tabs by path.
expected_fresh=""
actual_fresh=$(SYSTEMBAR_PLUGINS_FILE="$tmp/fresh/plugins.json" SYSTEMBAR_PLUGIN_DATA_ROOT="$tmp/plugin-data" ./SystemBar.app/Contents/MacOS/SystemBar --list-plugins) \
  || { echo "Fresh-file check failed: SystemBar --list-plugins exited $?" >&2; exit 1; }

if [[ "$actual_fresh" != "$expected_fresh" ]]; then
  echo "Fresh-file check failed. Expected:" >&2
  echo "$expected_fresh" >&2
  echo "Got:" >&2
  echo "$actual_fresh" >&2
  exit 1
fi
if [[ "$(jq -c . "$tmp/fresh/plugins.json" 2>/dev/null)" != '{"plugins":[]}' ]]; then
  echo "Fresh-file check failed: $tmp/fresh/plugins.json should hold an empty list" >&2
  exit 1
fi
if [[ -n "$(ls -A SystemBar.app/Contents/PlugIns)" ]]; then
  echo "Fresh-file check failed: the app ships bundles in Contents/PlugIns: $(ls SystemBar.app/Contents/PlugIns)" >&2
  exit 1
fi
echo "Fresh-file check passed: a new plugins.json is an empty list and the app ships no tabs"

# The old central sampler, its job type, the compiled-in tab table and the five adapter tabs are gone;
# nothing may bring their names back. The brackets keep this pattern from matching its own line.
deleted_names='Unified[M]onitor|Monitor[M]ode|Monitor[J]ob|Monitor[S]amplingPlan|Monitor[B]ackedTab|Builtin[T]abSource|Host[T]abSource|(Dev|Memory|Disk|Network|CPU)[T]ab([^A-Za-z]|$)'
found_names=$(grep -rnE "$deleted_names" Sources *.swift *.sh) && grep_status=0 || grep_status=$?
if (( grep_status == 0 )); then
  echo "Name check failed: a deleted name is back:" >&2
  echo "$found_names" >&2
  exit 1
elif (( grep_status != 1 )); then
  echo "Name check failed: grep exited $grep_status" >&2
  exit 1
fi
echo "Name check passed: no source names the deleted sampler or the compiled-in tab table"
