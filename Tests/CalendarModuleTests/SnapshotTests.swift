@testable import CalendarModule
import Foundation
import NotchCore
import NotchCoreTesting
import Testing

/// Writes the card in each state to $TMPDIR/notcher-snapshots for visual review.
@MainActor
@Suite struct SnapshotTests {
    static let dir = FileManager.default.temporaryDirectory.appending(path: "notcher-snapshots", directoryHint: .isDirectory)

    @Test func cards() throws {
        let now = Date.now
        func module(_ source: SampleEventSource) -> CalendarModule {
            let m = CalendarModule(source: source, now: { now }, openURL: { _ in })
            m.refresh()
            return m
        }
        let inProgress = SampleEventSource(events: [
            CalendarEvent(id: "now", title: "Quarterly planning with the whole product group", start: now.addingTimeInterval(-60),
                          end: now.addingTimeInterval(3600), url: URL(string: "https://acme.zoom.us/j/812345678")),
        ])
        let plain = SampleEventSource(events: [
            CalendarEvent(id: "lunch", title: "Lunch with Sam", start: now.addingTimeInterval(3 * 3600), end: now.addingTimeInterval(4 * 3600)),
        ])
        let cases: [(String, CalendarModule)] = [
            ("calendar-next", .sample()),
            ("calendar-now", module(inProgress)),
            ("calendar-nolink", module(plain)),
            ("calendar-empty", module(SampleEventSource())),
            ("calendar-connect", module(SampleEventSource(access: .notDetermined))),
            ("calendar-denied", module(SampleEventSource(access: .denied))),
        ]
        for (name, module) in cases {
            let url = try ViewSnapshot.write(module: module, to: Self.dir.appending(path: "\(name).png"))
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
        print("snapshots in \(Self.dir.path)")
    }
}
