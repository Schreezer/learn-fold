# Learnfold TestFlight — What to Test

## Summary

- Introduced the Learnfold course library and guided new-course flow.
- Added topic, link, file, and photo source intake.
- Added a short diagnostic, course-plan review, and progressive lesson generation.
- Added course-scoped questions and course workspace reading.
- Simplified Course Settings to show only currently supported learning agents.
- Show connected Hermes details instead of a redundant connection prompt.
- Added a persistent code-block preference: wrap long lines or scroll horizontally.

Learnfold is an early external beta. Visible adaptation, reassessment, citations, continuation, and sync behavior are active development areas rather than finished claims.

## What to test

1. Create a course from a topic and complete the diagnostic.
2. Review the proposed course plan before approving it.
3. Generate the first lesson, open it, then return to the course library and resume.
4. Add a link, file, or photo source and confirm the source remains attached to the course.
5. Ask a question from inside a course and confirm the response remains scoped to that course.
6. In Course Settings, confirm an already connected Hermes server is shown as connected and unavailable agents are hidden.
7. In a lesson with a long code line, turn wrapping off and confirm the code block scrolls horizontally without wrapping.
8. Relaunch during and after course generation and report any lost progress, duplicate content, or misleading readiness state.

## Feedback

Please include the course title, selected learning agent, the last visible step, and a screenshot when reporting a problem.
