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

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // The handler is held weakly through a proxy: WKUserContentController keeps a strong one.
        config.userContentController.add(WeakHandler(context.coordinator), name: "pluckk")
        let web = WKWebView(frame: .zero, configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = context.coordinator
        context.coordinator.web = web
        if let path = module.path, let url = URL(string: "\(Config.backendURL)/modules/\(path)/index.html") {
            web.load(URLRequest(url: url))
        }
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
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

    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "pluckk")
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
                  "revealed": parent.revealed, "capabilities": ["speak": true]])
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
                    let height = CGFloat(min(h, 900))
                    DispatchQueue.main.async { [weak self] in
                        if self?.parent.height != height { self?.parent.height = height }
                    }
                }
            case "response":
                guard parent.slot == .respond, !responded, let score = body["score"] as? Double else { return }
                responded = true
                let response = ModuleResponse(score: score, summary: body["summary"] as? String)
                DispatchQueue.main.async { [weak self] in self?.parent.onResponse?(response) }
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

    func stop() { synth.stopSpeaking(at: .immediate) }
}
