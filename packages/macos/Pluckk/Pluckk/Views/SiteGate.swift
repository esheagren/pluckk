import AppKit
import SwiftUI

/// Distracting sites (YouTube, X…) stay closed until today's Pluckk is done. Every second and a
/// half Pluckk reads the open tabs of Chrome-family browsers and Safari through Apple Events; a tab
/// on a gated site, outside an earned window, is sent to a page that says so. Finishing the day
/// (nothing due, no new cards left) earns a few minutes; the next window needs more cards done.
/// Once the day has been finished, a later batch (the next study day's, arriving in the evening)
/// doesn't lock the sites again: a finished practice session earns a window. Earned minutes are
/// spent by going to the site: the tab in front (the site, Learn Gate's page in Chrome, or
/// Pluckk's "not yet" page) is let through, with a signed pass where Learn Gate needs one.
/// It only runs while Pluckk does: a nudge, not a lock.
@MainActor
final class SiteGate: ObservableObject {
    static let shared = SiteGate()

    static let enabledKey = "siteGate.enabled"
    static let sitesKey = "siteGate.sites"
    static let minutesKey = "siteGate.minutes"
    static let defaultSites = "youtube.com, x.com, twitter.com"
    /// The rate: ten cards open the sites for twenty-five minutes (Settings changes the minutes).
    static let defaultMinutes = 25
    /// Cards to rate after a window before the next one can be earned.
    static let cardsPerWindow = 10
    /// Fewer count when they clear everything that was waiting: finishing is finishing. Not
    /// none, so a single card bouncing back every few minutes doesn't earn a window.
    static let batchCards = 5
    private static let untilKey = "siteGate.unlockedUntil"
    private static let sinceKey = "siteGate.reviewsSinceWindow"
    private static let usedTodayKey = "siteGate.windowDay"
    private static let finishedDayKey = "siteGate.finishedDay"
    private static let sessionDayKey = "siteGate.sessionEarnedDay"
    private static let leftSinceKey = "siteGate.leftSinceWindow"
    /// What a practice session must be to earn a window (the same numbers as core's gate.ts).
    static let sessionMinutes = 4
    static let sessionCards = 10

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

