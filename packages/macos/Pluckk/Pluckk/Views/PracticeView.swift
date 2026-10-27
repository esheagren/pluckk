import SwiftUI
import AppKit

// MARK: - Session

/// The practice session, kept outside the view so collapsing the panel or switching tabs
/// doesn't lose your place. The server deals the session and schedules every rating; this
/// only walks the queue (an "again" goes back to the end, as in the web app).
@MainActor
final class PracticeSession: ObservableObject {
    static let shared = PracticeSession()

    enum Phase { case idle, loading, reviewing, done, failed(String) }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var queue: [ReviewItem] = []
    @Published private(set) var index = 0
    @Published var revealed = false
    @Published private(set) var reviewedCount = 0
    @Published private(set) var busy = false
    @Published private(set) var notice: String?

    private var shownAt = Date()
    private var last: (eventId: String, item: ReviewItem, index: Int, wasAgain: Bool)?

    var current: ReviewItem? { index < queue.count ? queue[index] : nil }
    var canUndo: Bool { last != nil && !busy }
    var remaining: Int { max(0, queue.count - index) }

    private init() {}

    func startIfNeeded() {
        if case .idle = phase { start() }
    }

    /// Opening Practice after a finished (or failed) session deals a fresh one: more may be due.
    func refreshIfFinished() {
        switch phase {
        case .done, .failed: start()
        default: break
        }
    }

    func start() {
        guard let token = AuthManager.shared.accessToken else { return }
        phase = .loading
        notice = nil
        Task {
            do {
                let items = try await PluckkAPI.shared.reviewSession(token: token)
                queue = items
                index = 0
                reviewedCount = 0
                revealed = false
                last = nil
                shownAt = Date()
                phase = items.isEmpty ? .done : .reviewing
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func reveal() {
        guard current != nil, !revealed else { return }
        withAnimation(.easeOut(duration: 0.15)) { revealed = true }
    }

    func rate(_ rating: ReviewRating) {
        guard let item = current, revealed, !busy, let token = AuthManager.shared.accessToken else { return }
        busy = true
        notice = nil
        let elapsed = Int(Date().timeIntervalSince(shownAt) * 1000)
        Task {
            defer { busy = false }
            do {
                let result = try await PluckkAPI.shared.submitReview(token: token, item: item, rating: rating, responseMs: elapsed)
                last = (result.event_id, item, index, rating == .again)
                reviewedCount += 1
                if rating == .again {
                    var requeued = item
                    requeued.previews = result.previews
                    requeued.is_new = false
                    queue.remove(at: index)
                    queue.append(requeued)
                } else {
                    index += 1
                }
                advance()
            } catch {
                notice = "Couldn't save that rating: \(error.localizedDescription)"
            }
        }
    }

    func undo() {
        guard let last, !busy, let token = AuthManager.shared.accessToken else { return }
        busy = true
        notice = nil
        Task {
            defer { busy = false }
            do {
                let restored = try await PluckkAPI.shared.undoReview(token: token, eventId: last.eventId) ?? last.item
                // An "again" moved the item to the end; undo is only offered for the latest
                // rating, so that copy is still the last one.
                if last.wasAgain, !queue.isEmpty { queue.removeLast() }
                let at = min(last.index, queue.count)
                queue.insert(restored, at: at)
                index = at
                reviewedCount = max(0, reviewedCount - 1)
                self.last = nil
                phase = .reviewing
                revealed = false
                shownAt = Date()
            } catch {
                notice = "Couldn't undo: \(error.localizedDescription)"
            }
        }
    }

    private func advance() {
        revealed = false
        shownAt = Date()
        if index >= queue.count { phase = .done }
    }
}

// MARK: - View

struct PracticeView: View {
    @ObservedObject private var session = PracticeSession.shared
    @Environment(\.colorScheme) private var colorScheme
    /// The image shown full-panel after clicking it on the card.
    @State private var zoomed: URL?

    private var isDark: Bool { colorScheme == .dark }
    private var primaryText: Color { isDark ? PluckkTheme.Dark.textPrimary : PluckkTheme.Light.textPrimary }
    private var answerText: Color { isDark ? PluckkTheme.Dark.answerText : PluckkTheme.Light.answerText }
    private var mutedText: Color { isDark ? PluckkTheme.Dark.textTertiary : PluckkTheme.Light.textTertiary }
    private var rule: Color { isDark ? PluckkTheme.Dark.cardBorder : PluckkTheme.Light.cardBorder }
    private var cardSurface: Color { isDark ? PluckkTheme.Dark.card : PluckkTheme.Light.card }

    var body: some View {
        Group {
            switch session.phase {
            case .idle, .loading:
                centered { ProgressView().controlSize(.small) }
            case .failed(let message):
                centered {
                    VStack(spacing: 12) {
                        Text("Couldn't start a session").font(.system(size: 15, weight: .semibold)).foregroundColor(primaryText)
                        Text(message).font(.system(size: 13)).foregroundColor(mutedText).multilineTextAlignment(.center)
                        Button("Try again") { session.start() }.buttonStyle(PillButtonStyle(prominent: true))
                    }
                    .padding(24)
                }
            case .done:
                doneState
            case .reviewing:
                if let item = session.current { reviewing(item) }
            }
        }
        .overlay { if let zoomed { lightbox(zoomed) } }
        .onAppear { session.startIfNeeded() }
        .onChange(of: session.current?.id) { _ in zoomed = nil }
    }

    private func lightbox(_ url: URL) -> some View {
        ZStack {
            Color.black.opacity(0.92)
            AsyncImage(url: url) { image in
                image.resizable().aspectRatio(contentMode: .fit)
            } placeholder: {
                ProgressView().controlSize(.small)
            }
            .padding(12)
            Button("") { zoomed = nil }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
        }
        .contentShape(Rectangle())
        .onTapGesture { zoomed = nil }
        .help("Click or press Esc to close")
        .transition(.opacity)
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack { Spacer(); content(); Spacer() }.frame(maxWidth: .infinity)
    }

    // MARK: Reviewing

    private func reviewing(_ item: ReviewItem) -> some View {
        VStack(spacing: 14) {
            header(item)

            // A card with an image fills the height so the image can use every spare point
            // (and grows with the panel); text-only cards scroll if they run long.
            if item.image_url != nil {
                card(item)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 4)
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    card(item)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 4)
                }
                .scrollIndicators(.hidden)
            }

            if let notice = session.notice {
                Text(notice).font(.system(size: 12)).foregroundColor(PluckkTheme.Dark.error)
                    .padding(.horizontal, 20)
            }

            footer(item)
                .padding(.horizontal, 20)
                .padding(.bottom, 18)
        }
        .padding(.top, 10)
    }

