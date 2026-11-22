import Foundation
import NotchCore
import NotchCoreTesting
import SwiftUI
import Testing
@testable import NotchUI

@MainActor
@Suite("Nudge")
struct NudgeTests {
    static let dir = FileManager.default.temporaryDirectory.appending(path: "niche-snapshots", directoryHint: .isDirectory)

    @Test func openingTheNudgeSpringsOpenAndMovingBetweenOpenStatesMorphs() {
        #expect(NotchController.animation(from: .closed, to: .nudge) == Motion.open)
        #expect(NotchController.animation(from: .activity, to: .nudge) == Motion.open)
        #expect(NotchController.animation(from: .hover, to: .nudge) == Motion.open)
        #expect(NotchController.animation(from: .expanded, to: .nudge) == Motion.morph)
        #expect(NotchController.animation(from: .drop, to: .nudge) == Motion.morph)
        #expect(NotchController.animation(from: .nudge, to: .expanded) == Motion.morph)
        #expect(NotchController.animation(from: .nudge, to: .drop) == Motion.morph)
        #expect(NotchController.animation(from: .nudge, to: .activity) == Motion.close)
        #expect(NotchController.animation(from: .nudge, to: .closed) == Motion.close)
    }

    @Test func theNudgeStateCanBeForcedByName() {
        #expect(NotchState(rawValue: "nudge") == .nudge)
        #expect(NotchState.nudge.isOpen)
    }

    /// Writes the nudge card to $TMPDIR/niche-snapshots for visual review: the sample, a title far too long for
    /// the card, and one without an action button or countdown.
    @Test func snapshots() throws {
        let now = Date.now
        let sample = Nudge.sample(now: now)
        var long = sample
        long.title = "Quarterly planning with the whole product group, the design team and everyone from support"
        long.message = "Hey buddy, time to head over, the room is on the other side of the building"
        var noAction = sample
        noAction.actionTitle = nil
        var bare = noAction
        bare.countdown = nil
        let band: CGFloat = 38
        let size = CGSize(width: PanelLayout.nudgeSize.width, height: band + PanelLayout.nudgeSize.height)
        let cases: [(String, Nudge)] = [
            ("nudge-sample", sample), ("nudge-long-title", long), ("nudge-no-action", noAction), ("nudge-bare", bare),
        ]
        for (name, nudge) in cases {
            let view = NudgeView(nudge: nudge, bandHeight: band, onAction: {}, onDismiss: {})
            let url = try ViewSnapshot.write(view, size: size, to: Self.dir.appending(path: "\(name).png"))
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
        print("snapshots in \(Self.dir.path)")
    }
}
