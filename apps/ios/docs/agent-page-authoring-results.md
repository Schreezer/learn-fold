# Agent page authoring comparison

Date: 2026-09-12

**Recommendation: keep the current page editing tools as the default.** The editable Markdown draft prototype produced correct results, but did not improve editing quality in these scenarios. It required more model requests, tool calls, and elapsed time.

## What was run

Actual LLM calls used OpenCode Go's Responses endpoint with `gpt-5.6-luna`, matching the model and endpoint in Learnfold's current hosted-agent source. The existing `OPENCODE_API_KEY` environment variable supplied authentication. No new key was created and no credential was stored in the results.

The final comparison used three scenarios, two methods, and three repetitions per pair: **18 independent agent sessions and 78 successful model requests**. Each pair started from an identical native SQLite snapshot, including page ID, revision, block identities, and content, and received the same editing request. Method order alternated and calls ran sequentially.

Both methods used the actual native Markdown codec, block identity reconciliation, opaque block preservation, SQLite storage, and revision validation in `NativeEditorMCPService`.

- **Current:** the real `native-editor-fetch` and `native-editor-update-page` schemas. The agent chose targeted `update_content` in every final trial.
- **Draft:** a prototype exported a real `lesson.md` file and held the original revision outside that editable file. The agent could read, batch-edit, or rewrite the file, then explicitly apply it through native `replace_content`.

Both methods could batch several text replacements into one call. There was also an initial 18-session pilot where draft edits were limited to one replacement per call. That limitation exaggerated draft overhead, so it was corrected and the complete comparison rerun. Pilot results are retained separately and excluded from the numbers below. Total actual execution across pilot and final evaluation was 36 agent sessions and 165 successful model requests.

## Results

Times and tool counts below are medians across three repetitions for each method and scenario.

| Scenario | Current success | Draft success | Current time | Draft time | Current tool calls | Draft tool calls |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Correct one of two similar interest examples | 3/3 | 3/3 | 7.44 s | 10.12 s | 2 | 3 |
| Rewrite an introduction and add two worked examples while preserving native blocks | 3/3 | 3/3 | 9.91 s | 13.90 s | 2 | 3 |
| Recover from a concurrent learner edit | 3/3 | 3/3 | 11.71 s | 16.17 s | 4 | 6 |

Across the nine final trials per method:

| Metric | Current | Draft |
| --- | ---: | ---: |
| Successful tasks | 9/9 | 9/9 |
| Model requests | 33 | 45 |
| Tool calls | 24 | 36 |
| Input tokens, including replayed history | 52,035 | 59,245 |
| Cached input tokens, included in the input total | 28,026 | 27,937 |
| Output tokens | 3,859 | 4,057 |
| Total elapsed trial time | 89.37 s | 118.39 s |
| Expected revision conflicts | 3 | 3 |
| Unexpected tool errors or provider failures | 0 | 0 |

The draft method used about 14% more input tokens and 32% more total elapsed time in this run. Those are observed results, not a fixed performance guarantee. Provider latency, caching, and output variation affect the timings. No dollar cost is inferred from token counts.

## How the agents behaved

For ordinary edits, the current method consistently used:

`fetch -> update_content`

The draft method consistently used:

`open_page -> edit_file -> apply_page`

Both agents handled multiple requested changes in one batch. The extra apply step accounts for an additional tool turn in the draft method. Each tool turn requires another model continuation in this harness.

In the concurrent-edit scenario, the harness inserted the same learner note immediately before each agent's first attempted page commit. The actual native service rejected the stale revision. Both agents recovered correctly:

- Current: `fetch -> rejected update -> fetch -> successful update`.
- Draft: `open -> edit -> rejected apply -> open -> edit -> successful apply`.

All six concurrent-edit trials preserved the newly inserted learner note verbatim. Both methods also preserved the original note, changed the requested review interval, and replaced the exercise. The injected conflicts are expected behavior and are not counted as task failures.

## Content and preservation review

Automated checks passed for all 18 final trials. They checked requested edits, unrelated section preservation, page identity, title, course metadata, and conflict recovery. The caching scenario additionally checked exact native visualization and opaque plugin block equality, including their stable IDs and payloads.

I inspected the final lesson text for every final trial and read all six rewritten introductions and worked examples. This was an unblinded qualitative review, not a separate LLM judge score.

- The interest example outputs were identical across both methods. The corrected example used 8% and 1,080; the other example and learner note were unchanged.
- Both methods produced beginner-friendly caching introductions. All six outputs included an ETag/If-None-Match/304 example and a fingerprinted CSS example with the requested cache header. The explanations distinguished avoiding a body download from avoiding a network request. I found no clear quality advantage for either method.
- The concurrent-edit outputs were identical across both methods and preserved both learner notes.

## Decision

Do not replace the existing tools with the file-draft workflow on the strength of suggestion one. The current interface already lets this model perform focused, revision-safe edits efficiently. The file prototype adds a staging step without a demonstrated correctness or quality gain here.

Retain the prototype as an evaluation harness. A future reason to revisit file drafts would be a demonstrated need for large-document editing, repository-wide transformations, richer shell/patch workflows, or human review of a draft before application. Those benefits were not measured here.

## Scope and evidence

This was a host-side native engine test with a focused agent prompt and only the relevant editing tools. It did not run the full production agent prompt, the iPhone app, `CourseDocumentRepository`, approval UI, autosave journal, cloud sync, or rendering. It therefore establishes native engine/tool behavior on these fixtures, not end-to-end device or production proof.

The draft tools support real file reads, batched exact edits, and whole-file writes. They do not provide a full shell or unified-diff patch environment. One model and three repetitions per scenario are too small to generalize across providers or large documents.

- [Rerunnable harness and instructions](../../../tools/page-edit-benchmark/README.md)
- [Final detailed report](../../../artifacts/page-edit-benchmark/batched-2026-09-12/results.md)
- [Final metrics](../../../artifacts/page-edit-benchmark/batched-2026-09-12/summary.json)
- [Final run manifest](../../../artifacts/page-edit-benchmark/batched-2026-09-12/manifest.json)
- [Source hashes](../../../artifacts/page-edit-benchmark/batched-2026-09-12/source-hashes.json)
- [Pilot metrics, excluded from the final comparison](../../../artifacts/page-edit-benchmark/live-2026-09-12/summary.json)
- [Original proposal](agent-page-authoring-proposal.md)

Each trial directory contains before/after Markdown, native block snapshots, the disposable database, exact request payloads, provider responses with usage, and tool transcripts. Artifacts are local and ignored by Git. The harness and this summary are ordinary repository files. No production pages were edited.
