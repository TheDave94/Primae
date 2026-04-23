import SwiftUI

/// Top-of-screen picker with two tabs: "Buchstaben" (the existing
/// single-letter tile row) and "Wörter" (curated Austrian Volksschule
/// word-tracing list). Replaces the standalone `LetterPickerBar` —
/// `LetterPickerBar` is still used internally for the Buchstaben tab
/// so the single-letter flow is untouched.
///
/// Selecting a word tile calls `vm.loadWord(_:)` which builds a
/// `.word` sequence; the grid engine handles per-cell layout, and
/// Schreibschrift words get proper CoreText cursive ligatures via
/// `PrimaeLetterRenderer.renderWord`.
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

/// Curated word tiles for the "Wörter" tab. Source list comes from
/// `TracingViewModel.demoWordList` — see commit 5's commit message for
/// the Austrian Volksschule research that picked these words.
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
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }
}

private struct WordPickerButton: View {
    let word: String
    let isSelected: Bool
    let action: () -> Void

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
