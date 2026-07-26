#if os(iOS)
import NativeBlockEditorEngine
import UIKit
import UniformTypeIdentifiers

enum EditorClipboard {
    static let fragmentType = "com.forgeme.native-block-editor.fragment+json"
    static let markdownType = "net.daringfireball.markdown"

    static func write(_ document: BlockDocument) throws {
        let json = try JSONEncoder().encode(document)
        let html = documentToHTML(document)
        let markdown = documentToMarkdown(document)
        let text = document.plainText
        UIPasteboard.general.setItems([[
            fragmentType: json,
            UTType.html.identifier: html,
            markdownType: markdown,
            UTType.utf8PlainText.identifier: text,
        ]], options: [.localOnly: false])
    }

    static func read() throws -> BlockDocument? {
        for item in UIPasteboard.general.items {
            if let data = data(from: item[fragmentType]),
               let document = try? JSONDecoder().decode(BlockDocument.self, from: data) {
                return document
            }
            if let data = data(from: item[UTType.html.identifier]),
               let html = String(data: data, encoding: .utf8) {
                return try htmlToDocument(html)
            }
            if let data = data(from: item[markdownType]),
               let markdown = String(data: data, encoding: .utf8) {
                return try markdownToDocument(markdown)
            }
            if let data = data(from: item[UTType.utf8PlainText.identifier]),
               let text = String(data: data, encoding: .utf8) {
                return BlockDocument(root: BlockNode(type: "page", children: [.paragraph(text)]))
            }
        }
        if let text = UIPasteboard.general.string {
            return BlockDocument(root: BlockNode(type: "page", children: [.paragraph(text)]))
        }
        return nil
    }

    private static func data(from value: Any?) -> Data? {
        if let data = value as? Data { return data }
        if let string = value as? String { return Data(string.utf8) }
        return nil
    }
}
#endif