    private func header(_ item: ReviewItem) -> some View {
        HStack(spacing: 8) {
            if let deck = item.folder?.name {
                Text(deck.uppercased())
                    .font(.system(size: 10, weight: .semibold)).tracking(0.6)
                    .foregroundColor(PluckkTheme.accent)
            }
            if item.is_new {
                Text("NEW")
                    .font(.system(size: 10, weight: .semibold)).tracking(0.6)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(PluckkTheme.bidirectionalAccent.opacity(0.14))
                    .foregroundColor(PluckkTheme.bidirectionalAccent)
                    .cornerRadius(4)
            }
            Spacer()
            Button(action: { session.undo() }) {
                Image(systemName: "arrow.uturn.backward").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundColor(mutedText)
            .opacity(session.canUndo ? 1 : 0)
            .disabled(!session.canUndo)
            .keyboardShortcut("z", modifiers: [])
            .help("Undo last rating (Z)")

            Text("\(session.remaining) left")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundColor(mutedText)
        }
        .padding(.horizontal, 22)
    }

    private func card(_ item: ReviewItem) -> some View {
        VStack(spacing: 16) {
            Text(item.question)
                .font(.system(size: fittedSize(item.question), weight: .semibold))
                .foregroundColor(primaryText)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            if !session.revealed, let url = item.image_url.flatMap(URL.init(string:)) {
                cardImage(url)
            }

            if session.revealed {
                Rectangle().fill(rule).frame(height: 1)
                Text(item.answer)
                    .font(.system(size: fittedSize(item.answer) - 1))
                    .foregroundColor(answerText)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
                if let url = item.image_url.flatMap(URL.init(string:)) {
                    cardImage(url)
                }
                if let source = item.source_url, let url = URL(string: source), url.scheme?.hasPrefix("http") == true {
                    Button(action: { NSWorkspace.shared.open(url) }) {
                        Text("Source · \(url.host ?? source)")
                            .font(.system(size: 11))
                            .foregroundColor(mutedText)
                            .underline()
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity, minHeight: 160, maxHeight: item.image_url != nil ? .infinity : nil)
        .background(cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(rule.opacity(0.7), lineWidth: 1))
        .shadow(color: Color.black.opacity(isDark ? 0.55 : 0.10), radius: 12, y: 4)
        .contentShape(Rectangle())
        .onTapGesture { session.reveal() }
        .id(item.id)
    }

    /// Takes whatever room the text leaves (never less than 120pt); click to see it full-panel.
    private func cardImage(_ url: URL) -> some View {
        AsyncImage(url: url) { image in
            image.resizable().aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } placeholder: {
            ProgressView().controlSize(.small)
        }
        .frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { zoomed = url } }
        .onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .help("Click to enlarge")
    }

    @ViewBuilder
    private func footer(_ item: ReviewItem) -> some View {
        if session.revealed {
            HStack(spacing: 8) {
                ForEach(ReviewRating.allCases, id: \.self) { rating in
                    RatingButton(rating: rating, interval: item.previews.label(for: rating)) { session.rate(rating) }
                        .disabled(session.busy)
                        .keyboardShortcut(KeyEquivalent(rating.key), modifiers: [])
                }
            }
        } else {
            Button(action: { session.reveal() }) {
                HStack(spacing: 8) {
                    Text("Show answer")
                    Text("Space").font(.system(size: 11, weight: .medium)).opacity(0.6)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PillButtonStyle(prominent: true))
            .keyboardShortcut(.space, modifiers: [])
        }
    }

    // MARK: Done

    private var doneState: some View {
        centered {
            VStack(spacing: 14) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 30, weight: .light))
                    .foregroundColor(PluckkTheme.accent)
                Text(session.reviewedCount > 0 ? "Session done" : "Nothing due right now")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(primaryText)
                if session.reviewedCount > 0 {
                    Text("\(session.reviewedCount) review\(session.reviewedCount == 1 ? "" : "s")")
                        .font(.system(size: 13))
                        .foregroundColor(mutedText)
                }
                HStack(spacing: 10) {
                    if session.canUndo {
                        Button("Undo last") { session.undo() }.buttonStyle(PillButtonStyle(prominent: false))
                    }
                    Button("Start another") { session.start() }.buttonStyle(PillButtonStyle(prominent: true))
                }
                .padding(.top, 4)
                Button(action: {
                    if let url = URL(string: Config.webappURL) { NSWorkspace.shared.open(url) }
                }) {
                    Text("Open Pluckk in the browser ↗").font(.system(size: 12)).foregroundColor(mutedText)
                }
                .buttonStyle(.plain)
            }
            .padding(24)
        }
    }

    /// Type that fits its content: short prompts large, long ones step down (as in the web app).
    private func fittedSize(_ text: String) -> CGFloat {
        let n = text.trimmingCharacters(in: .whitespacesAndNewlines).count
        if n <= 60 { return 22 }
        if n <= 140 { return 19 }
        if n <= 320 { return 16 }
        return 14
    }
}

/// One of the four rating buttons: the rating, the interval it would set, and its key.
struct RatingButton: View {
    let rating: ReviewRating
    let interval: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    private var tint: Color {
        switch rating {
        case .again: return Color(hex: "e5534b")
        case .hard: return Color(hex: "d4a72c")
        case .good: return Color(hex: "3fb950")
        case .easy: return PluckkTheme.bidirectionalAccent
        }
    }

    var body: some View {
        let isDark = colorScheme == .dark
        Button(action: action) {
            VStack(spacing: 3) {
                Text(rating.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(isDark ? PluckkTheme.Dark.textPrimary : PluckkTheme.Light.textPrimary)
                Text("\(interval) · \(String(rating.key))")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(tint)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isDark ? PluckkTheme.Dark.card : PluckkTheme.Light.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(hovering ? tint.opacity(0.8) : (isDark ? PluckkTheme.Dark.cardBorder : PluckkTheme.Light.cardBorder),
                            lineWidth: 1)
            )
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
