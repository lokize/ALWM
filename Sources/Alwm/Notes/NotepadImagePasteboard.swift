import AppKit

@MainActor
enum NotepadImagePasteboard {
    static let maximumImageBytes = 25 * 1024 * 1024

    static func readImageData(from pasteboard: NSPasteboard = .general) -> [Data] {
        let imageTypes: Set<NSPasteboard.PasteboardType> = [
            NSPasteboard.PasteboardType("public.png"),
            NSPasteboard.PasteboardType("public.tiff"),
            NSPasteboard.PasteboardType("public.jpeg"),
            NSPasteboard.PasteboardType("public.heic"),
            NSPasteboard.PasteboardType("com.compuserve.gif")
        ]
        let itemImages = (pasteboard.pasteboardItems ?? []).compactMap { item -> NSImage? in
            guard let type = item.types.first(where: imageTypes.contains),
                  let data = item.data(forType: type) else { return nil }
            return NSImage(data: data)
        }
        if !itemImages.isEmpty {
            return itemImages.compactMap(pngData(from:))
        }

        let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage] ?? []
        if !images.isEmpty {
            return images.compactMap(pngData(from:))
        }

        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        return urls.compactMap(NSImage.init(contentsOf:)).compactMap(pngData(from:))
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]),
              png.count <= maximumImageBytes else { return nil }
        return png
    }
}
