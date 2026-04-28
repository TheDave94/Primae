import SwiftUI

struct LetterPickerBar: View {
    @Environment(TracingViewModel.self) private var vm

    private let demoLetters: Set<String> = ["A", "F", "I", "K", "L", "M", "O"]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // Mirror the nav-arrow source list so the bar's letters
                // and the ◀ ▶ buttons agree on what's reachable. Earlier
                // this used `allLetterNames`, which surfaced the full
                // alphabet even while the visibility toggle was off.
                ForEach(vm.visibleLetterNames, id: \.self) { name in
                    LetterPickerButton(
                        name: name,
                        isSelected: name == vm.currentLetterName,
                        completionState: completionState(for: name),
                        isDimmed: !vm.showAllLetters && !demoLetters.contains(name.uppercased())
                    ) {
                        vm.loadLetter(name: name)
                    }
                    .equatable()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private func completionState(for name: String) -> LetterCompletionState {
        let prog = vm.progressStore.progress(for: name)
        if prog.completionCount > 0 { return .complete }
        if prog.bestAccuracy > 0 { return .partial }
        return .notStarted
    }
}

enum LetterCompletionState: Equatable {
    case complete, partial, notStarted
}

/// Equatable so callers can wrap in `.equatable()` and SwiftUI skips
/// body re-evaluation while only unrelated VM state changes (audio
/// state, recognition flags, freeform buffers, …). The action closure
/// is intentionally excluded from `==`: it's reconstructed every render
/// from `vm.loadLetter` regardless of whether anything changed, so
/// including it would defeat the gate. Identity is fine — the closure
/// only fires after a tap, and at tap time the value-prop snapshot
/// already captures whatever the button visually represented.
private struct LetterPickerButton: View, Equatable {
    let name: String
    let isSelected: Bool
    let completionState: LetterCompletionState
    let isDimmed: Bool
    let action: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name == rhs.name
        && lhs.isSelected == rhs.isSelected
        && lhs.completionState == rhs.completionState
        && lhs.isDimmed == rhs.isDimmed
    }

    var body: some View {
        Button(action: action) {
            Text(name)
                .font(.system(.title, design: .rounded).weight(.bold))
                .foregroundStyle(textColor)
                .frame(width: 54, height: 54)
                .background(backgroundColor, in: RoundedRectangle(cornerRadius: 14))
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 3)
                }
        }
        .buttonStyle(.plain)
        .opacity(isDimmed ? 0.3 : 1)
        .scaleEffect(isSelected ? 1.08 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isSelected)
        .accessibilityLabel(name)
        .accessibilityHint("Tippen, um diesen Buchstaben zu üben")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var backgroundColor: Color {
        switch completionState {
        // Shared token with FortschritteWorldView gallery so a "mastered"
        // letter looks identical in the picker and the gallery.
        case .complete:   return AppSurface.mastered
        // Tint slightly darker + desaturated so the paired brown text meets
        // WCAG AA (was yellow.opacity(0.3) with .orange ≈ 2.5:1 — fail).
        case .partial:    return Color(red: 1.00, green: 0.88, blue: 0.60)
        case .notStarted: return .gray.opacity(0.12)
        }
    }

    private var textColor: Color {
        switch completionState {
        case .complete:   return AppSurface.masteredText
        // Dark brown over the honey-yellow fill above ≈ 4.7:1 — WCAG AA pass
        // for large bold text and also meets AA-Normal (4.5:1).
        case .partial:    return Color(red: 0.40, green: 0.20, blue: 0.00)
        case .notStarted: return .primary
        }
    }
}
