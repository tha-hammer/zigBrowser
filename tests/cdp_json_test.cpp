// WS2a.0 (Windows plan rev 2.21): the CDP-result reader used by the WebView2 shim's CDP wrapper
// (src/cdp_json.hpp; portable C++17, no Windows headers), driven on Linux. Every CDP answer the shim
// acts on (Page.getFrameTree's frame id, Page.createIsolatedWorld's executionContextId,
// Runtime.evaluate's result value / exceptionDetails, a CDP error message) is read through it.
//
// Exit 0 when every check passes; one line per check. Run: zig c++ -std=c++17 -Isrc tests/cdp_json_test.cpp
#include "cdp_json.hpp"

#include <cstdint>
#include <cstdio>
#include <random>
#include <string>

static int failures = 0;
static int passes = 0;

static void check(bool ok, const char *what) {
  std::printf("%s %s\n", ok ? "ok  " : "FAIL", what);
  (ok ? passes : failures) += 1;
}

static bool str_is(const std::string &json, std::initializer_list<const char *> path, const std::string &want) {
  std::string got;
  return cdp_json_string(json, path, &got) && got == want;
}

// Reference ENCODER (the oracle for the decoder under test): code points -> a JSON string literal using
// \uXXXX escapes (surrogate pairs above U+FFFF), plus the UTF-8 the decoder must produce.
static void encode(const std::u32string &cps, std::string *json_lit, std::string *utf8) {
  char buf[16];
  *json_lit = "\"";
  utf8->clear();
  for (char32_t c : cps) {
    if (c >= 0x10000) {
      const char32_t v = c - 0x10000;
      std::snprintf(buf, sizeof buf, "\\u%04x\\u%04x", 0xD800 + (unsigned)(v >> 10), 0xDC00 + (unsigned)(v & 0x3FF));
    } else {
      std::snprintf(buf, sizeof buf, "\\u%04x", (unsigned)c);
    }
    *json_lit += buf;
    if (c < 0x80) {
      *utf8 += (char)c;
    } else if (c < 0x800) {
      *utf8 += (char)(0xC0 | (c >> 6));
      *utf8 += (char)(0x80 | (c & 0x3F));
    } else if (c < 0x10000) {
      *utf8 += (char)(0xE0 | (c >> 12));
      *utf8 += (char)(0x80 | ((c >> 6) & 0x3F));
      *utf8 += (char)(0x80 | (c & 0x3F));
    } else {
      *utf8 += (char)(0xF0 | (c >> 18));
      *utf8 += (char)(0x80 | ((c >> 12) & 0x3F));
      *utf8 += (char)(0x80 | ((c >> 6) & 0x3F));
      *utf8 += (char)(0x80 | (c & 0x3F));
    }
  }
  *json_lit += "\"";
}

