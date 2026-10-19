// StoreFileQuarantine.swift
// PrimaeNative
//
// Helpers the JSON stores share so that a file which EXISTS but does not
// decode — or cannot be read, or is from a newer schema (2026-10-13,
// `load` below) — is neither silently dropped nor destroyed (2026-09-04
// audit):
//
//   1. `quarantine(_:)` moves the undecodable file aside before the next
//      atomic save replaces it — the study's phase records and raw traces
//      live in these files, and "starting empty" used to be
//      indistinguishable from a fresh install.
//   2. `LossyArray` decodes an array element by element, dropping (and
//      counting) only the elements that fail. One malformed row no longer
//      costs every row written before it.

import Foundation

enum StoreFileQuarantine {
    /// What `quarantine` / `preserveCopy` put into a set-aside file's
    /// name. A per-file directory load (archive, enrolment log) must SKIP
    /// such names: they keep the `.json` extension, so they used to be
    /// re-read on every launch, moved aside again, re-reported, and renamed
    /// `X.undecodable-1.undecodable-2.json` until the rename failed.
    static let setAsideMarker = ".undecodable-"

    /// Copies `url` to `<stem>.undecodable-<unix-seconds>.<ext>` beside it,
    /// leaving the original in place — for a file that decoded well enough
    /// to keep running from, but lost a block worth inspecting.
    @discardableResult
    static func preserveCopy(_ url: URL) -> URL? {
        let stamp = Int(Date().timeIntervalSince1970)
        let ext = url.pathExtension
        var dest = url.deletingPathExtension()
            .appendingPathExtension("undecodable-\(stamp)")
        if !ext.isEmpty { dest = dest.appendingPathExtension(ext) }
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            storePersistenceLogger.error(
                "Partly undecodable store file copied to \(dest.path, privacy: .private) for inspection; the live file keeps running.")
            return dest
        } catch {
            storePersistenceLogger.error(
                "Partly undecodable store file at \(url.path, privacy: .private) could NOT be copied aside (\(error.localizedDescription, privacy: .private)).")
            return nil
        }
    }

    /// Moves `url` to `<stem>.undecodable-<unix-seconds>.<ext>` beside it.
    /// Returns the destination, or nil (already logged) if the move failed.
    @discardableResult
    static func quarantine(_ url: URL) -> URL? {
        let stamp = Int(Date().timeIntervalSince1970)
        let ext = url.pathExtension
        var dest = url.deletingPathExtension()
            .appendingPathExtension("undecodable-\(stamp)")
        if !ext.isEmpty { dest = dest.appendingPathExtension(ext) }
        do {
            try FileManager.default.moveItem(at: url, to: dest)
            storePersistenceLogger.error(
                "Undecodable store file moved aside to \(dest.path, privacy: .private) — nothing was overwritten; copy it off the device and inspect it.")
            return dest
        } catch {
            storePersistenceLogger.error(
                "Undecodable store file at \(url.path, privacy: .private) could NOT be moved aside (\((error as NSError).domain, privacy: .public) \((error as NSError).code, privacy: .public): \(error.localizedDescription, privacy: .private)); the next save WILL overwrite it.")
            return nil
        }
    }
}

// MARK: - Load: only a MISSING file is a first launch (R-054, audit 2026-10-13)

/// What reading a store file found.
enum StoreFileRead {
    /// No file — the ordinary first launch.
    case missing
    case data(Data)
    /// The file exists but could not be read (permissions, data
    /// protection while locked, I/O). NOT a first launch: treating it as
    /// one made the next save atomically replace the real file.
    case unreadable(Error)
}

/// The outcome of loading one store file.
struct StoreLoad<Value> {
    /// The decoded value, or nil when the store starts empty.
    var value: Value?
    /// Non-nil when the store must NOT write: the file on disk could not
    /// be read, is from a newer schema, or could not be moved aside, and
    /// the next save would destroy it. Already reported as a failure.
    var writeRefusal: String?
}

/// Every JSON store's coder. Non-finite Doubles are written as the
/// strings "NaN" / "Infinity" / "-Infinity" instead of THROWING (R-053):
/// with the default `.throw` strategy one non-finite value anywhere in a
/// store made every later save of that store fail for the rest of the
/// process, and the row stayed in memory looking recorded. The decoder
/// accepts the same strings, so such a value round-trips unchanged.
nonisolated enum StoreCoding {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        return encoder
    }

    static func decoder(tally: StoreDecodeTally? = nil) -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        if let tally { decoder.userInfo[.storeDecodeTally] = tally }
        return decoder
    }

    /// Encodes `value`, or reports the failure (it is a lost save) and
    /// returns nil.
    static func encode<T: Encodable>(_ value: T, store: String,
                                     center: PersistenceFailureCenter) -> Data? {
        do {
            return try encoder().encode(value)
        } catch {
            storePersistenceLogger.error(
                "\(store, privacy: .public) encode failed (\(error.localizedDescription, privacy: .private)) — NOT persisted.")
            center.reportFailure(store: store, error: error)
            return nil
        }
    }
}

/// Counts elements an element-wise decode had to drop, so a load can
/// surface the loss (R-055) instead of only logging it. Passed to the
/// decoders through `userInfo[.storeDecodeTally]`.
nonisolated final class StoreDecodeTally: @unchecked Sendable {
    private let lock = NSLock()
    private var _dropped: [String] = []

    func record(_ count: Int, of what: String) {
        guard count > 0 else { return }
        lock.lock(); _dropped.append("\(count) × \(what)"); lock.unlock()
    }

    /// e.g. ["2 × phaseSessionRecords", "1 × rawTraces"]; empty when
    /// nothing was dropped.
    var dropped: [String] {
        lock.lock(); defer { lock.unlock() }
        return _dropped
    }
}

