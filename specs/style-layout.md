# Style and Layout Specification

Grounding: commit `3d43b1d`.

## 1. Scope
This file defines Track C style and layout behavior for:
- CSS cascade and inheritance into `ComputedStyle`
- block, inline, and float layout
- `f32` geometry policy
- read-only box-to-DOM back-reference policy

## 2. ComputedStyle Contract (C.6)
Implementation anchor: `src/css/cascade.zig`.

`ComputedStyle` is the canonical per-node style struct with fields for:
- display: `block | inline | inline_block | none`
- color and background color (`u32` ARGB)
- typography: font size, font weight, line height, text align
- box model vectors: margin, padding, border (`[4]f32`)
- optional `width` and `height`
- float and clear values

Initial values are encoded directly in the struct defaults.

## 3. Cascade and Specificity
Implementation anchor: `src/css/cascade.zig`.

### 3.1 Matching model
Selector matching is right-to-left (`matchesSelector` + `matchPart`) with:
- descendant combinator
- child combinator

Simple selector matching supports:
- tag
- id
- class tokens

### 3.2 Winning rule order
`pickWinningDeclaration` resolves conflicts using:
1. `!important`
2. specificity tuple `(ids, classes, types)`
3. source order

Inline-style equivalent priority exists via `Rule.inline_style`.

## 4. Inheritance Rules
Implementation anchor: `isInheritedProperty` in `src/css/cascade.zig`.

Inherited set in v1 implementation:
- `color`
- `font_size`
- `font_weight`
- `line_height`
- `text_align`

Keyword behavior:
- `inherit`: copy from parent style when available
- `initial`: reset to `ComputedStyle{}` default for the property

## 5. Layout Geometry (f32)
Implementation anchors:
- `src/layout/box.zig`
- `src/layout/block.zig`
- `src/layout/inline.zig`
- `src/layout/float.zig`

All layout geometry is `f32`.
Tests compare floats with `expectApproxEqAbs`.

### 5.1 Box model and block layout
`layoutBlockGeometry` provides:
- width resolution from explicit width or container-derived fallback
- margin auto-centering (`auto_margin_left` / `auto_margin_right`)
- margin collapse helper (`collapseAdjacentMargins`)
- percentage width helper (`resolvePercentWidth`)

### 5.2 Box-to-DOM back-reference
`Box.source` is `?*const dom.Node`.
- read-only by type (`*const`)
- used for traceability from layout back to source node
- not used to mutate DOM

### 5.3 Inline line layout
`layoutTextLines` computes line metrics using deterministic width heuristics:
- wraps by max width
- supports align offsets (left/right/center/justify)
- tracks per-line width, height, and x offset

### 5.4 Float flow
`availableLineWidth` and `clearOffset` provide float-aware behavior:
- right/left float line-width reduction
- `clear: left/right/both` vertical pushdown

## 6. Current 3d43b1d Status
- Cascade specificity/inheritance: implemented and tested.
- Block/inline/float geometry: implemented and tested.
- `f32` geometry + epsilon testing: implemented and used across tests.
- Read-only box-to-DOM reference: implemented (`Box.source: ?*const Node`) and explicitly tested.
