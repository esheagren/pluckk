import SwiftUI
import AppKit
import UserNotifications

struct CardGenerationView: View {
    @ObservedObject private var appState = AppState.shared
    @State private var editingCardIndex: Int?
    @State private var showFocusInput = false
    @State private var focusText = ""

    var body: some View {
        VStack(spacing: 0) {
            if appState.capturedContent == nil {
                emptyState
            } else if appState.isGenerating {
                loadingState
            } else if !appState.generatedCards.isEmpty {
                cardSelectionView
            } else if let error = appState.generationError {
                errorState(error)
            } else {
                // Content captured but not yet generating
                capturedContentPreview
            }
        }
        .onAppear {
            if appState.capturedContent != nil && appState.generatedCards.isEmpty && !appState.isGenerating {
                generateCards()
            }
        }
        .onChange(of: appState.capturedContent) { newContent in
            // When new content is captured (e.g., user double-tapped ⌘ with new selection),
            // clear existing cards and generate new ones
            guard newContent != nil else { return }
            appState.generatedCards = []
            appState.selectedCardIndices = []
            appState.generationError = nil
            appState.isGenerating = false  // Cancel any in-progress generation
            generateCards()
        }
    }

    // MARK: - Empty State (matches extension no-selection-state)

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()

            // Logo icon - using the actual PNG from extension
            if let logoImage = NSImage(named: "icon-128") {
                Image(nsImage: logoImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 64, height: 64)
                    .opacity(0.8)
            } else {
                // Fallback to PluckkLogo if PNG not found
                PluckkLogo(size: 64)
                    .opacity(0.8)
            }

            // Hint text matching extension
            Text("Select text or paste screenshot")
                .font(.system(size: PluckkTheme.FontSize.small))
                .foregroundColor(colorScheme == .dark
                    ? PluckkTheme.Dark.textSecondary
                    : PluckkTheme.Light.textSecondary)

            // Question input placeholder (matches extension's "..." input)
            TextField("...", text: .constant(""))
                .textFieldStyle(.plain)
                .font(.system(size: PluckkTheme.FontSize.body))
                .foregroundColor(colorScheme == .dark
                    ? PluckkTheme.Dark.textSecondary
                    : PluckkTheme.Light.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 200)
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(
                    RoundedRectangle(cornerRadius: PluckkTheme.Radius.medium)
                        .stroke(colorScheme == .dark
                            ? PluckkTheme.Dark.border
                            : PluckkTheme.Light.border, lineWidth: 1)
                )
                .disabled(true)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    @Environment(\.colorScheme) var colorScheme

    // MARK: - Loading State

