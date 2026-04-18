import SwiftUI

struct SettingsView: View {
    @Environment(TracingViewModel.self) private var vm
    @State private var selectedSchriftArt: SchriftArt = .druckschrift

    private static let defaultsKey = "selectedSchriftArt"

    var body: some View {
        Form {
            Section("Schriftart") {
                ForEach(SchriftArt.allCases.filter { $0 == .druckschrift }, id: \.self) { art in
                    schriftArtRow(art)
                }
            }
            Section("Hilfe") {
                Button("Einführung wiederholen") { vm.restartOnboarding() }
                    .accessibilityHint("Startet die Einführung beim nächsten App-Start neu")
            }
        }
        .navigationTitle("Einstellungen")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            selectedSchriftArt = vm.schriftArt
        }
    }

    @ViewBuilder
    private func schriftArtRow(_ art: SchriftArt) -> some View {
        let isAvailable = art == .druckschrift
        Button {
            guard isAvailable else { return }
            selectedSchriftArt = art
            UserDefaults.standard.set(art.rawValue, forKey: Self.defaultsKey)
            vm.schriftArt = art
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(art.displayName)
                        .foregroundStyle(isAvailable ? .primary : .secondary)
                    if !isAvailable {
                        Text("(bald verfügbar)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if selectedSchriftArt == art {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
        }
        .disabled(!isAvailable)
    }
}
