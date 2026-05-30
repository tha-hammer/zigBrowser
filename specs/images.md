# Images Specification

Grounding: commit `3d43b1d`.

## 1. Scope
This file defines image decoding and replaced element sizing behavior for v1 image support.

## 2. Decode Contract
Implementation anchor: `src/image/decode.zig`.

Current implementation behavior:
- validates PNG signature
- reads intrinsic width/height from PNG IHDR
- returns `DecodeError.InvalidPng` for malformed payloads

Normative project target references `zigimg`-backed decode for broader format support.
At `3d43b1d`, intrinsic-size extraction is implemented via direct PNG IHDR parsing.

## 3. Replaced Element Sizing Contract
Implementation anchors:
- `src/image/decode.zig` (`computeReplacedSize`)
- `src/layout/box.zig` (`Box.Content.replaced` with `ImageRef`)

Rules:
- both width and height attrs present: use attrs directly
- width only: preserve intrinsic aspect ratio and derive height
- height only: preserve intrinsic aspect ratio and derive width
- no attrs: use intrinsic size

## 4. Box Integration
`Box.content.replaced` is the image/replaced slot.
`ImageRef` carries:
- width
- height
- bytes

This is the integration point from decode to layout/paint.

## 5. Current 3d43b1d Status
- intrinsic PNG dimension parsing: implemented and tested
- aspect-ratio sizing for one-dimensional attributes: implemented and tested
- malformed PNG rejection: implemented and tested
- full `zigimg` decode path: reserved as next expansion beyond current subset
