import Foundation

/// Device-local reading UI state, separate from generated content and learning mastery.
struct CourseReadingBookmark: Codable, Equatable {
    let pageID: String
    var offset: Double
    var isAtEnd: Bool
}

enum CourseReadingOrder {
    static func lessons(in nodes: [CourseLearningNode]) -> [CourseLearningNode] {
        nodes.flatMap { node in
            (node.kind == .markdown ? [node] : []) + lessons(in: node.children)
        }
    }

    static func resume(in nodes: [CourseLearningNode], bookmark: CourseReadingBookmark?) -> CourseLearningNode? {
        let ordered = lessons(in: nodes)
        return ordered.first { $0.pageID == bookmark?.pageID } ?? ordered.first
    }

    static func next(after pageID: String, in nodes: [CourseLearningNode]) -> CourseLearningNode? {
        let ordered = lessons(in: nodes)
        guard let index = ordered.firstIndex(where: { $0.pageID == pageID }),
              ordered.indices.contains(index + 1) else { return nil }
        return ordered[index + 1]
    }
}