    /// The first window of a day comes with finishing it; after that, each needs more cards rated:
    /// a handful when there was a batch to clear, the full ten when the cards were added by hand.
    /// (A handful, not none, so one card bouncing back every few minutes doesn't earn a window.)
    var cardsToNextWindow: Int {
        let usedToday = defaults.string(forKey: Self.usedTodayKey) == Self.today()
        let needed = leftSinceWindow ? Self.batchCards : Self.cardsPerWindow
        return usedToday ? max(0, needed - reviewsSinceWindow) : 0
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

    /// A window earned (by a practice session, or by finishing what was due) and not yet used.
    /// It lapses at midnight.
    var sessionEarned: Bool { defaults.string(forKey: Self.sessionDayKey) == Self.today() }

    /// A timed session ran its course. Once the day has been finished, one that's long enough and
    /// had enough cards rated in it earns a window.
    func noteSession(minutes: Int, cards: Int) {
        guard enabled, finishedToday, !isOpen, minutes >= Self.sessionMinutes, cards >= Self.sessionCards else { return }
        defaults.set(Self.today(), forKey: Self.sessionDayKey)
        objectWillChange.send()
    }

    /// Nothing is left today, as Practice last saw it (across every deck).
    @Published private(set) var dayIsDone = false

    /// Practice's latest count of what's left today.
    func noteToday(left: Int) {
        if left == 0 { noteDayFinished() }
        // Cards waiting since the last window: clearing them is what earns the next one.
        if left > 0 && !defaults.bool(forKey: Self.leftSinceKey) { defaults.set(true, forKey: Self.leftSinceKey) }
        if dayIsDone != (left == 0) { dayIsDone = left == 0 }
        // Finishing earns the window there and then, and it's kept until it's used (or midnight).
        // "Nothing left" doesn't last: cards due later today keep coming into the count, a few an
        // hour, so a window that depended on the count still being zero when the site is visited
        // would often be gone by then.
        if left == 0 && cardsToNextWindow == 0 && !isOpen && !sessionEarned {
            defaults.set(Self.today(), forKey: Self.sessionDayKey)
            objectWillChange.send()
        }
    }

    /// There have been cards to do since the last window (a new batch came in, say).
    private var leftSinceWindow: Bool { defaults.bool(forKey: Self.leftSinceKey) }

    /// How a window was earned: by finishing the day's cards, or by a practice session after that.
    enum Earned { case day, session }

    /// A window there for the taking, if any.
    /// Finishing what's due earns one: the first of the day, and again whenever a later batch
    /// has been cleared (see cardsToNextWindow). Mid-batch, once the day has been finished, a
    /// practice session earns one too.
    var earned: Earned? {
        if dayIsDone && cardsToNextWindow == 0 { return .day }
        return sessionEarned ? .session : nil
    }

    /// Open the gate for the earned minutes, and the site itself in the default browser.
    /// `bySession`: the window was earned by a practice session rather than a finished day.
    func open(site: String, bySession: Bool = false) {
        guard !opening else { return }
        opening = true
        passProblem = nil
        Task {
            defer { opening = false }
            let signed = await pass(bySession ? .session : .day)
            // Without a pass the site still opens where only this gate stands in the way. In Chrome
            // Learn Gate would turn it away, so the minutes are kept rather than spent on nothing.
            if signed == nil && Self.defaultBrowserNeedsPass {
                passProblem = "Pluckk's server didn't give a pass, and Chrome's Learn Gate opens only with one, so your \(minutes) minutes are kept. Try again in a moment."
                return
            }
            beginWindow()
            if let url = URL(string: Self.address(of: "https://\(site)", pass: signed)) { NSWorkspace.shared.open(url) }
        }
    }

    /// A signed pass from Pluckk's server, which the Learn Gate extension in Chrome opens on.
    /// A kept window is asked for as a session's: the server gives the day's pass only while
    /// nothing is due at that very moment, and a card may have come due since the window was earned.
    private func pass(_ earned: Earned) async -> String? {
        let kept = earned == .session || sessionEarned
        guard let token = AuthManager.shared.accessToken,
              let data = try? await PluckkAPI.shared.raw(token: token, method: "POST", path: "/api/v1/gate/pass",
                                                         json: kept ? ["minutes": minutes, "session": true] : ["minutes": minutes]),
              let pass = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return pass["token"] as? String
    }

    /// The earned minutes start now.
    private func beginWindow() {
        let until = Date().addingTimeInterval(TimeInterval(minutes * 60))
        unlockedUntil = until
        now = Date()
        reviewsSinceWindow = 0
        defaults.set(until, forKey: Self.untilKey)
        defaults.set(0, forKey: Self.sinceKey)
        defaults.set(Self.today(), forKey: Self.usedTodayKey)
        defaults.removeObject(forKey: Self.sessionDayKey)      // a session's window is used once
        defaults.set(false, forKey: Self.leftSinceKey)
    }

    /// Where to send the browser for a site: through Pluckk's pass page when there's a pass (so
    /// Learn Gate unlocks too), else straight there.
    nonisolated private static func address(of target: String, pass: String?) -> String {
        guard let pass else { return target }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let to = target.addingPercentEncoding(withAllowedCharacters: allowed) ?? target
        return "\(Config.backendURL)/pass.html#token=\(pass)&to=\(to)"
    }

    /// Why the last try at opening a site came to nothing, if it did.
    @Published private(set) var passProblem: String?
    private var opening = false

    /// Chrome is where the Learn Gate extension lives; it lets a gated site through only on a pass.
    private static var defaultBrowserNeedsPass: Bool {
        guard let probe = URL(string: "https://example.com"), let app = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return false }
        return Bundle(url: app)?.bundleIdentifier?.hasPrefix("com.google.Chrome") == true
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
        guard !sweeping else { return }
        sweeping = true
        let earned = self.earned
        queue.async { [weak self] in
            let (problem, knock) = Self.sweep(browser: front, gated: gated, earned: earned != nil)
            Task { @MainActor in
                self?.sweeping = false
                self?.notePermission(problem)
                if let knock, let earned { await self?.answer(knock, earned: earned) }
            }
        }
    }

