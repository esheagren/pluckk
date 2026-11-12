import AppKit
import SwiftUI

/// Distracting sites (YouTube, X…) stay closed until today's Pluckk is done. Every second and a
/// half Pluckk reads the open tabs of Chrome-family browsers and Safari through Apple Events; a tab
/// on a gated site, outside an earned window, is sent to a page that says so. Finishing the day
/// (nothing due, no new cards left) earns a few minutes; the next window needs more cards done.
/// Once the day has been finished, a later batch (the next study day's, arriving in the evening)
/// doesn't lock the sites again: a finished practice session earns a window.
/// It only runs while Pluckk does: a nudge, not a lock.
@MainActor
final class SiteGate: ObservableObject {
    static let shared = SiteGate()

    static let enabledKey = "siteGate.enabled"
    static let sitesKey = "siteGate.sites"
    static let minutesKey = "siteGate.minutes"
    static let defaultSites = "youtube.com, x.com, twitter.com"
    static let defaultMinutes = 5
    /// Cards to rate after a window before the next one can be earned.
    static let cardsPerWindow = 10
    private static let untilKey = "siteGate.unlockedUntil"
    private static let sinceKey = "siteGate.reviewsSinceWindow"
    private static let usedTodayKey = "siteGate.windowDay"
    private static let finishedDayKey = "siteGate.finishedDay"
    private static let sessionDayKey = "siteGate.sessionEarnedDay"
    /// What a practice session must be to earn a window (the same numbers as core's gate.ts).
    static let sessionMinutes = 4
    static let sessionCards = 5

    /// Where a blocked tab goes.
    static let blockPage = "\(Config.backendURL)/blocked.html"

    @Published private(set) var unlockedUntil: Date?
    @Published private(set) var reviewsSinceWindow: Int
    @Published private(set) var now = Date()

