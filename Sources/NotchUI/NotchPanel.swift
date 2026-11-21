import AppKit
import SwiftUI

/// Borderless, non-activating, click-through-by-default panel that sits over the menu bar.
@MainActor
final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        level = .mainMenu + 3
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = true
        // Stay up when the app is hidden ("Hide Others"); the controller also unhides on didHide.
        canHide = false
    }

    // Key only for text input inside a module (becomesKeyOnlyIfNeeded); never main.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    // Allow the frame to cover the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Clicks in a non-key panel go straight to SwiftUI.
final class NotchHostingView: NSHostingView<NotchRootView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
protocol NotchDropHandling: AnyObject {
    func dragUpdated(at screenPoint: CGPoint, pasteboard: NSPasteboard) -> NSDragOperation
    func dragExited()
    func canAcceptDrop() -> Bool
    func performDrop(_ pasteboard: NSPasteboard) -> Bool
}

/// The panel's content view: hosts SwiftUI and is the drag destination for the whole panel.
@MainActor
final class NotchContainerView: NSView {
    weak var dropHandler: NotchDropHandling?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(DragPasteboard.registeredTypes)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func screenPoint(_ info: any NSDraggingInfo) -> CGPoint {
        window?.convertPoint(toScreen: info.draggingLocation) ?? info.draggingLocation
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dropHandler?.dragUpdated(at: screenPoint(sender), pasteboard: sender.draggingPasteboard) ?? []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dropHandler?.dragUpdated(at: screenPoint(sender), pasteboard: sender.draggingPasteboard) ?? []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { dropHandler?.dragExited() }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        dropHandler?.canAcceptDrop() ?? false
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        dropHandler?.performDrop(sender.draggingPasteboard) ?? false
    }
}
