import AppKit
import CryptoKit
import SwiftUI

/// Distracting sites (YouTube, X…) are earned by practising here, on this Mac. Every ten cards
/// rated earn a window on them, and so does finishing everything that's due. One window is kept
/// at a time, until it's used; going to the site spends it.
///
/// Every second and a half Pluckk reads the open tabs of Chrome-family browsers and Safari through
/// Apple Events. Outside a window, a tab on a gated site is sent to a page that says so. With a
/// window earned, the tab in front is let through instead: the site itself, Pluckk's "not yet"
/// page, or (in Chrome) the Learn Gate extension's page, which opens on a pass signed here. No
/// server and no web app take part: this app is the judge and Learn Gate takes its word.
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
    /// Cards to rate, since the last window began, to earn the next one.
    static let cardsPerWindow = 10
    /// Fewer count when they clear everything that was waiting: finishing is finishing. Not
    /// none, so a single card coming due every few minutes doesn't earn a window each time.
    static let batchCards = 5
    private static let untilKey = "siteGate.unlockedUntil"
    private static let sinceKey = "siteGate.reviewsSinceWindow"
    private static let usedTodayKey = "siteGate.windowDay"
    private static let bankedKey = "siteGate.banked"
    private static let leftSinceKey = "siteGate.leftSinceWindow"

    /// Where a blocked tab goes.
    static let blockPage = "\(Config.backendURL)/blocked.html"

    @Published private(set) var unlockedUntil: Date?
    @Published private(set) var reviewsSinceWindow: Int
    /// A window earned and not yet used. One at a time; it's kept until it's used.
    @Published private(set) var banked: Bool
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
        // A window earned under the earlier rules (kept by the day) carries over.
        if defaults.string(forKey: "siteGate.sessionEarnedDay") == Self.today() { defaults.set(true, forKey: Self.bankedKey) }
        defaults.removeObject(forKey: "siteGate.sessionEarnedDay")
        defaults.removeObject(forKey: "siteGate.finishedDay")
        banked = defaults.bool(forKey: Self.bankedKey)
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

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
    }

    // MARK: Earning a window

    /// Cards still to rate before the next window is earned.
    var cardsToNextWindow: Int { banked ? 0 : max(1, Self.cardsPerWindow - reviewsSinceWindow) }

    /// A card rated anywhere in Practice counts. Ten since the last window began earn the next.
    func noteReview() {
        reviewsSinceWindow += 1
        defaults.set(reviewsSinceWindow, forKey: Self.sinceKey)
        if reviewsSinceWindow >= Self.cardsPerWindow { bank() }
    }

    /// Nothing is left today, as Practice last saw it (across every deck).
    @Published private(set) var dayIsDone = false

    /// Practice's latest count of what's left today. Finishing earns a window too: the first
    /// time each day, and after that when what was cleared was a batch rather than a card or two.
    /// It's earned there and then and kept, because "nothing left" doesn't last: cards due later
    /// in the day keep coming into the count, a few an hour.
    func noteToday(left: Int) {
        if left > 0 && !defaults.bool(forKey: Self.leftSinceKey) { defaults.set(true, forKey: Self.leftSinceKey) }
        if dayIsDone != (left == 0) { dayIsDone = left == 0 }
        guard left == 0 else { return }
        let usedToday = defaults.string(forKey: Self.usedTodayKey) == Self.today()
        let clearedBatch = defaults.bool(forKey: Self.leftSinceKey) && reviewsSinceWindow >= Self.batchCards
        if !usedToday || clearedBatch { bank() }
    }

    private func bank() {
        guard enabled, !banked else { return }
        banked = true
        defaults.set(true, forKey: Self.bankedKey)
    }

    /// The button in Pluckk: go to the site. Arriving there is what spends the window (see `answer`).
    func open(site: String) {
        if let url = URL(string: "https://\(site)") { NSWorkspace.shared.open(url) }
    }

    /// The earned minutes start now.
    private func beginWindow() {
        let until = Date().addingTimeInterval(TimeInterval(minutes * 60))
        unlockedUntil = until
        now = Date()
        reviewsSinceWindow = 0
        banked = false
        defaults.set(until, forKey: Self.untilKey)
        defaults.set(0, forKey: Self.sinceKey)
        defaults.set(Self.today(), forKey: Self.usedTodayKey)
        defaults.set(false, forKey: Self.bankedKey)
        defaults.set(false, forKey: Self.leftSinceKey)
    }

    private static func today() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date())
    }

    // MARK: Learn Gate's pass

    /// The Learn Gate extension (Chrome) opens on a pass signed here: when the window ends, and
    /// this app's signature over it. The extension remembers the first key it's shown and takes
    /// passes from no other, so the pass can't be typed in by hand. The key never leaves this Mac.
    private static let passKey: P256.Signing.PrivateKey? = {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Pluckk", isDirectory: true)
        let file = folder.appendingPathComponent("gate-key")
        if let data = try? Data(contentsOf: file), let key = try? P256.Signing.PrivateKey(rawRepresentation: data) { return key }
        let key = P256.Signing.PrivateKey()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try key.rawRepresentation.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return key
        } catch {
            return nil
        }
    }()

    /// "<until, ms>.<signature>.<public key>", the last two base64url. Signed text: "pluckk-pass.v1.<until>".
    static func pass(until: Date) -> String? {
        let ms = Int64((until.timeIntervalSince1970 * 1000).rounded())
        guard let key = passKey, let signature = try? key.signature(for: Data("pluckk-pass.v1.\(ms)".utf8)) else { return nil }
        return "\(ms).\(base64url(signature.rawRepresentation)).\(base64url(key.publicKey.x963Representation))"
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// What Pluckk adds after the address on Learn Gate's page: the pass, or how far off one is.
    nonisolated static let passMark = "#pluckk-pass="
    nonisolated static let needMark = "#pluckk-need="

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
        guard enabled else { return }
        let gated = sites
        guard !gated.isEmpty else { return }
        // Only the browser in front: that's where a gated page would be read, it's certainly
        // running (telling one that isn't would launch it), and the rest of the time this costs nothing.
        guard let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, Self.browsers.contains(front) else { return }
        guard !sweeping else { return }
        sweeping = true
        // In a window nothing is sent away; with one earned, the tab in front is spared (it's about to be let in).
        let block: Blocking = isOpen ? .nothing : banked ? .allButFront : .all
        queue.async { [weak self] in
            let (problem, knock) = Self.sweep(browser: front, gated: gated, block: block)
            Task { @MainActor in
                self?.sweeping = false
                self?.notePermission(problem)
                if let knock { self?.answer(knock) }
            }
        }
    }

    private func notePermission(_ problem: String?) {
        if permissionProblem != problem { permissionProblem = problem }
    }

    /// Which gated tabs a sweep sends to the block page.
    enum Blocking { case all, allButFront, nothing }

    /// The tab in front is on a gated site, or on a page standing in for one.
    struct Knock {
        enum Kind {
            /// The site itself.
            case site
            /// Learn Gate's page (Chrome), which opens on a signed pass.
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

    /// Going to a gated site with a window earned spends it: the window starts and the tab goes
    /// on to the site. Nothing to click in Pluckk first. In a window that's already running, a
    /// waiting page is simply let through. With nothing earned, Learn Gate's page is told how
    /// many cards are still to go, so it can say so.
    private func answer(_ knock: Knock) {
        if !isOpen {
            guard banked else {
                if knock.kind == .learnGate { send(knock, to: Self.gatePage(knock.url, target: knock.target) + Self.needMark + "\(cardsToNextWindow)") }
                return
            }
            beginWindow()
        }
        switch knock.kind {
        case .site:
            break                                   // already there; it just stops being sent away
        case .blocked:
            send(knock, to: knock.target)
        case .learnGate:
            guard let until = unlockedUntil, let pass = Self.pass(until: until) else { return }
            send(knock, to: Self.gatePage(knock.url, target: knock.target) + Self.passMark + pass)
        }
    }

    /// Learn Gate's page for a target, without anything Pluckk added to it before.
    nonisolated private static func gatePage(_ url: String, target: String) -> String {
        guard let hash = url.range(of: "/gate.html#") else { return url }
        return String(url[..<hash.upperBound]) + target
    }

    /// Point the knocking tab somewhere else: only if it's still where it was (tabs move), and
    /// only if that changes anything (a pass or a count already handed over isn't sent again).
    private func send(_ knock: Knock, to address: String) {
        guard address != knock.url else { return }
        queue.async {
            _ = Self.osascript("""
            with timeout of 3 seconds
            tell application id "\(knock.browser)"
            if (URL of tab \(knock.tab) of window \(knock.window)) is "\(Self.quoted(knock.url))" then set URL of tab \(knock.tab) of window \(knock.window) to "\(Self.quoted(address))"
            end tell
            end timeout
            """)
        }
    }

    nonisolated private static func quoted(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Reads every tab's address in one browser. Gated ones are sent to the block page, as
    /// `block` says. The tab in front comes back as a knock when it's on a gated site, on Learn
    /// Gate's page or on Pluckk's block page. Runs osascript as its own process with a time limit,
    /// so a slow or hung browser can't stall Pluckk. Also returns a message if macOS refused
    /// (Automation permission not given).
    /// The separator is set outside the tell block: inside it, `tab` means the browser's tab
    /// class and comes out as the word "tab", so no line would parse and nothing would be blocked.
    nonisolated private static func sweep(browser id: String, gated: [String], block: Blocking) -> (problem: String?, knock: Knock?) {
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
            let inFront = w == 1 && t == front
            if let host = gatedHost(url, gated) {
                if inFront { knock = Knock(kind: .site, browser: id, window: w, tab: t, url: url, target: url) }
                if block == .all || (block == .allButFront && !inFront) {
                    sets.append("set URL of tab \(t) of window \(w) to \"\(blockPage)?site=\(host)\"")
                }
            } else if inFront, let target = wanted(by: url, gated: gated) {
                knock = Knock(kind: url.hasPrefix(blockPage) ? .blocked : .learnGate, browser: id, window: w, tab: t, url: url, target: target)
            }
        }
        if !sets.isEmpty {
            _ = osascript("with timeout of 3 seconds\ntell application id \"\(id)\"\n\(sets.joined(separator: "\n"))\nend tell\nend timeout")
        }
        // A gated tab in front that was just sent away isn't knocking any more.
        if block == .all, knock?.kind == .site { knock = nil }
        return (nil, knock)
    }

    /// The gated address a waiting page stands in for: Learn Gate's page carries it after the #
    /// (before anything Pluckk added), Pluckk's block page names the site.
    nonisolated static func wanted(by url: String, gated: [String]) -> String? {
        if url.hasPrefix("chrome-extension://"), let hash = url.range(of: "/gate.html#") {
            var target = String(url[hash.upperBound...])
            if let added = target.range(of: "#pluckk-") { target = String(target[..<added.lowerBound]) }
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

    /// "3 more cards", for what's still to rate before the next window.
    var cardsToGo: String { "\(cardsToNextWindow) more card\(cardsToNextWindow == 1 ? "" : "s")" }
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
                } else if gate.banked {
                    Text("You've earned \(gate.minutes) minutes").font(.system(size: 12)).foregroundColor(.secondary)
                    HStack(spacing: 8) {
                        ForEach(gate.shownSites, id: \.self) { site in
                            Button("Open \(site)") { gate.open(site: site) }
                                .buttonStyle(PillButtonStyle(prominent: false))
                        }
                    }
                } else {
                    Text("\(gate.cardsToGo) for \(gate.minutes) minutes of \(gate.shownSites.joined(separator: " or "))."
                         + (dayDone ? " Add new cards above." : ""))
                        .font(.system(size: 12)).foregroundColor(.secondary)
                        .multilineTextAlignment(.center).frame(maxWidth: 380)
                }
                if let problem = gate.permissionProblem {
                    Text(problem).font(.system(size: 11)).foregroundColor(PluckkTheme.Dark.warning)
                        .multilineTextAlignment(.center).frame(maxWidth: 360)
                }
            }
        }
    }
}

/// In Practice's header: how long an open window has left, a window waiting to be used, or how
/// many cards the next one is away.
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
            } else if gate.banked {
                HStack(spacing: 8) {
                    Text("\(gate.minutes) min earned").font(.system(size: 11, weight: .semibold)).foregroundColor(PluckkTheme.accent)
                    ForEach(gate.shownSites, id: \.self) { site in
                        Button(action: { gate.open(site: site) }) {
                            Text(site).font(.system(size: 11)).underline().foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Open \(site) for \(gate.minutes) minutes")
                    }
                }
            } else {
                Text("\(gate.cardsToNextWindow) to go")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(.secondary)
                    .help("\(gate.cardsToGo) for \(gate.minutes) minutes of \(gate.shownSites.joined(separator: " or "))")
            }
        }
    }
}
