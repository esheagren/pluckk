import SwiftUI

/// How new cards reach you: one daily total, shared out around a ring. Each deck sits beside its
/// slice, and the handles between slices drag cards from one deck to its neighbour, keeping the
/// total. Limits save as they change. More statistics over time can sit alongside this.
struct StatisticsView: View {
    @State private var decks: [DeckSummary] = []
    @State private var limits: [String: Int] = [:]      // by deck id
    @State private var dirty: Set<String> = []
    @State private var saveTask: Task<Void, Never>?
    @State private var notice: String?
    /// Where the first slice starts, as a fraction of the ring (the handle there moves too).
    @State private var origin = 0.0
    @State private var drag: HandleDrag?
    @State private var hoveredHandle: Int?

    private static let palette = ["c8a96e", "5b9bd5", "3fb950", "a371f7", "e5534b", "39c5cf", "e5a14b", "db61a2"]
    private static let ringWidth: CGFloat = 22
    private static let labelHeight: CGFloat = 58

    /// A handle being dragged. It's tracked as movement since the last event, so the pointer
    /// crossing the far side of the ring can't make the slices jump.
    private struct HandleDrag {
        let index: Int
        let before: Int         // the deck's limit at the start, either side of the handle
        let after: Int
        let origin: Double
        var lastFraction: Double
        var moved = 0.0
    }

    /// Decks with new cards to give. Paused decks are left out of the mix, so out of the share too.
    private var active: [DeckSummary] { decks.filter { !$0.is_paused && $0.new > 0 } }
    private var total: Int { active.reduce(0) { $0 + limit($1) } }

    private func limit(_ deck: DeckSummary) -> Int { limits[deck.id] ?? 0 }
    private func color(_ deck: DeckSummary) -> Color {
        let index = active.firstIndex(of: deck) ?? 0
        return Color(hex: Self.palette[index % Self.palette.count])
    }

    var body: some View {
        GeometryReader { outer in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text("I'll take on")
                        TextField("", value: Binding(get: { total }, set: setTotal), format: .number)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.center)
                            .frame(width: 54)
                        Text("new cards a day")
                        Spacer()
                        if decks.contains(where: \.is_paused) {
                            Text("Paused decks aren't shown").font(.caption).foregroundColor(.secondary)
                        }
                    }
                    .font(.system(size: 13))

                    GeometryReader { geo in ringWithDecks(in: geo.size) }
                        .frame(height: max(440, outer.size.height - 110))

