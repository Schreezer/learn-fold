import Foundation
import NativeEditorMCP

struct CourseMCPToolDefinition {
    let name: String
    let description: String
    let inputSchema: [String: Any]
    let readOnly: Bool
    let destructive: Bool
    let openWorld: Bool

    var jsonObject: [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": inputSchema,
            "annotations": [
                "readOnlyHint": readOnly,
                "destructiveHint": destructive,
                "idempotentHint": readOnly,
                "openWorldHint": openWorld,
            ],
        ]
    }
}

enum CourseAgentTools {
    static let mcpServerName = "learnfold_course"
    static let mcpDirectNamespace = "mcp__\(mcpServerName)"
    static let workspaceIDArgument = "workspace_id"
    static let presentPlan = "present_course_plan"
    static let courseBash = "course_bash"

    static func dynamicToolSpec() throws -> AppDynamicToolSpec {
        try DynamicToolSpecParams(
            name: presentPlan,
            description: """
            Present a complete course plan in the native course card after you have enough context. Speak a short natural-language introduction first, then call this tool. Do not print the plan as JSON or Markdown. Call it again with the same plan_id and a higher revision whenever the learner asks to change the plan. Do not call it after the learner approves the plan; begin building the shared native course pages instead.
            """,
            inputSchema: AnyEncodable(schema)
        ).rpcSpec()
    }

    static func courseBashDynamicToolSpec() throws -> AppDynamicToolSpec {
        let schemaData = try JSONSerialization.data(
            withJSONObject: addingWorkspaceID(to: courseBashSchema),
            options: [.sortedKeys]
        )
        return AppDynamicToolSpec(
            name: courseBash,
            description: """
            Run a shell script on the learner's iPhone against only the active course folder at /workspace. The workspace is read-only until the learner approves the protected course plan and read-write afterward. Network sockets and symbolic links are unavailable. Include the exact active workspace_id in every call.
            """,
            inputSchemaJson: String(decoding: schemaData, as: UTF8.self),
            deferLoading: false
        )
    }

    static func documentToolSpecs() throws -> [AppDynamicToolSpec] {
        try NativeEditorMCPToolCatalog.tools.map { tool in
            let schemaData = try JSONEncoder().encode(tool.inputSchema)
            return AppDynamicToolSpec(
                name: tool.name,
                description: tool.description,
                inputSchemaJson: String(data: schemaData, encoding: .utf8) ?? "{}",
                deferLoading: false
            )
        }
    }

    static func mcpToolDefinitions() throws -> [CourseMCPToolDefinition] {
        let planSchemaData = try JSONEncoder().encode(AnyEncodable(schema))
        let planSchema = try schemaObject(from: planSchemaData)
        var definitions = [
            CourseMCPToolDefinition(
                name: presentPlan,
                description: """
                Present a complete course plan in Learnfold's native approval card after you have enough learner context. Do not print the plan as JSON or Markdown. Call it again with the same plan_id and a higher revision when the learner requests changes.
                """,
                inputSchema: addingWorkspaceID(to: planSchema),
                readOnly: true,
                destructive: false,
                openWorld: false
            )
        ]
        definitions.append(
            CourseMCPToolDefinition(
                name: courseBash,
                description: """
                Run a shell script on this iPhone against the live course folder at /workspace. Before the learner approves the latest protected course plan, /workspace is read-only so you may inspect deterministic source material but cannot alter course files. After approval it is read-write. The shell cannot navigate to sibling courses or unrelated app files, symbolic links are unsupported, and internet/network sockets are unavailable. Use normal commands such as find, grep, sed, awk, cat, cp, mv, mkdir, and rm. Commands may partially modify files after approval even when they exit nonzero, so inspect the workspace before retrying a failed mutation.
                """,
                inputSchema: addingWorkspaceID(to: courseBashSchema),
                readOnly: false,
                destructive: true,
                openWorld: false
            )
        )
        definitions.append(contentsOf: try NativeEditorMCPToolCatalog.tools.map { tool in
            let schemaData = try JSONEncoder().encode(tool.inputSchema)
            return CourseMCPToolDefinition(
                name: tool.name,
                description: tool.description,
                inputSchema: addingWorkspaceID(to: try schemaObject(from: schemaData)),
                readOnly: tool.readOnly,
                destructive: tool.destructive,
                openWorld: false
            )
        })
        return definitions
    }

    static func isEditorTool(_ name: String) -> Bool {
        NativeEditorMCPToolCatalog.tools.contains(where: { $0.name == name })
    }

    static func isMutatingEditorTool(_ name: String) -> Bool {
        NativeEditorMCPToolCatalog.tools.contains {
            $0.name == name && !$0.readOnly
        }
    }

    static func isCourseTool(_ name: String) -> Bool {
        name == presentPlan || name == courseBash || isEditorTool(name)
    }

    static func isMutatingCourseTool(_ name: String) -> Bool {
        name == courseBash || isMutatingEditorTool(name)
    }

    private static func schemaObject(from data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.coderInvalidValue)
        }
        return object
    }

    private static func addingWorkspaceID(to schema: [String: Any]) -> [String: Any] {
        var schema = schema
        var properties = schema["properties"] as? [String: Any] ?? [:]
        properties[workspaceIDArgument] = [
            "type": "string",
            "description": "The current Learnfold course workspace ID. Use the final path component of the course cwd.",
            "minLength": 1,
        ]
        schema["properties"] = properties
        var required = schema["required"] as? [String] ?? []
        if !required.contains(workspaceIDArgument) {
            required.append(workspaceIDArgument)
        }
        schema["required"] = required
        schema["additionalProperties"] = false
        return schema
    }

    private static let schema = JSONSchema.object([
        "plan_id": .string(description: "Stable lowercase identifier for this plan. Reuse it for revisions."),
        "revision": .integer(description: "Positive revision number. Increase it for every replacement plan."),
        "title": .string(description: "Human-facing course title."),
        "summary": .string(description: "One concise sentence describing the course."),
        "outcome": .string(description: "What the learner will understand or be able to build."),
        "starting_point": .string(description: "The learner knowledge and experience this plan assumes."),
        "focus_gap": .string(description: "The most important gap this course should close."),
        "estimated_duration": .string(description: "Short human-readable estimate, such as 3h 30m or Adaptive."),
        "chapters": .array(items: .object([
            "id": .string(description: "Stable lowercase chapter slug."),
            "title": .string(description: "Short chapter title."),
            "objective": .string(description: "What this chapter teaches."),
            "deliverables": .array(items: .string(description: "Lesson, example, exercise, or artifact created in this chapter."))
        ], required: ["id", "title", "objective", "deliverables"]))
    ], required: [
        "plan_id",
        "revision",
        "title",
        "summary",
        "outcome",
        "starting_point",
        "focus_gap",
        "estimated_duration",
        "chapters"
    ])

    private static let courseBashSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "script": [
                "type": "string",
                "description": "Shell script to run from /workspace.",
                "minLength": 1,
                "maxLength": CourseBashTool.maximumScriptBytes,
            ],
            "timeout_seconds": [
                "type": "integer",
                "description": "Optional execution deadline from 1 through 120 seconds.",
                "minimum": 1,
                "maximum": CourseBashTool.maximumTimeoutSeconds,
            ],
        ],
        "required": ["script"],
        "additionalProperties": false,
    ]
}
