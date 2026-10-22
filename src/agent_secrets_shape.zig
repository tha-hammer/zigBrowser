//! The Claude Agent token's SHAPE — portable, platform-free (no std.os.*), so the one rule is shared
//! by the Linux file/libsecret store and the Windows CredMan/DPAPI store without either duplicating it
//! (WS6.1). The setup-token shape is the user's requirement after the S4a real-screen check
//! (RoseCat's contract 5731): ^sk-ant-oat01-[A-Za-z0-9_-]{22,499}$ (35..512 characters in all).
const std = @import("std");

/// The long-lived token `claude setup-token` prints; nothing else is a token
/// (API keys are out of scope, plan section 5).
pub const token_prefix = "sk-ant-oat01-";
/// RFC 6819 section 5.1.4.2.2 asks at least 128 bits of a token handle: 22
/// characters of the 64-symbol suffix alphabet carry 132 (RoseCat 5731).
pub const min_suffix_len = 22;
pub const min_token_len = token_prefix.len + min_suffix_len;
pub const max_token_len = 512;

/// A setup token, one rule for Save, store and load (the user's requirement
/// after the S4a real-screen check): ^sk-ant-oat01-[A-Za-z0-9_-]{22,499}$.
pub fn validToken(text: []const u8) bool {
    if (text.len < min_token_len or text.len > max_token_len) return false;
    if (!std.mem.startsWith(u8, text, token_prefix)) return false;
    for (text[token_prefix.len..]) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '_', '-' => {},
            else => return false,
        }
    }
    return true;
}

/// A pasted token: surrounding ASCII whitespace (SP HT CR LF VT FF) trimmed,
/// then validToken. The token as a slice of `text`, or null.
pub fn tokenFromPaste(text: []const u8) ?[]const u8 {
    const token = std.mem.trim(u8, text, &std.ascii.whitespace);
    return if (validToken(token)) token else null;
}
