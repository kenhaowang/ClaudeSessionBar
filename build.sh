#!/bin/bash
# Usage: ./build.sh            build build/ClaudeSessionBar.app
#        ./build.sh install    also copy it to ~/Applications and (re)launch it
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP="build/ClaudeSessionBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/ClaudeSessionBar "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
mkdir -p "$APP/Contents/Resources"
# The icon is drawn by the app itself (AppIconRenderer), so no image asset is checked in.
.build/release/ClaudeSessionBar --make-icon "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
echo "built $APP"

if [[ "${1:-}" == "install" ]]; then
    pkill -x ClaudeSessionBar || true
    # `open` on an app that is still shutting down just re-activates the dying instance.
    for _ in $(seq 50); do pgrep -x ClaudeSessionBar >/dev/null || break; sleep 0.1; done
    mkdir -p ~/Applications
    rm -rf ~/Applications/ClaudeSessionBar.app
    cp -R "$APP" ~/Applications/
    mkdir -p ~/.claude/session-dashboard
    cp hooks/hook.py ~/.claude/session-dashboard/hook.py
    # Make Finder and Launchpad pick up a changed icon right away.
    touch ~/Applications/ClaudeSessionBar.app
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f ~/Applications/ClaudeSessionBar.app
    open ~/Applications/ClaudeSessionBar.app
    echo "installed ~/Applications/ClaudeSessionBar.app"
fi
