import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var vm: TracingViewModel

    var body: some View {
        ZStack(alignment: .top) {
            TracingCanvasView()
                .background(Color.white)
                .ignoresSafeArea()

            VStack(spacing: 10) {
                topBar
                if let toast = vm.toastMessage {
                    Text(toast)
                        .font(.headline)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .transition(.opacity.combined(with: .scale))
                }

                Spacer()

                if let completion = vm.completionMessage {
                    CompletionHUD(message: completion) {
                        vm.dismissCompletionHUD()
                    }
                    .padding(.bottom, 26)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.top, 12)
            .padding(.horizontal, 12)
        }
        .animation(.easeInOut(duration: 0.2), value: vm.toastMessage)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: vm.completionMessage)
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            ToggleChip(title: "Ghost", isOn: vm.showGhost) { vm.toggleGhost() }
            ToggleChip(title: "Order", isOn: vm.strokeEnforced) { vm.toggleStrokeEnforcement() }
            ToggleChip(title: "Debug", isOn: vm.showDebug) { vm.toggleDebug() }
            Button("Reset") { vm.resetLetter() }
                .buttonStyle(.borderedProminent)

            Spacer(minLength: 6)

            Circle()
                .fill(vm.isPlaying ? .green : .red)
                .frame(width: 14, height: 14)

            Text(vm.currentLetterName)
                .font(.headline)
                .lineLimit(1)
        }
    }
}

private struct ToggleChip: View {
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.borderedProminent)
        .tint(isOn ? .blue : .gray)
    }
}


private struct CompletionHUD: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.green)
                .font(.title3)

            Text(message)
                .font(.headline)
                .multilineTextAlignment(.leading)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(.thinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.green.opacity(0.28), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.1), radius: 10, y: 5)
    }
}