int main() {
  // Runtime.evaluate (returnByValue) as WebView2 hands it back.
  const std::string eval_ok = R"({"result":{"type":"string","value":"undefined"}})";
  check(str_is(eval_ok, {"result", "value"}, "undefined"), "Runtime.evaluate result.value");
  check(!cdp_json_has(eval_ok, {"exceptionDetails"}), "no exceptionDetails on success");

  const std::string eval_throw =
      R"({"result":{"type":"object","subtype":"error","description":"Error: boom\n    at <anonymous>:1:7"},)"
      R"("exceptionDetails":{"exceptionId":1,"text":"Uncaught","exception":{"description":"Error: boom\n    at <anonymous>:1:7"}}})";
  check(cdp_json_has(eval_throw, {"exceptionDetails"}), "exceptionDetails present on a throw");
  check(str_is(eval_throw, {"exceptionDetails", "exception", "description"}, "Error: boom\n    at <anonymous>:1:7"),
        "exception description with an escaped newline");

  // Page.getFrameTree / Page.createIsolatedWorld.
  const std::string tree =
      R"({"frameTree":{"childFrames":[{"frame":{"id":"CHILD"}}],"frame":{"id":"9A1B2C","loaderId":"L1","url":"file:///C:/x.html"}}})";
  check(str_is(tree, {"frameTree", "frame", "id"}, "9A1B2C"), "main frame id (child frames skipped)");
  long long ctx = 0;
  check(cdp_json_int(R"({"executionContextId":42})", {"executionContextId"}, &ctx) && ctx == 42,
        "createIsolatedWorld executionContextId");
  check(cdp_json_int(R"({ "code" : -32000 , "message":"x"})", {"code"}, &ctx) && ctx == -32000,
        "negative integer with spaces");

  // A CDP error object.
  check(str_is(R"({"code":-32601,"message":"'Foo.bar' wasn't found"})", {"message"}, "'Foo.bar' wasn't found"),
        "CDP error message");

  // Keys are matched as keys at the right depth, never inside strings or deeper objects.
  check(str_is(R"({"a":"\"value\":\"WRONG\"","value":"right"})", {"value"}, "right"), "a key text inside a string is not a key");
  check(!cdp_json_has(R"({"x":{"value":"deep"}})", {"value"}), "a deeper key is not a top-level key");
  check(str_is(R"({"value":[{"value":"in-array"}],"z":1,"value2":"no"})", {"value2"}, "no"), "arrays are skipped whole");

  // Escapes.
  check(str_is(R"({"s":"q\" b\\ s\/ n\n t\t r\r f\f bs\b"})", {"s"}, "q\" b\\ s/ n\n t\t r\r f\f bs\b"), "simple escapes");
  check(str_is(R"({"s":"\u00e9\u4e2d\ud83d\ude00"})", {"s"}, "\xC3\xA9\xE4\xB8\xAD\xF0\x9F\x98\x80"), "\\u escapes incl. a surrogate pair");
  check(str_is(R"({"s":"é中😀"})", {"s"}, "é中😀"), "raw UTF-8 passes through");

  // Type and shape refusals.
  std::string out;
  check(!cdp_json_string(R"({"id":7})", {"id"}, &out), "a number is not a string");
  check(!cdp_json_int(R"({"id":"7"})", {"id"}, &ctx), "a string is not an integer");
  check(!cdp_json_int(R"({"id":7.5})", {"id"}, &ctx), "a fraction is not an integer");
  check(!cdp_json_string(R"({"s":"\ud83d"})", {"s"}, &out), "a lone high surrogate is refused");
  check(!cdp_json_string(R"({"s":"\ude00x"})", {"s"}, &out), "a lone low surrogate is refused");
  check(!cdp_json_string(R"({"s":"\u12"})", {"s"}, &out), "a short \\u escape is refused");
  check(!cdp_json_string(R"({"s":"a)", {"s"}, &out), "an unterminated string is refused");
  check(!cdp_json_has(R"({"s":"a"} trailing)", {"s"}), "trailing garbage is refused");
  check(!cdp_json_has(R"({"s":"a",})", {"s"}), "a trailing comma is refused");
  check(!cdp_json_has("", {"s"}), "empty input is refused");
  check(!cdp_json_has(R"(["s"])", {"s"}), "a top-level array has no keys");
  check(cdp_json_has(R"({"s":null})", {"s"}) && !cdp_json_string(R"({"s":null})", {"s"}, &out), "null is present but not a string");

  // Property: decode(encode(cps)) == utf8(cps) for 2000 generated code-point strings (BMP, astral, controls).
  std::mt19937 rng(20261022);
  std::uniform_int_distribution<int> len(0, 24);
  std::uniform_int_distribution<int> kind(0, 3);
  bool prop_ok = true;
  for (int i = 0; i < 2000 && prop_ok; i++) {
    std::u32string cps;
    for (int n = len(rng); n > 0; n--) {
      char32_t c;
      switch (kind(rng)) {
        case 0: c = (char32_t)std::uniform_int_distribution<int>(0, 0x7F)(rng); break;
        case 1: c = (char32_t)std::uniform_int_distribution<int>(0x80, 0xD7FF)(rng); break;
        case 2: c = (char32_t)std::uniform_int_distribution<int>(0xE000, 0xFFFF)(rng); break;
        default: c = (char32_t)std::uniform_int_distribution<int>(0x10000, 0x10FFFF)(rng); break;
      }
      cps.push_back(c);
    }
    std::string lit, want;
    encode(cps, &lit, &want);
    prop_ok = str_is("{\"k\":" + lit + "}", {"k"}, want);
  }
  check(prop_ok, "property: decode(encode(code points)) == UTF-8 over 2000 generated strings");

  // cdp_json_quote: caller text (an eval body, its arg, a script) placed in a CDP request.
  check(cdp_json_quote("a\"b\\c") == "\"a\\\"b\\\\c\"", "quote escapes quote and backslash");
  check(cdp_json_quote(std::string("\x01\x1f\n\t", 4)) == "\"\\u0001\\u001f\\n\\t\"", "quote escapes every control character");
  check(cdp_json_quote("\xC3\xA9\xF0\x9F\x98\x80") == "\"\xC3\xA9\xF0\x9F\x98\x80\"", "quote passes UTF-8 through");
  check(cdp_json_quote(std::string("a\0b", 3)) == "\"a\\u0000b\"", "quote keeps an embedded NUL as \\u0000");
  // Property: reading a quoted value back gives the exact bytes, for generated UTF-8 incl. controls.
  bool quote_ok = true;
  for (int i = 0; i < 2000 && quote_ok; i++) {
    std::u32string cps;
    for (int n = len(rng); n > 0; n--) {
      cps.push_back(kind(rng) == 0 ? (char32_t)std::uniform_int_distribution<int>(0, 0x7F)(rng)
                                   : (char32_t)std::uniform_int_distribution<int>(0x80, 0xD7FF)(rng));
    }
    std::string lit, text;
    encode(cps, &lit, &text);
    quote_ok = str_is("{\"k\":" + cdp_json_quote(text) + "}", {"k"}, text);
  }
  check(quote_ok, "property: cdp_json_string(quote(s)) == s over 2000 generated UTF-8 strings");

  std::printf("ASSERTS %d\n", passes);
  return failures == 0 ? 0 : 1;
}
