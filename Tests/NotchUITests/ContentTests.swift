import AppKit
import NotchCore
import NotchCoreTesting
import SwiftUI
import Testing
@testable import NotchUI

@Suite("Panel content")
@MainActor
struct PanelContentTests {
    @Test func pagesAreSortedByOrderThenModuleOrder() {
        let modules: [any NotchModule] = [
            FakeModule("b", placement: .page(order: 2)),
            FakeModule("a", placement: .page(order: 1)),
            FakeModule("dash", placement: .dashboard(.center)),
            FakeModule("c", placement: .page(order: 1)),
            FakeModule("hidden", placement: .hidden),
        ]
        #expect(PanelContent.pages(modules).map(\.id) == ["a", "c", "b"])
    }

    @Test func dashboardTakesTheFirstModulePerSlotInSlotOrder() {
        let modules: [any NotchModule] = [
            FakeModule("t", placement: .dashboard(.trailing)),
            FakeModule("c1", placement: .dashboard(.center)),
            FakeModule("c2", placement: .dashboard(.center)),
            FakeModule("lt", placement: .dashboard(.leadingTop)),
        ]
        let cards = PanelContent.dashboard(modules)
        #expect(cards.map(\.id) == ["lt", "c1", "t"])
        #expect(cards.map(\.slot) == [.leadingTop, .center, .trailing])
    }

    @Test func onlyPageModulesOpenAsPages() {
        let modules: [any NotchModule] = [FakeModule(.shelf, placement: .page(order: 0)), FakeModule(.convert, placement: .dashboard(.center))]
        #expect(PanelContent.pageModule(.shelf, in: modules)?.id == .shelf)
        #expect(PanelContent.pageModule(.convert, in: modules) == nil)
        #expect(PanelContent.pageModule(nil, in: modules) == nil)
    }

    @Test func modulesEnabledLaterAppearAndDisabledOnesDisappear() {
        let modules: [any NotchModule] = [
            FakeModule(.shelf, placement: .page(order: 0)), FakeModule(.convert, placement: .dashboard(.trailing)),
        ]
        #expect(PanelContent.enabled(modules, disabled: ["shelf"]).map(\.id) == [.convert])
        #expect(PanelContent.pages(PanelContent.enabled(modules, disabled: ["shelf"])).isEmpty)
        #expect(PanelContent.enabled(modules, disabled: []).map(\.id) == [.shelf, .convert])
        #expect(PanelContent.pages(PanelContent.enabled(modules, disabled: [])).map(\.id) == [.shelf])
        // A page whose module went away falls back to Home.
        #expect(PanelContent.pageModule(.shelf, in: PanelContent.enabled(modules, disabled: ["shelf"])) == nil)
    }

    @Test func settingsKeysAreNamespaced() {
        #expect(NotchSettings.openOnHover.name == "notch.openOnHover" && NotchSettings.openOnHover.defaultValue == false)
        #expect(NotchSettings.hotkeyEnabled.name == "notch.hotkeyEnabled" && NotchSettings.hotkeyEnabled.defaultValue == true)
    }
}

@Suite("Drop items")
@MainActor
struct DropItemTests {
    let file = URL(fileURLWithPath: "/tmp/a.png")

    @Test func filesWinOverImageDataWhichWinsOverText() {
        let data = Data([1, 2, 3])
        #expect(DropItems.resolve(fileURLs: [file], imageData: data, text: "x") == [.file(file)])
        #expect(DropItems.resolve(fileURLs: [], imageData: data, text: "x") == [.imageData(data, suggestedName: nil)])
        #expect(DropItems.resolve(fileURLs: [], imageData: nil, text: "x") == [.text("x")])
        #expect(DropItems.resolve(fileURLs: [], imageData: Data(), text: "") == [])
    }

    @Test func previewStandsInForPromisedFilesByType() {
        let items = DropItems.preview(fileURLs: [], promisedTypes: [["public.jpeg"], ["com.adobe.pdf"]], hasImage: true, hasText: true)
        #expect(items.count == 2)
        #expect(items[0].isImage)
        #expect(items[1].fileURL?.pathExtension == "pdf")
        #expect(DropItems.preview(fileURLs: [], promisedTypes: [], hasImage: true, hasText: true).first?.isImage == true)
        #expect(DropItems.preview(fileURLs: [], promisedTypes: [], hasImage: false, hasText: true) == [.text("")])
    }

    @Test func previewHintComesFromTheWinningModule() {
        let convert = FakeModule(.convert)
        convert.acceptance = { $0.isImage ? .accept(weight: DropWeight.preferred) : .reject }
        convert.hint = DropHint(title: "Convert", symbol: "photo")
        let shelf = FakeModule(.shelf)
        shelf.acceptance = { $0.fileURL != nil ? .accept(weight: DropWeight.fallback) : .reject }
        shelf.hint = DropHint(title: "Shelf", symbol: "tray")
        let modules: [any NotchModule] = [convert, shelf]
        let promisedJPEG = DropItems.preview(fileURLs: [], promisedTypes: [["public.jpeg"]], hasImage: false, hasText: false)
        #expect(DropRouter.hint(for: DropPayload(items: promisedJPEG), among: modules)?.title == "Convert")
        #expect(DropRouter.hint(for: DropPayload(items: promisedJPEG, optionKey: true), among: modules)?.title == "Shelf")
        #expect(DropRouter.hint(for: DropPayload(items: [.text("")]), among: modules) == nil)
        #expect(DropHint.fallback.title == "Drop")
    }

