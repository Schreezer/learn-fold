import Foundation
import NativeBlockEditorCore

public struct NativeEditorMCPToolDefinition: Hashable, Sendable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue
    public var readOnly: Bool
    public var destructive: Bool

    public init(
        name: String,
        description: String,
        inputSchema: JSONValue,
        readOnly: Bool = false,
        destructive: Bool = false
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.readOnly = readOnly
        self.destructive = destructive
    }
}

public enum NativeEditorMCPToolCatalog {
    public static let search = "native-editor-search"
    public static let fetch = "native-editor-fetch"
    public static let createPages = "native-editor-create-pages"
    public static let updatePage = "native-editor-update-page"
    public static let movePages = "native-editor-move-pages"
    public static let duplicatePage = "native-editor-duplicate-page"
    public static let getAsyncTask = "native-editor-get-async-task"

    public static let tools: [NativeEditorMCPToolDefinition] = [
        .init(
            name: search,
            description: "Search the Native Editor library. This follows Notion MCP search semantics and returns matching pages with IDs, URLs, titles, and snippets.",
            inputSchema: objectSchema(
                properties: [
                    "query": stringSchema("Text to search for in page titles and content."),
                    "limit": integerSchema("Maximum number of results. Defaults to 40."),
                ],
                required: ["query"]
            ),
            readOnly: true
        ),
        .init(
            name: fetch,
            description: "Fetch a page as enhanced Markdown by ID or native-editor URL. Pass 'self' to inspect the connected library and available tool access.",
            inputSchema: objectSchema(
                properties: [
                    "id": stringSchema("A page ID, native-editor:// page URL, or the special value 'self'."),
                ],
                required: ["id"]
            ),
            readOnly: true
        ),
        .init(
            name: createPages,
            description: "Create one or more pages from enhanced Markdown, matching Notion MCP create-pages behavior. Pages may be created synchronously or as an async task.",
            inputSchema: objectSchema(
                properties: [
                    "parent": objectSchema(properties: [
                        "page_id": stringSchema("Parent page or folder ID."),
                    ]),
                    "pages": arraySchema(
                        objectSchema(
                            properties: [
                                "properties": objectSchema(
                                    properties: [
                                        "title": stringSchema("Page title."),
                                        "course_node_id": stringSchema("Stable course node identifier."),
                                        "course_role": stringSchema("Course role such as course, chapter, lesson, context, or agent_notes."),
                                        "generation_status": enumSchema(
                                            ["pending_generation", "generating", "partially_generated", "generated"],
                                            description: "Current generation state for this course page."
                                        ),
                                        "bootstrap_status": stringSchema("Root-course bootstrap state, such as building or ready_for_learning."),
                                    ],
                                    required: ["title"]
                                ),
                                "content": stringSchema("Initial enhanced Markdown content."),
                                "icon": stringSchema("Optional icon name."),
                            ],
                            required: ["properties"]
                        ),
                        description: "Pages to create."
                    ),
                    "allow_async": booleanSchema("Create in the background and return an async task handle."),
                ],
                required: ["pages"]
            )
        ),
        .init(
            name: updatePage,
            description: "Update page content using Notion-style enhanced Markdown commands: update_content, replace_content, insert_content, replace_content_range, update_properties, or trash. Exact text matches are validated before mutation. Content commands apply any supplied title/course properties in the same revision-checked transaction.",
            inputSchema: objectSchema(
                properties: [
                    "page_id": stringSchema("Page ID or native-editor page URL."),
                    "expected_revision": integerSchema("Revision returned by the most recent fetch. The update is rejected if the learner changed the page since then."),
                    "command": enumSchema(
                        ["update_content", "replace_content", "insert_content", "replace_content_range", "update_properties", "trash"],
                        description: "Update command."
                    ),
                    "content_updates": arraySchema(
                        objectSchema(
                            properties: [
                                "old_str": stringSchema("Exact case-sensitive content to find."),
                                "new_str": stringSchema("Replacement enhanced Markdown."),
                                "replace_all_matches": booleanSchema("Replace every match instead of requiring exactly one."),
                            ],
                            required: ["old_str", "new_str"]
                        ),
                        description: "Search-and-replace operations for update_content."
                    ),
                    "new_str": stringSchema("Complete replacement Markdown for replace_content."),
                    "content": stringSchema("Markdown used by insert_content or replace_content_range."),
                    "position": objectSchema(properties: [
                        "type": enumSchema(["start", "end"], description: "Insertion position."),
                    ]),
                    "after": stringSchema("Legacy ellipsis selection after which content is inserted."),
                    "content_range": stringSchema("Legacy ellipsis selection to replace."),
                    "properties": objectSchema(properties: [
                        "title": stringSchema("New page title."),
                        "course_node_id": stringSchema("Stable course node identifier."),
                        "course_role": stringSchema("Course role such as course, chapter, lesson, context, or agent_notes."),
                        "generation_status": enumSchema(
                            ["pending_generation", "generating", "partially_generated", "generated"],
                            description: "Current generation state for this course page."
                        ),
                        "bootstrap_status": stringSchema("Root-course bootstrap state, such as building or ready_for_learning."),
                    ]),
                    "in_trash": booleanSchema("Whether the page should be placed in trash."),
                    "allow_deleting_content": booleanSchema("Explicitly allow removal of child-page or database blocks."),
                    "allow_async": booleanSchema("Apply a large content update as an async task."),
                ],
                required: ["page_id", "command", "expected_revision"]
            ),
            destructive: true
        ),
        .init(
            name: movePages,
            description: "Move one or more pages to a new parent, preserving page ownership and references.",
            inputSchema: objectSchema(
                properties: [
                    "page_ids": arraySchema(stringSchema("Page ID."), description: "Pages to move."),
                    "new_parent": objectSchema(
                        properties: ["page_id": stringSchema("Destination page or folder ID.")],
                        required: ["page_id"]
                    ),
                ],
                required: ["page_ids", "new_parent"]
            )
        ),
        .init(
            name: duplicatePage,
            description: "Duplicate a page and its nested page subtree. Like Notion MCP, duplication runs asynchronously.",
            inputSchema: objectSchema(
                properties: ["page_id": stringSchema("Page ID to duplicate.")],
                required: ["page_id"]
            )
        ),
        .init(
            name: getAsyncTask,
            description: "Retrieve the status and result of an async create, update, or duplicate operation.",
            inputSchema: objectSchema(
                properties: ["task_id": stringSchema("Async task ID.")],
                required: ["task_id"]
            ),
            readOnly: true
        ),
    ]

