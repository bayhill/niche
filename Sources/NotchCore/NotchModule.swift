import Observation
import SwiftUI

/// Where a module's `panelView()` appears in the expanded panel.
public enum PanelPlacement: Sendable, Equatable {
    /// A card on the Home dashboard. NotchUI sizes the card; the view must fill whatever frame it is given.
    case dashboard(DashboardSlot)
    /// A full-width page with its own icon in the top band. Lower `order` comes first.
    case page(order: Int)
    /// No panel UI (live activity and drops only).
    case hidden
}

/// Home dashboard layout: three columns; the leading column is split in two.
/// Approximate card sizes at the default panel size are in `PanelLayout`.
/// Assignment: Next meeting `leadingTop`, Claude sessions `leadingBottom`, Now Playing `center`, Convert `trailing`.
public enum DashboardSlot: Sendable, Equatable, CaseIterable {
    case leadingTop, leadingBottom, center, trailing
}

/// The contract every feature implements. One instance per module for the app's lifetime.
///
/// Conformers are `@MainActor @Observable final class`es. NotchUI observes `liveActivity` and whatever
/// `panelView()` reads, so plain stored properties are enough to drive the UI.
@MainActor
public protocol NotchModule: AnyObject, Observable {
    var id: ModuleID { get }
    /// Short human name ("Shelf"). Shown in tooltips and Settings.
    var title: String { get }
    /// SF Symbol for the page icon and Settings sidebar.
    var symbol: String { get }
    /// Permissions the module needs. The app shows these in onboarding; the module must not prompt on its own
    /// unless `ModuleContext.mayPrompt` is true.
    var requirements: [PermissionRequirement] { get }
    var placement: PanelPlacement { get }
    /// Observed. `nil` when there is nothing worth showing beside the notch.
    var liveActivity: LiveActivity? { get }

    /// Begin work. Idempotent: a second call while running is a no-op. Must return quickly; long work goes in tasks.
    func start(_ context: ModuleContext) async
    /// Stop timers, monitors, child processes. Idempotent.
    func stop()

    /// The module's UI. Built only from the NotchCore design kit. Called often; keep it cheap.
    func panelView() -> AnyView

    /// Whether (and how much) this module wants a dragged item. Pure and fast: called during drag tracking.
    func dropAcceptance(for item: DropItem) -> DropAcceptance
    /// Text for the drop target while dragging the given items (already filtered to ones this module would receive).
    func dropHint(for items: [DropItem]) -> DropHint?
    /// Take ownership of dropped items. Only called with items this module accepted.
    func handleDrop(_ payload: DropPayload) async

    /// Settings pane content, or `nil` for none. Standard macOS `Form` controls bound to `SettingsStore`.
    func settingsView() -> AnyView?
}

public extension NotchModule {
    var requirements: [PermissionRequirement] { [] }
    var liveActivity: LiveActivity? { nil }
    func stop() {}
    func dropAcceptance(for item: DropItem) -> DropAcceptance { .reject }
    func dropHint(for items: [DropItem]) -> DropHint? { nil }
    func handleDrop(_ payload: DropPayload) async {}
    func settingsView() -> AnyView? { nil }
}
