import AppKit
import Foundation
import Testing
@testable import Alwm

@Suite("Notepad image attachments", .serialized)
struct NotepadImageAttachmentTests {
    @Test("older notes decode without image attachments")
    func legacyPageDefaultsToNoAttachments() throws {
        let page = NotePage(categoryID: UUID())
        let encoded = try JSONEncoder().encode(page)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "attachments")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(NotePage.self, from: legacyData)

        #expect(decoded.attachments.isEmpty)
    }

    @Test("pasting an image attaches it to the active note and survives reopening")
    @MainActor
    func pastedImagePersistsWithPage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alwm-note-image-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NotesStore(root: root)
        let page = store.createPage(title: "Image note")
        let imageData = try makePNGData()

        let attachmentID = try #require(store.addImageAttachment(imageData, toPageID: page.id))
        store.flushPendingSaves()

        let reopened = NotesStore(root: root)
        let savedPage = try #require(reopened.page(page.id))
        let attachment = try #require(savedPage.attachments.first)
        #expect(attachment.id == attachmentID)
        #expect(try Data(contentsOf: reopened.imageURL(for: attachment, in: page.id)) == imageData)
    }

    @Test("removing an attachment can be undone without losing its image data")
    @MainActor
    func attachmentRemovalCanBeUndone() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alwm-note-image-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NotesStore(root: root)
        let page = store.createPage(title: "Undo image")
        let png = try makePNGData()
        let attachmentID = try #require(store.addImageAttachment(png, toPageID: page.id))
        let attachment = try #require(store.page(page.id)?.attachments.first)
        store.undoManager.removeAllActions()

        // Unit tests do not have AppKit's event loop to close the implicit
        // undo group between UI actions, so model the removal as one event.
        store.undoManager.beginUndoGrouping()
        store.removeImageAttachment(attachmentID, fromPageID: page.id)
        store.undoManager.endUndoGrouping()
        store.undoManager.undo()

        #expect(store.page(page.id)?.attachments == [attachment])
        #expect(try Data(contentsOf: store.imageURL(for: attachment, in: page.id)) == png)
    }

    @Test("image pasteboard data is recognized as an image attachment")
    @MainActor
    func readsImageFromPasteboard() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        let image = try makeImage()
        #expect(pasteboard.writeObjects([image]))

        let images = NotepadImagePasteboard.readImageData(from: pasteboard)

        #expect(images.count == 1)
        #expect(NSImage(data: try #require(images.first)) != nil)
    }

    @Test("pasteboard PNG items are attached when Command-V is pressed in Notepad")
    @MainActor
    func commandVPasteAttachesImage() throws {
        _ = NSApplication.shared
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        let png = try makePNGData()
        let item = NSPasteboardItem()
        #expect(item.setData(png, forType: NSPasteboard.PasteboardType("public.png")))
        #expect(pasteboard.writeObjects([item]))

        let panel = NotepadKeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        var pasted: [Data] = []
        panel.onPasteImageData = { pasted = $0 }
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: panel.windowNumber,
            context: nil,
            characters: "v",
            charactersIgnoringModifiers: "v",
            isARepeat: false,
            keyCode: 9
        ))

        #expect(panel.handleImagePaste(event, from: pasteboard))
        #expect(pasted.count == 1)
        #expect(NSImage(data: try #require(pasted.first)) != nil)
    }

    @MainActor
    private func makePNGData() throws -> Data {
        let image = try makeImage()
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    @MainActor
    private func makeImage() throws -> NSImage {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        return image
    }
}
