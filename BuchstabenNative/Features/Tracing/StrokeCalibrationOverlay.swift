// StrokeCalibrationOverlay.swift
// BuchstabenNative
//
// Interactive overlay for calibrating stroke checkpoint positions.
// Shown when Debug mode is active. Drag dots, add new ones, delete existing,
// then tap "Export JSON" to copy updated coordinates.

import SwiftUI

struct StrokeCalibrationOverlay: View {
    @Environment(TracingViewModel.self) private var vm

    let canvasSize: CGSize

    @State private var editableStrokes: [[CGPoint]] = []
    @State private var showExport = false
    @State private var exportText = ""
    @State private var loaded = false
    @State private var activeStroke = 0
    @State private var mode: CalibrationMode = .drag

    enum CalibrationMode: String, CaseIterable {
        case drag = "Drag"
        case add = "Add"
        case delete = "Delete"
    }

    private let strokeColors: [Color] = [.red, .blue, .green, .orange, .purple, .pink, .cyan, .yellow]

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                // Tap target for adding points
                if mode == .add {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { location in
                            let glyph = screenToGlyph(location, in: size)
                            addCheckpoint(glyph)
                        }
                }

                // Stroke path lines
                ForEach(Array(editableStrokes.enumerated()), id: \.offset) { si, stroke in
                    Path { path in
                        let pts = stroke.map { glyphToScreen($0, in: size) }
                        guard let first = pts.first else { return }
                        path.move(to: first)
                        for pt in pts.dropFirst() { path.addLine(to: pt) }
                    }
                    .stroke(strokeColors[si % strokeColors.count].opacity(si == activeStroke ? 0.7 : 0.3),
                            style: StrokeStyle(lineWidth: si == activeStroke ? 3 : 1.5, dash: [6, 3]))
                }

                // Draggable/tappable checkpoint dots
                ForEach(Array(editableStrokes.enumerated()), id: \.offset) { si, stroke in
                    ForEach(Array(stroke.enumerated()), id: \.offset) { ci, pt in
                        let screenPt = glyphToScreen(pt, in: size)
                        let color = strokeColors[si % strokeColors.count]
                        let isActive = si == activeStroke

                        Circle()
                            .fill(color.opacity(isActive ? 1 : 0.4))
                            .frame(width: isActive ? 32 : 22, height: isActive ? 32 : 22)
                            .overlay(
                                Text("\(ci + 1)")
                                    .font(.system(size: isActive ? 12 : 9, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.white)
                            )
                            .shadow(color: .black.opacity(0.5), radius: 2)
                            .position(screenPt)
                            .gesture(
                                mode == .drag ?
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        let newGlyph = screenToGlyph(value.location, in: size)
                                        editableStrokes[si][ci] = newGlyph
                                    } : nil
                            )
                            .onTapGesture {
                                if mode == .delete {
                                    deleteCheckpoint(si: si, ci: ci)
                                } else {
                                    activeStroke = si
                                }
                            }

                        // Stroke label on first checkpoint
                        if ci == 0 {
                            Text("S\(si + 1)")
                                .font(.system(size: 14, weight: .heavy, design: .monospaced))
                                .foregroundStyle(color)
                                .shadow(color: .black, radius: 2)
                                .position(x: screenPt.x - 24, y: screenPt.y - 24)
                        }
                    }
                }

                // Controls
                VStack {
                    // Top: mode picker + stroke selector
                    HStack(spacing: 8) {
                        ForEach(CalibrationMode.allCases, id: \.self) { m in
                            Button(m.rawValue) { mode = m }
                                .font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(mode == m ? Color.white.opacity(0.2) : Color.clear)
                                .foregroundStyle(mode == m ? .white : .gray)
                                .clipShape(Capsule())
                                .overlay(Capsule().stroke(mode == m ? Color.white.opacity(0.4) : Color.clear))
                        }

                        Divider().frame(height: 20)

                        ForEach(Array(editableStrokes.indices), id: \.self) { si in
                            Button("S\(si + 1)") { activeStroke = si }
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(activeStroke == si ? strokeColors[si % strokeColors.count].opacity(0.3) : Color.clear)
                                .foregroundStyle(strokeColors[si % strokeColors.count])
                                .clipShape(Capsule())
                        }

                        Button("+Stroke") { addStroke() }
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.green)
                    }
                    .padding(8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .padding(.top, 50)

                    Spacer()

                    // Bottom: actions
                    HStack(spacing: 12) {
                        Button("Reset") { loadFromVM() }
                            .buttonStyle(.bordered)
                            .tint(.gray)

                        Button("Apply") { applyToVM() }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)

                        Button("Export JSON") {
                            exportText = generateJSON()
                            showExport = true
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)

                        if editableStrokes.indices.contains(activeStroke) {
                            Button("Del Stroke \(activeStroke + 1)") {
                                deleteStroke(activeStroke)
                            }
                            .buttonStyle(.bordered)
                            .tint(.red)
                        }
                    }
                    .padding(8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
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
            x: max(-0.05, min(1.05, (x * 100).rounded() / 100)),
            y: max(-0.05, min(1.05, (y * 100).rounded() / 100))
        )
    }

    // MARK: - Editing

    private func addCheckpoint(_ pt: CGPoint) {
        while editableStrokes.count <= activeStroke {
            editableStrokes.append([])
        }
        editableStrokes[activeStroke].append(pt)
    }

    private func deleteCheckpoint(si: Int, ci: Int) {
        guard editableStrokes.indices.contains(si),
              editableStrokes[si].indices.contains(ci) else { return }
        editableStrokes[si].remove(at: ci)
        if editableStrokes[si].isEmpty {
            deleteStroke(si)
        }
    }

    private func addStroke() {
        editableStrokes.append([])
        activeStroke = editableStrokes.count - 1
        mode = .add
    }

    private func deleteStroke(_ idx: Int) {
        guard editableStrokes.indices.contains(idx) else { return }
        editableStrokes.remove(at: idx)
        activeStroke = max(0, min(activeStroke, editableStrokes.count - 1))
    }

    // MARK: - Data

    private func loadFromVM() {
        // Load directly from raw glyph-relative JSON — no round-trip through
        // the canvas-mapped tracker, which would corrupt coords if sizes differ.
        guard let raw = vm.glyphRelativeStrokes else { return }
        editableStrokes = raw.strokes.map { stroke in
            stroke.checkpoints.map { cp in
                CGPoint(x: CGFloat(cp.x), y: CGFloat(cp.y))
            }
        }
        activeStroke = 0
    }

    private func applyToVM() {
        vm.applyCalibration(editableStrokes)
    }

    private func generateJSON() -> String {
        var dict: [String: Any] = [
            "letter": vm.currentLetterName,
            "checkpointRadius": 0.05
        ]
        let strokesArr: [[String: Any]] = editableStrokes.enumerated().compactMap { (i, pts) in
            guard !pts.isEmpty else { return nil }
            return [
                "id": i + 1,
                "comment": "Stroke \(i + 1)",
                "checkpoints": pts.map { ["x": round($0.x * 1000) / 1000, "y": round($0.y * 1000) / 1000] }
            ] as [String: Any]
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
