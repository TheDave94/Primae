import SwiftUI

struct LetterPickerBar: View {
    @Environment(TracingViewModel.self) private var vm

    private let demoLetters: Set<String> = ["A", "F", "I", "K", "L", "M", "O"]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(vm.allLetterNames, id: \.self) { name in
                    LetterPickerButton(
                        name: name,
                        isSelected: name == vm.currentLetterName,
                        completionState: completionState(for: name),
                        isDimmed: !vm.showAllLetters && !demoLetters.contains(name.uppercased())
                    ) {
                        vm.loadLetter(name: name)
                    }
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

enum LetterCompletionState {
    case complete, partial, notStarted
}

private struct LetterPickerButton: View {
    let name: String
    let isSelected: Bool
    let completionState: LetterCompletionState
    let isDimmed: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(name)
                .font(.system(size: 28, weight: .bold, design: .rounded))
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
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var backgroundColor: Color {
        switch completionState {
        case .complete:   return .green.opacity(0.25)
        case .partial:    return .yellow.opacity(0.3)
        case .notStarted: return .gray.opacity(0.12)
        }
    }

    private var textColor: Color {
        switch completionState {
        case .complete:   return .green
        case .partial:    return .orange
        case .notStarted: return .primary
        }
    }
}
