import SwiftUI

/// Top-of-screen picker with "Buchstaben" / "Wörter" tabs. Words use
/// the curated Austrian Volksschule list; selecting a word tile builds
/// a `.word` sequence via `vm.loadWord(_:)`.
struct SequencePickerBar: View {
    @Environment(TracingViewModel.self) private var vm
    @State private var tab: Tab = .letters

    enum Tab: Hashable { case letters, words }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Buchstaben").tag(Tab.letters)
                Text("Wörter").tag(Tab.words)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.top, 6)

            switch tab {
            case .letters:
                LetterPickerBar()
            case .words:
                WordPickerRow()
            }
        }
    }
}

/// Curated word tiles for the "Wörter" tab. Source list:
/// `TracingViewModel.demoWordList`.
private struct WordPickerRow: View {
    @Environment(TracingViewModel.self) private var vm

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(TracingViewModel.demoWordList, id: \.self) { word in
                    WordPickerButton(
                        word: word,
                        isSelected: vm.currentLetterName.uppercased() == word
                    ) {
                        vm.loadWord(word)
                    }
                    .equatable()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }
}

/// Equatable so SwiftUI skips body re-evaluation on unrelated VM
/// state. Closure excluded from `==`.
private struct WordPickerButton: View, Equatable {
    let word: String
    let isSelected: Bool
    let action: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.word == rhs.word && lhs.isSelected == rhs.isSelected
    }

    var body: some View {
        Button(action: action) {
            Text(word)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .padding(.horizontal, 14)
                .frame(height: 54)
                .background(
                    isSelected ? Color.blue : Color.blue.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 14)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 3)
                }
        }
        .buttonStyle(.plain)
        .scaleEffect(isSelected ? 1.06 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isSelected)
        .accessibilityLabel("Wort \(word)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
