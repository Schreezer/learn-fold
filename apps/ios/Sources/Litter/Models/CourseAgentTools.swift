import Foundation

enum CourseAgentTools {
    static let presentPlan = "present_course_plan"

    static func dynamicToolSpec() throws -> AppDynamicToolSpec {
        try DynamicToolSpecParams(
            name: presentPlan,
            description: """
            Present a complete course plan in the native course card after you have enough context. Speak a short natural-language introduction first, then call this tool. Do not print the plan as JSON or Markdown. Call it again with the same plan_id and a higher revision whenever the learner asks to change the plan. Do not call it after the learner approves the plan; begin writing the course files instead.
            """,
            inputSchema: AnyEncodable(schema)
        ).rpcSpec()
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
}
