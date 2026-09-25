import { describe, expect, it } from "vitest"

import { COURSE_AGENT_PROMPT, QUESTION_FENCE } from "../src/course-prompt"

describe("course prompt", () => {
  it("teaches the multiple-choice fence the iOS chat parses", () => {
    expect(QUESTION_FENCE).toBe("learnfold-question")
    expect(COURSE_AGENT_PROMPT).toContain(`\`\`\`${QUESTION_FENCE}\n`)
    expect(COURSE_AGENT_PROMPT).toContain("For a bounded-answer question")
    expect(COURSE_AGENT_PROMPT).toContain("Ask at least one such fenced question")
    expect(COURSE_AGENT_PROMPT).toContain("genuinely distinct, non-overlapping answers")
    expect(COURSE_AGENT_PROMPT).toContain("not a tool call")
    expect(COURSE_AGENT_PROMPT).toContain("works in New Course and course-building chat")
  })

  it("asks assessment questions in separate turns, including the open-ended diagnostic", () => {
    expect(COURSE_AGENT_PROMPT).toContain("Ask only one assessment question in each reply")
    expect(COURSE_AGENT_PROMPT).toContain("wait for the learner's answer before asking another")
    expect(COURSE_AGENT_PROMPT).toContain("Never bundle questions in a numbered list")
    expect(COURSE_AGENT_PROMPT).toContain("Do not present bounded choices as plain-text numbered questions")
    expect(COURSE_AGENT_PROMPT).toContain("Ask that question in its own reply, without a fence")
  })

  it("keeps the example block well formed", () => {
    const match = COURSE_AGENT_PROMPT.match(/```learnfold-question\n([\s\S]*?)\n```/)
    expect(match).not.toBeNull()
    const lines = match![1].split("\n")
    expect(lines[0]).toMatch(/\?$/)
    const options = lines.slice(1)
    expect(options.length).toBeGreaterThanOrEqual(2)
    expect(options.length).toBeLessThanOrEqual(5)
    for (const option of options) expect(option).toMatch(/^- \S/)
    expect(new Set(options.map((option) => option.toLowerCase())).size).toBe(options.length)
  })
})
