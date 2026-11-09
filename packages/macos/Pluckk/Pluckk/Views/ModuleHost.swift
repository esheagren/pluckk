import SwiftUI
import WebKit
import AVFoundation

// Card modules: maps, audio and anything else a card can show or be answered with. A module is
// a small web page served from the API (/modules/<id>/<major>/index.html) that runs in a
// sandboxed web view and talks to the app only through the messages below. The design is in
// docs/roadmap/planned/card-modules/plan.md; the runtime modules include is
// packages/api/public/modules/pluckk-module.js.

/// Any JSON value, so a module's props pass through untouched.
indirect enum JSONValue: Codable, Equatable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

struct ModuleUse: Decodable, Equatable {
    let use: String
    let props: JSONValue?
    /// Where the page is served, as the API gives it ("/modules/geo-map/1/index.html", or
    /// "/um/<user>/<slug>/<n>/index.html" for his own modules).
    var src: String? = nil

    /// The page's full address on the API's own server.
    var pageURL: URL? {
        if let src, src.hasPrefix("/modules/") || src.hasPrefix("/um/") { return URL(string: "\(Config.backendURL)\(src)") }
        return path.flatMap { URL(string: "\(Config.backendURL)/modules/\($0)/index.html") }
    }

    /// "geo-map@1" → "geo-map/1", the module's folder under /modules.
    var path: String? {
        let parts = use.split(separator: "@")
        guard parts.count == 2, parts[0].allSatisfy({ $0.isLowercase || $0.isNumber || $0 == "-" }),
              parts[1].allSatisfy(\.isNumber) else { return nil }
        return "\(parts[0])/\(parts[1])"
    }
}

/// A card's modules: shown with the question, the way it's answered, shown with the answer.
struct CardModules: Decodable, Equatable {
    let prompt: [ModuleUse]?
    let respond: ModuleUse?
    let reveal: [ModuleUse]?
}

/// What a respond module sent back: a 0–1 score and a line saying how it went.
struct ModuleResponse: Equatable {
    let score: Double
    let summary: String?

    /// The same bands for every module, so a score means the same thing everywhere.
    var rating: ReviewRating {
        score >= 0.9 ? .easy : score >= 0.7 ? .good : score >= 0.4 ? .hard : .again
    }
}

enum ModuleSlot: String { case prompt, respond, reveal }

/// One module on a card, sized to whatever height the module reports.
struct ModuleSlotView: View {
    let module: ModuleUse
    let slot: ModuleSlot
    var revealed: Bool = false
    var onResponse: ((ModuleResponse) -> Void)? = nil
    @Environment(\.colorScheme) private var colorScheme
    @State private var height: CGFloat = 0

    var body: some View {
        ModuleWebView(module: module, slot: slot, revealed: revealed, dark: colorScheme == .dark,
                      height: $height, onResponse: onResponse)
            .frame(height: max(height, 24))
            .frame(maxWidth: .infinity)
    }
}

