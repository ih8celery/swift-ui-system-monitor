#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")"

action="${1:-install}"
label="com.ih8celery.systembar"
# Labels this app shipped under previously; cleaned up on install/uninstall so a
# rename never leaves a second copy loaded in launchd.
legacy_labels=("com.adamu.systembar")
app_dir="${HOME}/Applications"
app_path="${app_dir}/SystemBar.app"
executable_path="${app_path}/Contents/MacOS/SystemBar"
plist_dir="${HOME}/Library/LaunchAgents"
plist_path="${plist_dir}/${label}.plist"

usage() {
  echo "Usage: ./install.sh [install|uninstall|status]"
}

bootout_label() {
  launchctl bootout "gui/$(id -u)" "${plist_dir}/${1}.plist" >/dev/null 2>&1 || true
}

bootout_agent() {
  bootout_label "${label}"
}

remove_legacy_agents() {
  for legacy in "${legacy_labels[@]}"; do
    [[ "${legacy}" == "${label}" ]] && continue
    [[ -f "${plist_dir}/${legacy}.plist" ]] || continue

    bootout_label "${legacy}"
    rm -f "${plist_dir}/${legacy}.plist"
    echo "Removed legacy login service: ${legacy}"
  done
}

uninstall() {
  bootout_agent
  remove_legacy_agents
  pkill -x SystemBar >/dev/null 2>&1 || true
  rm -f "${plist_path}"
  rm -rf "${app_path}"

  echo "Uninstalled SystemBar login service: ${label}"
}

status() {
  if launchctl print "gui/$(id -u)/${label}" >/dev/null 2>&1; then
    echo "SystemBar LaunchAgent is loaded: ${label}"
  else
    echo "SystemBar LaunchAgent is not loaded: ${label}"
  fi

  if [[ -d "${app_path}" ]]; then
    echo "App: ${app_path}"
  else
    echo "App not installed: ${app_path}"
  fi

  if [[ -f "${plist_path}" ]]; then
    echo "LaunchAgent: ${plist_path}"
  else
    echo "LaunchAgent not installed: ${plist_path}"
  fi
}

install() {
  ./build.sh

  mkdir -p "${app_dir}" "${plist_dir}"
  bootout_agent
  remove_legacy_agents
  pkill -x SystemBar >/dev/null 2>&1 || true
  rm -rf "${app_path}"
  cp -R "./SystemBar.app" "${app_path}"

  cat > "${plist_path}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${executable_path}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>LimitLoadToSessionType</key>
  <string>Aqua</string>
  <key>ProcessType</key>
  <string>Interactive</string>
  <key>StandardOutPath</key>
  <string>${HOME}/Library/Logs/SystemBar.out.log</string>
  <key>StandardErrorPath</key>
  <string>${HOME}/Library/Logs/SystemBar.err.log</string>
</dict>
</plist>
PLIST

  launchctl bootstrap "gui/$(id -u)" "${plist_path}"
  launchctl kickstart -k "gui/$(id -u)/${label}"

  echo "Installed SystemBar login service: ${label}"
  echo "App: ${app_path}"
  echo "LaunchAgent: ${plist_path}"
}

case "${action}" in
  install)
    install
    ;;
  uninstall)
    uninstall
    ;;
  status)
    status
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 64
    ;;
esac
