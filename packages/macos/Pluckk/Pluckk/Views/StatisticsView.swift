import SwiftUI
import Charts

/// How new cards reach you: one daily total, shared out around a ring. Each deck sits beside its
/// slice. The handles work like a slider with several thumbs laid round the ring: one grows the
/// deck on the side it's leaving and takes from the decks ahead of it, keeping the total. Limits
/// save as they change. More statistics over time can sit alongside this.
struct StatisticsView: View {
    @State private var decks: [DeckSummary] = []
    @State private var limits: [String: Int] = [:]      // by deck id
    @State private var dirty: Set<String> = []
    @State private var saveTask: Task<Void, Never>?
    @State private var notice: String?
    @State private var drag: HandleDrag?
    @State private var hoveredHandle: Int?
    @State private var calibration: PluckkAPI.Calibration?
    /// The split the total is being scaled from, kept while only the total changes.
    @State private var totalBase: [String: Int]?

    private static let palette = ["c8a96e", "5b9bd5", "3fb950", "a371f7", "e5534b", "39c5cf", "e5a14b", "db61a2"]
    private static let ringWidth: CGFloat = 22
    private static let labelHeight: CGFloat = 58
    /// The least of the ring a deck is drawn with, so one at 0 keeps a sliver and its own handle.
    private static let minimumShare = 0.02

    /// A handle being dragged. It's tracked as movement since the last event, so the pointer
    /// crossing the far side of the ring can't make the slices jump.
    private struct HandleDrag {
        let index: Int
        let start: [Int]        // every deck's limit when the drag began
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
                    GeometryReader { geo in ringWithDecks(in: geo.size) }
                        .frame(height: max(440, outer.size.height - 70))

                    if let calibration, calibration.reviews > 0 {
                        calibrationLine(calibration)
                    }

                    WorkloadForecastView()
                        .padding(.top, 18)

