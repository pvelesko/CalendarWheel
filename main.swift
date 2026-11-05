import AppKit
import CoreGraphics

// A small accumulator: preserve distance, smooth at 120 Hz, end after wheel idle.
struct Motion {
    var pending = 0.0
    var lastInput = 0.0
    mutating func add(_ delta: Double, at time: Double) {
        if pending * delta < 0 { pending = 0 }
        pending += delta
        lastInput = time
    }
    mutating func step(at time: Double) -> (Double, Bool) {
        let amount = abs(pending) < 0.15 ? pending : pending * 0.24
        pending -= amount
        return (amount, abs(pending) < 0.001 && time - lastInput > 0.14)
    }
}

if CommandLine.arguments.contains("--self-test") {
    testMeetings()
    var m = Motion(); m.add(100, at: 0)
    var total = 0.0; var ended = false
    for i in 1...240 { let (d,e) = m.step(at: Double(i)/120); total += d; ended = ended || e }
    precondition(abs(total - 100) < 0.001 && ended)
    m.add(20, at: 3); m.add(-10, at: 3.01)
    precondition(m.pending == -10)
    print("PASS: distance conservation, idle end, direction reversal")
    exit(0)
}

final class WheelApp: NSObject, NSApplicationDelegate {
    let marker: Int64 = 0x43414C574845454C
    var tap: CFMachPort?
    var source: CFRunLoopSource?
    var timer: Timer?
    var meetings: Meetings?
    var item: NSStatusItem!
    var status: NSMenuItem!
    var motion = Motion()
    var active = false
    var firstFrame = false
    var target: pid_t = 0
    var point = CGPoint.zero
    var flags = CGEventFlags()
    var enabled = true
    var observer: NSObjectProtocol?
    var observedScroll = 0
    var observedGesture = 0
    var received = 0
    var converted = 0
    var emitted = 0
    var lastInputInfo = "none"
    func diagnostics() {
        guard CommandLine.arguments.contains("--diagnostics") else { return }
        let d: [String: Any] = ["observedScroll": observedScroll, "observedGesture": observedGesture, "canPostEvents": CGPreflightPostEventAccess(), "canListenEvents": CGPreflightListenEventAccess(), "trusted": AXIsProcessTrusted(), "tapActive": tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false, "received": received, "converted": converted, "emitted": emitted, "lastInput": lastInputInfo, "frontmost": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"]
        if let data = try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("CalendarWheel-status.json"), options: .atomic)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "↔︎"
        let menu = NSMenu()
        status = NSMenuItem(title: "CalendarWheel: starting", action: nil, keyEquivalent: "")
        menu.addItem(status)
        let toggle = NSMenuItem(title: "Enabled for Calendar", action: #selector(toggleEnabled(_:)), keyEquivalent: "")
        toggle.target = self; toggle.state = .on; menu.addItem(toggle)
        let permission = NSMenuItem(title: "Enable Accessibility…", action: #selector(requestAccess), keyEquivalent: "")
        permission.target = self; menu.addItem(permission)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit CalendarWheel", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit)
        item.menu = menu
        meetings = Meetings(item: item, menu: menu)
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.finish()
        }
        connect()
        timer = Timer(timeInterval: 1.0/120.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
    }
    @objc func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc func toggleEnabled(_ sender: NSMenuItem) {
        enabled.toggle(); sender.state = enabled ? .on : .off
        if !enabled { finish() }
    }
    @objc func quitApp() { finish(); NSApp.terminate(nil) }
    func connect() {
        guard tap == nil, AXIsProcessTrusted() else {
            if tap == nil { status.title = "Needs Accessibility permission" }
            return
        }
        let callback: CGEventTapCallBack = { _, type, event, ref in
            let app = Unmanaged<WheelApp>.fromOpaque(ref!).takeUnretainedValue()
            return app.handle(type, event)
        }
        guard let t = CGEvent.tapCreate(tap: .cgAnnotatedSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: (CGEventMask(1) << CGEventType.scrollWheel.rawValue) | (CGEventMask(1) << 29), callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            status.title = "Cannot start scroll listener"; return
        }
        tap = t; source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        status.title = "Ready • Calendar horizontal wheel"
    }
    func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            finish(); if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == marker {
            if type.rawValue == 29 { observedGesture += 1 } else { observedScroll += 1 }
            return Unmanaged.passUnretained(event)
        }
        if type.rawValue == 29 { return Unmanaged.passUnretained(event) }
        if event.getIntegerValueField(.eventSourceUserData) != marker {
            received += 1
            lastInputInfo = "horizontal=\(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)) lines=\(event.getIntegerValueField(.scrollWheelEventDeltaAxis2)) phase=\(event.getIntegerValueField(.scrollWheelEventScrollPhase)) momentum=\(event.getIntegerValueField(.scrollWheelEventMomentumPhase)) app=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none")"
        }
        guard enabled, event.getIntegerValueField(.eventSourceUserData) != marker,
              let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == "com.apple.iCal",
              event.getIntegerValueField(.scrollWheelEventScrollPhase) == 0,
              event.getIntegerValueField(.scrollWheelEventMomentumPhase) == 0 else {
            return Unmanaged.passUnretained(event)
        }
        let raw = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
        let lines = event.getDoubleValueField(.scrollWheelEventDeltaAxis2)
        let delta = raw != 0 ? raw : lines * 8
        guard delta != 0 else { return Unmanaged.passUnretained(event) }
        converted += 1
        if !active {
            target = front.processIdentifier; active = true; motion = Motion()
            point = event.location; flags = event.flags
            firstFrame = true
        }
        point = event.location; flags = event.flags
        motion.add(delta * 3, at: ProcessInfo.processInfo.systemUptime)
        // Preserve any simultaneous vertical component rather than swallowing it.
        if event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1) != 0 || event.getIntegerValueField(.scrollWheelEventDeltaAxis1) != 0 {
            event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: 0)
            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: 0)
            event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: 0)
            return Unmanaged.passUnretained(event)
        }
        return nil
    }
    var retry = 0
    func tick() {
        retry += 1
        if retry % 120 == 0 { diagnostics(); if tap == nil { connect() } }
        if tap == nil { return }
        guard active else { return }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target else { finish(); return }
        let (delta, end) = motion.step(at: ProcessInfo.processInfo.systemUptime)
        if delta != 0 { emit(delta, phase: firstFrame ? 1 : 2); firstFrame = false }
        if end { finish() }
    }
    func emit(_ delta: Double, phase: Int64) {
        let eventSource = CGEventSource(stateID: .hidSystemState)
        eventSource?.localEventsSuppressionInterval = 0
        guard let event = CGEvent(scrollWheelEvent2Source: eventSource, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: Int32(delta.rounded()), wheel3: 0) else { return }
        event.timestamp = DispatchTime.now().uptimeNanoseconds
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 0)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: 0)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: Int64((delta / 10).rounded()))
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: delta)
        event.location = point; event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: delta / 10)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
        emitted += 1
        event.post(tap: .cghidEventTap)
        // Trackpad scrolling also carries a type-29, subtype-6 gesture stream.
        // These undocumented field IDs were verified against captured native events.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target,
              let gesture = CGEvent(source: eventSource) else { return }
        gesture.location = point; gesture.flags = flags
        gesture.timestamp = event.timestamp
        gesture.setIntegerValueField(.eventSourceUserData, value: marker)
        gesture.setIntegerValueField(CGEventField(rawValue: 55)!, value: 29)
        gesture.setIntegerValueField(CGEventField(rawValue: 110)!, value: 6)
        gesture.setDoubleValueField(CGEventField(rawValue: 116)!, value: delta * 1.67)
        gesture.setDoubleValueField(CGEventField(rawValue: 119)!, value: 0)
        gesture.setIntegerValueField(CGEventField(rawValue: 132)!, value: phase)
        gesture.post(tap: .cghidEventTap)
    }
    func finish() {
        if active && NSWorkspace.shared.frontmostApplication?.processIdentifier == target { emit(0, phase: 4) } // ended
        active = false; motion = Motion()
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = WheelApp()
app.delegate = delegate
app.run()
