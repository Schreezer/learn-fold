import Foundation
import NativeBlockEditorCore

/// Bundled, editable lessons that introduce the same reader and agent used by other courses.
enum LearnfoldStarterCourse {
    static let workspaceID = "learnfold-getting-started"
    static let title = "Make Learnfold yours"
    static let subtitle = "Learn by asking, exploring, and editing a course."

    struct Lesson: Sendable {
        let id: String
        let title: String
        let summary: String
        let markdown: String
    }

    struct Chapter: Sendable {
        let id: String
        let title: String
        let summary: String
        let lessonIDs: [String]
    }

    static let lessons: [Lesson] = [
        Lesson(
            id: "\(workspaceID)-01-navigation",
            title: "Find your way around",
            summary: "Open a lesson, return to it, and find the course map.",
            markdown: """
            # Find your way around

            This practice copy stays on this device. Read a little, try something in the app, and look at what changed. You can edit these pages and come back whenever you need them.

            The lessons are already on your device, so reading and manual editing work offline. The AI exercises need an available AI provider. If the app asks you to connect one, finish that setup before trying a prompt. You can keep reading meanwhile.

            AI page edits and linked explainers need page tools, available with Hosted, Codex, and Hermes. With an Apple provider, try the chat and manual editing exercises; the relevant lessons include an alternative.

            ## Try it

            1. Go back to the course overview. In Learn, find Start course or Continue course.
            2. Open Structure and find this lesson in the course map. Open it again.
            3. Use Next lesson at the bottom of this page to keep going.

            Later, return to My Courses, open this course, and tap Continue course to pick up your reading. You can also use Structure to jump to a particular lesson.

            ## Check the result

            You can open a lesson from the course map and return to your reading without searching through a chat. Opening a page records your reading position; it does not mean you have tried its exercise.

            We will use one small topic throughout the course. Rereading means looking at something again. Recalling means looking away and trying to explain what you remember. No subject knowledge is needed.
            """
        ),
        Lesson(
            id: "\(workspaceID)-02-ask",
            title: "Ask about the page",
            summary: "Start a conversation with the page as context.",
            markdown: """
            # Ask about the page

            You can ask questions while you read. You do not need to describe where you are each time.

            ## Practice paragraph

            Imagine learning a short recipe. You could reread the steps with the recipe open. Or you could close it, describe the steps from memory, then reopen it to check what you missed. These are different things to try. Looking away makes it easier to notice which details you cannot yet explain without help.

            ## Try it

            Tap Ask AI at the bottom of this page. It brings the current page into the conversation. Send this prompt, or put it in your own words.

            > Explain the recipe example on this page in two short sentences. Answer here in chat and leave the page unchanged.

            Read the answer, then send a follow-up.

            > Give me one small thing I can try with a recipe I already know.

            Tap Done to return to the lesson.

            ## Check the result

            The answer should refer to this page's example. The second answer should build on your conversation. Look at the page again to confirm that asking for an explanation left its text in place.

            Chat is a useful place to explore an idea before deciding whether it belongs in your course.
            """
        ),
        Lesson(
            id: "\(workspaceID)-03-selection",
            title: "Select the part that needs explaining",
            summary: "Ask about a precise passage, then request a simpler explanation.",
            markdown: """
            # Select the part that needs explaining

            Sometimes only one sentence is getting in the way. Select it so the AI can see exactly what you mean.

            ## Select this sentence

            Recalling something without looking at the original can reveal a gap between recognizing an explanation and being able to produce it yourself.

            ## Try it

            1. Press and hold the sentence above. Adjust the selection handles to include the whole sentence.
            2. Choose Ask About This in the text selection menu. If you are already editing the page, the selection toolbar uses Ask AI.
            3. Send this prompt.

            > Explain the selected sentence in everyday language. Use the recipe example. Leave the page unchanged.

            If the answer is still too dense, follow up.

            > Make it simpler. Show what I would actually do, without using the words "recalling" or "recognizing".

            ## Check the result

            The conversation should include the passage you selected. The answer should explain that passage rather than summarize the whole course. If the wrong text is attached, close the discussion and select it again.

            Tap Done to return to reading. In a selection discussion, Resolve is available when you want to mark that discussion as handled. You decide when the explanation is enough.
            """
        ),
        Lesson(
            id: "\(workspaceID)-04-prompts",
            title: "Give the AI something to work with",
            summary: "Use your interests, current understanding, and a clear request.",
            markdown: """
            # Give the AI something to work with

            A useful prompt gives the AI a topic, some context about you, and a clear request. You can add these a bit at a time.

            ## Try it

            Tap Ask AI and adapt this prompt. Replace cooking with something you are learning.

            > I am learning to cook and I often forget the order of a recipe's steps. Show me one example of rereading and one example of recalling using that situation. Keep it short and answer in chat.

            Read the answer. Tell the AI what it got wrong or what you still need.

            > My problem is remembering when to add ingredients, not remembering their names. Adjust the example for that.

            You can also tell it what you already know, ask it to avoid jargon, or ask for a slower explanation of one step.

            ## Check the result

            The revised example should use the detail you added. If it still misses the point, quote the part that is off and explain why. You do not have to start a new conversation to correct a misunderstanding.

            Save ideas you want to keep by asking for a page edit, which we will try next. An answer in chat does not automatically become part of the lesson.
            """
        ),
        Lesson(
            id: "\(workspaceID)-05-ai-edit",
            title: "Ask the AI to change this page",
            summary: "Revise a practice section and check the actual saved page.",
            markdown: """
            # Ask the AI to change this page

            A course can change as you learn. Be clear when you want the AI to edit the page itself. Name the section and say what should stay.

            This page-editing exercise uses Hosted, Codex, or Hermes. With an Apple provider, use the draft-and-edit alternative below.

            ## Try it

            Tap Ask AI and send this prompt. You can replace the cooking example with your own interest.

            > Edit this page itself. Replace only the text between the headings "Practice section" and "End of practice" with a short cooking example that compares rereading a recipe with describing its steps from memory. Add one sentence about checking the original afterward. Keep both headings, the page title, and every instruction outside that section unchanged. Do not create a new page.

            Wait for the agent to finish, then tap Done and read the practice section below.

            With an Apple provider, ask for the example in chat instead: "Draft a short cooking example comparing rereading a recipe with describing its steps from memory. Include checking the original afterward. Answer in chat." Copy the wording you want, tap Done, then use Edit page to replace only the text between Practice section and End of practice. Keep both headings and all other instructions, then tap Finish editing. The next lesson walks through manual editing.

            ## Check the result

            Look for the new example in the page, not only in the agent's reply. Check that the instructions and headings are still here. Leave this page and reopen it to see that the change was saved.

            If a provider with page tools only suggested wording in chat, follow up with "Apply that change to the Practice section on this page." If the revision misses something, ask for a specific correction.

            ## Practice section

            I read a recipe twice. Then I close it and describe the steps in order. I open the recipe again to see what I left out.

            ## End of practice

            Everything outside the practice section is part of the tutorial. Keep it when revising the example.
            """
        ),
        Lesson(
            id: "\(workspaceID)-06-manual-edit",
            title: "Make an edit yourself",
            summary: "Use the native editor and confirm your changes were saved.",
            markdown: """
            # Make an edit yourself

            You can write directly on a course page. Use this for your own wording, a note, or a small correction.

            ## Try it

            1. Tap the pencil button, Edit page.
            2. Find My practice note below and replace the placeholder with a topic you want to learn.
            3. Add a second line describing one thing you want to try.
            4. Tap the checkmark, Finish editing, when you are ready to read again.

            Changes save automatically. Watch for Changes saved. If you see Changes not saved, use Retry save before leaving.

            ## My practice note

            A topic I want to try this with: replace this with your topic.

            One thing I want to try: add your own idea here.

            ## Check the result

            Leave the page and open it again. Your words should still be in My practice note.

            For another small experiment, enter Edit page and open Document actions using the ellipsis button. You can add a heading, bulleted list, or to-do. Undo and Redo are available in the editing toolbar if you change your mind while editing.

            Manual edits are useful when you already know what you want to say. Ask the AI when you want help deciding or writing it.
            """
        ),
        Lesson(
            id: "\(workspaceID)-07-explainer",
            title: "Ask for another page",
            summary: "Create a linked explainer without replacing the lesson.",
            markdown: """
            # Ask for another page

            A side question can have its own page. This lets you explore it without making the original lesson longer.

            Creating a linked explainer uses Hosted, Codex, or Hermes. If your provider cannot create linked pages, including Apple providers, keep the side question in chat for now. Ask "Walk me through closing a recipe, describing its steps, and checking what I missed. Answer in chat." You can try creating a linked explainer in a future course using a provider with page tools. Changing the default agent in Course Settings applies to new courses; it does not change the agent for this practice copy.

            ## Try it

            Tap Ask AI and send this prompt.

            > Create a short child explainer page under this lesson called "Try recalling a recipe". Give me a simple example of closing a recipe, describing the steps, and checking what I missed. Add a link to the new page in this lesson. Preserve the existing lesson text and instructions.

            Wait for the agent to finish. Tap Done and find the new link in this lesson. Open it.

            ## Check the result

            The link should open a separate page with the title you requested. Go back and check that the original lesson is still here. Look in Structure to find where the new page sits in your course.

            You can use Ask AI on the new page too. Try asking for a different example, or select a sentence that needs explaining.

            If a provider with page tools only describes a possible page in chat, ask it to create and link the explainer. Check that the link actually opens before moving on. If page creation is unavailable, continue with the chat alternative above.

            Use a page edit to change the lesson you are reading. Ask for a separate explainer when you want somewhere to follow a side question.
            """
        ),
        Lesson(
            id: "\(workspaceID)-08-quiz",
            title: "Try answering before seeing the explanation",
            summary: "Ask for a conversational quiz and respond in your own words.",
            markdown: """
            # Try answering before seeing the explanation

            You can ask the AI to check your understanding in chat. Start with one question so you have room to think.

            ## Try it

            Tap Ask AI and send this prompt.

            > Quiz me in chat about rereading versus recalling, using the recipe examples from this course. Ask one short question at a time. Wait for my answer before giving feedback or showing an explanation. Keep the course pages unchanged.

            Answer the first question in your own words. It is fine to say you are unsure.

            Read the feedback. If part of it is unclear, ask this before moving to the next question.

            > Show me which part of my answer needs changing and explain why. Then let me try again.

            ## Check the result

            The AI should wait for your answer and respond to what you actually wrote. If it gives away the answer too early, ask it to use a fresh question and wait this time.

            This is a conversation, so there is no course score to unlock. Stop when the exchange has helped, or ask for another question in a different context.
            """
        ),
        Lesson(
            id: "\(workspaceID)-09-sources",
            title: "Bring something you want to understand",
            summary: "Use a link or your own text, then check the source against the explanation.",
            markdown: """
            # Bring something you want to understand

            Your questions can start with an article, your notes, or something you have been reading elsewhere.

            ## Try it

            Copy the URL of a short article you want to understand. Open Ask AI, tap the plus button, Add a source, and choose Paste Link. Check that the source appears before sending your message.

            You can also paste a short passage directly into your message. If your AI provider shows File or Photo in the source menu, you can attach one of those instead.

            > Use the source I just added. Explain one idea from it in plain language and tell me which passage supports your explanation. Separate what the source says from any example you add. If you cannot read the source, tell me instead of guessing. Answer in chat and leave this course unchanged.

            ## Check the result

            Open the original and find the passage the AI used. Does it support the explanation? Ask about anything that seems missing or overstated.

            If a link or attachment cannot be read, paste the relevant text and try again. File and photo options depend on your provider, and a scan may not contain readable text.

            To keep an explanation after checking it, copy it into your notes with Edit page. With a provider that has page tools, you can also ask it to update a named section or create a linked explainer. Include the source so you can find it again.
            """
        ),
        Lesson(
            id: "\(workspaceID)-10-visuals",
            title: "Ask to see the idea another way",
            summary: "Request a comparison, diagram, or small interactive example when it helps.",
            markdown: """
            # Ask to see the idea another way

            You can ask for a different form of explanation. A small table may answer your question faster than another paragraph.

            The prompt below asks Hosted, Codex, or Hermes to save a table on this page. With an Apple provider, ask for the same comparison in chat, then use Edit page to add the parts you want under Visual practice. Preserve the other sections and tap Finish editing.

            ## Try it

            Open Ask AI and send this prompt.

            > Add a short comparison table under "Visual practice" on this page. Compare rereading a recipe with describing it from memory. Show what I do, whether I can see the recipe, and how I check what I missed. Preserve the other sections and the tutorial instructions.

            Return to the page and inspect the result.

            ## Visual practice

            This space is for the comparison you request.

            ## Check the result

            Does each row make the difference clearer? Ask for a correction if a label is confusing or a row adds something you did not ask for.

            For a topic involving steps, try asking for a diagram. For a topic where changing one value affects another, try asking for a small interactive example with one control. Describe what you want to compare or change.

            Available formats depend on the AI provider and the page tools it can use. If it cannot create the requested format, ask for a table or a worked example. Always read the explanation and try any controls yourself before relying on the result.
            """
        ),
        Lesson(
            id: "\(workspaceID)-11-new-course",
            title: "Start with your own question",
            summary: "Shape a new course brief, approve it, and use the same tools on your topic.",
            markdown: """
            # Start with your own question

            Pick something you keep wondering about. Your next course can start there.

            ## Try it

            Return to My Courses and tap the plus button, New Course. Describe what you want to understand. For example, adapt this prompt to your own interest.

            > I want to understand how bread rises. I bake occasionally, but I do not know the science. Help me understand what yeast does and how temperature changes the process. Use plain language and examples I can connect to a kitchen.

            Answer the agent's questions. Read Your Course Brief when it appears. Check whether the outline matches what you wanted to learn.

            Before approving, you can ask for changes in chat.

            > Keep this focused on yeast bread. Add an explanation of what happens when the dough is too cold, and leave sourdough for another course.

            When the brief fits, tap Create Course & First Page. The app builds the course map and first learning page. Later pages are generated as you reach them and can adapt to your questions.

            ## Keep using what you tried

            Open the first page and ask one real question. Select an unclear sentence, request an example from your life, or ask the agent to revise a section that could explain something better.

            You can return to this practice course whenever you want. There is no need to complete every experiment before starting your own course.
            """
        ),
    ]