                    Text(notice ?? "Drag a handle round the ring to share cards out, or set a deck's number directly." + (decks.contains(where: \.is_paused) ? " Paused decks aren't shown." : ""))
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
        let shares = active.map { total > 0 ? Double(limit($0)) / Double(total) : 1 / Double(active.count) }
        let drawn = shares.map { max($0, Self.minimumShare) }
        let scale = drawn.reduce(0, +)
        var position = 0.0
        return zip(active, drawn).map { deck, share in
            defer { position += share / scale }
            return Slice(deck: deck, start: position, end: position + share / scale)
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
            ForEach(current, id: \.deck.id) { slice in
                RingArc(start: slice.start, end: slice.end)
                    .stroke(color(slice.deck), lineWidth: Self.ringWidth)
                    .frame(width: radius * 2, height: radius * 2)
                    .position(center)
            }
            VStack(spacing: 4) {
                Text("I'll take on")
                TextField("", value: Binding(get: { total }, set: setTotal), format: .number)
                    .textFieldStyle(.plain)
                    .font(.system(size: radius < 100 ? 24 : 34, weight: .semibold).monospacedDigit())
                    .multilineTextAlignment(.center)
                    .frame(width: radius < 100 ? 72 : 104)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.07)))
                Text("new cards a day")
            }
            .font(.system(size: 12))
            .foregroundColor(.secondary)
            .position(center)
            ForEach(placed, id: \.slice.deck.id) { label in
                deckLabel(label.slice, onRight: label.onRight, compact: labelWidth < 150)
                    .frame(width: labelWidth, height: Self.labelHeight, alignment: label.onRight ? .leading : .trailing)
                    .position(x: center.x + (label.onRight ? 1 : -1) * (radius + 34 + labelWidth / 2), y: label.y)
                    .animation(.easeOut(duration: 0.15), value: label.y)
            }
            if current.count > 1 && total > 0 {
                ForEach(current.indices.dropLast(), id: \.self) { index in
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

    private func deckLabel(_ slice: Slice, onRight: Bool, compact: Bool) -> some View {
        let deck = slice.deck
        let edge: HorizontalAlignment = onRight ? .leading : .trailing
        let share = total > 0 ? Int((Double(limit(deck)) / Double(total) * 100).rounded()) : 0
        return VStack(alignment: edge, spacing: 2) {
            Text(deck.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(color(deck))
                .lineLimit(1)
            HStack(spacing: 4) {
                stepButton("minus") { setLimit(deck, limit(deck) - 1) }
                TextField("", text: Binding(get: { String(limit(deck)) }, set: { setLimit(deck, Int($0) ?? 0) }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .multilineTextAlignment(.center)
                    .frame(width: 34, height: 20)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
                stepButton("plus") { setLimit(deck, limit(deck) + 1) }
                Text(compact ? "\(share)%" : "a day · \(share)%").lineLimit(1)
            }
            .font(.system(size: 12).monospacedDigit())
            Text("\(deck.new.formatted()) left · \(finishEstimate(deck))")
                .font(.system(size: 11).monospacedDigit())
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }

    private func stepButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.secondary)
                .frame(width: 18, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func handle(_ index: Int, slices: [Slice], radius: CGFloat, center: CGPoint) -> some View {
        let active = drag?.index == index || hoveredHandle == index
        return Circle()
            .fill(Color.white)
            .frame(width: active ? 16 : 11, height: active ? 16 : 11)
            .shadow(color: .black.opacity(0.5), radius: 2)
            .frame(width: 22, height: 22)
            .contentShape(Circle())
            .onHover { inside in
                hoveredHandle = inside ? index : (hoveredHandle == index ? nil : hoveredHandle)
                if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("ring"))
                    .onChanged { dragHandle(index, value: $0, center: center) }
                    .onEnded { _ in drag = nil }
            )
            .animation(.easeOut(duration: 0.1), value: active)
            .position(point(slices[index].end, radius, around: center))   // last: it fills the ring
    }

    private func dragHandle(_ index: Int, value: DragGesture.Value, center: CGPoint) {
        let fraction = { (p: CGPoint) in Double(atan2(p.y - center.y, p.x - center.x)) / (2 * .pi) + 0.25 }
        var current = drag ?? HandleDrag(index: index, start: active.map(limit), lastFraction: fraction(value.startLocation))
        let here = fraction(value.location)
        var step = (here - current.lastFraction).truncatingRemainder(dividingBy: 1)
        if step > 0.5 { step -= 1 } else if step < -0.5 { step += 1 }
        current.moved += step
        current.lastFraction = here
        drag = current

        let cards = Int((current.moved * Double(current.start.reduce(0, +))).rounded())
        let shared = Self.moved(cards, across: index, from: current.start)
        for (deck, value) in zip(active, shared) { setLimit(deck, value) }
    }

    /// Moves cards over the boundary after deck `index`. Clockwise grows that deck and takes from
    /// the decks ahead, nearest first; anticlockwise grows the next deck and takes from those
    /// behind. Passing over decks at 0 is what keeps every handle usable.
    static func moved(_ cards: Int, across index: Int, from start: [Int]) -> [Int] {
        var limits = start
        let takers = cards > 0 ? Array(start.indices[(index + 1)...]) : Array(start.indices[...index].reversed())
        var wanted = abs(cards)
        for deck in takers where wanted > 0 {
            let taken = min(limits[deck], wanted)
            limits[deck] -= taken
            wanted -= taken
        }
        limits[cards > 0 ? index : index + 1] += abs(cards) - wanted
        return limits
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
        totalBase = nil
        store(deck, value)
    }

    private func store(_ deck: DeckSummary, _ value: Int) {
        limits[deck.id] = min(max(value, 0), 2000)
        dirty.insert(deck.id)
        scheduleSave()
    }

    /// A new total keeps the decks' proportions. Typing it passes through each prefix (2, then 26,
    /// then 260), so every step scales from the split as it was before typing began; scaling from
    /// the last step would let a tiny total round the smaller decks away for good.
    private func setTotal(_ value: Int) {
        guard !active.isEmpty else { return }
        let base = totalBase ?? Dictionary(uniqueKeysWithValues: active.map { ($0.id, limit($0)) })
        totalBase = base
        let shares = Self.scaled(active.map { base[$0.id] ?? 0 }, to: min(max(value, 0), 2000))
        for (deck, share) in zip(active, shares) { store(deck, share) }
    }

    /// `base` scaled to add up to `target`, largest remainders taking the rounding. All zeros share equally.
    static func scaled(_ base: [Int], to target: Int) -> [Int] {
        let weights = base.reduce(0, +) > 0 ? base.map(Double.init) : base.map { _ in 1.0 }
        let sum = weights.reduce(0, +)
        guard sum > 0 else { return base }
        let exact = weights.map { $0 / sum * Double(target) }
        var out = exact.map { Int($0.rounded(.down)) }
        let byRemainder = exact.indices.sorted { exact[$0] - Double(out[$0]) > exact[$1] - Double(out[$1]) }
        for i in byRemainder.prefix(max(0, target - out.reduce(0, +))) { out[i] += 1 }
        return out
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

    /// How often 95% ranges on number cards caught the answer.
    private func calibrationLine(_ c: PluckkAPI.Calibration) -> some View {
        let rate = Int((Double(c.caught) / Double(c.reviews) * 100).rounded())
        let advice = c.reviews < 10 ? "Too few yet to judge."
            : rate < 88 ? "Below 95%: your ranges are too narrow."
            : rate > 98 ? "Nearly always: your ranges could be tighter."
            : "About right for 95%."
        return VStack(spacing: 4) {
            Text("Number cards").font(.system(size: 10, weight: .semibold)).tracking(0.7).foregroundColor(.secondary)
            Text("Your 95% ranges caught \(c.caught) of \(c.reviews) answers (\(rate)%). \(advice)")
                .font(.system(size: 13))
        }
        .frame(maxWidth: .infinity)
    }

    private func load() async {
        guard let token = AuthManager.shared.accessToken else { return }
        calibration = try? await PluckkAPI.shared.calibration(token: token)
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


/// Reviews ahead, day by day: what the decks will ask for if every review is rated Good and new
/// cards keep arriving at today's limits. Changing a limit on the ring changes it.
struct WorkloadForecastView: View {
    @State private var days: [PluckkAPI.ForecastDay] = []
    @State private var span = 30
    @State private var failed = false

    private struct Point: Identifiable {
        let id = UUID()
        let date: Date
        let count: Int
        let series: String
    }

    private static let series = ["Reviews of cards you know", "Reviews of cards you'll learn", "New cards", "Total"]

    private var points: [Point] {
        days.flatMap { d in
            [Point(date: d.day, count: d.reviews, series: Self.series[0]),
             Point(date: d.day, count: d.learned, series: Self.series[1]),
             Point(date: d.day, count: d.new, series: Self.series[2]),
             Point(date: d.day, count: d.total, series: Self.series[3])]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Reviews ahead").font(.headline)
                Spacer()
                Picker("", selection: $span) {
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("6 months").tag(180)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if days.isEmpty {
                Text(failed ? "Couldn't load the forecast." : "Working it out…")
                    .font(.system(size: 12)).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                Chart(points) { point in
                    LineMark(x: .value("Day", point.date, unit: .day), y: .value("Cards", point.count))
                        .foregroundStyle(by: .value("Series", point.series))
                        .lineStyle(StrokeStyle(lineWidth: point.series == "Total" ? 2.5 : 1.5,
                                               dash: point.series == "New cards" ? [4, 3] : []))
                        .interpolationMethod(.monotone)
                }
                .chartForegroundStyleScale([
                    Self.series[0]: Color(hex: "5b9bd5"),
                    Self.series[1]: Color(hex: "3fb950"),
                    Self.series[2]: Color(hex: "a371f7"),
                    Self.series[3]: PluckkTheme.accent,
                ])
                .chartLegend(position: .bottom, alignment: .leading)
                .frame(height: 220)
                summary
            }
            Text("Assumes every review is rated Good and new cards keep coming at today's limits. Misses (Again) add reviews, so treat it as a floor.")
                .font(.system(size: 11)).foregroundColor(.secondary)
        }
        .task(id: span) { await load() }
    }

    private var summary: some View {
        let week = days.prefix(7)
        let weekAverage = week.isEmpty ? 0 : week.map(\.total).reduce(0, +) / week.count
        let peak = days.max { $0.total < $1.total }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM"
        return HStack(spacing: 18) {
            stat("\(days.first?.total ?? 0)", "today")
            stat("\(weekAverage)", "a day this week")
            if let peak { stat("\(peak.total)", "peak, \(formatter.string(from: peak.day))") }
            stat("\(days.map(\.new).reduce(0, +))", "new cards in \(span) days")
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 17, weight: .semibold).monospacedDigit())
            Text(label).font(.system(size: 11)).foregroundColor(.secondary)
        }
    }

    private func load() async {
        guard let token = AuthManager.shared.accessToken else { return }
        do {
            days = try await PluckkAPI.shared.forecast(token: token, days: span)
            failed = false
        } catch {
            failed = true
        }
    }
}
