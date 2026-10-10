import SwiftUI

struct GameTab: View {
    @Environment(UsageStore.self) private var store
    @State private var showAllAchievements = false

    var body: some View {
        let g = store.game
        VStack(alignment: .leading, spacing: 12) {
            LevelCard(game: g)
            questsCard(g)
            achievementsCard(g)
            recordsCard(g)
            Text("XP rewards shipping, streaks and efficiency — never spending. Everything is computed from your history, so it can't be gamed by burning tokens.")
                .font(.system(size: 9.5)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func questsCard(_ g: GameState) -> some View {
        Card {
            SectionHeader(title: "Today's quests", trailing: "\(g.dailyQuests.filter(\.done).count)/\(g.dailyQuests.count) done · new ones at midnight")
            ForEach(g.dailyQuests) { q in QuestRow(quest: q) }
            if let w = g.weeklyQuest {
                Divider().opacity(0.4)
                SectionHeader(title: "Weekly quest")
                QuestRow(quest: w)
            }
        }
    }

    private func achievementsCard(_ g: GameState) -> some View {
        let sorted = g.achievements.sorted {
            if $0.isUnlocked != $1.isUnlocked { return $0.isUnlocked }
            return ($0.unlockedAt.compactMap { $0 }.max() ?? .distantPast) > ($1.unlockedAt.compactMap { $0 }.max() ?? .distantPast)
        }
        let shown = showAllAchievements ? sorted : Array(sorted.prefix(9))
        return Card {
            SectionHeader(title: "Achievements", trailing: "\(g.unlockedCount)/\(g.achievements.count) unlocked")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(shown) { a in AchievementTile(a: a) }
            }
            if g.achievements.count > 9 {
                Button(showAllAchievements ? "Show fewer" : "Show all \(g.achievements.count)") {
                    withAnimation(.snappy) { showAllAchievements.toggle() }
                }
                .buttonStyle(.plain).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Color.accentColor)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func recordsCard(_ g: GameState) -> some View {
        Card(padding: 10) {
            SectionHeader(title: "Personal records")
            ForEach(g.records) { r in
                HStack(spacing: 8) {
                    Text(r.emoji).font(.system(size: 13))
                    Text(r.name).font(.system(size: 11))
                    if r.isNew {
                        Text("NEW").font(.system(size: 8.5, weight: .heavy))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Capsule().fill(Palette.accent)).foregroundStyle(.white)
                    }
                    Spacer()
                    Text(r.value).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    if let d = r.date {
                        Text(d.formatted(.dateTime.month(.abbreviated).day())).font(.system(size: 9.5)).foregroundStyle(.tertiary)
                            .frame(width: 42, alignment: .trailing)
                    }
                }
            }
        }
    }
}

struct LevelCard: View {
    let game: GameState
    @State private var showBreakdown = false

    var body: some View {
        let g = game
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                ZStack {
                    RingGauge(fraction: g.levelProgress, lineWidth: 7, color: Palette.accent)
                    VStack(spacing: -2) {
                        Text("LV").font(.system(size: 8.5, weight: .heavy)).foregroundStyle(.secondary)
                        Text("\(g.level)").font(.system(size: 22, weight: .bold))
                    }
                }
                .frame(width: 66, height: 66)
                VStack(alignment: .leading, spacing: 3) {
                    Text(g.title).font(.system(size: 16, weight: .bold))
                    Text("\(Fmt.number(g.totalXP - g.levelFloor)) / \(Fmt.number(g.levelCeil - g.levelFloor)) XP to level \(g.level + 1)")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Chip(text: "🔥 \(g.streak)-day streak")
                        Chip(text: "❄️ ×\(g.freezes)").help("Streak freezes: earn one every 7 active days (max 2). A missed day uses one instead of breaking your streak.")
                        Chip(text: "\(seasonEmoji(g.seasonRank)) \(g.seasonRank)").help("This month's season rank")
                    }
                }
                Spacer(minLength: 0)
            }
            if g.frozenToday {
                Text("No activity yet today — send a prompt to keep the 🔥 alive" + (g.freezes > 0 ? " (a ❄️ freeze will cover you if not)" : ""))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            // Season progress
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("Season · \(Date().formatted(.dateTime.month(.wide)))").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    if let next = g.seasonNext {
                        Text("\(Fmt.number(g.seasonXP)) / \(Fmt.number(next.xp)) XP → \(seasonEmoji(next.rank)) \(next.rank)")
                            .font(.system(size: 10)).foregroundStyle(.tertiary).monospacedDigit()
                    } else {
                        Text("\(Fmt.number(g.seasonXP)) XP · max rank!").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }
                Bar(value: seasonProgress(g), color: Palette.series[6], height: 7)
            }
            Button {
                withAnimation(.snappy) { showBreakdown.toggle() }
            } label: {
                HStack {
                    Text("Today: +\(Fmt.number(g.todayXP)) XP").font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(showBreakdown ? 90 : 0)).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showBreakdown {
                ForEach(g.todayLines) { l in
                    HStack {
                        Text(l.label).font(.system(size: 10.5)).foregroundStyle(.secondary)
                        Spacer()
                        Text("+\(l.xp)").font(.system(size: 10.5, weight: .medium)).monospacedDigit()
                    }
                }
                if g.todayLines.isEmpty { Text("Nothing yet — go make something!").font(.system(size: 10.5)).foregroundStyle(.tertiary) }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: [Palette.accent.opacity(0.14), Palette.series[6].opacity(0.10)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 0.5))
    }

    private func seasonProgress(_ g: GameState) -> Double {
        guard let next = g.seasonNext else { return 1 }
        let floor = Game.seasonRanks.last { $0.1 <= g.seasonXP }?.1 ?? 0
        return Double(g.seasonXP - floor) / Double(max(next.xp - floor, 1))
    }
}

func seasonEmoji(_ rank: String) -> String {
    ["Bronze": "🥉", "Silver": "🥈", "Gold": "🥇", "Platinum": "💠", "Diamond": "💎"][rank] ?? "🏅"
}

struct QuestRow: View {
    let quest: Quest
    var body: some View {
        HStack(spacing: 9) {
            Text(quest.emoji).font(.system(size: 16)).frame(width: 22)
                .grayscale(quest.done ? 0 : 0.3)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(quest.title).font(.system(size: 11.5, weight: .semibold))
                        .strikethrough(quest.done, color: .secondary)
                    Text(quest.detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if quest.done {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(Palette.good).font(.system(size: 11))
                    }
                    Text("+\(quest.xp) XP").font(.system(size: 10, weight: .semibold)).foregroundStyle(quest.done ? Palette.good : .secondary)
                }
                HStack(spacing: 6) {
                    Bar(value: quest.progress, color: quest.done ? Palette.good : Palette.series[0], height: 5)
                    Text(quest.label).font(.system(size: 9.5)).foregroundStyle(.tertiary).monospacedDigit()
                        .frame(minWidth: 40, alignment: .trailing)
                }
            }
        }
    }
}

struct AchievementTile: View {
    let a: Achievement
    @State private var hover = false

