#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")"

swiftc \
  -D TESTING \
  -parse-as-library \
  -package-name SystemBar \
  -framework SwiftUI \
  -framework AppKit \
  -o /tmp/SystemBarPerformanceTests \
  $(find Sources -name '*.swift' | sort) \
  TestSupport.swift \
  SystemBarCapacityTests.swift \
  SystemBarPluginTests.swift \
  SystemBarPerformanceTests.swift

/tmp/SystemBarPerformanceTests
