import SwiftUI

/// Overlay shown after the freeWrite phase when paper-transfer mode is enabled.
/// Flow: shows the reference letter for 3 s → write-on-paper prompt for 10 s →
/// three-button self-assessment (😊 / 😐 / 😟). Selecting a button calls
/// onComplete with the corresponding score (1.0 / 0.5 / 0.0).
struct PaperTransferView: View {
    let letter: String
    let onComplete: (Double) -> Void

    @State private var phase: Phase = .showLetter

    private enum Phase { case showLetter, writePaper, assess }

    var body: some View {
        ZStack {
            Color.black.opacity(0.65)
                .ignoresSafeArea()

            VStack(spacing: 32) {
                switch phase {
                case .showLetter:
                    Text(letter)
                        .font(.system(size: 180, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                        .transition(.opacity)
                        .accessibilityLabel("Buchstabe \(letter)")

                case .writePaper:
                    VStack(spacing: 16) {
                        Image(systemName: "pencil")
                            .font(.system(size: 64))
                            .foregroundStyle(.blue)
                        Text("Schreibe den Buchstaben jetzt auf Papier!")
                            .font(.title2.bold())
                            .multilineTextAlignment(.center)
                    }
                    .transition(.opacity)

                case .assess:
                    VStack(spacing: 24) {
                        Text("Wie war dein Buchstabe?")
                            .font(.title2.bold())
                            .multilineTextAlignment(.center)
                        HStack(spacing: 20) {
                            assessButton(emoji: "😟", label: "nochmal üben", score: 0.0)
                            assessButton(emoji: "😐", label: "okay",          score: 0.5)
                            assessButton(emoji: "😊", label: "super",         score: 1.0)
                        }
                    }
                    .transition(.opacity)
                }
            }
            .padding(40)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 24)
            .padding(48)
        }
        .task {
            do {
                try await Task.sleep(for: .seconds(3))
                withAnimation { phase = .writePaper }
                try await Task.sleep(for: .seconds(10))
                withAnimation { phase = .assess }
            } catch {}
        }
    }

    private func assessButton(emoji: String, label: String, score: Double) -> some View {
        Button {
            onComplete(score)
        } label: {
            VStack(spacing: 8) {
                Text(emoji)
                    .font(.system(size: 56))
                Text(label)
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