extension CodingUserInfoKey {
    nonisolated static let storeDecodeTally = CodingUserInfoKey(rawValue: "de.flamingistan.primae.storeDecodeTally")!
}

extension Decoder {
    /// The tally a store load passed in, if any.
    nonisolated var storeDecodeTally: StoreDecodeTally? {
        userInfo[.storeDecodeTally] as? StoreDecodeTally
    }
}

/// The error a store reports when it refuses to write.
nonisolated struct StoreWriteRefusal: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

extension StoreFileQuarantine {

    static func read(_ url: URL) -> StoreFileRead {
        do {
            return .data(try Data(contentsOf: url))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .missing
        } catch {
            // Anything else with no file behind it is still a first launch;
            // with a file behind it, it is a finding.
            return FileManager.default.fileExists(atPath: url.path) ? .unreadable(error) : .missing
        }
    }

    /// The one load path every single-file JSON store shares (R-054):
    ///   - missing file            → empty, writes allowed (first launch)
    ///   - unreadable file         → empty, writes REFUSED, failure reported
    ///   - undecodable file        → moved aside, empty, notice reported;
    ///                               if it cannot be moved: writes REFUSED
    ///   - future schema           → empty, writes REFUSED, failure reported
    /// A refusing store never touches the file, so its bytes survive for
    /// inspection; the failure hard-stops a study session.
    static func load<Value>(_ url: URL, store: String, center: PersistenceFailureCenter,
                            currentSchemaVersion: Int? = nil,
                            schemaVersion: (Value) -> Int? = { _ in nil },
                            decode: (Data) throws -> Value) -> StoreLoad<Value> {
        let data: Data
        switch read(url) {
        case .missing:
            return StoreLoad(value: nil, writeRefusal: nil)
        case .unreadable(let error):
            return refuse(url, store: store, center: center,
                          reason: "exists but could not be read (\(error.localizedDescription))")
        case .data(let bytes):
            data = bytes
        }
        let decoded: Value
        do {
            decoded = try decode(data)
        } catch {
            storePersistenceLogger.error(
                "\(store, privacy: .public) at \(url.path, privacy: .private) exists but failed to decode (\(error.localizedDescription, privacy: .private)) — starting EMPTY.")
            guard let dest = quarantine(url) else {
                return refuse(url, store: store, center: center,
                              reason: "is undecodable and could not be moved aside")
            }
            center.reportNotice(store: store,
                                message: "\(url.lastPathComponent) was undecodable and moved aside to \(dest.lastPathComponent); this store started empty")
            return StoreLoad(value: nil, writeRefusal: nil)
        }
        if let current = currentSchemaVersion, let version = schemaVersion(decoded), version > current {
            return refuse(url, store: store, center: center,
                          reason: "is schema v\(version) but this build reads v\(current)")
        }
        return StoreLoad(value: decoded, writeRefusal: nil)
    }

    private static func refuse<Value>(_ url: URL, store: String, center: PersistenceFailureCenter,
                                      reason: String) -> StoreLoad<Value> {
        // The original stays exactly where it is, untouched — that IS the
        // preserved copy; a second copy per launch would only accumulate.
        let message = "\(url.lastPathComponent) \(reason) — kept on disk; this store will not write until it is resolved"
        storePersistenceLogger.error("\(store, privacy: .public): \(message, privacy: .private)")
        center.reportFailure(store: store, error: StoreWriteRefusal(message: message))
        return StoreLoad(value: nil, writeRefusal: message)
    }
}

/// Dictionary decoding that survives individual bad values — the
/// keyed counterpart of `LossyArray` (R-055).
struct LossyDictionary<Value: Decodable>: Decodable {
    let elements: [String: Value]
    let droppedCount: Int

    nonisolated private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        var out: [String: Value] = [:]
        var dropped = 0
        for key in container.allKeys {
            if let value = try? container.decode(Value.self, forKey: key) {
                out[key.stringValue] = value
            } else {
                dropped += 1
            }
        }
        elements = out
        droppedCount = dropped
    }
}

/// Array decoding that survives individual bad elements. `droppedCount`
/// is reported by the caller so the loss is visible in the log.
struct LossyArray<Element: Decodable>: Decodable {
    let elements: [Element]
    let droppedCount: Int

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var out: [Element] = []
        var dropped = 0
        while !container.isAtEnd {
            let before = container.currentIndex
            if let element = try? container.decode(Element.self) {
                out.append(element)
            } else {
                dropped += 1
                // Consume the bad element so the loop advances.
                _ = try? container.decode(Skip.self)
            }
            // A container that cannot advance would spin forever — stop
            // and keep what was decoded so far.
            if container.currentIndex == before {
                // Everything after this element is lost too — say so.
                if let total = container.count {
                    dropped += max(0, total - container.currentIndex - 1)
                }
                break
            }
        }
        elements = out
        droppedCount = dropped
    }

    /// Decodes any JSON value without inspecting it.
    private struct Skip: Decodable {
        init(from decoder: Decoder) throws {
            _ = try decoder.singleValueContainer()
        }
    }
}
