import SwiftUI
import AppKit

/// Write a card by hand: question, answer, a deck, and optionally one image (a pasted screenshot
/// or a dropped file) shown on the question or the answer side. No AI involved. Light inline
/// formatting (**bold**, *italic*, `code`) is rendered in Practice.
struct NewCardView: View {
    @State private var question = ""
    @State private var answer = ""
    @State private var decks: [DeckSummary] = []
    @AppStorage("newCardDeckId") private var deckId = ""      // "" = unfiled
    @State private var image: NSImage?
    @State private var imageOnQuestion = false
    @State private var saving = false
    @State private var notice: String?
    @State private var savedFlash = false
    @FocusState private var focus: Field?
    @Environment(\.colorScheme) private var colorScheme

    private enum Field { case question, answer }

    private var isDark: Bool { colorScheme == .dark }
    private var canSave: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !saving
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("New card").font(.system(size: 16, weight: .semibold))
                    Spacer()
                    deckPicker
                }

                field("Question", text: $question, focused: .question, weight: .semibold)
                field("Answer", text: $answer, focused: .answer, weight: .regular)

                Text("**bold**   *italic*   `code`")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)

                imageSection

                if let notice {
                    Text(notice).font(.system(size: 12)).foregroundColor(.red)
                }

                HStack(spacing: 10) {
                    if savedFlash {
                        Label("Card added", systemImage: "checkmark")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(PluckkTheme.Dark.success)
                            .transition(.opacity)
                    }
                    Spacer()
                    Button("Clear") { reset(keepDeck: true) }
                        .buttonStyle(PillButtonStyle(prominent: false))
                    Button(action: save) {
                        HStack(spacing: 6) {
                            if saving { ProgressView().controlSize(.small) }
                            Text("Add card")
                            Text("⌘↩").font(.system(size: 11, weight: .medium)).opacity(0.6)
                        }
                    }
                    .buttonStyle(PillButtonStyle(prominent: true))
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canSave)
                }
            }
            .padding(20)
        }
        .scrollIndicators(.hidden)
        .onAppear {
            focus = .question
            loadDecks()
        }
    }

    // MARK: Fields

    private func field(_ label: String, text: Binding<String>, focused: Field, weight: Font.Weight) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold)).tracking(0.6)
                .foregroundColor(.secondary)
            TextField(label, text: text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: weight))
                .lineLimit(2...12)
                .focused($focus, equals: focused)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isDark ? PluckkTheme.Dark.card : PluckkTheme.Light.card))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isDark ? PluckkTheme.Dark.cardBorder : PluckkTheme.Light.cardBorder, lineWidth: 1))
        }
    }

    private var deckPicker: some View {
        Picker("Deck", selection: $deckId) {
            Text("Unfiled").tag("")
            ForEach(decks.filter { $0.folder_id != nil }) { deck in
                Text(deck.title).tag(deck.folder_id ?? "")
            }
        }
        .labelsHidden()
        .fixedSize()
        .help("Deck for new cards (remembered)")
    }

    // MARK: Image

    @ViewBuilder
    private var imageSection: some View {
        if let image {
            VStack(alignment: .leading, spacing: 8) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                HStack {
                    Picker("Show image with", selection: $imageOnQuestion) {
                        Text("Answer").tag(false)
                        Text("Question").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    Spacer()
                    Button("Remove") { self.image = nil }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundColor(.secondary)
                }
                Text(imageOnQuestion ? "Shown with the question, before you reveal." : "Shown with the answer, after you reveal.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
        } else {
            HStack(spacing: 10) {
                Button(action: pasteImage) {
                    HStack(spacing: 6) {
                        Image(systemName: "photo.on.rectangle")
                        Text("Paste screenshot")
                    }
                }
                .buttonStyle(QuietButtonStyle())
                Text("or drop an image here")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .foregroundColor(.secondary.opacity(0.4)))
            .onDrop(of: [.image, .fileURL], isTargeted: nil, perform: drop)
        }
    }

    private func pasteImage() {
        notice = nil
        if let img = SelectionReader().getClipboardImage() {
            image = img
        } else {
            notice = "No image on the clipboard. Take a screenshot with ⌃⇧⌘4 (to clipboard), then paste."
        }
    }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.canLoadObject(ofClass: NSImage.self) {
            _ = provider.loadObject(ofClass: NSImage.self) { obj, _ in
                if let img = obj as? NSImage { DispatchQueue.main.async { image = img } }
            }
            return true
        }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            if let url, let img = NSImage(contentsOf: url) { DispatchQueue.main.async { image = img } }
        }
        return true
    }

    /// JPEG, longest side ≤ 1600px: keeps the upload well under the API's request size limit.
    private func jpegData(_ img: NSImage) -> Data? {
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = min(1, 1600 / CGFloat(max(cg.width, cg.height)))
        let w = Int(CGFloat(cg.width) * scale), h = Int(CGFloat(cg.height) * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    // MARK: Save

    private func save() {
        guard canSave, let token = AuthManager.shared.accessToken else { return }
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let a = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = deckId.isEmpty ? nil : deckId
        let tags = (image != nil && imageOnQuestion) ? [ImageSide.questionTag] : []
        let imageData = image.flatMap(jpegData)
        saving = true
        notice = nil
        Task {
            defer { saving = false }
            do {
                let id = try await PluckkAPI.shared.createManualCard(token: token, question: q, answer: a, folderId: folder, tags: tags)
                if let imageData {
                    do {
                        try await PluckkAPI.shared.uploadCardImage(token: token, cardId: id, imageData: imageData, mimeType: "image/jpeg")
                    } catch {
                        notice = "Card added, but the image didn't upload: \(error.localizedDescription)"
                    }
                }
                reset(keepDeck: true)
                withAnimation { savedFlash = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withAnimation { savedFlash = false } }
            } catch {
                notice = "Couldn't add the card: \(error.localizedDescription)"
            }
        }
    }

    private func reset(keepDeck: Bool) {
        question = ""
        answer = ""
        image = nil
        imageOnQuestion = false
        if !keepDeck { deckId = "" }
        focus = .question
    }

    private func loadDecks() {
        guard let token = AuthManager.shared.accessToken else { return }
        Task {
            decks = (try? await PluckkAPI.shared.reviewDecks(token: token)) ?? []
            // A remembered deck that no longer exists falls back to unfiled.
            if !deckId.isEmpty && !decks.contains(where: { $0.folder_id == deckId }) { deckId = "" }
        }
    }
}

/// Inline markdown (**bold**, *italic*, `code`) for card text; anything else shows as typed.
func cardMarkdown(_ s: String) -> AttributedString {
    (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
}
