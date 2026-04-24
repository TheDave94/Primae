// FortschritteWorldView.swift
// BuchstabenNative
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
                letterGallery
                fluencyFooter
            }
            .padding(.horizontal, 24)
            .padding(.top, 32)
            .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WorldPalette.background(for: .fortschritte).ignoresSafeArea())
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 20) {
            starCountCard
            streakCard
            Spacer()
        }
    }

    private var starCountCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "star.fill")
                .font(.system(size: 44))
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(totalStars) Sterne")
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                Text("gesammelt")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
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
                Text(vm.currentStreak <= 1 ? "Weiter so!" : "hintereinander")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(vm.currentStreak) Tage hintereinander")
    }

    // MARK: - Gallery

    private var letterGallery: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Deine Buchstaben")
                .font(.title2.weight(.bold))
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

    @ViewBuilder
    private func letterCard(letter: String) -> some View {
        let prog = vm.progressStore.progress(for: letter)
        let stars = LetterStars.stars(for: prog.phaseScores)
        let tint: Color = {
            if stars >= LetterStars.maxStars {
                return Color(red: 0.82, green: 0.94, blue: 0.82)
            }
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
                            .foregroundStyle(idx < stars ? .orange : Color.gray.opacity(0.5))
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
                .font(.headline)
            Text(fluencyMessage)
                .font(.title3)
                .foregroundStyle(fluencyColor)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.05), radius: 10, y: 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Schreibflüssigkeit: \(fluencyMessage)")
    }

    // MARK: - Derived values

    private var totalStars: Int {
        vm.progressStore.allProgress.values.reduce(0) { acc, prog in
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
        case .stable:    return .secondary
        case .declining: return .orange
        case .none:      return .secondary
        }
    }
}
