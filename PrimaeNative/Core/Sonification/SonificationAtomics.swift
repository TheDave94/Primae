// SonificationAtomics.swift
// PrimaeNative
//
// Lock-free parameter cells for `SonificationRenderer` conformers: the
// setters are written from the touch thread and read on the render
// thread, so they go through `Synchronization.Atomic` (part of the Swift
// standard library distribution, no package dependency) with relaxed
// ordering. Relaxed is enough for independent scalar targets (each value
// stands alone; nothing is published through them). A Float travels as
// its bit pattern because `Float` is not `AtomicRepresentable`.
//
// Store the cell as a `let` property of the renderer class
// (`let rate = Atomic<UInt32>(Float(1).bitPattern)`); `Atomic` is
// `~Copyable` and must not be copied or wrapped in a `var`.

import Synchronization

extension Atomic where Value == UInt32 {
    /// Relaxed store of a Float target. Real-time safe.
    nonisolated func storeFloat(_ value: Float) {
        store(value.bitPattern, ordering: .relaxed)
    }

    /// Relaxed load of a Float target. Real-time safe.
    nonisolated func loadFloat() -> Float {
        Float(bitPattern: load(ordering: .relaxed))
    }
}
