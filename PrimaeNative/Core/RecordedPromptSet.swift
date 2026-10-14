// RecordedPromptSet.swift
// PrimaeNative
//
// The five recorded phrases a study child hears (protocol r9, D15):
// "Schau genau hin." / "Jetzt du." / "Und jetzt ganz allein." /
// "Probier's nochmal." / "Super gemacht!", voice Kiki. Their bytes are
// pinned by `Resources/Prompts/MANIFEST.json` (CI: scripts/check_study_prompts.py).
//
// A study session that speaks needs ALL FIVE bundled; a missing one refuses
// the session (`refusal`) instead of falling back to the system voice, which
// would say that line differently than it did for the children before.
// Every exported row names the set that was played (`setId`).

import CryptoKit
import Foundation

enum RecordedPromptSet {
    /// The required takes, in the order the set id hashes them (the order of
    /// MANIFEST.json "files").
    static let requiredKeys: [PromptPlayer.PromptKey] = [
        .phaseObserve, .phaseGuided, .phaseFreeWrite, .retryCue, .celebration,
    ]
    /// Written into `setId`; must match MANIFEST.json "voice", lowercased.
    static let voiceName = "kiki"

    /// Required keys with no bundled file.
    static func missing(
        locate: @MainActor (PromptPlayer.PromptKey) -> URL? = PromptPlayer.locate
    ) -> [PromptPlayer.PromptKey] {
        requiredKeys.filter { locate($0) == nil }
    }

    /// "rec:kiki:" + the first 12 hex of sha256 over the five files' bytes,
    /// concatenated in `requiredKeys` order; nil when a file is missing or
    /// unreadable. This is the `voiceId` stamped on every row of a session
    /// that plays the recorded set.
    static func setId(
        locate: @MainActor (PromptPlayer.PromptKey) -> URL? = PromptPlayer.locate,
        read: (URL) -> Data? = { try? Data(contentsOf: $0) }
    ) -> String? {
        var hasher = SHA256()
        for key in requiredKeys {
            guard let url = locate(key), let data = read(url) else { return nil }
            hasher.update(data: data)
        }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return "rec:\(voiceName):\(hex.prefix(12))"
    }

    /// What a session finds when it checks the five takes (once, at init).
    enum Verdict: Equatable {
        /// All five present and hashing to the manifest's set id.
        case ok(String)
        /// These takes are not bundled.
        case missing([PromptPlayer.PromptKey])
        /// All present, but the bytes are not the reviewed ones: the set id
        /// they produce (nil: a file is unreadable) differs from the
        /// manifest's (nil: the manifest is missing or unreadable).
        case corrupt(actual: String?, expected: String?)
    }

    /// The set id `MANIFEST.json` names, or nil.
    static func manifestSetId(
        read: (URL) -> Data? = { try? Data(contentsOf: $0) }
    ) -> String? {
        guard let url = PrimaeBundle.resourceURL(
                firstOf: PrimaeBundle.layouts(dir: "Prompts", name: "MANIFEST", ext: "json")),
              let data = read(url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["setId"] as? String
    }

    /// Present AND byte-identical to the reviewed set. Hashes five small
    /// files; callers run it once and keep the verdict.
    static func verify(
        locate: @MainActor (PromptPlayer.PromptKey) -> URL? = PromptPlayer.locate,
        read: (URL) -> Data? = { try? Data(contentsOf: $0) }
    ) -> Verdict {
        let gone = missing(locate: locate)
        if !gone.isEmpty { return .missing(gone) }
        let actual = setId(locate: locate, read: read)
        let expected = manifestSetId(read: read)
        if let actual, actual == expected { return .ok(actual) }
        return .corrupt(actual: actual, expected: expected)
    }

    /// Proctor-facing refusal for a verdict that cannot run a session, or nil.
    static func refusal(for verdict: Verdict) -> String? {
        switch verdict {
        case .ok: return nil
        case .missing(let keys): return refusal(missing: keys)
        case .corrupt(let actual, let expected):
            return "Die aufgenommenen Anweisungen sind nicht die geprüften (gefundener Satz \(actual ?? "unlesbar"), erwartet \(expected ?? "unbekannt")). Die Sitzung wird nicht gestartet — andere Aufnahmen würden die Anweisungen anders sprechen als bei den bisherigen Kindern. Die App neu installieren."
        }
    }

    /// The research dashboard's line for the recorded set.
    static func dashboardText(_ verdict: Verdict) -> String {
        switch verdict {
        case .ok(let id): return "Kiki · \(id)"
        case .missing(let keys): return "UNVOLLSTÄNDIG – fehlt: " + keys.map { "\($0.rawValue).mp3" }.joined(separator: ", ")
        case .corrupt(let actual, let expected):
            return "VERÄNDERT – Satz \(actual ?? "unlesbar"), geprüft \(expected ?? "unbekannt")"
        }
    }

    /// Proctor-facing refusal text for a set that is not complete, or nil.
    static func refusal(missing keys: [PromptPlayer.PromptKey]) -> String? {
        guard !keys.isEmpty else { return nil }
        let names = keys.map { "\($0.rawValue).mp3" }.joined(separator: ", ")
        return "Aufgenommene Anweisungen fehlen: \(names). Die Sitzung wird nicht gestartet — eine Ersatzstimme des Geräts würde diese Anweisung anders sprechen als bei den bisherigen Kindern. Die App mit den fünf Aufnahmen (Resources/Prompts) neu installieren."
    }
}