    private func notePermission(_ problem: String?) {
        if permissionProblem != problem { permissionProblem = problem }
    }

    /// The tab in front is asking for a gated site, and there are minutes earned.
    struct Knock {
        enum Kind {
            /// The site itself, in a browser where only this gate stands in the way.
            case site
            /// Learn Gate's page (Chrome), which opens only on a signed pass.
            case learnGate
            /// Pluckk's own "not yet" page.
            case blocked
        }
        let kind: Kind
        let browser: String
        let window: Int
        let tab: Int
        /// The tab's address now, and the site address it wants.
        let url: String
        let target: String
    }

    /// Going to a gated site with minutes earned spends them: the window starts and the tab goes
    /// on to the site. Nothing to click in Pluckk first.
    private func answer(_ knock: Knock, earned: Earned) async {
        guard !opening, !isOpen, self.earned != nil else { return }
        opening = true
        defer { opening = false }
        passProblem = nil
        var signed: String?
        if knock.kind != .site {
            signed = await pass(earned)
            if signed == nil && knock.kind == .learnGate {
                // The day's pass is refused once a new batch has arrived: what's left has changed.
                if earned == .day { PracticeSession.shared.refreshTodayCounts() }
                passProblem = "Pluckk's server didn't give a pass, and Chrome's Learn Gate opens only with one, so your \(minutes) minutes are kept. Try again in a moment."
                return
            }
        }
        beginWindow()
        guard knock.kind != .site else { return }       // already on the site; it just stops being sent away
        let to = Self.address(of: knock.target, pass: signed)
        queue.async {
            // Only if the tab is still where it was: tabs move while a pass is fetched.
            _ = Self.osascript("""
            with timeout of 3 seconds
            tell application id "\(knock.browser)"
            if (URL of tab \(knock.tab) of window \(knock.window)) is "\(Self.quoted(knock.url))" then set URL of tab \(knock.tab) of window \(knock.window) to "\(Self.quoted(to))"
            end tell
            end timeout
            """)
        }
    }

