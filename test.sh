#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")"

swiftc \
  -D TESTING \
  -parse-as-library \
  -framework SwiftUI \
  -framework AppKit \
  -o /tmp/SystemBarPerformanceTests \
  $(find Sources -name '*.swift' | sort) \
  SystemBarPerformanceTests.swift

/tmp/SystemBarPerformanceTests
