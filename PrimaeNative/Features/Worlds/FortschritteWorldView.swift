// FortschritteWorldView.swift
// PrimaeNative
//
// World 3 — Meine Fortschritte. Child-facing view that celebrates
// progress without any parent-grade analytics. Three rows:
//   • big star total + streak headline
//   • letter gallery (4 stars each — one per completed learning phase),
//     colour-coded by mastery tier
//   • "Schreibflüssigkeit" footer pulled from vm.writingSpeedTrend

import SwiftUI

struct FortschritteWorldView: View {
    @Environment(TracingViewModel.self) private var vm
    let onLetterSelected: (String) -> Void

    private let columns = Array(repeating: GridItem(.adaptive(minimum: 92), spacing: 12),
                                 count: 1)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                rewardsBadgeRow
                letterGallery
                fluencyFooter
            }
            .padding(.horizontal, 24)
            .padding(.top, 32)
            .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WorldPalette.background(for: .fortschritte).ignoresSafeArea())
        // Letter gallery / fluency cards use opaque white surfaces, so
        // pin to light mode to keep `.primary` resolving to dark text
        // even when the system theme is dark.
        .preferredColorScheme(.light)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 20) {
            starCountCard
            streakCard
            dailyGoalCard
            Spacer()
        }
    }

    /// P7 (ROADMAP_V5): daily-goal pill. Goal-setting theory (Locke &
    /// Latham 1990) predicts that explicit, proximal goals improve
    /// practice quality. Default goal = 3 letters/day; parent can
    /// adjust via UserDefaults. Tile turns green once the goal is hit.
    private var dailyGoalCard: some View {
        let done = vm.completionsToday
        let goal = vm.dailyGoal
        let achieved = done >= goal
        return HStack(spacing: 12) {
            Text(achieved ? "🎯" : "📅").font(.system(size: 38))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(done) / \(goal)")
                    .font(.system(.title, design: .rounded).weight(.bold))
                    .foregroundStyle(.primary)
                Text(achieved ? "Tagesziel!" : "heute geschafft")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(achieved ? AppSurface.masteredText : AppSurface.caption)
            }
        }
        .padding(20)
        .background(achieved ? AppSurface.mastered : Color.white,
                    in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(AppSurface.cardEdge.opacity(0.6), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(achieved
            ? "Tagesziel erreicht: \(done) von \(goal) Buchstaben"
            : "\(done) von \(goal) Buchstaben heute")
    }

    private var starCountCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "star.fill")
                .font(.system(size: 44))
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(totalStars) Sterne")
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .foregroundStyle(.primary)
                Text("gesammelt")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppSurface.caption)
            }
        }
        .padding(20)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(AppSurface.cardEdge.opacity(0.6), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(totalStars) Sterne gesammelt")
    }

    private var streakCard: some View {
        HStack(spacing: 12) {
            Text("🔥").font(.system(size: 40))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(vm.currentStreak) \(vm.currentStreak == 1 ? "Tag" : "Tage")")
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .foregroundStyle(.primary)
                Text(vm.currentStreak <= 1 ? "Weiter so!" : "hintereinander")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppSurface.caption)
            }
        }
        .padding(20)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(AppSurface.cardEdge.opacity(0.6), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(vm.currentStreak == 1
                            ? "1 Tag hintereinander"
                            : "\(vm.currentStreak) Tage hintereinander")
    }

    // MARK: - Rewards

    /// Achievement badges. Shows every `RewardEvent` case as a tile;
    /// earned ones render in colour with a labelled emoji, unearned
    /// ones render gray-scale so the child can see what's still ahead.
    /// Surfaces data the StreakStore has been collecting since launch
    /// but never displayed (HIDDEN_FEATURES_AUDIT C.6).
    private var rewardsBadgeRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Auszeichnungen")
                .font(.title2.weight(.bold))
                .foregroundStyle(.primary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(RewardEvent.allCases, id: \.self) { event in
                        rewardBadge(event: event,
                                     earned: vm.earnedRewards.contains(event))
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private func rewardBadge(event: RewardEvent, earned: Bool) -> some View {
        VStack(spacing: 4) {
            Text(rewardEmoji(event))
                .font(.system(size: 32))
                .saturation(earned ? 1 : 0)
                .opacity(earned ? 1 : 0.45)
            Text(rewardLabel(event))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(earned ? .primary : AppSurface.caption)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(width: 78)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .frame(width: 88)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppSurface.cardEdge.opacity(earned ? 0.6 : 0.3), lineWidth: 1)
        )
        .shadow(color: .black.opacity(earned ? 0.05 : 0), radius: 6, y: 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(rewardLabel(event)). \(earned ? "Erreicht" : "Noch nicht erreicht")")
    }

    private func rewardEmoji(_ event: RewardEvent) -> String {
        switch event {
        case .firstLetter:         return "🌟"
        case .dailyGoalMet:        return "🎯"
        case .streakDay3:          return "🔥"
        case .streakWeek:          return "🏅"
        case .streakMonth:         return "🏆"
        case .allLettersComplete:  return "🎉"
        case .perfectAccuracy:     return "✨"
        case .centuryClub:         return "💯"
        }
    }

    private func rewardLabel(_ event: RewardEvent) -> String {
        switch event {
        case .firstLetter:         return "Erster Buchstabe"
        case .dailyGoalMet:        return "Tagesziel"
        case .streakDay3:          return "3 Tage Serie"
        case .streakWeek:          return "7 Tage Serie"
        case .streakMonth:         return "30 Tage Serie"
        case .allLettersComplete:  return "Alle Buchstaben"
        case .perfectAccuracy:     return "Perfekt"
        case .centuryClub:         return "100 Buchstaben"
        }
    }

    // MARK: - Gallery

    private var letterGallery: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Deine Buchstaben")
                .font(.title2.weight(.bold))
                .foregroundStyle(.primary)
            if vm.visibleLetterNames.isEmpty {
                // Defensive empty state — shouldn't happen in practice
                // (letter list is bundled), but a parent who's somehow
                // landed here on an empty install gets a verbal hint
                // rather than a silent grey box.
                ContentUnavailableView(
                    "Noch keine Buchstaben",
                    systemImage: "textformat.abc",
                    description: Text("Starte im Schule-Modus, um Buchstaben freizuschalten.")
                )
                .frame(maxWidth: .infinity, alignment: .center)
            } else {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 6),
                    spacing: 14
                ) {
                    ForEach(vm.visibleLetterNames, id: \.self) { letter in
                        letterCard(letter: letter)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func letterCard(letter: String) -> some View {
        let prog = vm.progress(for: letter)
        let stars = LetterStars.stars(for: prog.phaseScores)
        let tint: Color = {
            // Shared token with LetterPickerBar so a "mastered" letter
            // looks identical in the picker and the gallery.
            if stars >= LetterStars.maxStars { return AppSurface.mastered }
            if stars >= 1 { return Color(red: 1.00, green: 0.88, blue: 0.60) }
            return Color.gray.opacity(0.15)
        }()

        Button { onLetterSelected(letter) } label: {
            VStack(spacing: 6) {
                Text(letter)
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                HStack(spacing: 2) {
                    ForEach(0..<4, id: \.self) { idx in
                        Image(systemName: idx < stars ? "star.fill" : "star")
                            .font(.system(size: 10))
                            .foregroundStyle(idx < stars ? AppSurface.starGold : Color.gray.opacity(0.5))
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 96)
            .background(tint, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.black.opacity(0.05), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Buchstabe \(letter)")
        .accessibilityValue(stars == 0
            ? "Noch keine Sterne"
            : "\(stars) von 4 Sternen")
        .accessibilityHint("Tippen, um diesen Buchstaben zu üben")
    }

    // MARK: - Footer

    @ViewBuilder
    private var fluencyFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Schreibflüssigkeit")
                .font(.headline.weight(.bold))
                .foregroundStyle(.primary)
            Text(fluencyMessage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(fluencyColor)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(AppSurface.cardEdge.opacity(0.6), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 10, y: 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Schreibflüssigkeit: \(fluencyMessage)")
    }

    // MARK: - Derived values

    private var totalStars: Int {
        vm.allProgress.values.reduce(0) { acc, prog in
            acc + LetterStars.stars(for: prog.phaseScores)
        }
    }

    private var fluencyMessage: String {
        switch vm.writingSpeedTrend {
        case .improving: return "↑ Wird besser!"
        case .stable:    return "→ Bleib dran."
        case .declining: return "↓ Lass uns üben."
        case .none:      return "Noch nicht genug Daten."
        }
    }

    private var fluencyColor: Color {
        switch vm.writingSpeedTrend {
        case .improving: return .green
        case .stable:    return AppSurface.prompt
        case .declining: return .orange
        case .none:      return AppSurface.caption
        }
    }
}
