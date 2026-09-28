# Learnfold TestFlight — What to Test

## Summary

- Added a built-in starter course for learning how to read, ask questions, and edit lessons.
- Reworked course maps into a reading path with progress, a clear next lesson, and side paths created from questions.
- Added tappable answer choices when an agent asks a supported multiple-choice question; free-text replies still work.
- Improved lesson reading, page editing, and recovery after interrupted course requests.
- Fixed conversation loading and streaming cases that could hide or replace a recent reply.
- Added an analytics setting and limited product events without sending lesson content.

Learnfold is an early external beta. Visible adaptation, reassessment, citations, continuation, and sync behavior are active development areas rather than finished claims.

## What to test

1. Open the built-in starter course, complete an exercise, leave the app, and resume at the next lesson.
2. Create a course, review its proposed plan, and follow the reading path through a generated lesson.
3. Ask a question in a lesson, then check that any linked side path appears beside its parent lesson.
4. When the agent asks a multiple-choice question, tap an answer; also try typing a custom answer.
5. Relaunch while a lesson or course is generating and confirm the request recovers without duplicate content.
6. Edit a lesson page, reopen it, and confirm the saved content remains readable.
7. Turn analytics off in Settings and confirm the preference stays off after relaunch.

## Feedback

Please include the course title, selected learning agent, the last visible step, and a screenshot when reporting a problem.