    private var timer: Timer?
    private let queue = DispatchQueue(label: "com.pluckk.sitegate")
    private var sweeping = false
    @Published private(set) var permissionProblem: String?

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [Self.enabledKey: true, Self.sitesKey: Self.defaultSites, Self.minutesKey: Self.defaultMinutes])
        let until = defaults.object(forKey: Self.untilKey) as? Date
        unlockedUntil = until.flatMap { $0 > Date() ? $0 : nil }
        reviewsSinceWindow = defaults.integer(forKey: Self.sinceKey)
    }

    var enabled: Bool { defaults.bool(forKey: Self.enabledKey) }
    var minutes: Int { max(1, min(60, defaults.integer(forKey: Self.minutesKey))) }

    /// "youtube.com, x.com" → ["youtube.com", "x.com"]; a site covers its subdomains.
    var sites: [String] {
        (defaults.string(forKey: Self.sitesKey) ?? Self.defaultSites)
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" })
            .map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "./")) }
            .map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
            .filter { $0.contains(".") }
    }

    var isOpen: Bool { (unlockedUntil ?? .distantPast) > now }
    var secondsLeft: Int { max(0, Int((unlockedUntil ?? now).timeIntervalSince(now).rounded(.up))) }

    /// The first window of a day comes with finishing it; after that, each needs more cards rated.
    var cardsToNextWindow: Int {
        let usedToday = defaults.string(forKey: Self.usedTodayKey) == Self.today()
        return usedToday ? max(0, Self.cardsPerWindow - reviewsSinceWindow) : 0
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
    }

    /// A card rated anywhere in Practice counts toward the next window.
    func noteReview() {
        reviewsSinceWindow += 1
        defaults.set(reviewsSinceWindow, forKey: Self.sinceKey)
    }

    // MARK: After the day is done

    /// Today's cards were all done at some point today (by the calendar), even if a new batch has
    /// arrived since.
    var finishedToday: Bool { defaults.string(forKey: Self.finishedDayKey) == Self.today() }

    /// Nothing due and no new cards left: the day is finished, and stays so until midnight.
    func noteDayFinished() {
        guard !finishedToday else { return }
        defaults.set(Self.today(), forKey: Self.finishedDayKey)
        objectWillChange.send()
    }

    /// A window earned by a practice session and not yet used. It lapses at midnight.
    var sessionEarned: Bool { defaults.string(forKey: Self.sessionDayKey) == Self.today() }

    /// A timed session ran its course. Once the day has been finished, one that's long enough and
    /// had enough cards rated in it earns a window.
    func noteSession(minutes: Int, cards: Int) {
        guard enabled, finishedToday, !isOpen, minutes >= Self.sessionMinutes, cards >= Self.sessionCards else { return }
        defaults.set(Self.today(), forKey: Self.sessionDayKey)
        objectWillChange.send()
    }

    /// Open the gate for the earned minutes, and the site itself in the default browser.
    /// `bySession`: the window was earned by a practice session rather than a finished day.
    func open(site: String, bySession: Bool = false) {
        let until = Date().addingTimeInterval(TimeInterval(minutes * 60))
        unlockedUntil = until
        now = Date()
        reviewsSinceWindow = 0
        defaults.set(until, forKey: Self.untilKey)
        defaults.set(0, forKey: Self.sinceKey)
        defaults.set(Self.today(), forKey: Self.usedTodayKey)
        defaults.removeObject(forKey: Self.sessionDayKey)      // a session's window is used once
        let minutes = self.minutes
        // Through Pluckk's pass page with a signed pass, so the Learn Gate extension in Chrome
        // opens too; if no pass can be had, straight to the site.
        Task {
            var target = URL(string: "https://\(site)")
            if let token = AuthManager.shared.accessToken,
               let data = try? await PluckkAPI.shared.raw(token: token, method: "POST", path: "/api/v1/gate/pass",
                                                          json: bySession ? ["minutes": minutes, "session": true] : ["minutes": minutes]),
               let pass = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let signed = pass["token"] as? String {
                target = URL(string: "\(Config.backendURL)/pass.html#token=\(signed)&to=https://\(site)")
            }
            if let target { NSWorkspace.shared.open(target) }
        }
    }

    private static func today() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date())
    }

    // MARK: Watching the browsers

    /// Browsers whose tabs can be read and set with the same Apple Events.
    private static let browsers = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.brave.Browser", "com.microsoft.edgemac",
        "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.apple.Safari",
    ]

    private func tick() {
        now = Date()
        if let until = unlockedUntil, until <= now {
            unlockedUntil = nil
            defaults.removeObject(forKey: Self.untilKey)
        }
        guard enabled, !isOpen else { return }
        let gated = sites
        guard !gated.isEmpty else { return }
        // Only the browser in front: that's where a gated page would be read, it's certainly
        // running (telling one that isn't would launch it), and the rest of the time this costs nothing.
        guard let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, Self.browsers.contains(front) else { return }
        let targets = [front]
        guard !sweeping else { return }
        sweeping = true
        queue.async { [weak self] in
            var problem: String?
            for id in targets { problem = Self.sweep(browser: id, gated: gated) ?? problem }
            Task { @MainActor in
                self?.sweeping = false
                self?.notePermission(problem)
            }
        }
    }

    private func notePermission(_ problem: String?) {
        if permissionProblem != problem { permissionProblem = problem }
    }

    /// Reads every tab's address in one browser and sends gated ones to the block page. Runs
    /// osascript as its own process with a time limit, so a slow or hung browser can't stall
    /// Pluckk. Returns a message if macOS refused (Automation permission not given).
    /// The separator is set outside the tell block: inside it, `tab` means the browser's tab
    /// class and comes out as the word "tab", so no line would parse and nothing would be blocked.
    nonisolated private static func sweep(browser id: String, gated: [String]) -> String? {
        let read = """
        set sep to (character id 9)
        with timeout of 3 seconds
        tell application id "\(id)"
        set out to ""
        set wi to 0
        repeat with w in windows
        set wi to wi + 1
        set ti to 0
        repeat with u in (get URL of tabs of w)
        set ti to ti + 1
        set out to out & wi & sep & ti & sep & u & linefeed
        end repeat
        end repeat
        return out
        end tell
        end timeout
        """
        let (out, err) = osascript(read)
        if err.contains("-1743") || err.localizedCaseInsensitiveContains("not authorized") {
            return "Pluckk isn't allowed to control \(name(of: id)), so it can't keep gated sites closed there. Turn it on in System Settings › Privacy & Security › Automation."
        }
        var sets: [String] = []
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard parts.count == 3, let w = Int(parts[0]), let t = Int(parts[1]), let host = gatedHost(parts[2], gated) else { continue }
            sets.append("set URL of tab \(t) of window \(w) to \"\(blockPage)?site=\(host)\"")
        }
        if !sets.isEmpty {
            _ = osascript("with timeout of 3 seconds\ntell application id \"\(id)\"\n\(sets.joined(separator: "\n"))\nend tell\nend timeout")
        }
        return nil
    }

    /// Runs an AppleScript in /usr/bin/osascript, giving up after 5 seconds. (stdout, stderr)
    nonisolated private static func osascript(_ source: String) -> (String, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return ("", "\(error)") }
        let deadline = Date().addingTimeInterval(5)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate(); return ("", "timed out") }
        let o = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (o, e)
    }

    /// The gated site an address belongs to, if any (subdomains included).
    nonisolated static func gatedHost(_ address: String, _ gated: [String]) -> String? {
        guard let host = URL(string: address)?.host?.lowercased() else { return nil }
        return gated.first { host == $0 || host.hasSuffix("." + $0) }
    }

    nonisolated private static func name(of id: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? id
    }
}

