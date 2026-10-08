import AppKit
import Foundation
import Testing
@testable import Alwm

@Suite("Notepad editing behavior")
struct NotepadEditingBehaviorTests {
    @Test("Enter inserts an empty block of the same kind and style immediately below")
    func enterContinuesCurrentBlock() throws {
        let categoryID = UUID()
        let before = NoteBlock(kind: .paragraph, text: "before")
        let current = NoteBlock(kind: .callout, text: "remember this", calloutStyle: .warn)
        let after = NoteBlock(kind: .heading2, text: "after")
        let page = NotePage(
            categoryID: categoryID,
            blocks: [before, current, after]
        )

        let updated = try #require(page.insertingContinuation(after: current.id))

        #expect(updated.page.blocks.map(\.id) == [before.id, current.id, updated.insertedBlockID, after.id])
        let inserted = try #require(updated.page.blocks.first { $0.id == updated.insertedBlockID })
        #expect(inserted.id != current.id)
        #expect(inserted.kind == .callout)
        #expect(inserted.text.isEmpty)
        #expect(inserted.calloutStyle == .warn)
    }

    @Test("Enter on a todo creates a fresh unchecked todo")
    func enterResetsTodoState() throws {
        let current = NoteBlock(kind: .todo, text: "done", checked: true)
        let page = NotePage(categoryID: UUID(), blocks: [current])

        let updated = try #require(page.insertingContinuation(after: current.id))
        let inserted = try #require(updated.page.blocks.first { $0.id == updated.insertedBlockID })

        #expect(inserted.kind == .todo)
        #expect(inserted.text.isEmpty)
        #expect(!inserted.checked)
        #expect(inserted.id != current.id)
    }

    @Test("clicks on ALWM windows outside the overlay reach the ALWM window")
    func popupClickOutsideOverlayIsAllowed() {
        let popupPID: pid_t = 42
        let otherAppPID: pid_t = 99
        let overlay = Rect(x: 100, y: 100, width: 500, height: 300)
        let popupInfo: [String: Any] = [
            kCGWindowOwnerPID as String: popupPID,
            kCGWindowLayer as String: 101,
            kCGWindowAlpha as String: 1.0,
            kCGWindowBounds as String: ["X": 550, "Y": 150, "Width": 280, "Height": 360],
        ]
        let underlyingInfo: [String: Any] = [
            kCGWindowOwnerPID as String: otherAppPID,
            kCGWindowLayer as String: 0,
            kCGWindowAlpha as String: 1.0,
            kCGWindowBounds as String: ["X": 500, "Y": 100, "Width": 800, "Height": 600],
        ]

        let popupOwner = OverlayClickCapturePolicy.windowOwnerPID(
            atX: 600,
            y: 200,
            windowInfos: [popupInfo, underlyingInfo]
        )
        let outsideOwner = OverlayClickCapturePolicy.windowOwnerPID(
            atX: 700,
            y: 400,
            windowInfos: [underlyingInfo]
        )

        #expect(popupOwner == popupPID)
        #expect(!OverlayClickCapturePolicy.shouldConsumeOutsideClick(
            pointX: 600,
            pointY: 200,
            visibleFrames: [overlay],
            frontmostWindowOwnerPID: popupOwner,
            ownProcessID: popupPID
        ))
        #expect(outsideOwner == otherAppPID)
        #expect(OverlayClickCapturePolicy.shouldConsumeOutsideClick(
            pointX: 700,
            pointY: 400,
            visibleFrames: [overlay],
            frontmostWindowOwnerPID: outsideOwner,
            ownProcessID: popupPID
        ))
        #expect(!OverlayClickCapturePolicy.shouldConsumeOutsideClick(
            pointX: 700,
            pointY: 400,
            visibleFrames: [overlay],
            frontmostWindowOwnerPID: popupPID,
            ownProcessID: popupPID
        ))
    }
}
