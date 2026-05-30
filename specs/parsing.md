# Parsing Specification

Baseline: commit `3d43b1d`.

## 1. Scope

This spec covers:
- HTML tokenizer/entities/tree builder/DOM
- CSS tokenizer/parser/CSSOM

Primary files:
- `src/html/dom.zig`
- `src/html/tokenizer.zig`
- `src/html/entities.zig`
- `src/html/tree_builder.zig`
- `src/css/tokenizer.zig`
- `src/css/parser.zig`
- `src/css/cssom.zig`

## 2. Canonical HTML Types (§C Surface)

### `Attribute`
```zig
pub const Attribute = struct {
    name: []const u8,
    value: []const u8,
};
```

### `Node` and `Element`
```zig
pub const Node = struct {
    kind: Kind,
    parent: ?*Node = null,
    first_child: ?*Node = null,
    next_sibling: ?*Node = null,
    script_wrapper: ?WrapperRef = null,

    pub const Kind = union(enum) {
        element: Element,
        text: []const u8,
        comment: []const u8,
        doctype: []const u8,
    };
};

pub const Element = struct {
    tag_name: []const u8,
    attributes: []Attribute,
};
```

### `Token` (§C.8)
```zig
pub const Token = union(enum) {
    doctype: []const u8,
    start_tag: struct { name: []const u8, attrs: []dom.Attribute, self_closing: bool },
    end_tag: []const u8,
    comment: []const u8,
    character: []const u8,
    eof,
};
```

## 3. HTML Tokenization and Entity Decoding

### 3.1 Tokenizer behavior
`src/html/tokenizer.zig`:
- Lowercases tag and attribute names for normalized token output.
- Parses start tags with attributes and self-closing flag.
- Deduplicates repeated attribute names (first one wins).
- Parses end tags, comments (`<!-- -->`), and doctype (`<!doctype ...>`).
- Emits text as `character` tokens.
- Always emits terminal `.eof` token.

### 3.2 Raw-text handling
For `script` and `style` start tags:
- Tokenizer enters raw-text consumption until matching `</tag>`.
- Raw content is emitted verbatim as a `character` token.
- If matching close tag exists, tokenizer emits the synthetic close token.

### 3.3 Entity decoding
`src/html/entities.zig` supports:
- Named entities: `amp`, `lt`, `gt`, `quot`, `apos`, `nbsp`
- Numeric entities: decimal (`&#65;`) and hex (`&#x41;`)
- Legacy named form handling without semicolon at boundary
- Overflow/invalid numeric entity fallback to U+FFFD

## 4. HTML Tree Building

`parseDocument` (`src/html/tree_builder.zig`) consumes token stream and constructs linked DOM.

### 4.1 Implied structure
- Always creates `html` and `body` root/container elements.
- Appends parsed nodes into this structure.

### 4.2 Stack-based insertion
- Maintains element stack (`html`, `body`, descendants).
- Pushes non-void, non-self-closing start tags.
- Pops to matching element on end tags.

### 4.3 Recovery and implicit close
Implemented behaviors:
- Implicit close for `p`, `li`, and `dt`/`dd` sibling transitions.
- Foster parenting for non-whitespace character data in table insertion contexts.
- Foster parenting for non-structural start tags in table insertion contexts.
- Whitespace in table context remains inside table flow.

### 4.4 Script capture, no execution
- Script text is preserved via tokenizer raw-text capture.
- Tree-builder parse tests assert no `.run_script` invocations on shared spy engine path.

### 4.5 Wrapper slot reservation
- `Node.script_wrapper` is present on all nodes and remains `null` in parsing flows.

## 5. Canonical CSS Types (`cssom.zig`)

```zig
pub const Combinator = enum { descendant, child, adjacent };

pub const SimpleSelector = union(enum) {
    type_sel: []const u8,
    class: []const u8,
    id: []const u8,
    pseudo: []const u8,
    universal,
};

pub const SelectorPart = struct {
    simple: []SimpleSelector,
    combinator: ?Combinator,
};

pub const Declaration = struct {
    name: []const u8,
    value: []const u8,
};

pub const Rule = struct {
    selectors: [][]SelectorPart,
    decls: []Declaration,
};
```

## 6. CSS Tokenization and Parsing

### 6.1 CSS tokenizer (`src/css/tokenizer.zig`)
Token classes include:
- identifiers, class/id/pseudo fragments
- punctuation (`{}`, `:`, `;`, `,`, `>`, `+`)
- universal selector `*`
- terminal `.eof`

### 6.2 CSS parser (`src/css/parser.zig`)
`parseStylesheet` behavior:
- Skips whitespace.
- Skips at-rules structurally (`skipAtRule`) without crashing.
- Parses selector lists by comma into multiple selector chains.
- Parses selector parts with combinators: descendant, child (`>`), adjacent (`+`).
- Parses declarations as `name:value`; malformed declaration fragments are dropped.
- Returns `error.InvalidSelector` when a selector part has no simple selectors.

### 6.3 No-crash corpus gate
`parseCssCorpusNoCrash(arena, sources)`:
- Iterates all CSS sources and requires parser to complete without crashing.
- Current Phase-3 gate test loads 50 curated CSS pages from `tests/corpus_css/manifest.json` and `tests/corpus_css/pageNN.css`.

## 7. Parse Error Surface

Parsing error boundaries are intentionally narrow in v1:
- HTML tokenizer/entity/tree builder primarily propagate allocator failures.
- CSS parser explicit domain error is `error.InvalidSelector` plus allocator errors.
- Page-level caller maps upstream failures to navigation-level `error.MalformedDocument` in `src/page.zig`.
