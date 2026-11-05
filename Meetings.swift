import AppKit
import EventKit

// Only recognize conference-provider URLs; never open arbitrary URLs from notes automatically.
func meetingLink(url: URL?, location: String?, notes: String?) -> URL? {
    let providers = ["zoom.us", "zoom.com", "zoomgov.com", "meet.google.com", "teams.microsoft.com", "teams.live.com", "teams.cloud.microsoft", "webex.com", "whereby.com", "meet.jit.si", "gotomeet.me", "gotomeeting.com", "bluejeans.com"]
    func supported(_ candidate: URL) -> Bool {
        guard candidate.scheme?.lowercased() == "https", candidate.user == nil,
              candidate.password == nil, let host = candidate.host?.lowercased() else { return false }
        return providers.contains { host == $0 || host.hasSuffix("." + $0) }
    }
    if let url = url, supported(url) { return url }
    let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    for text in [location, notes].compactMap({ $0 }) {
        let decoded = text.replacingOccurrences(of: "&amp;", with: "&")
        let matches = detector?.matches(in: decoded, range: NSRange(decoded.startIndex..., in: decoded)) ?? []
        if let found = matches.compactMap({ $0.url }).first(where: supported) { return found }
    }
    return nil
}

struct MeetingTime {
    let start: Date
    let end: Date
    let allDay: Bool
    let excluded: Bool
    func isEligible(at now: Date) -> Bool {
        !allDay && !excluded && end > now && start < now.addingTimeInterval(86400)
    }
    func countdown(at now: Date) -> String {
        if start <= now { return "now · \(max(1, Int(ceil(end.timeIntervalSince(now) / 60))))m left" }
        let minutes = max(1, Int(ceil(start.timeIntervalSince(now) / 60)))
        return minutes < 60 ? "in \(minutes)m" : "in \(minutes / 60)h\(minutes % 60 == 0 ? "" : " \(minutes % 60)m")"
    }
}

func testMeetings() {
    let now = Date(timeIntervalSince1970: 100000)
    let upcoming = MeetingTime(start: now.addingTimeInterval(90), end: now.addingTimeInterval(3600), allDay: false, excluded: false)
    precondition(upcoming.isEligible(at: now) && upcoming.countdown(at: now) == "in 2m")
    precondition(upcoming.countdown(at: now.addingTimeInterval(90)) == "now · 59m left")
    precondition(!upcoming.isEligible(at: now.addingTimeInterval(3600)))
    precondition(!MeetingTime(start: now, end: now.addingTimeInterval(60), allDay: true, excluded: false).isEligible(at: now))
    precondition(!MeetingTime(start: now, end: now.addingTimeInterval(60), allDay: false, excluded: true).isEligible(at: now))
    precondition(meetingLink(url: nil, location: nil, notes: "Join https://meet.google.com/abc-defg-hij")?.host == "meet.google.com")
    precondition(meetingLink(url: nil, location: "https://us02web.zoom.us/j/123?pwd=test", notes: nil)?.query == "pwd=test")
    precondition(meetingLink(url: URL(string: "https://zoom.us.evil.example/j/1"), location: nil, notes: nil) == nil)
    precondition(meetingLink(url: URL(string: "file:///tmp/meeting"), location: nil, notes: nil) == nil)
    precondition(meetingLink(url: nil, location: nil, notes: "Agenda https://example.com then https://teams.microsoft.com/l/meetup-join/abc?a=1&amp;b=2")?.query == "a=1&b=2")
    print("PASS: meeting link detection, query preservation, unrelated and unsafe URL rejection")
    print("PASS: meeting countdown, ongoing/ended events, all-day and declined exclusion")
}

