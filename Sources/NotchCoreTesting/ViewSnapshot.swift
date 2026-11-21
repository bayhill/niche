import AppKit
import NotchCore
import SwiftUI

/// Renders a SwiftUI view to a PNG off-screen, so a module's panel view can be inspected without putting
/// a window on the user's display. Liquid Glass does not render off-screen (glass controls lose their backing);
/// layout, type, colour and cards do.
@MainActor
public enum ViewSnapshot {
    /// Renders `view` at `size` points on a dark backdrop that approximates the expanded panel.
    public static func png(of view: some View, size: CGSize, scale: CGFloat = 2) -> Data? {
        let content = view
            .frame(width: size.width, height: size.height)
            .padding(12)
            .background(Color(red: 0.11, green: 0.11, blue: 0.12))
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        guard let cg = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    /// Renders and writes the PNG; returns the URL written.
    @discardableResult
    public static func write(_ view: some View, size: CGSize, to url: URL, scale: CGFloat = 2) throws -> URL {
        guard let data = png(of: view, size: size, scale: scale) else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    /// Renders a module's `panelView()` at the size its placement gets in the panel.
    @discardableResult
    public static func write(module: any NotchModule, to url: URL) throws -> URL {
        let size: CGSize = switch module.placement {
        case .dashboard(let slot): PanelLayout.cardSize(for: slot)
        case .page, .hidden: PanelLayout.pageSize
        }
        return try write(module.panelView(), size: size, to: url)
    }
}
