// RecognitionFeedbackView.swift
// BuchstabenNative
//
// Shows a child-friendly badge with the CoreML recognition result after
// the freeWrite KP overlay dismisses. Color and message depend on
// whether the prediction was correct and how confident the model was:
//   • green  (correct & confident): "Du hast ein A geschrieben! 🎉"
//   • yellow (correct & uncertain): "Das sieht aus wie ein A — gut gemacht!"
//   • orange (wrong   & confident): "Das sieht aus wie ein O — versuche nochmal A!"
// When raw confidence is below 0.4 the recognizer is too unsure to show
// anything, and the caller falls back to the Fréchet score alone.
//
// Auto-dismisses after 4 seconds or on tap.

import SwiftUI

struct RecognitionFeedbackView: View {
    let result: RecognitionResult
    let expectedLetter: String
    let onDismiss: () -> Void

    var body: some View {
        Group {
            if let style = feedbackStyle {
                HStack(spacing: 12) {
                    Image(systemName: style.icon)
                        .font(.title2)
                        .foregroundStyle(.white)
                    Text(style.message)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.leading)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .background(style.tint, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
                .onTapGesture { onDismiss() }
                .task {
                    try? await Task.sleep(for: .seconds(4))
                    onDismiss()
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(style.message)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Tippen um die Rückmeldung zu schließen")
            } else {
                // Confidence < 0.4 — model is unsure, show nothing so the
                // child isn't distracted by a meaningless badge. Caller's
                // Fréchet-based feedback path remains the primary signal.
                Color.clear.frame(height: 0)
            }
        }
    }

    // MARK: - Style selection

    private struct Style {
        let tint: Color
        let icon: String
        let message: String
    }

    private var feedbackStyle: Style? {
        let conf = result.confidence
        if conf < 0.4 { return nil }

        if result.isCorrect {
            if conf > 0.7 {
                return Style(
                    tint: .green,
                    icon: "checkmark.circle.fill",
                    message: "Du hast ein \(expectedLetter) geschrieben! 🎉"
                )
            } else {
                return Style(
                    tint: .yellow,
                    icon: "hand.thumbsup.fill",
                    message: "Das sieht aus wie ein \(expectedLetter) — gut gemacht!"
                )
            }
        }

        if conf > 0.7 {
            return Style(
                tint: .orange,
                icon: "arrow.triangle.2.circlepath",
                message: "Das sieht aus wie ein \(result.predictedLetter) — versuche nochmal \(expectedLetter)!"
            )
        }
        // conf in (0.4, 0.7] but wrong — model isn't confident enough to
        // confuse the child with a correction message. Stay silent.
        return nil
    }
}

#if DEBUG
#Preview("Green") {
    RecognitionFeedbackView(
        result: RecognitionResult(
            predictedLetter: "A",
            confidence: 0.92,
            topThree: [.init(letter: "A", confidence: 0.92)],
            isCorrect: true
        ),
        expectedLetter: "A",
        onDismiss: {}
    )
    .padding()
}

#Preview("Yellow") {
    RecognitionFeedbackView(
        result: RecognitionResult(
            predictedLetter: "A",
            confidence: 0.55,
            topThree: [.init(letter: "A", confidence: 0.55)],
            isCorrect: true
        ),
        expectedLetter: "A",
        onDismiss: {}
    )
    .padding()
}

#Preview("Orange") {
    RecognitionFeedbackView(
        result: RecognitionResult(
            predictedLetter: "O",
            confidence: 0.82,
            topThree: [.init(letter: "O", confidence: 0.82)],
            isCorrect: false
        ),
        expectedLetter: "A",
        onDismiss: {}
    )
    .padding()
}
#endif