    private static func objectSchema(
        properties: [String: JSONValue],
        required: [String] = []
    ) -> JSONValue {
        var value: [String: JSONValue] = [
            "type": "object",
            "properties": .object(properties),
            "additionalProperties": false,
        ]
        if !required.isEmpty { value["required"] = .array(required.map(JSONValue.string)) }
        return .object(value)
    }

    private static func stringSchema(_ description: String) -> JSONValue {
        ["type": "string", "description": .string(description)]
    }

    private static func integerSchema(_ description: String) -> JSONValue {
        ["type": "integer", "description": .string(description), "minimum": 1]
    }

    private static func booleanSchema(_ description: String) -> JSONValue {
        ["type": "boolean", "description": .string(description)]
    }

    private static func enumSchema(_ values: [String], description: String) -> JSONValue {
        [
            "type": "string",
            "enum": .array(values.map(JSONValue.string)),
            "description": .string(description),
        ]
    }

    private static func arraySchema(_ items: JSONValue, description: String) -> JSONValue {
        ["type": "array", "items": items, "description": .string(description)]
    }
}

public struct NativeEditorMCPToolResult: Hashable, Sendable {
    public var value: JSONValue
    public var isError: Bool

    public init(value: JSONValue, isError: Bool = false) {
        self.value = value
        self.isError = isError
    }
}