private struct ModuleWebView: NSViewRepresentable {
    let module: ModuleUse
    let slot: ModuleSlot
    let revealed: Bool
    let dark: Bool
    @Binding var height: CGFloat
    let onResponse: ((ModuleResponse) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> ModuleContainer {
        let config = WKWebViewConfiguration()
        // The handler is held weakly through a proxy: WKUserContentController keeps a strong one.
        config.userContentController.add(WeakHandler(context.coordinator), name: "pluckk")
        let web = WKWebView(frame: .zero, configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = context.coordinator
        context.coordinator.web = web
        if let url = module.pageURL { web.load(URLRequest(url: url)) }
        return ModuleContainer(web)
    }

    func updateNSView(_ container: ModuleContainer, context: Context) {
        let c = context.coordinator
        c.parent = self
        if revealed && !c.sentReveal && c.loaded {
            c.sentReveal = true
            c.post(["type": "reveal"])
        }
        if dark != c.lastDark && c.loaded {
            c.lastDark = dark
            c.post(["type": "theme", "theme": Self.theme(dark)])
        }
    }

    static func dismantleNSView(_ container: ModuleContainer, coordinator: Coordinator) {
        container.web.configuration.userContentController.removeScriptMessageHandler(forName: "pluckk")
        ModuleSpeech.shared.stop()
    }

    /// Pluckk's colour tokens, as CSS colours, so a module matches the card it sits on.
    static func theme(_ dark: Bool) -> [String: Any] {
        dark
        ? ["dark": true, "text": "#f5f5f5", "muted": "#777777", "accent": "#c9a66b", "surface": "#1c1c1e",
           "rule": "#2e2e30", "success": "#27ae60", "warning": "#e5a14b"]
        : ["dark": false, "text": "#2d3436", "muted": "#a0a0a0", "accent": "#c9a66b", "surface": "#ffffff",
           "rule": "#dedede", "success": "#27ae60", "warning": "#e5a14b"]
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: ModuleWebView
        weak var web: WKWebView?
        var loaded = false
        var sentReveal = false
        var lastDark: Bool
        var responded = false
        private var heights: [CGFloat] = []
        private var settled: CGFloat?

        /// A module's height, applied only when it's a real change. If it starts flipping between
        /// two values (content and layout feeding each other), keep the larger one for good.
        func apply(height h: CGFloat) {
            if let settled { if h > settled + 1 { self.settled = h; set(h) }; return }
            if heights.count >= 2, abs(heights[heights.count - 2] - h) <= 1, abs(heights.last! - h) > 1 {
                let keep = max(h, heights.last!)
                settled = keep
                set(keep)
                return
            }
            heights.append(h)
            if heights.count > 6 { heights.removeFirst() }
            set(h)
        }

        private func set(_ h: CGFloat) {
            guard abs(parent.height - h) > 1 else { return }
            parent.height = h
        }

        init(_ parent: ModuleWebView) {
            self.parent = parent
            self.lastDark = parent.dark
        }

        func post(_ message: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: ["pluckk": message]),
                  let json = String(data: data, encoding: .utf8) else { return }
            web?.evaluateJavaScript("window.postMessage(\(json), '*')")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            var props: Any = [String: Any]()
            if let p = parent.module.props, let data = try? JSONEncoder().encode(p),
               let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) { props = obj }
            post(["type": "init", "slot": parent.slot.rawValue, "props": props, "theme": ModuleWebView.theme(parent.dark),
                  "revealed": parent.revealed, "capabilities": ["speak": true, "play": true]])
            sentReveal = parent.revealed
        }

        /// Modules stay on their own server: no links out, no other pages.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let ours = URL(string: Config.backendURL)?.host
            if action.targetFrame?.isMainFrame == false || action.request.url?.host == ours { decisionHandler(.allow) }
            else { decisionHandler(.cancel) }
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "ready", "resize":
                if let h = body["height"] as? Double, h > 0 {
                    let height = CGFloat(min(h, 900)).rounded()
                    DispatchQueue.main.async { [weak self] in self?.apply(height: height) }
                }
            case "response":
                guard parent.slot == .respond, !responded, let score = body["score"] as? Double else { return }
                responded = true
                let response = ModuleResponse(score: score, summary: body["summary"] as? String)
                DispatchQueue.main.async { [weak self] in self?.parent.onResponse?(response) }
            case "play":
                if let src = body["src"] as? String, let url = URL(string: src), url.scheme == "https" {
                    ModuleSpeech.shared.play(url)
                }
            case "speak":
                if let text = body["text"] as? String {
                    ModuleSpeech.shared.say(text, lang: body["lang"] as? String ?? "zh-CN")
                }
            default:
                break
            }
        }
    }

    private final class WeakHandler: NSObject, WKScriptMessageHandler {
        weak var target: WKScriptMessageHandler?
        init(_ target: WKScriptMessageHandler) { self.target = target }
        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
            target?.userContentController(c, didReceive: m)
        }
    }
}

/// Holds the web view so its own layout changes stay inside: SwiftUI sees a plain view with no
/// size of its own and gives it the frame the module asked for.
final class ModuleContainer: NSView {
    let web: WKWebView

    init(_ web: WKWebView) {
        self.web = web
        super.init(frame: .zero)
        web.autoresizingMask = [.width, .height]
        web.frame = bounds
        addSubview(web)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    override var isFlipped: Bool { true }
}

/// The Mac's own voices, for modules that read things aloud (Tingting for zh-CN).
final class ModuleSpeech {
    static let shared = ModuleSpeech()
    private let synth = AVSpeechSynthesizer()

    func say(_ text: String, lang: String) {
        synth.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: lang)
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
        synth.speak(u)
    }

    private var player: AVPlayer?

    /// A recorded pronunciation, from a module's audio URL.
    func play(_ url: URL) {
        synth.stopSpeaking(at: .immediate)
        player = AVPlayer(url: url)
        player?.play()
    }

    func stop() { synth.stopSpeaking(at: .immediate); player?.pause() }
}

// MARK: - Trying a module without a card