    nonisolated private static func quoted(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Reads every tab's address in one browser. Gated ones are sent to the block page, unless
    /// minutes are earned and it's the tab in front: that one comes back as a knock, to be let in.
    /// So do Learn Gate's page and Pluckk's block page when they're in front. Runs osascript as its
    /// own process with a time limit, so a slow or hung browser can't stall Pluckk. Also returns a
    /// message if macOS refused (Automation permission not given).
    /// The separator is set outside the tell block: inside it, `tab` means the browser's tab
    /// class and comes out as the word "tab", so no line would parse and nothing would be blocked.
    nonisolated private static func sweep(browser id: String, gated: [String], earned: Bool) -> (problem: String?, knock: Knock?) {
        // Which tab of the front window is showing: Safari and the Chrome family say it differently.
        let active = id == "com.apple.Safari" ? "index of current tab of window 1" : "active tab index of window 1"
        let read = """
        set sep to (character id 9)
        with timeout of 3 seconds
        tell application id "\(id)"
        set a to 0
        try
        set a to \(active)
        end try
        set out to "A" & sep & a & linefeed
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
            return ("Pluckk isn't allowed to control \(name(of: id)), so it can't keep gated sites closed there. Turn it on in System Settings › Privacy & Security › Automation.", nil)
        }
        var front = 0
        var sets: [String] = []
        var knock: Knock?
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
            if parts.count == 2, parts[0] == "A" { front = Int(parts[1]) ?? 0; continue }
            guard parts.count == 3, let w = Int(parts[0]), let t = Int(parts[1]) else { continue }
            let url = parts[2]
            let inFront = earned && w == 1 && t == front
            if let host = gatedHost(url, gated) {
                if inFront { knock = Knock(kind: .site, browser: id, window: w, tab: t, url: url, target: url) }
                else { sets.append("set URL of tab \(t) of window \(w) to \"\(blockPage)?site=\(host)\"") }
            } else if inFront, let target = wanted(by: url, gated: gated) {
                knock = Knock(kind: url.hasPrefix(blockPage) ? .blocked : .learnGate, browser: id, window: w, tab: t, url: url, target: target)
            }
        }
        if !sets.isEmpty {
            _ = osascript("with timeout of 3 seconds\ntell application id \"\(id)\"\n\(sets.joined(separator: "\n"))\nend tell\nend timeout")
        }
        return (nil, knock)
    }

    /// The gated address a waiting page stands in for: Learn Gate's page carries it after the #,
    /// Pluckk's block page names the site.
    nonisolated static func wanted(by url: String, gated: [String]) -> String? {
        if url.hasPrefix("chrome-extension://"), let hash = url.range(of: "/gate.html#") {
            let target = String(url[hash.upperBound...])
            return gatedHost(target, gated) != nil ? target : nil
        }
        if url.hasPrefix(blockPage), let site = URLComponents(string: url)?.queryItems?.first(where: { $0.name == "site" })?.value,
           gatedHost("https://\(site)", gated) != nil {
            return "https://\(site)"
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
                if gate.isOpen {
                    Text("Open for \(gate.countdown) more")
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                        .foregroundColor(PluckkTheme.accent)
                } else if let earned = gate.earned {
                    Text("You've earned \(gate.minutes) minutes").font(.system(size: 12)).foregroundColor(.secondary)
                    HStack(spacing: 8) {
                        ForEach(gate.shownSites, id: \.self) { site in
                            Button("Open \(site)") { gate.open(site: site, bySession: earned == .session) }
                                .buttonStyle(PillButtonStyle(prominent: false))
                        }
                    }
                } else if dayDone {
                    Text("\(gate.cardsToNextWindow) more card\(gate.cardsToNextWindow == 1 ? "" : "s") to earn another \(gate.minutes) minutes. Add new cards above.")
                        .font(.system(size: 12)).foregroundColor(.secondary)
                } else if gate.finishedToday {
                    // The day was done once; what's here now is the next batch.
                    Text("Today's cards are done. A practice session of \(SiteGate.sessionMinutes) minutes and \(SiteGate.sessionCards) cards earns \(gate.minutes) minutes of \(gate.shownSites.joined(separator: " or ")).")
                        .font(.system(size: 12)).foregroundColor(.secondary)
                        .multilineTextAlignment(.center).frame(maxWidth: 380)
                } else {
                    Text("Finish today's cards to open \(gate.shownSites.joined(separator: " or "))")
                        .font(.system(size: 12)).foregroundColor(.secondary)
                }
                if let problem = gate.passProblem ?? gate.permissionProblem {
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
            } else if let earned = gate.earned {
                HStack(spacing: 8) {
                    Text("\(gate.minutes) min earned").font(.system(size: 11, weight: .semibold)).foregroundColor(PluckkTheme.accent)
                    ForEach(gate.shownSites, id: \.self) { site in
                        Button(action: { gate.open(site: site, bySession: earned == .session) }) {
                            Text(site).font(.system(size: 11)).underline().foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Open \(site) for \(gate.minutes) minutes")
                    }
                    if let problem = gate.passProblem {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10))
                            .foregroundColor(PluckkTheme.Dark.warning)
                            .help(problem)
                    }
                }
            }
        }
    }
}
