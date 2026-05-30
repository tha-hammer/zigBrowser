const dom = @import("dom.zig");
const tokenizer = @import("tokenizer.zig");

// Aggregates Track B tests behind a single stable root import.
test {
    _ = dom.Node;
    _ = tokenizer.Token;
}
