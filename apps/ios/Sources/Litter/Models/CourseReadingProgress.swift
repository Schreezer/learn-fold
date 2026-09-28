import Foundation

/// Device-local reading UI state, separate from generated content and learning mastery.
struct CourseReadingBookmark: Codable, Equatable {
    let pageID: String
    var offset: Double
    var isAtEnd: Bool
}

enum CourseReadingOrder {
    /// The planned reading path. Branch pages hanging off a lesson are
    /// optional side paths, so they are never part of this order.
    static func lessons(in nodes: [CourseLearningNode]) -> [CourseLearningNode] {
        nodes.flatMap { node in
            node.kind == .markdown ? [node] : lessons(in: node.children)
        }
    }

    static func resume(in nodes: [CourseLearningNode], bookmark: CourseReadingBookmark?) -> CourseLearningNode? {
        let ordered = lessons(in: nodes)
        guard let pageID = bookmark?.pageID else { return ordered.first }
        return ordered.first { $0.pageID == pageID }
            ?? trunkLesson(containing: pageID, in: ordered)
            ?? ordered.first
    }

    static func next(after pageID: String, in nodes: [CourseLearningNode]) -> CourseLearningNode? {
        let ordered = lessons(in: nodes)
        let anchorPageID = ordered.contains { $0.pageID == pageID }
            ? pageID
            // Finishing a branch continues the main path after its lesson.
            : trunkLesson(containing: pageID, in: ordered)?.pageID
        guard let anchorPageID,
              let index = ordered.firstIndex(where: { $0.pageID == anchorPageID }),
              ordered.indices.contains(index + 1) else { return nil }
        return ordered[index + 1]
    }

    /// The planned lesson whose branches contain `pageID`, at any depth.
    static func trunkLesson(
        containing pageID: String,
        in ordered: [CourseLearningNode]
    ) -> CourseLearningNode? {
        func contains(_ node: CourseLearningNode) -> Bool {
            node.children.contains { $0.pageID == pageID || contains($0) }
        }
        return ordered.first(where: contains)
    }
}