                    Text(notice ?? "Drag a handle on the ring to move cards between neighbouring decks, or type a number.")
                        .font(.system(size: 11))
                        .foregroundColor(notice == nil ? .secondary : PluckkTheme.Dark.error)
                        .frame(maxWidth: .infinity)
                }
                .padding(20)
            }
            .scrollIndicators(.hidden)
        }
        .task { await load() }
    }

    // MARK: The ring

    private struct Slice {
        let deck: DeckSummary
        let start: Double
        let end: Double
        var middle: Double { (start + end) / 2 }
    }

    private var slices: [Slice] {
        guard !active.isEmpty else { return [] }
        var position = origin
        return active.map { deck in
            let share = total > 0 ? Double(limit(deck)) / Double(total) : 1 / Double(active.count)
            defer { position += share }
            return Slice(deck: deck, start: position, end: position + share)
        }
    }

    private func point(_ fraction: Double, _ radius: CGFloat, around center: CGPoint) -> CGPoint {
        let angle = (fraction - 0.25) * 2 * .pi
        return CGPoint(x: center.x + radius * CGFloat(cos(angle)), y: center.y + radius * CGFloat(sin(angle)))
    }

    private func ringWithDecks(in size: CGSize) -> some View {
        let labelWidth = max(96, min(200, size.width * 0.24))
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = max(70, min((size.width - 2 * (labelWidth + 44)) / 2, (size.height - 40) / 2, 170))
        let current = slices
        let placed = placeLabels(current, center: center, radius: radius, height: size.height)

        return ZStack {
            // Leaders first, so the ring and labels sit over them.
            ForEach(placed, id: \.slice.deck.id) { label in
                Path { path in
                    path.move(to: point(label.slice.middle, radius + Self.ringWidth / 2 + 3, around: center))
                    path.addLine(to: CGPoint(x: center.x + (label.onRight ? 1 : -1) * (radius + 36), y: label.y))
                }
                .stroke(color(label.slice.deck).opacity(0.45), lineWidth: 1)
            }
            ForEach(current, id: \.deck.id) { slice in
                RingArc(start: slice.start, end: slice.end)
                    .stroke(color(slice.deck), lineWidth: Self.ringWidth)
                    .frame(width: radius * 2, height: radius * 2)
                    .position(center)
            }
            VStack(spacing: 0) {
                Text("\(total)").font(.system(size: 34, weight: .semibold).monospacedDigit())
                Text("new a day").font(.system(size: 11)).foregroundColor(.secondary)
            }
            .position(center)
            ForEach(placed, id: \.slice.deck.id) { label in
                deckLabel(label.slice, onRight: label.onRight)
                    .frame(width: labelWidth, height: Self.labelHeight, alignment: label.onRight ? .leading : .trailing)
                    .position(x: center.x + (label.onRight ? 1 : -1) * (radius + 42 + labelWidth / 2), y: label.y)
                    .animation(.easeOut(duration: 0.15), value: label.y)
            }
            if current.count > 1 && total > 0 {
                ForEach(current.indices, id: \.self) { index in
                    handle(index, slices: current, radius: radius, center: center)
                }
            }
        }
        .coordinateSpace(name: "ring")
    }

    private struct PlacedLabel {
        let slice: Slice
        let onRight: Bool
        let y: CGFloat
    }

    /// Each label beside its slice, then nudged apart down each side so small slices stay readable.
    private func placeLabels(_ slices: [Slice], center: CGPoint, radius: CGFloat, height: CGFloat) -> [PlacedLabel] {
        var placed: [PlacedLabel] = []
        for side in [true, false] {
            let members = slices
                .map { (slice: $0, y: point($0.middle, radius + 20, around: center).y, x: point($0.middle, 1, around: center).x) }
                .filter { ($0.x >= center.x) == side }
                .sorted { $0.y < $1.y }
            var ys = members.map(\.y)
            let gap = Self.labelHeight + 4
            for i in ys.indices { ys[i] = max(ys[i], i == 0 ? Self.labelHeight / 2 : ys[i - 1] + gap) }
            for i in ys.indices.reversed() {
                ys[i] = min(ys[i], i == ys.count - 1 ? height - Self.labelHeight / 2 : ys[i + 1] - gap)
            }
            for (member, y) in zip(members, ys) { placed.append(PlacedLabel(slice: member.slice, onRight: side, y: y)) }
        }
        return placed
    }

    private func deckLabel(_ slice: Slice, onRight: Bool) -> some View {
        let deck = slice.deck
        let edge: HorizontalAlignment = onRight ? .leading : .trailing
        let share = total > 0 ? Int((Double(limit(deck)) / Double(total) * 100).rounded()) : 0
        return VStack(alignment: edge, spacing: 2) {
            Text(deck.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(color(deck))
                .lineLimit(1)
            HStack(spacing: 3) {
                TextField("", value: Binding(get: { limit(deck) }, set: { setLimit(deck, $0) }), format: .number)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .multilineTextAlignment(onRight ? .leading : .trailing)
                    .fixedSize()
                Text("a day · \(share)%")
            }
            .font(.system(size: 12).monospacedDigit())
            Text("\(deck.new.formatted()) left · \(finishEstimate(deck))")
                .font(.system(size: 11).monospacedDigit())
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }

    private func handle(_ index: Int, slices: [Slice], radius: CGFloat, center: CGPoint) -> some View {
        let active = drag?.index == index || hoveredHandle == index
        return Circle()
            .fill(Color.white)
            .frame(width: active ? 16 : 11, height: active ? 16 : 11)
            .shadow(color: .black.opacity(0.5), radius: 2)
            .frame(width: 30, height: 30)
            .contentShape(Circle())
            .onHover { inside in
                hoveredHandle = inside ? index : (hoveredHandle == index ? nil : hoveredHandle)
                if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("ring"))
                    .onChanged { dragHandle(index, value: $0, slices: slices, center: center) }
                    .onEnded { _ in drag = nil }
            )
            .animation(.easeOut(duration: 0.1), value: active)
            .position(point(slices[index].start, radius, around: center))   // last: it fills the ring
    }

    private func dragHandle(_ index: Int, value: DragGesture.Value, slices: [Slice], center: CGPoint) {
        let before = slices[(index + slices.count - 1) % slices.count].deck
        let after = slices[index].deck
        let fraction = { (p: CGPoint) in Double(atan2(p.y - center.y, p.x - center.x)) / (2 * .pi) + 0.25 }
        var current = drag ?? HandleDrag(index: index, before: limit(before), after: limit(after), origin: origin,
                                         lastFraction: fraction(value.startLocation))
        let here = fraction(value.location)
        var step = (here - current.lastFraction).truncatingRemainder(dividingBy: 1)
        if step > 0.5 { step -= 1 } else if step < -0.5 { step += 1 }
        current.moved += step
        current.lastFraction = here
        drag = current

        let pair = current.before + current.after
        let moved = Int((current.moved * Double(total)).rounded())
        let next = min(max(current.before + moved, max(0, pair - 500)), min(pair, 500))
        let shift = Double(next - current.before) / Double(max(total, 1))
        setLimit(before, next)
        setLimit(after, pair - next)
        if index == 0 { origin = current.origin + shift }
    }

    /// At this deck's limit, how long until its new cards run out.
    private func finishEstimate(_ deck: DeckSummary) -> String {
        guard limit(deck) > 0 else { return "not coming in" }
        let days = Int((Double(deck.new) / Double(limit(deck))).rounded(.up))
        if days == 1 { return "done in a day" }
        if days < 14 { return "\(days) days" }
        if days < 60 { return "\(Int((Double(days) / 7).rounded())) weeks" }
        if days < 730 { return "\(Int((Double(days) / 30).rounded())) months" }
        return String(format: "%.1f years", Double(days) / 365)
    }

    // MARK: Changing limits

    private func setLimit(_ deck: DeckSummary, _ value: Int) {
        limits[deck.id] = min(max(value, 0), 500)
        dirty.insert(deck.id)
        scheduleSave()
    }

    /// A new total keeps the decks' proportions; rounding is settled on the largest deck.
    private func setTotal(_ value: Int) {
        let target = min(max(value, 0), 2000)
        guard !active.isEmpty, target != total else { return }
        let current = total
        var scaled: [String: Int] = [:]
        for deck in active {
            let share = current > 0 ? Double(limit(deck)) / Double(current) : 1 / Double(active.count)
            scaled[deck.id] = Int((share * Double(target)).rounded())
        }
        if let largest = active.max(by: { (scaled[$0.id] ?? 0) < (scaled[$1.id] ?? 0) }) {
            scaled[largest.id] = max(0, (scaled[largest.id] ?? 0) + target - scaled.values.reduce(0, +))
        }
        for deck in active { setLimit(deck, scaled[deck.id] ?? 0) }
    }

    /// After a short pause, so clicking through the arrows saves once.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let token = AuthManager.shared.accessToken else { return }
            let changed = decks.filter { dirty.contains($0.id) }
            dirty = []
            do {
                try await save(changed, token: token)
                notice = nil
                PracticeSession.shared.refreshTodayCounts()
            } catch {
                notice = "Couldn't save that: \(error.localizedDescription)"
            }
        }
    }

    private func save(_ changed: [DeckSummary], token: String) async throws {
        // Unfiled cards use the account default, which decks without their own limit share, so
        // those decks keep their limit first.
        if changed.contains(where: { $0.folder_id == nil }) {
            for deck in decks where deck.folder_id != nil && deck.new_per_day == nil && !changed.contains(deck) {
                try await PluckkAPI.shared.setDeckNewPerDay(token: token, folderId: deck.folder_id!, value: limit(deck))
            }
        }
        for deck in changed {
            if let folder = deck.folder_id {
                try await PluckkAPI.shared.setDeckNewPerDay(token: token, folderId: folder, value: limit(deck))
            } else {
                try await PluckkAPI.shared.setDefaultNewPerDay(token: token, value: limit(deck))
            }
        }
    }

    private func load() async {
        guard let token = AuthManager.shared.accessToken else { return }
        do {
            async let summaries = PluckkAPI.shared.reviewDecks(token: token)
            async let fallback = PluckkAPI.shared.defaultNewPerDay(token: token)
            let (loaded, standard) = try await (summaries, fallback)
            decks = loaded
            limits = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0.new_per_day ?? standard) })
        } catch {
            notice = "Couldn't load your decks: \(error.localizedDescription)"
        }
    }
}

/// One slice, a little short at each end so neighbours read as separate.
private struct RingArc: Shape {
    let start: Double
    let end: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let gap = min(0.003, (end - start) / 4)
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: min(rect.width, rect.height) / 2,
                    startAngle: .degrees((start + gap) * 360 - 90), endAngle: .degrees((end - gap) * 360 - 90), clockwise: false)
        return path
    }
}
