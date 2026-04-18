import SwiftUI

struct CompletionCelebrationOverlay: View {
    let starsEarned: Int
    let onWeiter: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Text("Super gemacht!")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                HStack(spacing: 12) {
                    ForEach(1...3, id: \.self) { index in
                        Image(systemName: index <= starsEarned ? "star.fill" : "star")
                            .font(.system(size: 48))
                            .foregroundStyle(index <= starsEarned ? .yellow : .white.opacity(0.4))
                    }
                }

                Button(action: onWeiter) {
                    Text("Weiter")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 48)
                        .padding(.vertical, 16)
                        .background(.blue, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Weiter zum nächsten Buchstaben")
            }
            .padding(40)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .shadow(color: .black.opacity(0.3), radius: 24, y: 8)
        }
    }
}
