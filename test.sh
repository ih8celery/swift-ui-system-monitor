#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")"
source "$(dirname "$0")/toolchain.env"

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
  TestSupport.swift \
  SystemBarCapacityTests.swift \
  SystemBarPluginTests.swift \
  SystemBarPerformanceTests.swift

build/SystemBarTests
