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
            }
            .padding(.top, 12)
            .padding(.horizontal, 12)
        }
        .animation(.easeInOut(duration: 0.2), value: vm.toastMessage)
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
