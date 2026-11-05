import AppKit
import SwiftUI

/// Distracting sites (YouTube, X…) stay closed until today's Pluckk is done. Every second and a
/// half Pluckk reads the open tabs of Chrome-family browsers and Safari through Apple Events; a tab
/// on a gated site, outside an earned window, is sent to a page that says so. Finishing the day
/// (nothing due, no new cards left) earns a few minutes; the next window needs more cards done.
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

    /// Open the gate for the earned minutes, and the site itself in the default browser.
    func open(site: String) {
        let until = Date().addingTimeInterval(TimeInterval(minutes * 60))
        unlockedUntil = until
        now = Date()
        reviewsSinceWindow = 0
        defaults.set(until, forKey: Self.untilKey)
        defaults.set(0, forKey: Self.sinceKey)
        defaults.set(Self.today(), forKey: Self.usedTodayKey)
        if let url = URL(string: "https://\(site)") { NSWorkspace.shared.open(url) }
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
        // Only browsers already running: telling one that isn't would launch it.
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let targets = Self.browsers.filter(running.contains)
        guard !targets.isEmpty else { return }
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
    nonisolated private static func sweep(browser id: String, gated: [String]) -> String? {
        let read = """
        with timeout of 3 seconds
        tell application id "\(id)"
        set out to ""
        set wi to 0
        repeat with w in windows
        set wi to wi + 1
        set ti to 0
        repeat with u in (get URL of tabs of w)
        set ti to ti + 1
        set out to out & wi & tab & ti & tab & u & linefeed
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

/// On the Done screen: the earned minutes, as one button per gated site, or what's left to earn them.
struct SiteGateOffer: View {
    let dayDone: Bool
    @ObservedObject private var gate = SiteGate.shared
    @AppStorage(SiteGate.enabledKey) private var enabled = true

    var body: some View {
        if enabled && !gate.sites.isEmpty {
            VStack(spacing: 8) {
                if gate.isOpen {
                    Text("Open for \(gate.secondsLeft / 60):\(String(format: "%02d", gate.secondsLeft % 60)) more")
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                        .foregroundColor(PluckkTheme.accent)
                } else if dayDone && gate.cardsToNextWindow == 0 {
                    Text("You've earned \(gate.minutes) minutes").font(.system(size: 12)).foregroundColor(.secondary)
                    HStack(spacing: 8) {
                        ForEach(visibleSites, id: \.self) { site in
                            Button("Open \(site)") { gate.open(site: site) }
                                .buttonStyle(PillButtonStyle(prominent: false))
                        }
                    }
                } else if dayDone {
                    Text("\(gate.cardsToNextWindow) more card\(gate.cardsToNextWindow == 1 ? "" : "s") to earn another \(gate.minutes) minutes")
                        .font(.system(size: 12)).foregroundColor(.secondary)
                } else {
                    Text("Finish today's cards to open \(visibleSites.joined(separator: " or "))")
                        .font(.system(size: 12)).foregroundColor(.secondary)
                }
                if let problem = gate.permissionProblem {
                    Text(problem).font(.system(size: 11)).foregroundColor(PluckkTheme.Dark.warning)
                        .multilineTextAlignment(.center).frame(maxWidth: 360)
                }
            }
        }
    }

    /// twitter.com is X's old name; one button for the pair is enough.
    private var visibleSites: [String] { gate.sites.filter { $0 != "twitter.com" || !gate.sites.contains("x.com") } }
}
