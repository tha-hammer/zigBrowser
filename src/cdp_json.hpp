// Reads one value out of a CDP answer (the JSON text ICoreWebView2::CallDevToolsProtocolMethod returns).
// Portable C++17 with no Windows headers, so tests/cdp_json_test.cpp drives it on Linux.
//
// `path` is a chain of object keys from the top-level object; each key is matched only at its own depth
// (never inside a string or a deeper object). The whole input must be one well-formed JSON value with
// nothing after it but whitespace; anything else is "not found". Strings come back as UTF-8 with every
// escape decoded; a lone surrogate is refused.
#pragma once

#include <cstddef>
#include <initializer_list>
#include <string>

namespace cdp_json_detail {

struct Reader {
  const std::string &s;
  size_t i = 0;

  void ws() {
    while (i < s.size() && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r')) i++;
  }
  bool eat(char c) {
    ws();
    if (i < s.size() && s[i] == c) {
      i++;
      return true;
    }
    return false;
  }

  static void put_utf8(std::string *out, unsigned long cp) {
    if (cp < 0x80) {
      *out += static_cast<char>(cp);
    } else if (cp < 0x800) {
      *out += static_cast<char>(0xC0 | (cp >> 6));
      *out += static_cast<char>(0x80 | (cp & 0x3F));
    } else if (cp < 0x10000) {
      *out += static_cast<char>(0xE0 | (cp >> 12));
      *out += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
      *out += static_cast<char>(0x80 | (cp & 0x3F));
    } else {
      *out += static_cast<char>(0xF0 | (cp >> 18));
      *out += static_cast<char>(0x80 | ((cp >> 12) & 0x3F));
      *out += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
      *out += static_cast<char>(0x80 | (cp & 0x3F));
    }
  }

  bool hex4(unsigned long *v) {
    if (i + 4 > s.size()) return false;
    *v = 0;
    for (int k = 0; k < 4; k++) {
      const char c = s[i++];
      *v <<= 4;
      if (c >= '0' && c <= '9') *v |= static_cast<unsigned long>(c - '0');
      else if (c >= 'a' && c <= 'f') *v |= static_cast<unsigned long>(c - 'a' + 10);
      else if (c >= 'A' && c <= 'F') *v |= static_cast<unsigned long>(c - 'A' + 10);
      else return false;
    }
    return true;
  }

  // A string at s[i] (the opening quote); decoded into *out when out is not null.
  bool string(std::string *out) {
    ws();
    if (i >= s.size() || s[i] != '"') return false;
    i++;
    while (i < s.size()) {
      const char c = s[i++];
      if (c == '"') return true;
      if (static_cast<unsigned char>(c) < 0x20) return false;
      if (c != '\\') {
        if (out) *out += c;
        continue;
      }
      if (i >= s.size()) return false;
      const char e = s[i++];
      char lit = 0;
      switch (e) {
        case '"': lit = '"'; break;
        case '\\': lit = '\\'; break;
        case '/': lit = '/'; break;
        case 'b': lit = '\b'; break;
        case 'f': lit = '\f'; break;
        case 'n': lit = '\n'; break;
        case 'r': lit = '\r'; break;
        case 't': lit = '\t'; break;
        case 'u': {
          unsigned long cp = 0;
          if (!hex4(&cp)) return false;
          if (cp >= 0xDC00 && cp <= 0xDFFF) return false;  // a low surrogate with no high one
          if (cp >= 0xD800 && cp <= 0xDBFF) {
            unsigned long lo = 0;
            if (i + 2 > s.size() || s[i] != '\\' || s[i + 1] != 'u') return false;
            i += 2;
            if (!hex4(&lo) || lo < 0xDC00 || lo > 0xDFFF) return false;
            cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
          }
          if (out) put_utf8(out, cp);
          continue;
        }
        default: return false;
      }
      if (out) *out += lit;
    }
    return false;  // unterminated
  }

  // A number; *integer is set when it has no fraction or exponent and fits a long long.
  bool number(bool *is_int, long long *integer) {
    ws();
    const size_t start = i;
    if (i < s.size() && s[i] == '-') i++;
    if (i >= s.size() || s[i] < '0' || s[i] > '9') return false;
    if (s[i] == '0') i++;
    else while (i < s.size() && s[i] >= '0' && s[i] <= '9') i++;
    bool frac = false;
    if (i < s.size() && s[i] == '.') {
      frac = true;
      i++;
      if (i >= s.size() || s[i] < '0' || s[i] > '9') return false;
      while (i < s.size() && s[i] >= '0' && s[i] <= '9') i++;
    }
    if (i < s.size() && (s[i] == 'e' || s[i] == 'E')) {
      frac = true;
      i++;
      if (i < s.size() && (s[i] == '+' || s[i] == '-')) i++;
      if (i >= s.size() || s[i] < '0' || s[i] > '9') return false;
      while (i < s.size() && s[i] >= '0' && s[i] <= '9') i++;
    }
    *is_int = false;
    if (!frac && i - start - (s[start] == '-' ? 1 : 0) <= 18) {  // 18 digits never overflow
      long long v = 0;
      size_t k = start + (s[start] == '-' ? 1 : 0);
      for (; k < i; k++) v = v * 10 + (s[k] - '0');
      *integer = s[start] == '-' ? -v : v;
      *is_int = true;
    }
    return true;
  }

  bool literal(const char *word) {
    ws();
    size_t k = 0;
    for (; word[k]; k++) {
      if (i + k >= s.size() || s[i + k] != word[k]) return false;
    }
    i += k;
    return true;
  }

  // Skips any value (depth-limited so hostile nesting cannot exhaust the stack).
  bool skip(int depth = 0) {
    if (depth > 64) return false;
    ws();
    if (i >= s.size()) return false;
    const char c = s[i];
    if (c == '"') return string(nullptr);
    if (c == '{' || c == '[') {
      const char close = c == '{' ? '}' : ']';
      i++;
      if (eat(close)) return true;
      for (;;) {
        if (c == '{') {
          if (!string(nullptr) || !eat(':')) return false;
        }
        if (!skip(depth + 1)) return false;
        if (eat(close)) return true;
        if (!eat(',')) return false;
      }
    }
    if (c == 't') return literal("true");
    if (c == 'f') return literal("false");
    if (c == 'n') return literal("null");
    bool is_int = false;
    long long v = 0;
    return number(&is_int, &v);
  }
};

// Finds the value at `path`; on success r.i is at that value. The whole document is validated.
inline bool locate(const std::string &json, std::initializer_list<const char *> path, size_t *at) {
  Reader r{json};
  size_t found = std::string::npos;
  bool ok = true;
  // Walks the objects on the path, validating every value it passes over.
  auto walk = [&](auto &&self, const char *const *k, int depth) -> bool {
    if (depth > 64) return false;
    r.ws();
    if (!r.eat('{')) return false;
    if (r.eat('}')) return true;
    for (;;) {
      std::string name;
      if (!r.string(&name) || !r.eat(':')) return false;
      r.ws();
      const bool hit = k != path.end() && name == *k && found == std::string::npos;
      if (hit && k + 1 == path.end()) {
        found = r.i;
        if (!r.skip(depth + 1)) return false;
      } else if (hit) {
        r.ws();
        if (r.i < r.s.size() && r.s[r.i] == '{') {
          if (!self(self, k + 1, depth + 1)) return false;
        } else if (!r.skip(depth + 1)) {
          return false;
        }
      } else if (!r.skip(depth + 1)) {
        return false;
      }
      if (r.eat('}')) return true;
      if (!r.eat(',')) return false;
    }
  };
  r.ws();
  if (r.i >= json.size() || json[r.i] != '{') return false;
  ok = walk(walk, path.begin(), 0);
  r.ws();
  if (!ok || r.i != json.size() || found == std::string::npos) return false;
  *at = found;
  return true;
}

}  // namespace cdp_json_detail

// True when `path` names a value (of any type, null included) in a well-formed document.
inline bool cdp_json_has(const std::string &json, std::initializer_list<const char *> path) {
  size_t at = 0;
  return cdp_json_detail::locate(json, path, &at);
}

// The string at `path`, decoded to UTF-8.
inline bool cdp_json_string(const std::string &json, std::initializer_list<const char *> path, std::string *out) {
  size_t at = 0;
  if (!cdp_json_detail::locate(json, path, &at)) return false;
  cdp_json_detail::Reader r{json, at};
  std::string value;
  if (!r.string(&value)) return false;
  *out = std::move(value);
  return true;
}

// The integer at `path` (no fraction, no exponent, fits a long long).
inline bool cdp_json_int(const std::string &json, std::initializer_list<const char *> path, long long *out) {
  size_t at = 0;
  if (!cdp_json_detail::locate(json, path, &at)) return false;
  cdp_json_detail::Reader r{json, at};
  bool is_int = false;
  long long v = 0;
  if (!r.number(&is_int, &v) || !is_int) return false;
  *out = v;
  return true;
}