    // MARK: Drop acceptance

    func modules() -> [any NotchModule] {
        let convert = FakeModule(.convert)
        convert.acceptance = { $0.isImage ? .accept(weight: DropWeight.preferred) : .reject }
        let shelf = FakeModule(.shelf)
        shelf.acceptance = { $0.fileURL != nil ? .accept(weight: DropWeight.fallback) : .reject }
        return [convert, shelf]
    }

    @Test func dragsNobodyWantsAreNotAccepted() {
        let m = modules()
        // Selected text, a link or a browser tab: text only, which no module here takes.
        #expect(!DropDecision.accepts([.text("")], optionKey: false, among: m))
        #expect(!DropDecision.accepts([], optionKey: false, among: m))
        #expect(!DropDecision.accepts([.file(file)], optionKey: false, among: []))
        #expect(DropDecision.accepts([.file(file)], optionKey: false, among: m))
        #expect(DropDecision.accepts([.imageData(Data(), suggestedName: nil)], optionKey: false, among: m))
        // ⌥ sends everything to the shelf, which does not take raw image data.
        #expect(!DropDecision.accepts([.imageData(Data(), suggestedName: nil)], optionKey: true, among: m))
    }

    @Test func onlyPromisesSomeModuleWantsAreReceived() {
        let convertOnly: [any NotchModule] = [modules()[0]]
        #expect(DropDecision.acceptedPromises([["com.adobe.pdf"], ["public.jpeg"], ["public.png", "com.adobe.pdf"]], optionKey: false, among: convertOnly) == [1, 2])
        #expect(DropDecision.acceptedPromises([["com.adobe.pdf"]], optionKey: false, among: convertOnly).isEmpty)
        #expect(DropDecision.acceptedPromises([["com.adobe.pdf"]], optionKey: false, among: modules()) == [0])
        #expect(DropDecision.acceptedPromises([], optionKey: false, among: modules()).isEmpty)
    }

    @Test func promiseFileCountDoesNotDependOnPrimedNames() {
        #expect(FilePromises.expectedFileCount(fileNames: 0, fileTypes: 3) == 3)
        #expect(FilePromises.expectedFileCount(fileNames: 2, fileTypes: 2) == 2)
        #expect(FilePromises.expectedFileCount(fileNames: 0, fileTypes: 0) == 1)
    }

    /// Uses a private named pasteboard, never the general one.
    @Test func readsFileURLsAndTextFromAPasteboard() throws {
        let pb = NSPasteboard(name: NSPasteboard.Name("dev.bayhill.notcher.tests.\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.writeObjects([file as NSURL])
        #expect(DragPasteboard.read(pb).fileURLs == [file])
        #expect(DragPasteboard.preview(pb) == [.file(file)])

        pb.clearContents()
        pb.setString("hello", forType: .string)
        let contents = DragPasteboard.read(pb)
        #expect(contents.fileURLs.isEmpty && contents.promises.isEmpty)
        #expect(DropItems.resolve(fileURLs: contents.fileURLs, imageData: contents.imageData, text: contents.text) == [.text("hello")])

        pb.clearContents()
        let png = TestImage.data(TestImage.solid())
        pb.setData(png, forType: .png)
        #expect(DragPasteboard.read(pb).imageData == png)
        #expect(DragPasteboard.preview(pb).first?.isImage == true)
    }

    @Test func dropTypesIncludeFilesPromisesImagesAndText() {
        let types = Set(DragPasteboard.registeredTypes)
        #expect(types.isSuperset(of: [.fileURL, .png, .tiff, .string]))
        #expect(NSFilePromiseReceiver.readableDraggedTypes.allSatisfy { types.contains(NSPasteboard.PasteboardType($0)) })
    }
}

@Suite("Shape")
struct ShapeTests {
    @Test func closedShapeStaysInsideItsRectAndFillsTheTopEdge() {
        let rect = CGRect(x: 0, y: 0, width: 220, height: 38)
        let path = NotchShape(topRadius: 6, bottomRadius: 13).path(in: rect)
        #expect(rect.insetBy(dx: -0.01, dy: -0.01).contains(path.boundingRect))
        // Full width along the top edge, narrower by the ears just below it.
        #expect(path.contains(CGPoint(x: 1, y: 0.2)))
        #expect(!path.contains(CGPoint(x: 1, y: 10)))
        #expect(path.contains(CGPoint(x: 110, y: 37)))
        // Convex bottom corners.
        #expect(!path.contains(CGPoint(x: 7, y: 37.5)))
    }

    @Test func degenerateRectsDoNotCrash() {
        #expect(NotchShape(topRadius: 14, bottomRadius: 28).path(in: .zero).isEmpty)
        #expect(!NotchShape(topRadius: 14, bottomRadius: 28).path(in: CGRect(x: 0, y: 0, width: 20, height: 10)).isEmpty)
    }
}
