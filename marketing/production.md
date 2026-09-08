# Carousel image production

## User preferences

Use manhwa or cartoon illustration with a specific, consistent style supplied in the prompt. The user requested ChatGPT in the already open Helium browser to generate a full carousel from one prompt as multiple separate images. Use that workflow for continuations unless the user requests a different method.

The user welcomes darker adult themes, mild sexual wordplay, taboos and emotionally awkward stories for the appropriate niche accounts. Keep the main Wait, How? account welcoming across ages. Existing body-image material uses object photography and a narrator's experience rather than appearance scoring or a treatment claim.

Copy should have a concrete hook, a reason to swipe, a satisfying payoff and a soft Learnfold connection. For explainers, deliver a useful answer before inviting further exploration. Follow the length guidance in [wait-how.md](wait-how.md#slide-lengths-and-generation-budget).

## Workflow

1. Read the chosen account plan and script. Verify substantive factual explanations and product claims against current sources. Save sources with new explainer scripts.
2. Prepare one complete prompt with the audience, exact slide count, art style, character bible, recurring props, exact per-slide copy and scene directions. Specify separate portrait images and ask ChatGPT to continue through the full set.
3. Use available browser/computer tools to locate Helium and its ChatGPT tab. In this session the connected extension identified its browser family as Chrome while the native app was Helium. Verify the current app and tabs rather than hard-coding browser or tab IDs.
4. Open a separate ChatGPT conversation for a distinct carousel, preserving previous work. Submit the complete prompt. The user has requested image creation; account creation and TikTok publishing are separate tasks.
5. Allow the generation response to finish. Open thumbnail images to check the gallery. Read the visible state before deciding that a retry is necessary.
6. Check the slide count, order, caption readability, character continuity, factual details and product reveal. Record any inspected subset honestly. Use targeted corrections if needed.
7. Save the prompt, conversation URL and status locally. If downloading, use a dedicated asset directory with ordered filenames and verify the files. Add deliverable links to the folder index or status file.

## Gallery behavior learned in this session

ChatGPT displays one large selected image and a vertical strip of thumbnails. Clicking a thumbnail changes the large image. The accessibility tree can contain repeated "Generated image" groups that look like empty placeholders; these were not evidence of missing assets.

The first run was mistakenly described as incomplete until the user explained the thumbnail behavior. On later runs, screenshots and thumbnail clicks confirmed slides 7 and 8. A "Something went wrong" banner also appeared on the dating chat while generation continued and eventually produced the full gallery. Judge the actual response and images before retrying, to avoid duplicate generation.

A browser automation call may report a detached element while the page changes. Inspect the latest state and screenshot before repeating an action. Follow the currently available tool documentation for browser control and keeping deliverable tabs open.

## Existing visual identities

| Set | Style and palette | Recurring characters and props |
| --- | --- | --- |
| Hate-follow syllabus | Contemporary romance-comedy manhwa, fine dark-plum outlines, cel shading, cream caption boxes, dusty lavender, charcoal, sage and mint | Adult South Asian woman, medium-brown skin, shoulder-length black hair, silver hoops, plum cardigan, cream shirt, mint phone. Another adult woman with auburn bob, glasses and sage jacket. Concrete library, notebook and train window. |
| Plot & Footnotes | Gothic romance-comedy manhwa, espresso linework, parchment captions, burgundy, forest green and antique gold | Adult reader with warm brown skin, curly dark hair, loose bun, round glasses and green sweater. Fictional adult duke with dark hair, burgundy waistcoat and black coat. Burgundy book with gold key, candles and estate sketches. |
| Better Questions Club | Contemporary romance manhwa, aubergine linework, luminous shading, midnight indigo, dusty rose, ivory and mint | Adult South Asian woman with wavy black hair, gold hoops, rose blouse and cream cardigan at home. Adult man with wavy dark hair, glasses, navy overshirt and ivory shirt. Receipt with a star drawing, restaurant and telescope. |

Use the actual existing images as references when making a sequel; descriptive prompts alone do not guarantee exact character continuity. The generated sets are linked from [README.md](README.md).

## Reusable prompt structure

This is a template reconstructed from the successful approach, not a verbatim original prompt.

```text
Generate the complete [N]-slide TikTok carousel now using image generation.
Deliver [N] separate portrait images in order. A thumbnail gallery is welcome
if each image opens separately. Continue until the complete set is generated.

ACCOUNT AND AUDIENCE
[Name, audience motivation, editorial promise, relationship to Learnfold.]

LOCKED ART DIRECTION
[Specific manhwa/cartoon style, linework, shading, palette, lighting, texture.]
Portrait 9:16, ideally 1080x1920. Keep rendering consistent throughout.

CHARACTER AND PROP CONTINUITY
[Age where relevant, appearance, clothing, recurring objects and locations.]

TYPOGRAPHY
Render the exact supplied captions legibly with consistent type and contrast.
Use comfortable safe margins for the TikTok interface. Keep important text
roughly 8% from the left, 12% from the right, 10% from the top and 18% from
the bottom as an initial layout guide. Verify in the actual posting preview.
Use discreet slide numbers. Label fictional POVs in the post where applicable.

SLIDE 1
Exact copy: [...]
Scene: [...]

[Repeat through slide N.]

PRODUCT APPEARANCE
[One natural, usually late, Learnfold mention. Use a real screenshot when
available or a clearly illustrated conceptual course card. Detailed app UI
must reflect actual product behavior.]

Generate all [N] complete, separately viewable images with exact copy.
```

## Product grounding

Learnfold is an iOS learning workspace that turns a topic or source into a personal course, proposes a plan, generates lessons progressively and supports course-context questions. Recheck the [iOS product description](../apps/ios/fastlane/metadata/en-US/description.txt) and relevant app behavior for new claims.

The generated promotional course cards are conceptual illustrations. Example courses are proposed demonstrations, not a claim that these subjects ship as a built-in catalogue. Existing scripts sometimes request real screenshots; the generated manhwa versions used illustrated cards instead.

## Future asset layout

When exporting or creating additional sets, use a structure such as:

```text
marketing/assets/<story-slug>/
  prompt.md
  sources.md        # for factual explainers
  delivery.md       # gallery URL, generation date, version, checks, open issues
  slide-01.png
  slide-02.png
  ...
```

The asset folders above are a convention for future work, not files already present. Generation capacity should support readable explanations, better illustrations and useful variants. No subscription entitlement or unlimited image allowance has been verified by this task.
