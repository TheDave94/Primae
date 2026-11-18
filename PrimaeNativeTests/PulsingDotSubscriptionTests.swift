// PulsingDotSubscriptionTests.swift
//
// Audit R-083 (narrowed): `PulsingDot` subscribed a 30 Hz `Timer.publish`
// unconditionally and then did `guard isNext else { scale = 1.0; return }`, so
// every dot that was NOT the next target woke the main actor 30 times a second
// forever. The timer itself is a deliberate workaround (see the doc comment on
// `PulsingDot`) and is NOT under test or under change here — only WHEN it is
// subscribed.
//
// The seam is `PulsingDot.tickSource` (`PulseTickSource`), added for this
// test: it lets a test hand the dot a publisher that counts real
// subscriptions and cancellations. This is a BEHAVIOUR test of the
// subscription, not of the pixels: `scale` is private `@State` and a
// `Canvas`/`scaleEffect` result is not reachable from a unit test.
//
// No clock is involved. The negative case is not "wait a while and see nothing
// happened" (which proves nothing); each test hosts a dot that SHOULD
// subscribe next to the dot under test and waits for THAT subscription —
// proof that the hosting pipeline has attached — before asserting the other
// is silent.

import Testing
import Foundation
import SwiftUI
import UIKit
import Combine
@testable import PrimaeNative

@MainActor
private final class SubscriptionLedger {
    private(set) var subscribed = 0
    private(set) var cancelled = 0

    /// A source whose publisher never emits but records subscribe/cancel.
    var source: PulseTickSource {
        PulseTickSource { [self] in
            PassthroughSubject<Date, Never>()
                .handleEvents(
                    receiveSubscription: { _ in MainActor.assumeIsolated { self.subscribed += 1 } },
                    receiveCancel: { MainActor.assumeIsolated { self.cancelled += 1 } })
                .eraseToAnyPublisher()
        }
    }
}

@MainActor
@Observable
private final class NextFlag {
    var isNext: Bool
    init(_ isNext: Bool) { self.isNext = isNext }
}

private struct FlagDot: View {
    let flag: NextFlag
    let source: PulseTickSource
    var body: some View {
        PulsingDot(isNext: flag.isNext, isTapped: false, emphasis: false,
                   label: "1", radius: 18, tickSource: source)
    }
}

@MainActor
@Suite struct PulsingDotSubscriptionTests {

    private func host<V: View>(_ view: V) -> UIWindow {
        let hc = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        window.rootViewController = hc
        window.makeKeyAndVisible()
        hc.view.frame = window.bounds
        hc.view.layoutIfNeeded()
        return window
    }

    /// Wait until `condition` holds; event-driven, the deadline only bounds
    /// a failure. It SUSPENDS the main actor rather than spinning
    /// `RunLoop.main` by hand: a nested run loop inside a synchronous
    /// main-actor test re-enters every other suite's main-actor work, and on
    /// the iPad a full run starved to a kill at 900 s that way.
    private func spin(until condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("a dot that is not the next target holds no timer subscription")
    func nonNextDotSubscribesNothing() async {
        let idle = SubscriptionLedger()
        let control = SubscriptionLedger()
        let window = host(
            VStack {
                PulsingDot(isNext: false, isTapped: false, emphasis: false,
                           label: "2", radius: 18, tickSource: idle.source)
                // Positive control: a next dot IS subscribed, and its arrival
                // proves the hosting pipeline attached subscriptions.
                PulsingDot(isNext: true, isTapped: false, emphasis: false,
                           label: "1", radius: 22, tickSource: control.source)
            })
        defer { window.isHidden = true }

        await spin { control.subscribed >= 1 }
        #expect(control.subscribed == 1, "positive control: the next dot subscribes once")
        #expect(idle.subscribed == 0, "a non-next dot must not subscribe the 30 Hz timer")
    }

    @Test("a dot that stops being next releases its subscription")
    func losingNextReleasesSubscription() async {
        let ledger = SubscriptionLedger()
        let flag = NextFlag(true)
        let window = host(FlagDot(flag: flag, source: ledger.source))
        defer { window.isHidden = true }

        await spin { ledger.subscribed >= 1 }
        #expect(ledger.subscribed == 1)
        #expect(ledger.cancelled == 0)

        flag.isNext = false
        await spin { ledger.cancelled >= 1 }
        #expect(ledger.cancelled == 1, "the subscription must be cancelled when the dot is no longer next")
        #expect(ledger.subscribed == 1)
    }

    @Test("a dot that becomes next subscribes")
    func gainingNextSubscribes() async {
        let ledger = SubscriptionLedger()
        let flag = NextFlag(false)
        let window = host(FlagDot(flag: flag, source: ledger.source))
        defer { window.isHidden = true }

        flag.isNext = true
        await spin { ledger.subscribed >= 1 }
        #expect(ledger.subscribed == 1)
        #expect(ledger.cancelled == 0)
    }
}
