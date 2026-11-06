# Trix toolbar refinement

Status: implemented; local verification recorded in the PR.

Visual target: [interactive mockup](../../design/note-editor/show-me-trix-toolbar.html).
Research: [editor comparison](../../plan/2026-11-06-note-editor-research.md).

## Intended result

A compact, cohesive note editor with consistent outline icons, balanced spacing, subtle group separators, warm amber selected states, and visible keyboard focus. Match Kith's existing surface, typography, radius, and dark-mode tokens. Keep Trix as the editing engine.

## Implementation

1. Render custom Trix-compatible toolbar markup in `lib/kith_web/components/note_components.ex`. Keep its unique toolbar ID, editor association, and ignored LiveView island. Use the existing Heroicons system wherever suitable, with matching stroke geometry for remaining controls. Give every button `type="button"`, localized accessible names and tooltips. Preserve Trix attribute/action wiring, including link dialog and keyboard behavior.
2. Organize controls into text styling (bold, italic, strike, link), blocks (heading, quote, code), lists/indentation, and history. Retain current capabilities. Keep file tools absent and file rejection enforced. Scope styles to this component so unrelated Trix instances are unaffected.
3. Replace stock toolbar icon pseudo-elements for these buttons. Use 18px icons, consistent desktop button dimensions, 2px intra-group gaps, and logical padding/separators. On narrow/touch layouts increase targets to at least 40px and wrap whole groups without clipping; avoid stretched justification. Use semantic tokens for hover, selected, disabled and focus states, including dark mode. Treat mockup sizes as a starting point and validate the actual rendered toolbar at 320px.
4. Style the link dialog to match, with a labeled URL field, apply/remove actions, Escape dismissal and reliable focus return. Keep Trix responsible for selection/history and button enabled/active states. Verify state semantics rather than bolting on mockup toggles.
5. Preserve the existing hook's input synchronization, server-value comparisons, imported text handling and delayed-save protection. Avoid persistence, sanitizer, package, or vendored-source changes for this visual refinement.

## Verification

- Review desktop and 320/390px layouts, light/dark and LTR/RTL, zoom and touch spacing. Check icon alignment, tooltip/dialog placement and overflow.
- Exercise keyboard focus, selection retention, active/disabled states, formatting shortcuts, link apply/remove and every existing toolbar action.
- Run existing note browser regressions and editor security tests; preserve coverage of validation, delayed responses and unrelated LiveView patches. Use relevant ExUnit sanitizer/render checks if component markup changes affect them. Run the asset build.
- The HTML mockup demonstrates visual states only; it is not the production editor and does not save notes. This paragraph describes the design artifact; see the PR for implementation verification.

## Implementation notes

- Custom SVG controls use the approved mockup geometry, with Trix command attributes and keyboard shortcuts retained.
- A small hook bridge supports native keyboard activation and mirrors Trix state into ARIA attributes. Link expansion follows dialog visibility independently of link formatting.
- Escape from the link input stops at the editor wrapper after Trix handles dismissal, preserving the enclosing note modal.
- Indentation icons mirror in RTL. The link field retains Trix URL validation and receives an error border.
- Standards review found one accessibility issue; spec review found that issue plus untranslated label sources. Both were corrected before publishing. Labels now use Gettext; existing English fallbacks remain until translations are supplied.
