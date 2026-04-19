// DebugAudioPanel.swift
// BuchstabenNative
//
// Debug-only floating panel that surfaces every audio-tuning knob as a
// live slider so a researcher can dial in fade-out, debounce windows,
// velocity thresholds and the time-stretch curve while a child is
// actually tracing — no rebuild needed.
//
// Wrapped in #if DEBUG at the use site (ContentView) so the panel and
// its bindings disappear from release builds entirely.

#if DEBUG
import SwiftUI

struct DebugAudioPanel: View {

    @Bindable var vm: TracingViewModel
    @State private var collapsed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !collapsed {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        section("Timing") {
                            row("Audio fade-out",  $vm.tuneFadeOutSeconds,
                                range: 0...0.5,    unit: "s",  step: 0.01)
                            row("Idle debounce (Fingerheben)", $vm.tuneIdleDebounce,
                                range: 0...0.5,    unit: "s",  step: 0.01)
                            row("Active debounce", $vm.tuneActiveDebounce,
                                range: 0...0.2,    unit: "s",  step: 0.005)
                            row("Play-intent dedup", $vm.tunePlayIntentDedup,
                                range: 0...0.5,    unit: "s",  step: 0.01)
                        }
                        section("Velocity") {
                            row("Activation threshold", $vm.tuneVelocityThreshold,
                                range: 0...100,    unit: "pt/s", step: 1, format: "%.0f")
                            row("Smoothing α",  $vm.tuneVelocitySmoothing,
                                range: 0...1,      unit: "",     step: 0.01)
                            row("Min move",     $vm.tuneMinMoveDistance,
                                range: 0...10,     unit: "pt",   step: 0.1)
                        }
                        section("Time-stretch") {
                            row("Min rate",     $vm.tuneMinPlaybackRate,
                                range: 0.25...1,   unit: "×",    step: 0.05)
                            row("Max rate",     $vm.tuneMaxPlaybackRate,
                                range: 1...3,      unit: "×",    step: 0.05)
                            row("Pitch (cents)", $vm.tunePitchCents,
                                range: -1200...1200, unit: "c", step: 25, format: "%.0f")
                        }
                    }
                    .padding(14)
                }
                .frame(maxHeight: 360)
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.2), lineWidth: 1))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .frame(maxWidth: 380)
    }

    // MARK: - Subviews

    private var header: some View {
        HStack {
            Image(systemName: "speaker.wave.3.fill")
                .foregroundStyle(.secondary)
            Text("Audio-Tuning (Debug)")
                .font(.headline)
            Spacer()
            Button(action: { collapsed.toggle() }) {
                Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
                .tracking(0.6)
            content()
        }
    }

    // Generic row supporting both Float-typed and CGFloat/TimeInterval-typed knobs.
    @ViewBuilder
    private func row<Value: BinaryFloatingPoint>(
        _ label: String,
        _ value: Binding<Value>,
        range: ClosedRange<Value>,
        unit: String,
        step: Value,
        format: String = "%.2f"
    ) -> some View where Value.Stride: BinaryFloatingPoint {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.primary)
                .frame(width: 150, alignment: .leading)
            Slider(value: value, in: range, step: step)
                .controlSize(.small)
            Text("\(String(format: format, Double(value.wrappedValue)))\(unit.isEmpty ? "" : " \(unit)")")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
        }
    }
}
#endif
