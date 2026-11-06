# Kith note editor research — 2026-11-06

## Recommendation

**Keep Trix and redesign its toolbar for Kith first. Runner-up: Tiptap core with a small Kith-owned vanilla JavaScript toolbar.** This is an engineering recommendation based on the local integration and the official evidence below, not a browser-validated usability finding. The reported problem is icons and spacing; replacing a document engine would add migration and lifecycle risk without automatically delivering a suitable interface.

Trix supports custom toolbar markup and emits HTML; its upstream repository is MIT licensed. That makes a targeted toolbar redesign a supported approach, rather than requiring an engine fork. [Trix documentation](https://github.com/basecamp/trix)

Choose Tiptap if a concrete roadmap requires richer structured content or extensions beyond Trix's useful scope. If the priority changes to purchasing a complete vendor-supported editing interface, evaluate CKEditor 5 as the commercial alternative. Do not introduce React solely to obtain an editor demo's toolbar.

## Scope and evidence limits

Research only: no application changes, package installation, browser reproduction, or test execution. Official documentation and release pages were consulted on 2026-11-06. Versions below are those visible in retrieved sources, not an assertion that every registry, distribution channel, or security advisory was exhaustively checked. Mutable `latest` documentation is not an immutable historical snapshot. No late-2026 capability is inferred from popularity, demo appearance, package age, or an undated marketing statement.

All external factual claims link to primary sources. Relative links refer to inspected repository evidence. Effort and suitability assessments are this report's judgments. No dollar quote is invented: commercial terms and package-specific licenses must be checked against the eventual pinned build.

## What Kith actually has

- [Note components](../../lib/kith_web/components/note_components.ex) render sanitized HTML, an independently addressable toolbar, a hidden form input, and an editor inside `phx-update="ignore"`. The wrapper remains patchable so server values can reach the hook. This is a Phoenix LiveView DOM island, not a React component tree.
- [The hook](../../assets/js/hooks/trix_editor.js) serializes the editor document rather than trusting the potentially patched hidden-input alias. It compares server versions to preserve typing across unrelated patches and captures the submitted document to preserve corrections typed before a delayed save response. Plain text/entity imports are decoded into text rather than promoted to markup. File acceptance is prevented. Replacement must preserve these semantics, not merely bind `onChange` to a field.
- [Package pins](../../assets/package.json) are Trix 2.1.19 and DOMPurify 3.4.17. [esbuild configuration](../../config/config.exs) aliases Trix imports to [vendored source](../../assets/vendor/trix/src/trix/trix.js), including editor/toolbar element aliases. Updating the npm package alone does not establish that the shipped editor implementation changed. CSS still imports the package's distribution stylesheet.
- [Styles](../../assets/css/app.css) use Tailwind 4 syntax and warm semantic tokens, with dark mode selected by `data-theme`. The editor imports stock `trix.css`; around lines 188–219, Kith mainly restores content formatting, changes toolbar colors/borders and icon opacity/inversion, and hides file tools. There is only a small mobile group-margin adjustment. Thus stock toolbar presentation is a plausible cause of the complaint; actual computed layout, clipping, and group spacing remain unmeasured. No visual defect was reproduced in this research.
- [The CSP plug](../../lib/kith_web/plugs/csp.ex) allows self-hosted scripts plus per-request nonces, without `unsafe-eval` or blanket inline-script permission. **Styles already allow `unsafe-inline`**. Images allow data/blob plus configured origins; connections and frames are restricted. Calling this a strict CSP must not imply that inline styles are currently forbidden. `/dev/` bypasses header generation, so production verification matters.
- [Locale handling](../../lib/kith_web/plugs/assign_locale.ex) recognizes Arabic, Hebrew, Persian, and Urdu as RTL. Existing content CSS uses logical spacing, but does not establish complete toolbar or bidirectional editing support.
- [Note persistence/scrubber](../../lib/kith/contacts/note.ex) stores a string and permits a narrow HTML subset: paragraphs/divs/breaks, emphasis, deletion, preformatted text, headings, lists, quotes, and links with restricted URI schemes. It discards styles/classes and most attributes, including `dir` and `lang`. [RichText](../../lib/kith/rich_text.ex) sanitizes again before raw rendering. [Tests](../../test/kith/rich_text_test.exs) show the boundary is shared with journal entries: changing it affects more than notes.

Existing relevant evidence includes [browser note regressions](../../test/playwright/contact-notes.spec.ts), [editor security tests](../../test/playwright/editor-security.spec.ts), [LiveView rendering security](../../test/kith_web/live/rich_text_security_test.exs), [sanitizer tests](../../test/kith/contacts_note_sanitizer_test.exs), and [dependency policy](../dependency-security.md). The inspected browser suite covers formatting, save/reload/edit, unrelated patches, dark mobile layout, and delayed invalid-submit corrections. These are existing assertions, not newly passing results. Policy requires compatible stable dependencies and maintenance evidence; age alone does not mandate replacement.

## Options: engine versus delivered interface

| Option | What is actually supplied | Framework/license position | Kith assessment |
| --- | --- | --- | --- |
| Trix, restyled | Editor custom elements, default toolbar, custom-toolbar hooks, HTML output | Vanilla DOM; MIT. [Official repository](https://github.com/basecamp/trix) | Best response to the present visual complaint; smallest persistence/lifecycle change. Own the toolbar design and verification. |
| Tiptap | Headless extensible engine; UI is a separate concern | Official vanilla JS setup; MIT core. [Setup](https://tiptap.dev/docs/editor/getting-started/install/vanilla-javascript), [overview](https://tiptap.dev/docs/editor/getting-started/overview) | Best replacement candidate when extension needs justify migration. Build the limited toolbar in HEEx/JS and retain HTML storage initially. |
| Quill 2 | Engine plus Snow toolbar theme or Bubble tooltip theme | Vanilla constructor; permissive BSD licensing. [Themes and license](https://quilljs.com/docs/customization/themes) | Plausible ready-themed, low-license-cost alternative; still needs Kith colors, spacing, labels, lifecycle bridge, and HTML round-trip proof. Less compelling than retaining Trix for a purely cosmetic request. |
| Lexical | Composable engine/packages; a playground is not a turnkey product toolbar | Framework-agnostic integration and MIT repository. [Official API](https://lexicaljs.org/docs/api/), [repository](https://github.com/meta/lexical) | Technically viable without React, but considerable UI, node registration, import/export, and integration ownership for a small notes surface. |
| CKEditor 5 | Integrated editor UI with configurable feature set | GPL option or commercial licensing; premium features separate. [Licensing](https://ckeditor.com/docs/ckeditor5/latest/getting-started/licensing/license-and-legal.html) | Strong commercial shortlist for complete UI and documented accessibility/RTL; broader feature surface and licensing review outweigh benefits for today's complaint. |
| TinyMCE | Complete editor interface with skins and plugins | TinyMCE 8 GPLv2+ or commercial license path. [License key documentation](https://www.tiny.cloud/docs/tinymce/latest/license-key/) | Another credible full-product choice; skin/content styling and asset loading need integration work. Not justified solely to modernize a compact toolbar. |
| BlockNote | Block-oriented editing experience; normal UI uses React; custom vanilla use is possible | MPL 2.0 core; XL features have GPL/commercial terms. [Introduction](https://www.blocknotejs.org/docs), [licensing/pricing](https://www.blocknotejs.org/pricing) | Changes the interaction model and persistence concerns. Vanilla core availability does not make its polished React UI a drop-in LiveView solution. |

### The Tiptap UI distinction

Official UI components are React components, copied into the application as source. Components over open-source extensions are MIT; components for paid services have different terms and may depend on vendor backends. Therefore neither “all Tiptap UI is commercial” nor “the free headless engine includes the polished demo toolbar for vanilla JS” is accurate. [UI components and licensing](https://tiptap.dev/docs/ui-components/getting-started/overview)

For Kith, Tiptap core would run inside the existing ignored island. HEEx could render a small toolbar wired to commands and selection-state updates; accessible focus handling, link dialogs, active states, and dark/RTL styling would still be Kith's responsibility. Tiptap supports HTML and JSON output; choosing HTML avoids a mandatory database-format migration, but does not guarantee lossless Trix imports. [Output formats](https://tiptap.dev/docs/guides/output-json-html)

## Persistence and migration implications

**Retaining Trix:** no planned data conversion. Keep the hidden-input contract, existing source aliases and sanitizer boundaries. A cosmetic change should not alter document loading or submission behavior.

**Tiptap:** restrict the schema to the existing allowlist and explicitly map strikethrough/code serialization. Treat unknown imported nodes as a compatibility question. Validate legacy `div` blocks, nested lists, whitespace and entity handling before rollout. Store sanitized HTML first; introducing JSON later would require a versioned canonical format, rendering strategy, exports/API compatibility, and rollback design. This is a proposed architecture, not a requirement imposed by the engine. [Tiptap HTML/JSON documentation](https://tiptap.dev/docs/guides/output-json-html)

**Quill:** its document API uses Delta and provides `getSemanticHTML()`. Use semantic export rather than assuming its editable DOM is a stable persistence format. Test HTML import/export through Kith's scrubber, particularly nested lists and any indentation/direction represented through attributes the scrubber removes. [Quill content API](https://quilljs.com/docs/api)

**Lexical:** official APIs support JSON, HTML, and Markdown serialization; Kith would need to select/register nodes and verify the chosen HTML path against legacy content. [Official API overview](https://lexicaljs.org/docs/api/)

**CKEditor/TinyMCE:** limit configured features to persisted formatting. Font/color/alignment/table/media controls are misleading if Kith strips their output. A complete toolbar is not automatically a compatible storage contract. CKEditor's own CSP guide notes that several formatting features rely on inline styles. [CKEditor CSP](https://ckeditor.com/docs/ckeditor5/latest/getting-started/setup/csp.html)

**BlockNote:** documentation distinguishes JSON blocks, full HTML, and lossy HTML conversion. A block-based editor should have an explicit canonical-format decision; sending its full HTML through today's attribute-stripping scrubber cannot be assumed to preserve block metadata. [Format interoperability](https://www.blocknotejs.org/docs/foundations/supported-formats)

For every replacement, preserve existing rows unchanged until edited and retain a backup/rollback path. Compare rendered semantics across load → edit → sanitize → save → reload, not byte equality alone. No candidate eliminates server sanitization or makes arbitrary imported HTML trusted.

## Accessibility, RTL, dark mode, and CSP

CKEditor publishes accessibility guidance and a version-specific conformance report, including exceptions; its UI/content language can be configured independently and RTL interfaces are documented. These are stronger vendor artifacts than an attractive demo, but do not certify Kith's selected plugins and modal behavior. [Accessibility](https://ckeditor.com/docs/ckeditor5/latest/features/accessibility.html), [RTL/language configuration](https://ckeditor.com/docs/ckeditor5/latest/getting-started/setup/ui-language.html)

TinyMCE documents directionality controls and separately offers premium skins. Availability of a direction button or a skin does not establish mixed-direction caret correctness or warm-token integration. [Directionality](https://www.tiny.cloud/docs/tinymce/latest/directionality/), [skins](https://www.tiny.cloud/docs/tinymce/latest/editor-skin/)

Tiptap exposes CSS injection and nonce configuration. TinyMCE's security guide supplies CSP guidance that includes vendor origins for its cloud example. Kith should self-host the selected assets and test its actual header rather than copy cloud allowances. [Tiptap editor configuration](https://tiptap.dev/docs/editor/api/editor), [TinyMCE security](https://www.tiny.cloud/docs/tinymce/latest/security/)

No candidate's complete Kith CSP, RTL, screen-reader, or mobile compatibility was verified here. For headless options especially, engine accessibility goals do not cover a custom toolbar. Inherited locale direction can support a whole editor, but persistent per-paragraph language/direction is currently outside Kith's scrubber contract. Any expansion requires a narrow reviewed attribute allowlist, not blanket preservation of styles.

## Maintenance evidence, bounded to inspected sources

| Project | Observed official evidence | What this establishes / limitation |
| --- | --- | --- |
| Trix | Release page lists 2.1.19 and a DOMPurify dependency update. [Releases](https://github.com/basecamp/trix/releases) | Kith's nominal Trix version matches the latest listed release retrieved. No evidence here of a newer stable toolbar redesign to obtain by upgrading. Local vendoring must still be compared before future upgrades. |
| Tiptap | Retrieved releases list 3.33.0 and ProseMirror dependency updates. [Releases](https://github.com/ueberdosis/tiptap/releases) | Published release activity; not proof every extension is equally supported. |
| Quill | Retrieved release list and docs identify 2.0.3; notes include paste/spacing fixes. [Releases](https://github.com/slab/quill/releases) | Available stable 2.x release evidence. This research does not establish a fresh late-2026 release cadence or abandonment. |
| Lexical | Retrieved release page lists 0.53.0, a monthly release with migration notes and breaking changes. [Releases](https://github.com/meta/lexical/releases) | Ongoing release engineering with upgrade work to budget, not a stability guarantee for Kith. |
| CKEditor 5 | Official guidance describes a commercial LTS line with security/critical fixes. [LTS](https://ckeditor.com/docs/ckeditor5/latest/getting-started/setup/using-lts-edition.html) | An explicit paid support option; ordinary open-source usage does not imply those commercial guarantees. |
| TinyMCE | Support page describes updates for supported major/LTS lines. [Support policy](https://www.tiny.cloud/docs/tinymce/latest/support/) | Published support policy; check entitlement and selected major rather than assuming every old release receives fixes. |
| BlockNote | Retrieved releases list 0.57.0 with published release notes. [Releases](https://github.com/TypeCellOS/BlockNote/releases) | Active publication evidence, not a long-term compatibility or security SLA. |

These observations support a shortlist of credible projects. They are not vulnerability audits, comparative performance benchmarks, or guarantees of future responsiveness.

## Cost tradeoffs and decision trigger

Relative engineering estimates, not quotes: **Trix restyle is low effort; Tiptap/Quill replacement is medium; Lexical or BlockNote adoption is high for this app.** Commercial editors reduce how much general toolbar behavior Kith builds, but add license/support evaluation and product styling work. Migration corpus and LiveView race testing remain necessary regardless of vendor.

Trix/MIT, Tiptap core/MIT, Quill/BSD, and Lexical/MIT do not require purchasing basic formatting UI rights under those licenses. Tiptap commercial extensions/services remain separate. BlockNote core is MPL rather than MIT; modifications to its covered source have publication obligations, and XL commercial terms are separate. CKEditor offers GPL or commercial use, with a limited free commercial CDN plan that must not be mistaken for unrestricted self-hosting. TinyMCE's GPL and commercial options likewise require a deployment-specific choice. [Trix license](https://github.com/basecamp/trix), [Tiptap](https://tiptap.dev/docs/editor/getting-started/overview), [Quill](https://quilljs.com/docs/customization/themes), [Lexical](https://github.com/meta/lexical), [BlockNote](https://www.blocknotejs.org/pricing), [CKEditor activation/distribution](https://ckeditor.com/docs/ckeditor5/latest/getting-started/licensing/license-key-and-activation.html), [TinyMCE licensing](https://www.tiny.cloud/docs/tinymce/latest/license-key/)

Before adopting a copyleft/commercial candidate, confirm Kith's distribution/license compatibility and obtain the appropriate vendor terms. This report does not decide legal compatibility or assume a subscription is necessary for all open-source use.

Proceed with a Kith toolbar design on the existing engine: consistent icon family, measured icon/button sizes, compact logical gaps, clear grouping, theme-token hover/selected/focus states, and wrapping at narrow widths. Keep uploads absent. Revisit Tiptap only when the design cannot be delivered adequately through Trix's supported toolbar APIs, or a separately approved feature requires a richer schema. An engine upgrade alone is not a visual redesign.

## Implementation acceptance checks for subsequent work

1. **Visual acceptance:** inspect actual computed stock layout first. Review light/dark and LTR/RTL at 320, 390, 768 px and desktop widths, plus zoom. Approve icon consistency, grouping, target sizes, contrast, link dialog placement, wrapping, and absence of horizontal overflow. Avoid assuming today's icon-presence assertion verifies aesthetics.
2. **Keyboard/accessibility:** editor has a meaningful accessible name; all controls have localized names and correct selected/disabled state; visible focus survives toolbar use; formatting preserves selection; link dialog Escape/focus return works; toolbar buttons do not submit the form. Exercise keyboard-only use, VoiceOver/Safari and NVDA/Chrome where available. Record limitations rather than claiming automatic WCAG conformance.
3. **LiveView lifecycle:** type through unrelated patches, validation failures, slow save responses, close/reopen, switching records, multiple instances, and reconnects. Corrections made after submission must survive the response. Verify server-requested resets still apply, hidden input always reflects the live document, and teardown leaves no listeners/duplicate editors.
4. **Persistence corpus:** round-trip bold/italic/deletion, headings, quotes, preformatted text, nested ordered/unordered lists, links, line breaks, empty documents, Unicode, literal `<`/`>`, entity-encoded imported text, Arabic/Hebrew with English URLs/numbers, and legacy sanitized rows. Check note display, editing, journal usage of the shared sanitizer, and API/import compatibility. Do not rewrite old rows as a side effect of merely opening an editor.
5. **Security:** preserve sanitization on write and render. Repeat malicious HTML, paste, drag/drop, link-scheme, attachment metadata, and file rejection cases. No upload/network path becomes available merely because a toolbar button is hidden. A client-side sanitizer is defense in depth, not the persistence boundary.
6. **Production assets/CSP:** build using the actual esbuild aliases and Tailwind pipeline; verify runtime bundle inputs and stylesheet versions agree. Test the production header with violation capture, no new script origins, inline script permission, or eval allowance. Verify icons, menus and CSS under that header; do not rely on the `/dev/` exemption.
7. **Upgrade/release gate:** run relevant existing ExUnit and browser regressions and the repository's required dependency/security checks, following their documented environment requirements. Update implementation-specific selectors if replacing Trix, preserving behavioral assertions. Record pinned versions, license notices, bundle-size delta, failures, and rollback steps. No passing checks are claimed by this research report.
