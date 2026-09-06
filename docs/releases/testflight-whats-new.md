# Learnfold TestFlight — What to Test

## Summary

- Course replies now render bold, italics, headings, lists, links, code blocks, and tables, including while replies stream.
- Fixed stale history replacing Apple and focused-discussion messages, and kept focused tools in the correct course workspace.
- Fixed chained Hosted tools finishing early and surfaced model stream errors instead of silently dropping them.
- Fixed Hosted continuing after plan tools and corrected interrupted-reply recovery so already-sent messages stay in the conversation.
- Removed the empty response bubble shown alongside Hosted’s Thinking indicator before a reply arrives.
- Fixed the first Hosted message disappearing when conversation history finishes loading after you send.
- Hosted is ready by default without login. Start with Continue, or use Change agent to choose another provider.
- Hardened course creation, plan review, lesson generation, recovery, and resume flows.
- Improved source intake, course-scoped questions, workspace reading, and CloudKit synchronization.
- Improved Hermes pairing, connection recovery, and server status presentation.
- Corrected the app icon background to render as pure black.

Learnfold is an early external beta. Visible adaptation, reassessment, citations, continuation, and sync behavior are active development areas rather than finished claims.

## What to test

1. Start without logging in or configuring a server. Confirm Hosted is selected, Continue opens your library, and Change agent reveals other providers.
2. Create a course from a topic, complete the diagnostic, and review the full proposed plan before approving it.
3. Generate the first lesson, open it, then return to the course library and resume.
4. Relaunch during course or lesson generation and confirm progress recovers without duplicate content.
5. Add a link, file, or photo source and confirm the source remains attached to the course.
6. Ask a question from inside a course and confirm the response stays scoped to that course.
7. Pair or reconnect a Hermes server and confirm its connection state is accurate throughout the flow.
8. Confirm the app icon has a pure black background on the Home Screen and in TestFlight.
9. Ask Hosted for a formatted explanation with a numbered list and code sample. Check formatting in light and dark mode and with larger text.

## Feedback

Please include the course title, selected learning agent, the last visible step, and a screenshot when reporting a problem.