final class Meetings: NSObject, NSMenuDelegate {
    private let store = EKEventStore()
    private let item: NSStatusItem
    private let menu: NSMenu
    private var timer: Timer?
    private var observations: [NSObjectProtocol] = []
    private var events: [EKEvent] = []
    private var hidden: Set<String> { Set(UserDefaults.standard.stringArray(forKey: "hiddenCalendars") ?? []) }
    private var allowed: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }
    private let heading = NSMenuItem(title: "Upcoming meeting", action: nil, keyEquivalent: "")
    private let detail = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let join = NSMenuItem(title: "Join Meeting", action: #selector(joinMeeting(_:)), keyEquivalent: "")
    private let access = NSMenuItem(title: "Connect Apple Calendar…", action: #selector(connect), keyEquivalent: "")
    private let calendars = NSMenuItem(title: "Calendars", action: nil, keyEquivalent: "")
    private let agenda = NSMenuItem(title: "Next 24 hours", action: nil, keyEquivalent: "")

    init(item: NSStatusItem, menu: NSMenu) {
        self.item = item; self.menu = menu
        super.init()
        access.target = self; join.target = self
        let open = NSMenuItem(title: "Open Apple Calendar", action: #selector(openCalendar), keyEquivalent: "")
        open.target = self
        [heading, detail, join, access, agenda, calendars, open, .separator()].reversed().forEach { menu.insertItem($0, at: 0) }
        menu.delegate = self
        observations.append(NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in self?.refresh() })
        observations.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer!, forMode: .common)
        refresh()
        if EKEventStore.authorizationStatus(for: .event) == .notDetermined { connect() }
    }

    func menuWillOpen(_ menu: NSMenu) { refresh() }

    @objc private func connect() {
        if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
            store.requestFullAccessToEvents { [weak self] _, error in
                DispatchQueue.main.async {
                    self?.refresh()
                    if let error = error { self?.detail.title = "Calendar access: \(error.localizedDescription)" }
                }
            }
        } else {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
        }
    }

    @objc private func joinMeeting(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    private func link(for event: EKEvent) -> URL? {
        meetingLink(url: event.url, location: event.location, notes: event.notes)
    }

    @objc private func openCalendar() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        }
    }

    @objc private func toggleCalendar(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        var excluded = hidden
        if excluded.contains(id) { excluded.remove(id) } else { excluded.insert(id) }
        UserDefaults.standard.set(Array(excluded), forKey: "hiddenCalendars")
        refresh()
    }

    private func timing(_ event: EKEvent) -> MeetingTime {
        let declined = event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false
        return MeetingTime(start: event.startDate, end: event.endDate, allDay: event.isAllDay,
                           excluded: event.status == .canceled || declined)
    }

    private func timeLabel(_ event: EKEvent) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short; formatter.timeStyle = .short
        return "\(formatter.string(from: event.startDate)) · \(event.calendar.title)"
    }

    private func refresh() {
        let now = Date()
        join.isHidden = true; join.representedObject = nil
        guard allowed else {
            events = []
            item.button?.title = "↔︎  📅"
            item.button?.toolTip = "Connect Apple Calendar to show your upcoming meeting"
            heading.title = "Upcoming meetings"
            detail.title = "Calendar access needed"
            access.isHidden = false; calendars.isHidden = true; agenda.isHidden = true
            calendars.submenu = nil; agenda.submenu = nil
            return
        }
        access.isHidden = true; calendars.isHidden = false; agenda.isHidden = false
        let available = store.calendars(for: .event).sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        let picker = NSMenu()
        for calendar in available {
            let entry = NSMenuItem(title: "\(calendar.title) — \(calendar.source.title)", action: #selector(toggleCalendar(_:)), keyEquivalent: "")
            entry.target = self; entry.representedObject = calendar.calendarIdentifier
            entry.state = hidden.contains(calendar.calendarIdentifier) ? .off : .on
            picker.addItem(entry)
        }
        calendars.submenu = picker
        let selected = available.filter { !hidden.contains($0.calendarIdentifier) }
        if selected.isEmpty { events = [] } else {
            let predicate = store.predicateForEvents(withStart: Calendar.current.startOfDay(for: now), end: now.addingTimeInterval(86400), calendars: selected)
            events = store.events(matching: predicate).filter { timing($0).isEligible(at: now) }
                .sorted { $0.startDate == $1.startDate ? $0.endDate < $1.endDate : $0.startDate < $1.startDate }
        }
        let list = NSMenu()
        for event in events.prefix(12) {
            list.addItem(NSMenuItem(title: "\(event.title ?? "Untitled event") · \(timing(event).countdown(at: now))", action: nil, keyEquivalent: ""))
            list.addItem(NSMenuItem(title: timeLabel(event), action: nil, keyEquivalent: ""))
            if let url = link(for: event) {
                let action = NSMenuItem(title: "Join Meeting — \(url.host ?? "")", action: #selector(joinMeeting(_:)), keyEquivalent: "")
                action.target = self; action.representedObject = url
                list.addItem(action)
            }
            list.addItem(.separator())
        }
        if events.isEmpty { list.addItem(NSMenuItem(title: "No upcoming timed events", action: nil, keyEquivalent: "")) }
        agenda.submenu = list
        guard let next = events.first else {
            item.button?.title = "↔︎  📅"
            item.button?.toolTip = "No upcoming timed events in the next 24 hours"
            heading.title = "No upcoming meetings"
            detail.title = selected.isEmpty ? "Choose calendars below" : "No timed events in the next 24 hours"
            return
        }
        if let url = link(for: next) {
            join.isHidden = false; join.representedObject = url
            join.title = "Join Meeting — \(url.host ?? "")"
        }
        let title = (next.title ?? "Untitled event").replacingOccurrences(of: "\n", with: " ")
        let short = title.count > 28 ? String(title.prefix(27)) + "…" : title
        let countdown = timing(next).countdown(at: now)
        item.button?.title = "📅 \(short) · \(countdown)"
        item.button?.toolTip = "\(title)\n\(timeLabel(next))\n\(countdown)"
        heading.title = title
        detail.title = "\(timeLabel(next)) · \(countdown)"
    }
}
