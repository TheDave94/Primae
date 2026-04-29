// StrokeCalibrationOverlay.swift
// PrimaeNative
//
// Interactive overlay for calibrating stroke checkpoint positions.
// Shown when Debug mode is active. Drag dots, add / delete them, switch
// between strokes, and persist the result per-script directly — JSON
// export is still available as a secondary action for backup.

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
    @State private var savedFlashUntil: Date? = nil
    /// (letter, schriftArt) pair used for the last reload. A change in either
    /// must reload from disk so switching font while calibrating picks up the
    /// other script's saved strokes instead of keeping stale edit state.
    @State private var loadedKey: LoadKey? = nil

    private struct LoadKey: Equatable {
        let letter: String
        let schriftArt: SchriftArt
    }

    enum CalibrationMode: String, CaseIterable {
        case drag = "Drag"
        case add = "Add"
        case delete = "Delete"
    }

    private let strokeColors: [Color] = [.red, .blue, .green, .orange, .purple, .pink, .cyan, .yellow]

    private var isSaved: Bool {
        guard let until = savedFlashUntil else { return false }
        return Date() < until
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                addTapLayer(in: size)
                glyphRectDebugLayer(in: size)
                strokePathsLayer(in: size)
                dotsLayer(in: size)
                controlsLayer
            }
            .onAppear { loadFromVM() }
            .onChange(of: vm.currentLetterName) { loadFromVM() }
            .onChange(of: vm.schriftArt) { loadFromVM(force: true) }
        }
        .sheet(isPresented: $showExport) {
            ExportSheet(text: exportText, letterName: vm.currentLetterName)
        }
    }

    // MARK: - Canvas layers

    @ViewBuilder
    private func addTapLayer(in size: CGSize) -> some View {
        if mode == .add {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { location in
                    let glyph = screenToGlyph(location, in: size)
                    addCheckpoint(glyph)
                }
        }
    }

    /// Dashed red outline of `PrimaeLetterRenderer.normalizedGlyphRect` for
    /// the current (letter, schriftArt). Lets us spot-check whether the
    /// coordinate system used to place dots lines up with the visible glyph:
    /// if the rect isn't wrapping the rendered glyph, the glyph-rel coords
    /// stored in JSON will also be off on render.
    @ViewBuilder
    private func glyphRectDebugLayer(in size: CGSize) -> some View {
        let gr = glyphRect(in: size)
        let rect = CGRect(
            x: gr.minX * size.width,
            y: gr.minY * size.height,
            width: gr.width * size.width,
            height: gr.height * size.height
        )
        Path { p in p.addRect(rect) }
            .stroke(Color.red.opacity(0.6),
                    style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private func strokePathsLayer(in size: CGSize) -> some View {
        // Only render the dashed path for the active stroke. Drawing every
        // stroke's dashed polyline on top of the letter turns the glyph into
        // an unreadable crosshatch — the inactive strokes still show their
        // start dot as a tap-target for switching, which is all the user
        // needs to orient between strokes.
        if editableStrokes.indices.contains(activeStroke) {
            let stroke = editableStrokes[activeStroke]
            Path { path in
                let pts = stroke.map { glyphToScreen($0, in: size) }
                guard let first = pts.first else { return }
                path.move(to: first)
                for pt in pts.dropFirst() { path.addLine(to: pt) }
            }
            .stroke(
                strokeColors[activeStroke % strokeColors.count].opacity(0.7),
                style: StrokeStyle(lineWidth: 3, dash: [6, 3])
            )
        }
    }

    @ViewBuilder
    private func dotsLayer(in size: CGSize) -> some View {
        ForEach(Array(editableStrokes.enumerated()), id: \.offset) { si, stroke in
            if si == activeStroke {
                // Full numbered checkpoint chain for the stroke being edited.
                ForEach(Array(stroke.enumerated()), id: \.offset) { ci, pt in
                    checkpointDot(si: si, ci: ci, pt: pt, in: size)
                    if ci == 0 {
                        strokeLabel(si: si, pt: pt, in: size)
                    }
                }
            } else if let first = stroke.first {
                // Inactive strokes: just the start dot, faded, as a tap-to-
                // switch target. Keeps the letter visible under the overlay.
                checkpointDot(si: si, ci: 0, pt: first, in: size)
                strokeLabel(si: si, pt: first, in: size)
            }
        }
    }

    @ViewBuilder
    private func checkpointDot(si: Int, ci: Int, pt: CGPoint, in size: CGSize) -> some View {
        let screenPt = glyphToScreen(pt, in: size)
        let color = strokeColors[si % strokeColors.count]
        let isActive = si == activeStroke
        let diameter: CGFloat = isActive ? 32 : 20
        let fontSize: CGFloat = isActive ? 12 : 9

        // Inactive start dots are only a switcher hint — keep them small and
        // faint so the glyph underneath stays readable while calibrating.
        Circle()
            .fill(color.opacity(isActive ? 1 : 0.35))
            .frame(width: diameter, height: diameter)
            .overlay(
                Text("\(ci + 1)")
                    .font(.system(size: fontSize, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
            )
            .shadow(color: .black.opacity(0.5), radius: 2)
            .position(screenPt)
            .gesture(
                // Dragging any dot — active or not — switches the active
                // stroke to the one being edited. Cross-stroke editing on the
                // fly shouldn't require a separate tap to activate first.
                mode == .drag
                    ? DragGesture(minimumDistance: 0).onChanged { value in
                        if activeStroke != si { activeStroke = si }
                        editableStrokes[si][ci] = screenToGlyph(value.location, in: size)
                    }
                    : nil
            )
            .onTapGesture {
                if mode == .delete {
                    deleteCheckpoint(si: si, ci: ci)
                } else {
                    activeStroke = si
                }
            }
    }

    @ViewBuilder
    private func strokeLabel(si: Int, pt: CGPoint, in size: CGSize) -> some View {
        let screenPt = glyphToScreen(pt, in: size)
        let color = strokeColors[si % strokeColors.count]
        Text("S\(si + 1)")
            .font(.system(size: 14, weight: .heavy, design: .monospaced))
            .foregroundStyle(color)
            .shadow(color: .black, radius: 2)
            .position(x: screenPt.x - 24, y: screenPt.y - 24)
    }

    // MARK: - Controls

    @ViewBuilder
    private var controlsLayer: some View {
        VStack {
            topBar
                .padding(10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                // Sits just below the debug toggle chips. An earlier bump to
                // 110 pushed the bar down into the letter's top and covered
                // apexes (e.g. A, F). 50 keeps it flush under the chips and
                // above the letter render area on all demo letters.
                .padding(.top, 50)

            if mode == .add {
                Text("Tippe um Punkt zu setzen")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
            }

            Spacer()

            bottomBar
                .padding(10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding(.bottom, 40)
        }
    }

    @ViewBuilder
    private var topBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Label(vm.schriftArt.displayName, systemImage: "textformat")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.white.opacity(0.12), in: Capsule())
                    .foregroundStyle(.white)
                    .accessibilityLabel("Schriftart: \(vm.schriftArt.displayName)")

                Spacer(minLength: 0)

                ForEach(CalibrationMode.allCases, id: \.self) { m in
                    modeButton(m)
                }
            }

            HStack(spacing: 8) {
                ForEach(Array(editableStrokes.indices), id: \.self) { si in
                    strokeChip(si: si)
                }

                Button {
                    addStroke()
                } label: {
                    Label("Strich", systemImage: "plus.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.green)

                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private func modeButton(_ m: CalibrationMode) -> some View {
        let selected = mode == m
        Button(m.rawValue) { mode = m }
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(selected ? Color.white.opacity(0.2) : Color.clear)
            .foregroundStyle(selected ? Color.white : Color.gray)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(selected ? Color.white.opacity(0.4) : Color.clear))
    }

    @ViewBuilder
    private func strokeChip(si: Int) -> some View {
        let color = strokeColors[si % strokeColors.count]
        let selected = activeStroke == si
        Button("S\(si + 1)") { activeStroke = si }
            .font(.system(size: 12, weight: .bold, design: .monospaced))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(selected ? color.opacity(0.35) : Color.clear)
            .foregroundStyle(color)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(selected ? color : Color.clear, lineWidth: 1.5))
    }

    @ViewBuilder
    private var bottomBar: some View {
        HStack(spacing: 10) {
            Button("Reset") { loadFromVM(force: true) }
                .buttonStyle(.bordered)
                .tint(.gray)

            Button("Undo") { undoLastCheckpoint() }
                .buttonStyle(.bordered)
                .tint(.indigo)
                .disabled(!canUndo)

            if editableStrokes.indices.contains(activeStroke) {
                Button {
                    deleteStroke(activeStroke)
                } label: {
                    Label("Strich \(activeStroke + 1)", systemImage: "trash")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }

            Spacer(minLength: 0)

            Button("Apply") { applyToVM() }
                .buttonStyle(.bordered)
                .tint(.blue)

            saveButton

            Button("JSON") {
                exportText = generateJSON()
                showExport = true
            }
            .buttonStyle(.bordered)
            .tint(.orange)
        }
    }

    @ViewBuilder
    private var saveButton: some View {
        let saved = isSaved
        let title = saved ? "Gespeichert ✓" : "Speichern"
        let icon = saved ? "checkmark.circle.fill" : "square.and.arrow.down.fill"
        Button {
            saveToVM()
        } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 13, weight: .bold))
        }
        .buttonStyle(.borderedProminent)
        .tint(saved ? Color.green : Color.purple)
        .animation(.easeInOut(duration: 0.15), value: saved)
    }

    // MARK: - Coordinate conversion

    private func glyphRect(in size: CGSize) -> CGRect {
        PrimaeLetterRenderer.normalizedGlyphRect(for: vm.currentLetterName, canvasSize: size, schriftArt: vm.schriftArt)
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

    private var canUndo: Bool {
        editableStrokes.indices.contains(activeStroke) && !editableStrokes[activeStroke].isEmpty
    }

    private func undoLastCheckpoint() {
        guard editableStrokes.indices.contains(activeStroke),
              !editableStrokes[activeStroke].isEmpty else { return }
        editableStrokes[activeStroke].removeLast()
        if editableStrokes[activeStroke].isEmpty {
            deleteStroke(activeStroke)
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

    /// Load the raw glyph-relative JSON for the current (letter, schriftArt)
    /// pair. `force: true` reloads even if the same pair is already loaded —
    /// used for Reset and explicit font switches so edits are thrown away
    /// on-demand. The default call only re-reads when the pair actually
    /// changed to avoid clobbering in-flight edits on every view update.
    private func loadFromVM(force: Bool = false) {
        let key = LoadKey(letter: vm.currentLetterName, schriftArt: vm.schriftArt)
        if !force, loaded, loadedKey == key { return }
        guard let raw = vm.glyphRelativeStrokes else { return }
        editableStrokes = raw.strokes.map { stroke in
            stroke.checkpoints.map { cp in
                CGPoint(x: CGFloat(cp.x), y: CGFloat(cp.y))
            }
        }
        activeStroke = 0
        loadedKey = key
        loaded = true
        savedFlashUntil = nil
    }

    private func applyToVM() {
        vm.applyCalibration(editableStrokes)
    }

    /// Apply the current edits to the live tracker AND persist them to the
    /// per-script calibration file. This is the primary save path — parents
    /// don't need to visit the JSON export sheet to make their tuning
    /// survive a relaunch.
    private func saveToVM() {
        vm.applyCalibration(editableStrokes)
        vm.persistCalibratedStrokes(editableStrokes, for: vm.currentLetterName)
        savedFlashUntil = Date().addingTimeInterval(1.2)
        // Clear the badge after the flash window so a second save shows the
        // check again instead of sticking green forever.
        Task {
            try? await Task.sleep(for: .milliseconds(1300))
            if let until = savedFlashUntil, Date() >= until {
                savedFlashUntil = nil
            }
        }
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
                Text("JSON in diese Datei kopieren:")
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

                Button(copied ? "Kopiert ✓" : "In Zwischenablage kopieren") {
                    UIPasteboard.general.string = text
                    copied = true
                }
                .buttonStyle(.borderedProminent)
                .tint(copied ? .green : .blue)
            }
            .padding()
            .navigationTitle("Stroke-JSON")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
    }
}
