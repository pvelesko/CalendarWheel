# CalendarWheel

A small native Swift menu-bar app with upcoming Apple Calendar events, meeting shortcuts, and smooth horizontal mouse-wheel scrolling.

Converts horizontal wheel input into continuous scroll events with companion trackpad gesture events, only while Calendar is frontmost. Vertical scrolling and existing trackpad gestures pass through. No network access, analytics, or third-party dependencies.

## Build and install

Requires macOS and the Xcode Command Line Tools (`xcode-select --install`).

```sh
./build.sh
ditto CalendarWheel.app /Applications/CalendarWheel.app
open /Applications/CalendarWheel.app
```

Enable **CalendarWheel** in **System Settings → Privacy & Security → Accessibility**. This lets the app intercept and send scroll events. Quit and reopen the app if necessary after granting access.

For automatic startup, add the installed app under **System Settings → General → Login Items & Extensions → Open at Login**.

Use the **↔︎** menu-bar icon to enable or disable conversion, open Accessibility settings, or quit. Test the horizontal wheel with the pointer over Calendar’s Week grid.

## Upcoming meetings

Grant CalendarWheel Full Calendar Access when prompted. EventKit requires that permission to read existing events; CalendarWheel never creates or modifies events and does not upload calendar data.

The menu bar shows the next timed event within 24 hours with a countdown, or the time remaining for an ongoing event. All-day, cancelled, and declined events are excluded. Use **Calendars** in the menu to choose which calendars are included; this selection is independent of Apple Calendar’s sidebar checkboxes and is saved across launches. The display refreshes every 30 seconds, when events change, and after waking.

**Join Meeting** opens a recognized conference link from the event URL, location, or notes. Supported services include Google Meet, Zoom, Microsoft Teams, Webex, Whereby, Jitsi Meet, GoToMeeting, and BlueJeans. Links open only when clicked. The **Next 24 hours** submenu also provides join actions for upcoming events. **Open Apple Calendar** opens the Calendar app.

Requires macOS 14 or later for calendar access. Meeting titles are visible in the menu bar, including during screen sharing.

## Implementation

- Swift, AppKit, and Core Graphics.
- Smoothing at 120 Hz, horizontal speed multiplier 3, gesture end after motion settles and 140 ms of idle.
- Continuous scroll events paired with type-29, subtype-6 gesture events.
- Ad-hoc signing with a stable designated requirement for local rebuilds. The app is not notarized.

The companion gesture fields are undocumented macOS interfaces, verified against native trackpad captures. Future macOS updates may require adjustments. Tested with a Logitech MX Master horizontal wheel in Apple Calendar; other hardware has not been verified.

## Validation and diagnostics

The build script tests distance conservation, idle completion, and direction reversal. These checks do not replace a physical mouse test.

```sh
CalendarWheel.app/Contents/MacOS/CalendarWheel --self-test
```

Normal launches do not log input. For diagnostics, quit the running app and launch:

```sh
open /Applications/CalendarWheel.app --args --diagnostics
```

The temporary `$TMPDIR/CalendarWheel-status.json` file contains permission state, event counts, foreground application identifier, and latest scroll values. It does not record keystrokes or calendar contents.

## Uninstall

Quit CalendarWheel, remove it from Login Items, move the app to Trash, and remove its Accessibility entry.

## Technical references

Native trackpad captures guided the event format. [Mac Mouse Fix](https://github.com/noah-nuebling/mac-mouse-fix) and [Mos](https://github.com/Caldis/Mos) were useful references for understanding macOS scroll phases and companion gesture events.
