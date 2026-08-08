#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")"
exec ./install.sh uninstall