    private var loadingState: some View {
        VStack(spacing: 16) {
            Spacer()

            ProgressView()
                .scaleEffect(1.2)

            Text("Generating cards...")
                .font(.subheadline)
                .foregroundColor(.secondary)

            // Show preview of captured content
            if let content = appState.capturedContent {
                contentPreviewSmall(content)
                    .padding(.top, 8)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    // MARK: - Error State

    private func errorState(_ error: String) -> some View {
        let _ = print("CardGenerationView: Displaying errorState: \(error)")
        return VStack(spacing: 16) {
            Spacer()

            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundColor(.orange)

            Text(error)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button("Try Again") {
                generateCards()
            }
            .buttonStyle(.borderedProminent)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    // MARK: - Content Preview

    private var capturedContentPreview: some View {
        VStack(spacing: 16) {
            if let content = appState.capturedContent {
                contentPreviewSmall(content)
            }

            Button("Generate Cards") {
                generateCards()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    @ViewBuilder
    private func contentPreviewSmall(_ content: CapturedContent) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let context = appState.sourceContext {
                Text(context.displayString)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            switch content {
            case .text(let text):
                Text(text.prefix(200) + (text.count > 200 ? "..." : ""))
                    .font(.caption)
                    .foregroundColor(.primary.opacity(0.8))
                    .lineLimit(4)
            case .image(let image):
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 100)
                    .cornerRadius(6)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.05))
        .cornerRadius(8)
    }

    // MARK: - Card Selection

    private var cardSelectionView: some View {
        VStack(spacing: 0) {
            // Cards list
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(Array(appState.generatedCards.enumerated()), id: \.element.id) { index, card in
                        CardRowView(
                            card: card,
                            index: index,
                            isSelected: appState.selectedCardIndices.contains(index),
                            isEditing: editingCardIndex == index,
                            onToggle: { toggleCard(index) },
                            onEdit: { startEditing(index) },
                            onSaveEdit: { question, answer in saveEdit(index, question: question, answer: answer) },
                            onCancelEdit: { cancelEdit() }
                        )
                    }
                }
                .padding(16)
                .padding(.top, 24)  // Extra breathing room at top
            }

            Divider()

            // Bottom actions
            bottomActions
        }
        .onAppear {
            // Don't auto-select - user must choose which cards to keep
            appState.selectedCardIndices = []
        }
    }

    /// Total number of cards after expansion (bidirectional → 2, list → N)
    private var totalExpandedCardCount: Int {
        appState.selectedCardIndices.reduce(0) { count, index in
            guard index < appState.generatedCards.count else { return count }
            return count + appState.generatedCards[index].expandedCardCount
        }
    }

    private var bottomActions: some View {
        VStack(spacing: 12) {

            // Action buttons
            HStack {
                // Regenerate button with optional focus input
                if showFocusInput {
                    HStack(spacing: 8) {
                        TextField("Focus on...", text: $focusText)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                            .frame(maxWidth: 150)

                        Button(action: {
                            regenerateCardsWithFocus()
                        }) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)

                        Button(action: {
                            showFocusInput = false
                            focusText = ""
                        }) {
                            Image(systemName: "xmark")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                    }
                } else {
                    Button(action: {
                        showFocusInput = true
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                            Text("Regenerate")
                        }
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut("r", modifiers: [])
                }

                Spacer()

                // Store button with expanded card count
                Button(action: {
                    sendCards()
                }) {
                    HStack(spacing: 4) {
                        Text("Store")
                        if totalExpandedCardCount > 0 {
                            Text("(\(totalExpandedCardCount))")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(appState.selectedCardIndices.isEmpty)
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(16)
    }

    // MARK: - Actions

    private func generateCards(withFocus focus: String? = nil) {
        guard let token = AuthManager.shared.accessToken else { return }

        appState.isGenerating = true
        appState.generationError = nil
        appState.generatedCards = []

        Task {
            do {
                let result: [GeneratedCard]

                switch appState.capturedContent {
                case .text(let text):
                    let request = PluckkAPI.GenerateCardsRequest(
                        selection: text,
                        context: "",
                        url: appState.sourceContext?.displayString ?? "",
                        title: appState.sourceContext?.windowTitle ?? "",
                        focusText: focus
                    )
                    result = try await PluckkAPI.shared.generateCards(token: token, request: request)

                case .image(let image):
                    guard let tiffData = image.tiffRepresentation,
                          let bitmap = NSBitmapImageRep(data: tiffData),
                          let pngData = bitmap.representation(using: .png, properties: [:]) else {
                        throw APIError.serverError("Failed to convert image")
                    }
                    result = try await PluckkAPI.shared.generateCardsFromImage(
                        token: token,
                        imageData: pngData,
                        context: appState.sourceContext
                    )

                case .none:
                    return
                }

                await MainActor.run {
                    appState.generatedCards = result
                    appState.selectedCardIndices = []  // User must select which cards to keep
                    appState.isGenerating = false
                }

                // Fetch decks if we haven't yet
                if appState.decks.isEmpty {
                    let decks = try await PluckkAPI.shared.fetchDecks(token: token)
                    await MainActor.run {
                        appState.decks = decks
                    }
                }

            } catch {
                print("CardGenerationView: generateCards error: \(error.localizedDescription)")
                print("CardGenerationView: Full error: \(error)")
                await MainActor.run {
                    appState.generationError = error.localizedDescription
                    appState.isGenerating = false
                }
            }
        }
    }

    private func regenerateCards() {
        // Clear selection first to avoid index out of bounds
        appState.selectedCardIndices = []
        appState.generatedCards = []
        appState.generationError = nil
        generateCards()
    }

    private func regenerateCardsWithFocus() {
        // Clear selection first to avoid index out of bounds
        appState.selectedCardIndices = []
        appState.generatedCards = []
        appState.generationError = nil
        let focus = focusText.isEmpty ? nil : focusText
        generateCards(withFocus: focus)
        showFocusInput = false
        focusText = ""
    }

    private func toggleCard(_ index: Int) {
        if appState.selectedCardIndices.contains(index) {
            appState.selectedCardIndices.remove(index)
        } else {
            appState.selectedCardIndices.insert(index)
        }
    }

    private func startEditing(_ index: Int) {
        editingCardIndex = index
    }

    private func saveEdit(_ index: Int, question: String, answer: String) {
        appState.generatedCards[index].question = question
        appState.generatedCards[index].answer = answer
        editingCardIndex = nil
    }

    private func cancelEdit() {
        editingCardIndex = nil
    }

    /// The selected cards, in order, dropping any with no usable content. A bidirectional
    /// or list card is saved as ONE card; the server schedules its components (core-engine step 4).
    private func selectedCardsForSaving() -> [GeneratedCard] {
        appState.selectedCardIndices.sorted().compactMap { index -> GeneratedCard? in
            guard index < appState.generatedCards.count else { return nil }
            let card = appState.generatedCards[index]
            return card.expandedCardCount > 0 ? card : nil
        }
    }

    private func sendCards() {
        guard let token = AuthManager.shared.accessToken else {
            print("CardGenerationView: sendCards - No access token available!")
            return
        }

        let expandedCards = selectedCardsForSaving()
        guard !expandedCards.isEmpty else {
            print("CardGenerationView: sendCards - No cards to send!")
            appState.generationError = "Selected cards contain invalid data and cannot be saved"
            return
        }
        let selection: String? = { if case .text(let t) = appState.capturedContent { return t } ; return nil }()

        print("CardGenerationView: sendCards - Starting to send \(expandedCards.count) card(s)")
        print("CardGenerationView: sendCards - Source URL: \(appState.sourceContext?.displayString ?? "none")")
        print("CardGenerationView: sendCards - Deck ID: \(appState.selectedDeckId ?? "none")")

        Task {
            var successCount = 0
            var lastError: Error?

            for (index, card) in expandedCards.enumerated() {
                print("CardGenerationView: sendCards - Sending card \(index + 1)/\(expandedCards.count)")
                do {
                    let response = try await PluckkAPI.shared.sendCard(
                        token: token,
                        card: card,
                        sourceUrl: appState.sourceContext?.displayString ?? "",
                        sourceTitle: appState.sourceContext?.windowTitle,
                        appName: appState.sourceContext?.appName,
                        selection: selection,
                        deckId: appState.selectedDeckId
                    )
                    successCount += 1
                    print("CardGenerationView: sendCards - Card \(index + 1) sent successfully (cardId: \(response.cardId ?? "nil"))")
                } catch {
                    lastError = error
                    print("CardGenerationView: sendCards - Card \(index + 1) FAILED: \(error.localizedDescription)")
                    print("CardGenerationView: sendCards - Full error: \(error)")
                }
            }

            print("CardGenerationView: sendCards - Completed: \(successCount)/\(expandedCards.count) successful")

            await MainActor.run {
                if successCount > 0 {
                    print("CardGenerationView: sendCards - Showing success toast for \(successCount) cards")
                    showSuccessToast(count: successCount)
                    if successCount == expandedCards.count {
                        print("CardGenerationView: sendCards - All cards sent, collapsing panel")
                        collapsePanel()
                    }
                }

                // Show error if some cards failed
                let failedCount = expandedCards.count - successCount
                if failedCount > 0 {
                    let errorMsg = "Failed to save \(failedCount) card\(failedCount == 1 ? "" : "s"): \(lastError?.localizedDescription ?? "Unknown error")"
                    print("CardGenerationView: sendCards error: \(errorMsg)")
                    if let err = lastError {
                        print("CardGenerationView: sendCards full error: \(err)")
                    }
                    appState.generationError = errorMsg
                }
            }
        }
    }

    private func showSuccessToast(count: Int) {
        // Use UserNotifications framework
        let content = UNMutableNotificationContent()
        content.title = "Cards Saved"
        content.body = "\(count) card\(count == 1 ? "" : "s") added to Pluckk"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    /// A pinned card stays open on its desktop, ready for the next capture.
    private func collapsePanel() {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return }
        if appDelegate.panel.isPinned {
            appState.reset()
        } else {
            appDelegate.panel.collapse()
        }
    }
}

// MARK: - Card Row View

struct CardRowView: View {
    let card: GeneratedCard
    let index: Int
    let isSelected: Bool
    let isEditing: Bool
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onSaveEdit: (String, String) -> Void
    let onCancelEdit: () -> Void

    @State private var editQuestion: String = ""
    @State private var editAnswer: String = ""

    /// Left border accent color based on card type
    private var accentColor: Color {
        switch card.style {
        case .qa_bidirectional:
            return PluckkTheme.bidirectionalAccent
        case .cloze_list:
            return PluckkTheme.listAccent
        case .diagram:
            return PluckkTheme.diagramAccent
        default:
            return .clear
        }
    }

    /// Whether this card type shows a colored left border
    private var showsAccentBorder: Bool {
        switch card.style {
        case .qa_bidirectional, .cloze_list, .diagram:
            return true
        default:
            return false
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left accent border for special card types
            if showsAccentBorder {
                Rectangle()
                    .fill(accentColor)
                    .frame(width: 3)
            }

            VStack(alignment: .leading, spacing: 8) {
                // Header with checkbox and style badge
                cardHeader

                if isEditing {
                    editModeContent
                } else {
                    displayModeContent
                }
            }
            .padding(12)
        }
        .background(isSelected ? Color.accentColor.opacity(0.05) : Color.primary.opacity(0.03))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
        )
    }

    private var cardHeader: some View {
        HStack {
            Button(action: onToggle) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .accentColor : .secondary)
            }
            .buttonStyle(.plain)

            Text("[\(index + 1)]")
                .font(.caption)
                .foregroundColor(.secondary)

            // Style badge with appropriate color
            Text(card.style.displayName)
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(badgeBackgroundColor.opacity(0.1))
                .foregroundColor(badgeBackgroundColor)
                .cornerRadius(4)

            // Card count indicator for multi-card types
            if card.expandedCardCount > 1 {
                Text("→ \(card.expandedCardCount) cards")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if !isEditing {
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var badgeBackgroundColor: Color {
        switch card.style {
        case .qa_bidirectional:
            return PluckkTheme.bidirectionalAccent
        case .cloze_list:
            return PluckkTheme.listAccent
        case .diagram:
            return PluckkTheme.diagramAccent
        default:
            return .accentColor
        }
    }

    private var editModeContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Question", text: $editQuestion, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...6)

            TextField("Answer", text: $editAnswer, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...6)

            HStack {
                Button("Cancel") {
                    onCancelEdit()
                }
                .buttonStyle(.bordered)

                Button("Save") {
                    onSaveEdit(editQuestion, editAnswer)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .onAppear {
            editQuestion = card.question
            editAnswer = card.answer
        }
    }

    @ViewBuilder
    private var displayModeContent: some View {
        switch card.style {
        case .qa_bidirectional:
            bidirectionalContent
        case .cloze_list:
            listContent
        default:
            standardContent
        }
    }

    // MARK: - Standard Card Content (Q&A, Cloze, etc.)

    private var standardContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Q: \(card.question)")
                .font(.subheadline)
                .fontWeight(.medium)
                .lineLimit(3)

            Text("A: \(card.answer)")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineLimit(3)
        }
    }

    // MARK: - Bidirectional Card Content

    private var bidirectionalContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let forward = card.forward {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Forward:")
                        .font(.caption2)
                        .foregroundColor(PluckkTheme.bidirectionalAccent)
                        .fontWeight(.semibold)
                    Text("Q: \(forward.question)")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(2)
                    Text("A: \(forward.answer)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }

            if let reverse = card.reverse {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reverse:")
                        .font(.caption2)
                        .foregroundColor(PluckkTheme.bidirectionalAccent)
                        .fontWeight(.semibold)
                    Text("Q: \(reverse.question)")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(2)
                    Text("A: \(reverse.answer)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    // MARK: - List Card Content

    private var listContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            // List name
            if let listName = card.listName {
                Text(listName)
                    .font(.subheadline)
                    .fontWeight(.medium)
            }

            // Item chips
            if let items = card.items, !items.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(items, id: \.self) { item in
                        Text(item)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(PluckkTheme.listAccent.opacity(0.1))
                            .foregroundColor(PluckkTheme.listAccent)
                            .cornerRadius(12)
                    }
                }
            }

            // Note about testing
            Text("Each item tested individually + recall all")
                .font(.caption2)
                .foregroundColor(.secondary)
                .italic()
        }
    }
}

// MARK: - Flow Layout for Item Chips

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(in: proposal.width ?? 0, subviews: subviews, spacing: spacing)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.positions[index].x,
                                      y: bounds.minY + result.positions[index].y),
                         proposal: .unspecified)
        }
    }

    struct FlowResult {
        var positions: [CGPoint] = []
        var size: CGSize = .zero

        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var x: CGFloat = 0
            var y: CGFloat = 0
            var rowHeight: CGFloat = 0

            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                if x + size.width > maxWidth && x > 0 {
                    x = 0
                    y += rowHeight + spacing
                    rowHeight = 0
                }
                positions.append(CGPoint(x: x, y: y))
                rowHeight = max(rowHeight, size.height)
                x += size.width + spacing
                self.size.width = max(self.size.width, x)
            }
            self.size.height = y + rowHeight
        }
    }
}

#Preview {
    CardGenerationView()
        .frame(width: 320, height: 600)
}