extension SiteGate {
    /// twitter.com is X's old name; one button for the pair is enough.
    var shownSites: [String] { sites.filter { $0 != "twitter.com" || !sites.contains("x.com") } }

    var countdown: String { "\(secondsLeft / 60):\(String(format: "%02d", secondsLeft % 60))" }
}

/// On the Done screen and after a session: the earned minutes, as one button per gated site, or
/// what's left to earn them.
struct SiteGateOffer: View {
    let dayDone: Bool
    @ObservedObject private var gate = SiteGate.shared
    @AppStorage(SiteGate.enabledKey) private var enabled = true

    var body: some View {
        if enabled && !gate.sites.isEmpty {
            VStack(spacing: 8) {
                let byDay = dayDone && gate.cardsToNextWindow == 0
                if gate.isOpen {
                    Text("Open for \(gate.countdown) more")
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                        .foregroundColor(PluckkTheme.accent)
                } else if byDay || gate.sessionEarned {
                    Text("You've earned \(gate.minutes) minutes").font(.system(size: 12)).foregroundColor(.secondary)
                    HStack(spacing: 8) {
                        ForEach(gate.shownSites, id: \.self) { site in
                            Button("Open \(site)") { gate.open(site: site, bySession: !byDay) }
                                .buttonStyle(PillButtonStyle(prominent: false))
                        }
                    }
                } else if dayDone {
                    Text("\(gate.cardsToNextWindow) more card\(gate.cardsToNextWindow == 1 ? "" : "s") to earn another \(gate.minutes) minutes")
                        .font(.system(size: 12)).foregroundColor(.secondary)
                } else if gate.finishedToday {
                    // The day was done once; what's here now is the next batch.
                    Text("Today's cards are done. A practice session of \(SiteGate.sessionMinutes) minutes or more earns \(gate.minutes) minutes of \(gate.shownSites.joined(separator: " or ")).")
                        .font(.system(size: 12)).foregroundColor(.secondary)
                        .multilineTextAlignment(.center).frame(maxWidth: 380)
                } else {
                    Text("Finish today's cards to open \(gate.shownSites.joined(separator: " or "))")
                        .font(.system(size: 12)).foregroundColor(.secondary)
                }
                if let problem = gate.permissionProblem {
                    Text(problem).font(.system(size: 11)).foregroundColor(PluckkTheme.Dark.warning)
                        .multilineTextAlignment(.center).frame(maxWidth: 360)
                }
            }
        }
    }
}

/// In Practice's header: a session's window waiting to be used, or how long an open one has left.
/// Nothing at all otherwise.
struct SiteGateChip: View {
    @ObservedObject private var gate = SiteGate.shared
    @AppStorage(SiteGate.enabledKey) private var enabled = true

    var body: some View {
        if enabled && !gate.sites.isEmpty {
            if gate.isOpen {
                Text("Sites open \(gate.countdown)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundColor(PluckkTheme.accent)
                    .help("\(gate.shownSites.joined(separator: " and ")) stay open until this runs out")
            } else if gate.sessionEarned {
                HStack(spacing: 8) {
                    Text("\(gate.minutes) min earned").font(.system(size: 11, weight: .semibold)).foregroundColor(PluckkTheme.accent)
                    ForEach(gate.shownSites, id: \.self) { site in
                        Button(action: { gate.open(site: site, bySession: true) }) {
                            Text(site).font(.system(size: 11)).underline().foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Open \(site) for \(gate.minutes) minutes")
                    }
                }
            }
        }
    }
}
