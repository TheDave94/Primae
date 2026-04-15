// StrokeCalibrationOverlay.swift
// BuchstabenNative
//
// Interactive overlay for calibrating stroke checkpoint positions.
// Shown when Debug mode is active. Drag dots to align with letter strokes,
// then tap "Export JSON" to copy updated coordinates.

import SwiftUI

struct StrokeCalibrationOverlay: View {
    @Environment(TracingViewModel.self) private var vm

    let canvasSize: CGSize

    @State private var editableStrokes: [[CGPoint]] = []
    @State private var showExport = false
    @State private var exportText = ""
    @State private var loaded = false

    private let strokeColors: [Color] = [.red, .blue, .green, .orange, .purple, .pink]

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                // Draggable checkpoint dots
                ForEach(Array(editableStrokes.enumerated()), id: \.offset) { si, stroke in
                    ForEach(Array(stroke.enumerated()), id: \.offset) { ci, pt in
                        let screenPt = glyphToScreen(pt, in: size)
                        Circle()
                            .fill(strokeColors[si % strokeColors.count])
                            .frame(width: 30, height: 30)
                            .overlay(
                                Text("\(ci + 1)")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.white)
                            )
                            .shadow(color: .black.opacity(0.5), radius: 3)
                            .position(screenPt)
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        let newGlyph = screenToGlyph(value.location, in: size)
                                        editableStrokes[si][ci] = newGlyph
                                    }
                            )

                        // Stroke label on first checkpoint
                        if ci == 0 {
                            Text("S\(si + 1)")
                                .font(.system(size: 13, weight: .heavy, design: .monospaced))
                                .foregroundStyle(strokeColors[si % strokeColors.count])
                                .shadow(color: .black, radius: 2)
                                .position(x: screenPt.x - 22, y: screenPt.y - 22)
                        }
                    }
                }

                // Stroke path lines
                ForEach(Array(editableStrokes.enumerated()), id: \.offset) { si, stroke in
                    Path { path in
                        let pts = stroke.map { glyphToScreen($0, in: size) }
                        guard let first = pts.first else { return }
                        path.move(to: first)
                        for pt in pts.dropFirst() {
                            path.addLine(to: pt)
                        }
                    }
                    .stroke(strokeColors[si % strokeColors.count].opacity(0.5),
                            style: StrokeStyle(lineWidth: 2, dash: [6, 3]))
                }

                // Controls at bottom
                VStack {
                    Spacer()
                    HStack(spacing: 12) {
                        Button("Export JSON") {
                            exportText = generateJSON()
                            showExport = true
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)

                        Button("Reset") {
                            loadFromVM()
                        }
                        .buttonStyle(.bordered)

                        Button("Apply") {
                            applyToVM()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                    }
                    .padding(.bottom, 40)
                }
            }
            .onAppear { if !loaded { loadFromVM(); loaded = true } }
            .onChange(of: vm.currentLetterName) { loadFromVM() }
        }
        .sheet(isPresented: $showExport) {
            ExportSheet(text: exportText, letterName: vm.currentLetterName)
        }
    }

    // MARK: - Coordinate conversion

    private func glyphRect(in size: CGSize) -> CGRect {
        PrimaeLetterRenderer.normalizedGlyphRect(for: vm.currentLetterName, canvasSize: size)
            ?? CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
    }

    private func glyphToScreen(_ pt: CGPoint, in size: CGSize) -> CGPoint {
        let gr = glyphRect(in: size)
        return CGPoint(
            x: (gr.minX + pt.x * gr.width) * size.width,
            y: (gr.minY + pt.y * gr.height) * size.height
        )
    }

    private func screenToGlyph(_ pt: CGPoint, in size: CGSize) -> CGPoint {
        let gr = glyphRect(in: size)
        let x = ((pt.x / size.width) - gr.minX) / gr.width
        let y = ((pt.y / size.height) - gr.minY) / gr.height
        return CGPoint(
            x: max(0, min(1, (x * 100).rounded() / 100)),
            y: max(0, min(1, (y * 100).rounded() / 100))
        )
    }

    // MARK: - Data

    private func loadFromVM() {
        guard let def = vm.strokeTrackerDefinition else { return }
        // Convert from canvas-normalised back to glyph-relative
        let gr = PrimaeLetterRenderer.normalizedGlyphRect(for: vm.currentLetterName, canvasSize: canvasSize)
            ?? CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)

        editableStrokes = def.strokes.map { stroke in
            stroke.checkpoints.map { cp in
                CGPoint(
                    x: gr.width > 0 ? (cp.x - gr.minX) / gr.width : cp.x,
                    y: gr.height > 0 ? (cp.y - gr.minY) / gr.height : cp.y
                )
            }
        }
    }

    private func applyToVM() {
        vm.applyCalibration(editableStrokes)
    }

    private func generateJSON() -> String {
        var dict: [String: Any] = [
            "letter": vm.currentLetterName,
            "checkpointRadius": 0.05
        ]
        let strokesArr: [[String: Any]] = editableStrokes.enumerated().map { (i, pts) in
            [
                "id": i + 1,
                "comment": "Stroke \(i + 1)",
                "checkpoints": pts.map { ["x": $0.x, "y": $0.y] }
            ]
        }
        dict["strokes"] = strokesArr
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }
}

// MARK: - Export sheet

private struct ExportSheet: View {
    let text: String
    let letterName: String
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text("Copy this JSON into:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Letters/\(letterName)/strokes.json")
                    .font(.system(.body, design: .monospaced))
                    .bold()

                ScrollView {
                    Text(text)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                Button(copied ? "Copied ✓" : "Copy to Clipboard") {
                    UIPasteboard.general.string = text
                    copied = true
                }
                .buttonStyle(.borderedProminent)
                .tint(copied ? .green : .blue)
            }
            .padding()
            .navigationTitle("Stroke JSON")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
