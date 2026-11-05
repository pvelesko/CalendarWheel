#!/bin/zsh
set -eu
cd "$(dirname "$0")"
mkdir -p CalendarWheel.app/Contents/MacOS
xcrun swiftc -O -framework AppKit -framework CoreGraphics -framework EventKit main.swift Meetings.swift -o CalendarWheel.app/Contents/MacOS/CalendarWheel
cat > CalendarWheel.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>CalendarWheel</string>
<key>CFBundleIdentifier</key><string>local.pvelesko.CalendarWheel</string>
<key>CFBundleName</key><string>CalendarWheel</string>
<key>CFBundleVersion</key><string>2</string>
<key>CFBundleShortVersionString</key><string>1.1</string>
<key>NSCalendarsFullAccessUsageDescription</key><string>Show upcoming meetings and countdowns in your menu bar. CalendarWheel only reads events and never changes them.</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - --identifier local.pvelesko.CalendarWheel --requirements '=designated => identifier "local.pvelesko.CalendarWheel"' CalendarWheel.app
CalendarWheel.app/Contents/MacOS/CalendarWheel --self-test