    var body: some View {
        VStack(spacing: 4) {
            Text(a.emoji).font(.system(size: 24))
                .grayscale(a.isUnlocked ? 0 : 1)
                .opacity(a.isUnlocked ? 1 : 0.35)
                .scaleEffect(hover && a.isUnlocked ? 1.15 : 1)
            Text(a.name).font(.system(size: 9.5, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.75)
            if a.tiers.count > 1 {
                HStack(spacing: 3) {
                    ForEach(0..<a.tiers.count, id: \.self) { i in
                        Circle().fill(i < a.tier ? tierColor(i) : Palette.hairline).frame(width: 6, height: 6)
                    }
                }
            }
            if !a.isMaxed {
                Bar(value: a.progress, color: Palette.series[0], height: 4).padding(.horizontal, 6)
                Text("\(compact(a.value)) / \(compact(a.nextTarget ?? 0))").font(.system(size: 8.5)).foregroundStyle(.tertiary).monospacedDigit()
            } else {
                Text(a.tierName.map { "\($0) ✓" } ?? "Unlocked ✓").font(.system(size: 8.5, weight: .medium)).foregroundStyle(Palette.good)
            }
        }
        .padding(.vertical, 8).padding(.horizontal, 6)
        .frame(maxWidth: .infinity, minHeight: 104)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(a.isUnlocked ? Palette.accent.opacity(0.08) : Palette.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(a.isUnlocked ? Palette.accent.opacity(0.25) : Palette.hairline, lineWidth: 0.5))
        .onHover { h in withAnimation(.spring(duration: 0.25)) { hover = h } }
        .help("\(a.name): \(a.blurb)\n\(compact(a.value)) \(a.unit)" + (a.unlockedAt.compactMap { $0 }.max().map { "\nLast unlocked \($0.formatted(.dateTime.month().day()))" } ?? ""))
    }

    private func tierColor(_ i: Int) -> Color {
        [Color(hex: 0xc0804a), Color(hex: 0xa8a8b0), Color(hex: 0xe0b020)][min(i, 2)]
    }

    private func compact(_ v: Double) -> String {
        v >= 1e9 ? String(format: "%.1fB", v / 1e9) : v >= 1e6 ? String(format: "%.0fM", v / 1e6) : v >= 1e4 ? String(format: "%.0fk", v / 1e3)
            : v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }
}
