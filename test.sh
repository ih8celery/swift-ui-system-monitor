#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")"

# The tests link the same SDK dylib the app does, built by build.sh a moment ago. Everything
# else (host without its @main, each plugin's sources and tests, the test files) is one module.
./build.sh

swiftc \
  -D TESTING \
  -parse-as-library -module-name SystemBarTests \
  -swift-version 5 -target arm64-apple-macos14 -package-name SystemBar \
  -I build/SDK -L build/Frameworks -lSystemBarKit \
  -Xlinker -rpath -Xlinker "$(pwd)/build/Frameworks" \
  -framework SwiftUI -framework AppKit \
  -o /tmp/SystemBarPerformanceTests \
  $(find Sources/Host -name '*.swift' | sort) \
  TestSupport.swift \
  SystemBarCapacityTests.swift \
  SystemBarPluginTests.swift \
  SystemBarPerformanceTests.swift

/tmp/SystemBarPerformanceTests
