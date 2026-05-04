// RewardCelebrationOverlay.swift
// PrimaeNative
//
// One-time "you just earned this" moment for an unlocked
// `RewardEvent`. The persistent display lives in the Fortschritte
// gallery's badge row; this overlay is the immediate affirmation.
// Auto-dismisses after the duration set in
// `CanvasOverlay.rewardCelebration.defaultDuration`; the queue then
// proceeds to the celebration that triggered the achievement.

import SwiftUI

struct RewardCelebrationOverlay: View {
    let event: RewardEvent

    private var emoji: String {
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

    private var label: String {
        switch event {
        case .firstLetter:         return "Erster Buchstabe!"
        case .dailyGoalMet:        return "Tagesziel geschafft!"
        case .streakDay3:          return "3 Tage in Folge!"
        case .streakWeek:          return "7 Tage in Folge!"
        case .streakMonth:         return "30 Tage in Folge!"
        case .allLettersComplete:  return "Alle Buchstaben!"
        case .perfectAccuracy:     return "Perfekt!"
        case .centuryClub:         return "100 Buchstaben!"
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 18) {
                Text(emoji)
                    .font(.system(size: 84))
                    .accessibilityHidden(true)
                Text("Auszeichnung freigeschaltet")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
                Text(label)
                    .font(.system(.title, design: .rounded).weight(.bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
            }
            .padding(36)
            .frame(maxWidth: 360)
            .background(
                LinearGradient(
                    colors: [
                        Color(red: 1.00, green: 0.78, blue: 0.20),
                        Color(red: 1.00, green: 0.55, blue: 0.05)
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 28, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(Color.white.opacity(0.45), lineWidth: 1.5)
            )
            .shadow(color: .black.opacity(0.30), radius: 22, y: 6)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Auszeichnung: \(label)")
        }
    }
}
