import SwiftUI

struct CompletionCelebrationOverlay: View {
    let starsEarned: Int
    /// W-5: max achievable stars for the current thesis condition (1 for
    /// guidedOnly/control, 4 for threePhase). Showing 4 stars to a
    /// guidedOnly child who scored perfectly would always show 3 empty
    /// stars — a motivational confound between conditions.
    let maxStars: Int
    let onWeiter: () -> Void

    /// Warm panel gradient — reads as a "reward" card against the dark
    /// scrim and gives the white headline text a solid colour to sit on
    /// instead of ultraThinMaterial (which renders near-white in light
    /// mode and crushed the contrast).
    private let panelGradient = LinearGradient(
        colors: [
            Color(red: 0.33, green: 0.53, blue: 0.96),  // friendly blue
            Color(red: 0.51, green: 0.36, blue: 0.88)   // playful purple
        ],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Text("🎉")
                    .font(.system(size: 58))
                    .accessibilityHidden(true)

                Text("Super gemacht!")
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                HStack(spacing: 12) {
                    ForEach(1...max(1, maxStars), id: \.self) { index in
                        Image(systemName: index <= starsEarned ? "star.fill" : "star")
                            .font(.system(size: 40))
                            .foregroundStyle(index <= starsEarned
                                ? Color.yellow
                                : Color.white.opacity(0.55))
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(starsEarned) von \(maxStars) Sternen")

                Button(action: onWeiter) {
                    Text("Weiter")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Color(red: 0.22, green: 0.30, blue: 0.75))
                        .padding(.horizontal, 48)
                        .padding(.vertical, 16)
                        .background(Color.white, in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.8), lineWidth: 2))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Weiter zum nächsten Buchstaben")
            }
            .padding(40)
            .background(panelGradient,
                        in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(Color.white.opacity(0.3), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
        }
    }
}