    static let chapters: [Chapter] = [
        Chapter(
            id: "\(workspaceID)-chapter-01",
            title: "Read and ask",
            summary: "Find your way around, ask about a page, and get an explanation that makes sense to you.",
            lessonIDs: lessons[0..<4].map(\.id)
        ),
        Chapter(
            id: "\(workspaceID)-chapter-02",
            title: "Make the course yours",
            summary: "Edit a page, create an explainer, and try answering a question yourself.",
            lessonIDs: lessons[4..<8].map(\.id)
        ),
        Chapter(
            id: "\(workspaceID)-chapter-03",
            title: "Explore your own questions",
            summary: "Bring a source, ask for another way to see an idea, and start your own course.",
            lessonIDs: lessons[8..<11].map(\.id)
        ),
    ]

    static func makeWorkspace() throws -> PageWorkspace {
        let rootPageID = "\(workspaceID)-root"
        var rootDocument = try document(
            markdown: """
            # \(title)

            \(subtitle)

            Use this course as a practice copy. Open the first lesson, try a prompt, and check what happened in the app. You will ask about selected text, change a page, add your own notes, and create an explainer before starting a course on your own topic.

            These lessons are available offline. AI exercises need an available AI provider. Your practice edits stay in this copy.

            Start with Find your way around in Read and ask. Open a chapter below to find its lessons whenever you need them.
            """,
            nodeID: workspaceID,
            role: "course",
            summary: subtitle
        )
        rootDocument.root.data["course_bootstrap_status"] = .string("ready_for_learning")
        var workspace = PageWorkspace(rootPage: PageRecord(
            id: rootPageID,
            title: title,
            icon: "book.closed.fill",
            document: rootDocument
        ))

        for chapter in chapters {
            var chapterDocument = try document(
                markdown: """
                # \(chapter.title)

                \(chapter.summary)

                Open a lesson below to try it in the app.
                """,
                nodeID: chapter.id,
                role: "chapter",
                summary: chapter.summary
            )
            let chapterPage = try workspace.createPage(
                title: chapter.title,
                parentID: rootPageID,
                icon: "folder.fill",
                document: chapterDocument,
                id: chapter.id
            )
            for lessonID in chapter.lessonIDs {
                guard let lesson = lessons.first(where: { $0.id == lessonID }) else {
                    preconditionFailure("Starter chapter references an unknown lesson: \(lessonID)")
                }
                let page = try workspace.createPage(
                    title: lesson.title,
                    parentID: chapterPage.id,
                    document: document(
                        markdown: lesson.markdown,
                        nodeID: lesson.id,
                        role: "lesson",
                        summary: lesson.summary
                    ),
                    id: lesson.id
                )
                chapterDocument.root.children.append(.childPage(pageID: page.id, title: page.title, icon: page.icon))
            }
            chapterDocument.ensureStableBlockIDs()
            try workspace.saveDocument(chapterDocument, for: chapterPage.id)
            rootDocument.root.children.append(.childPage(
                pageID: chapterPage.id,
                title: chapterPage.title,
                icon: chapterPage.icon
            ))
        }
        rootDocument.ensureStableBlockIDs()
        try workspace.saveDocument(rootDocument, for: rootPageID)
        try workspace.validate()
        return workspace
    }

    private static func document(
        markdown: String,
        nodeID: String,
        role: String,
        summary: String
    ) throws -> BlockDocument {
        var document = try AppFlowyMarkdownCodec().decode(markdown)
        document.root.data["course_node_id"] = .string(nodeID)
        document.root.data["course_role"] = .string(role)
        document.root.data["course_generation_status"] = .string("generated")
        document.root.data["course_summary"] = .string(summary)
        document.ensureStableBlockIDs()
        return document
    }
}
