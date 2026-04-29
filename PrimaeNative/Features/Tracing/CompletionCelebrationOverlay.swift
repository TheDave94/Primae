import SwiftUI

struct CompletionCelebrationOverlay: View {
    let starsEarned: Int
    /// W-5: max achievable stars for the current thesis condition (1 for
    /// guidedOnly/control, 4 for threePhase). Showing 4 stars to a
    /// guidedOnly child who scored perfectly would always show 3 empty
    /// stars — a motivational confound between conditions.
    let maxStars: Int
    let onWeiter: () -> Void

    var body: some View {
        ZStack {
            // Backdrop dim — black regardless of mode (overlay dims darken
            // the canvas; in dark mode the canvas is already dark and the
            // dim still reads as "everything below is paused").
            Color.black.opacity(0.45)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Text("🎉")
                    .font(.system(size: 58))
                    .accessibilityHidden(true)

                // I-7: distinct from the SchuleWorldView "Nachspuren
                // fertig" feedback card (which uses "Super gemacht!" for
                // a 3-of-3 score), so the child doesn't see the same
                // praise text stack twice when the card and the
                // celebration both show after the freeWrite phase.
                Text("Geschafft!")
                    .font(.display(FontSize.xxl, weight: .bold))
                    .foregroundStyle(Color.paper)
                    .multilineTextAlignment(.center)

                HStack(spacing: 12) {
                    ForEach(1...max(1, maxStars), id: \.self) { index in
                        Image(systemName: index <= starsEarned ? "star.fill" : "star")
                            .font(.system(size: 40))
                            .foregroundStyle(index <= starsEarned
                                ? AppSurface.starGold
                                : Color.paper.opacity(0.55))
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(starsEarned) von \(maxStars) Sternen")

                Button("Weiter", action: onWeiter)
                    .buttonStyle(StickerButtonStyle(tint: .paper, labelColor: .brand))
                    .accessibilityLabel("Weiter zum nächsten Buchstaben")
            }
            .padding(40)
            .background(Color.brand,
                        in: RoundedRectangle(cornerRadius: Radii.xl, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radii.xl, style: .continuous)
                    .stroke(Color.paper.opacity(0.3), lineWidth: 1)
            )
            .shadow(color: Color.brand.opacity(0.35), radius: 24, y: 8)
        }
    }
}
