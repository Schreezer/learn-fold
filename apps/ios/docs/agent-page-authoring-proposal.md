# Agent page authoring proposal

Date: 2026-09-12

Status: Suggestions for evaluation. No runtime changes implemented.

Evaluation update: [The live LLM comparison](agent-page-authoring-results.md) found both workflows correct on all three scenarios, with fewer calls and lower elapsed time for the current tools. Keep the current tools as the default; suggestion one remains an experimental option rather than a recommended replacement.

The aim is to make Learnfold pages easier for agents to edit while retaining the native editor, existing document persistence, learner edits, and approved course structure.

## 1. Make editing one existing lesson more convenient

Let an agent work with editable enhanced Markdown bound to a page identity and base revision, then submit its changes through the existing document repository. Preserve native blocks and reject stale edits.

**Clarification: most of this already exists.** `native-editor-fetch` returns enhanced Markdown, page identity, revision, and course metadata. `native-editor-update-page` accepts targeted text replacements or complete replacement Markdown with a required `expected_revision`. This proposal should not create another fetch/save API with equivalent behavior.

The incremental experiment would be an optional editing session or file projection for agents that benefit from ordinary text editing. Opening a page would capture its identity, original content, and base revision. Applying the edited text would submit a change through the repository. The existing native page library would remain authoritative; writing a Markdown file alone would not update the page.

Keep page identity and base revision in app-owned session state rather than trusting editable file metadata. Preserve learner notes, stable block identities, links, visualization blocks, and opaque references. Reject stale changes and require a fresh read before a retry. Unknown content must never silently disappear during conversion.

For agents that already handle exact text replacements well, keep the current tools. Establish a concrete usability or reliability benefit before adding a second authoring interface. Apple agents already have higher-level lesson tools, so any new interface should account for those wrappers.

Suggested pilot: edit one existing approved lesson, read it back, repeat an unchanged apply, attempt an apply after a concurrent learner edit, and round-trip an interactive visualization and an opaque native block. An unchanged apply should be a no-op. A stale apply should preserve the learner's newer content. These are proposed acceptance checks, not completed tests.

## 2. Add declarative batch authoring where it helps

Consider a small manifest describing approved pages with stable course node IDs, titles, parents, and Markdown. Applying it repeatedly should update the same pages without duplicates.

Learnfold already creates the complete approved course shell. Normal lesson generation must continue targeting the existing approved page. A manifest must not silently create missing planned pages, extend the hierarchy, or generate unrelated lessons. Structural operations should use an explicitly authorized course creation or repair path.

Validate references and revisions before mutation. Define retry behavior and whether a batch is atomic before exposing it. Never imply that existing individual page transactions already provide whole-batch atomicity. Omission from a manifest should not imply deletion by default.

## 3. Make TypeScript optional

A TypeScript helper could compile an authoring description into the same structured manifest, following Notion as Code's approach. Structured data should remain directly usable by Apple and hosted agents, without requiring Node on the iPhone.

Keep the helper small and limited to supported Learnfold operations. It should not become another runtime state owner. Any future shared canonical reconciliation should follow the repository's Rust placement rules and integrate with the existing document durability boundary.

## Current editing behavior

Native pages are structured block documents persisted through the native library and `CourseDocumentRepository`. Markdown is the agent-facing representation, not the canonical lesson file format.

The shared course tool catalog exposes:

| Tool | Purpose |
| --- | --- |
| `native-editor-search` | Find pages by title and content. |
| `native-editor-fetch` | Read a page as enhanced Markdown with identity, revision, and metadata; `id: "self"` inspects the library. |
| `native-editor-create-pages` | Create one or more native pages from Markdown. |
| `native-editor-update-page` | Edit content, properties, or trash state with a required expected revision. |
| `native-editor-move-pages` | Move pages between parents. |
| `native-editor-duplicate-page` | Duplicate a page subtree asynchronously. |
| `native-editor-get-async-task` | Inspect an asynchronous operation. |
| `present_course_plan` | Present or revise the learner's course approval card. |
| `course_bash` | Work on course-folder files on the phone; not the prescribed page-editing interface. |

The update commands are `update_content`, `replace_content`, `insert_content`, `replace_content_range`, `update_properties`, and `trash`. `update_content` uses exact `old_str` / `new_str` pairs. Ambiguous matches fail unless replacing all matches is explicitly requested.

Codex can receive the tools through the local course MCP server or dynamic tools, depending on its connection. The hosted agent uses definitions from the same catalog; Hermes receives the course definitions through its mobile-tool path. MCP-style definitions require `workspace_id`; adapters may bind the workspace for other tool paths.

Apple agents receive a smaller, mode-dependent tool set. `learnfold_generate_lesson` accepts structured lesson content. `learnfold_append_lesson_section` accepts a heading and body. Their Swift wrappers resolve the target, fetch its revision, and call the same native editor update path. The planning tool is exposed when the mode permits it.

For direct page editing, the instructed flow is:

1. Read relevant course context and identify the exact target page.
2. Fetch that page immediately before editing.
3. Submit a focused update with the returned revision. Preserve unrelated learner content.
4. The repository flushes pending learner edits and checks the approved plan for mutations.
5. The editor validates the revision and text selection, converts edited Markdown back into blocks, preserves course metadata, reconciles stable block IDs, and checks protected child-page/database references.
6. A revision-checked save commits the native page. The result contains the updated page representation and revision. Repository notifications update consumers and schedule cloud sync.
7. On conflict, reread and adapt the change to the learner's newer content. Do not blindly resend a whole-page replacement with a newer revision.

Tool availability is broader than permission for a particular turn. The initial approved lesson workflow explicitly limits the agent to its named existing leaf. Instructions prefer targeted edits and forbid treating filesystem Markdown as canonical course pages.

## Source pointers

- [Course tool definitions](../Sources/Litter/Models/CourseAgentTools.swift)
- [Native editor tool catalog](../../../shared/third_party/NativeBlockEditor/Sources/NativeEditorMCP/NativeEditorMCPToolCatalog.swift)
- [Page fetch, update, and Markdown mutation handling](../../../shared/third_party/NativeBlockEditor/Sources/NativeEditorMCP/NativeEditorMCPService.swift)
- [Enhanced Markdown codec](../../../shared/third_party/NativeBlockEditor/Sources/NativeEditorMCP/NotionEnhancedMarkdownCodec.swift)
- [Document repository](../Sources/Litter/Models/CourseDocumentRepository.swift)
- [Course prompts and provider tool wiring](../Sources/Litter/Models/CourseExperienceStore.swift)
- [Apple lesson tool wrappers](../Sources/Litter/Models/AppleCourseAgent.swift)
- [Hosted agent tool wiring](../Sources/Litter/Models/HostedCourseAgent.swift)
- [Local course MCP server](../Sources/Litter/Models/CourseMCPServer.swift)
- [Notion as Code guide](https://app.notion.com/p/notionambassadors/How-to-use-Notion-as-Code-3973139dbfef802eb77cfbe7cf08c12a)
- [Notion's public authoring template](https://github.com/makenotion/notion-as-code-template)

Evidence: current source inspection. No live agent session, app build, or page mutation was run for this document.