/// Loads a module page off-screen with given props, the way a card would, and reports what
/// happened: whether it said it was ready, its height, any responses, and every script error or
/// blocked load. The assistant uses this to test a module it has just written.
@MainActor
final class ModuleProbe: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private var web: WKWebView?
    private var window: NSWindow?
    private var lines: [String] = []
    private var ready: Double?
    private var finished: CheckedContinuation<Void, Never>?
    private let slot: ModuleSlot
    private let props: Any

    private init(slot: ModuleSlot, props: Any) {
        self.slot = slot
        self.props = props
    }

    static func run(url: URL, slot: ModuleSlot, props: Any, dark: Bool = true) async -> String {
        let probe = ModuleProbe(slot: slot, props: props)
        return await probe.go(url, dark: dark)
    }

    private func go(_ url: URL, dark: Bool) async -> String {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let watch = """
        (function(){
          const post = (m) => { try { window.webkit.messageHandlers.probe.postMessage(m); } catch (e) {} };
          addEventListener('error', (e) => post('Script error: ' + (e.message || e) + (e.filename ? ' (' + e.filename.split('/').pop() + ':' + e.lineno + ')' : '')), true);
          addEventListener('unhandledrejection', (e) => post('Unhandled promise rejection: ' + (e.reason && (e.reason.message || e.reason))));
          document.addEventListener('securitypolicyviolation', (e) => post('Blocked by the content policy: ' + e.blockedURI + ' (' + e.violatedDirective + ')'));
          const ce = console.error.bind(console);
          console.error = (...a) => { post('console.error: ' + a.map(String).join(' ')); ce(...a); };
        })();
        """
        config.userContentController.addUserScript(WKUserScript(source: watch, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController.add(self, name: "probe")
        config.userContentController.add(self, name: "pluckk")
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 560, height: 600), configuration: config)
        web.navigationDelegate = self
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 560, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = web
        window.orderBack(nil)
        self.web = web
        self.window = window
        web.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            finished = c
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.finish() }
        }
        web.configuration.userContentController.removeAllScriptMessageHandlers()
        window.orderOut(nil)
        self.web = nil
        self.window = nil
        var report = [ready.map { "Loaded and ready, \(Int($0)) px tall." } ?? "It never called Pluckk.ready() within 8 seconds."]
        report += lines.isEmpty ? ["No script errors."] : Array(lines.prefix(20))
        return report.joined(separator: "\n")
    }

    private func finish() {
        finished?.resume()
        finished = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let theme = ["dark": true, "text": "#f5f5f5", "muted": "#777777", "accent": "#c9a66b", "surface": "#1c1c1e",
                     "rule": "#2e2e30", "success": "#27ae60", "warning": "#e5a14b"] as [String: Any]
        let message: [String: Any] = ["pluckk": ["type": "init", "slot": slot.rawValue, "props": props, "theme": theme,
                                                 "revealed": slot == .reveal, "capabilities": ["speak": true, "play": true]]]
        guard let data = try? JSONSerialization.data(withJSONObject: message), let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.postMessage(\(json), '*')")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        lines.append("The page failed to load: \(error.localizedDescription)"); finish()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        lines.append("The page failed to load: \(error.localizedDescription)"); finish()
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let http = response.response as? HTTPURLResponse, http.statusCode >= 400 {
            lines.append("The page answered HTTP \(http.statusCode).")
        }
        decisionHandler(.allow)
    }

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "probe", let text = message.body as? String {
            lines.append(text)
            return
        }
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            ready = body["height"] as? Double ?? 0
            // Give it a moment to show any errors from drawing, then report.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.finish() }
        case "response":
            lines.append("It sent a response: score \(body["score"] ?? "?"), \(body["summary"] ?? "")")
        default:
            break
        }
    }
}

/// A module shown in the assistant panel, to try before it goes on a card. Answering it reveals
/// it, as a card would.
struct ModulePreview: View {
    let module: ModuleUse
    let slot: ModuleSlot
    let title: String
    @State private var revealed = false
    @State private var response: ModuleResponse?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
                Spacer()
                if slot == .respond {
                    Button(revealed ? "Reset" : "Reveal") {
                        if revealed { revealed = false; response = nil } else { revealed = true }
                    }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
            ModuleSlotView(module: module, slot: slot, revealed: revealed || slot == .reveal) { r in
                response = r
                revealed = true
            }
            .id(revealed ? "r" : "q")
            if let response {
                Text("\(response.summary ?? "Answered") · suggests \(response.rating.title)")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}
