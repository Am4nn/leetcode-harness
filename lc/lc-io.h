// Parse / print / compare LeetCode values (LeetCode's canonical text format).
// Relies on lc-prelude.h (TreeNode, ListNode, <bits/stdc++.h>) being included first.
#ifndef LC_IO_H
#define LC_IO_H

namespace lc {

struct ParseError : std::runtime_error {
    using std::runtime_error::runtime_error;
};

template <class> inline constexpr bool always_false = false;

template <class T> struct is_vector : std::false_type {};
template <class U, class A> struct is_vector<std::vector<U, A>> : std::true_type {};
template <class T> inline constexpr bool is_vector_v = is_vector<T>::value;

inline std::string json_escape(std::string_view s) {
    std::string o;
    for (char ch : s) {
        unsigned char c = (unsigned char)ch;
        switch (c) {
            case '"': o += "\\\""; break;
            case '\\': o += "\\\\"; break;
            case '\n': o += "\\n"; break;
            case '\r': o += "\\r"; break;
            case '\t': o += "\\t"; break;
            default:
                if (c < 0x20) {
                    char b[8];
                    std::snprintf(b, sizeof b, "\\u%04x", c);
                    o += b;
                } else o += ch;
        }
    }
    return o;
}

namespace detail {

struct Reader {
    std::string_view s;
    size_t p = 0;

    [[noreturn]] void fail(const std::string& msg) const {
        throw ParseError(msg + " at position " + std::to_string(p));
    }
    void skip_ws() {
        while (p < s.size() && std::isspace((unsigned char)s[p])) ++p;
    }
    bool at_end() { skip_ws(); return p >= s.size(); }
    bool peek_is(char c) { skip_ws(); return p < s.size() && s[p] == c; }
    void expect(char c) {
        skip_ws();
        if (p >= s.size() || s[p] != c) fail(std::string("expected '") + c + "'");
        ++p;
    }
    bool accept(char c) {
        if (peek_is(c)) { ++p; return true; }
        return false;
    }
    bool accept_word(std::string_view w) {
        skip_ws();
        if (s.substr(p, w.size()) != w) return false;
        size_t e = p + w.size();
        if (e < s.size() && std::isalnum((unsigned char)s[e])) return false;
        p = e;
        return true;
    }
    // Scans a number-ish token (no whitespace or delimiters) and returns it.
    std::string_view token() {
        skip_ws();
        size_t b = p;
        while (p < s.size() && (std::isalnum((unsigned char)s[p]) || s[p] == '-' || s[p] == '+' || s[p] == '.')) ++p;
        if (b == p) fail("expected a value");
        return s.substr(b, p - b);
    }

    template <class N> N number() {
        size_t at = p;
        std::string_view t = token();
        N v{};
        auto [e, ec] = std::from_chars(t.data(), t.data() + t.size(), v);
        if (ec != std::errc() || e != t.data() + t.size()) {
            p = at;
            fail("bad number '" + std::string(t) + "'");
        }
        return v;
    }

    std::string str() {
        expect('"');
        std::string o;
        while (true) {
            if (p >= s.size()) fail("unterminated string");
            char c = s[p++];
            if (c == '"') break;
            if (c != '\\') { o += c; continue; }
            if (p >= s.size()) fail("unterminated string");
            char e = s[p++];
            switch (e) {
                case '"': o += '"'; break;
                case '\\': o += '\\'; break;
                case '/': o += '/'; break;
                case 'n': o += '\n'; break;
                case 't': o += '\t'; break;
                case 'r': o += '\r'; break;
                case 'b': o += '\b'; break;
                case 'f': o += '\f'; break;
                case 'u': {
                    if (p + 4 > s.size()) fail("bad \\u escape");
                    unsigned cp = 0;
                    auto [e2, ec] = std::from_chars(s.data() + p, s.data() + p + 4, cp, 16);
                    if (ec != std::errc() || e2 != s.data() + p + 4) fail("bad \\u escape");
                    p += 4;
                    if (cp < 0x80) o += (char)cp;
                    else if (cp < 0x800) { o += (char)(0xC0 | (cp >> 6)); o += (char)(0x80 | (cp & 0x3F)); }
                    else {
                        o += (char)(0xE0 | (cp >> 12));
                        o += (char)(0x80 | ((cp >> 6) & 0x3F));
                        o += (char)(0x80 | (cp & 0x3F));
                    }
                    break;
                }
                default: fail("bad escape");
            }
        }
        return o;
    }

    // Reads "[ item, item, ... ]" calling f() for each item.
    template <class F> void array(F f) {
        expect('[');
        if (accept(']')) return;
        while (true) {
            f();
            if (accept(',')) continue;
            expect(']');
            return;
        }
    }

    template <class T> T read();
};

template <class T> T Reader::read() {
    if constexpr (std::is_same_v<T, bool>) {
        if (accept_word("true")) return true;
        if (accept_word("false")) return false;
        fail("expected true or false");
    } else if constexpr (std::is_same_v<T, int> || std::is_same_v<T, long long> || std::is_same_v<T, double>) {
        return number<T>();
    } else if constexpr (std::is_same_v<T, char>) {
        std::string t = str();
        if (t.size() != 1) fail("expected a one-character string");
        return t[0];
    } else if constexpr (std::is_same_v<T, std::string>) {
        return str();
    } else if constexpr (is_vector_v<T>) {
        T v;
        array([&] { v.push_back(read<typename T::value_type>()); });
        return v;
    } else if constexpr (std::is_same_v<T, TreeNode*>) {
        std::vector<std::optional<int>> tok;
        array([&] {
            if (accept_word("null")) tok.push_back(std::nullopt);
            else tok.push_back(number<int>());
        });
        if (tok.empty() || !tok[0]) return nullptr;
        TreeNode* root = new TreeNode(*tok[0]);
        std::queue<TreeNode*> q;
        q.push(root);
        size_t i = 1;
        while (!q.empty() && i < tok.size()) {
            TreeNode* n = q.front();
            q.pop();
            if (tok[i]) { n->left = new TreeNode(*tok[i]); q.push(n->left); }
            ++i;
            if (i < tok.size()) {
                if (tok[i]) { n->right = new TreeNode(*tok[i]); q.push(n->right); }
                ++i;
            }
        }
        return root;
    } else if constexpr (std::is_same_v<T, ListNode*>) {
        std::vector<int> v = read<std::vector<int>>();
        ListNode* head = nullptr;
        for (size_t i = v.size(); i-- > 0;) head = new ListNode(v[i], head);
        return head;
    } else {
        static_assert(always_false<T>, "lc: unsupported parameter type");
    }
}

}  // namespace detail

template <class T> T parse(std::string_view text) {
    detail::Reader r{text};
    T v = r.template read<T>();
    if (!r.at_end()) r.fail("unexpected trailing text");
    return v;
}

template <class T> std::string show(const T& v) {
    if constexpr (std::is_same_v<T, bool>) {
        return v ? "true" : "false";
    } else if constexpr (std::is_same_v<T, char>) {
        return "\"" + json_escape(std::string_view(&v, 1)) + "\"";
    } else if constexpr (std::is_integral_v<T>) {
        return std::to_string(v);
    } else if constexpr (std::is_floating_point_v<T>) {
        char b[64];
        std::snprintf(b, sizeof b, "%.5f", (double)v);
        return b;
    } else if constexpr (std::is_same_v<T, std::string>) {
        return "\"" + json_escape(v) + "\"";
    } else if constexpr (is_vector_v<T>) {
        std::string o = "[";
        bool first = true;
        for (const auto& x : v) {
            if (!first) o += ',';
            first = false;
            o += show(x);
        }
        return o + "]";
    } else if constexpr (std::is_same_v<T, TreeNode*>) {
        std::vector<std::string> out;
        std::queue<const TreeNode*> q;
        if (v) q.push(v);
        while (!q.empty()) {
            const TreeNode* n = q.front();
            q.pop();
            if (!n) { out.push_back("null"); continue; }
            out.push_back(std::to_string(n->val));
            q.push(n->left);
            q.push(n->right);
        }
        while (!out.empty() && out.back() == "null") out.pop_back();
        std::string o = "[";
        for (size_t i = 0; i < out.size(); ++i) { if (i) o += ','; o += out[i]; }
        return o + "]";
    } else if constexpr (std::is_same_v<T, ListNode*>) {
        std::string o = "[";
        for (const ListNode* n = v; n; n = n->next) {
            if (n != v) o += ',';
            o += std::to_string(n->val);
        }
        return o + "]";
    } else {
        static_assert(always_false<T>, "lc: unsupported parameter type");
    }
}

namespace detail {

template <class T> bool less_than(const T& a, const T& b) {
    if constexpr (std::is_arithmetic_v<T> || std::is_same_v<T, std::string>) return a < b;
    else return show(a) < show(b);
}

// Recursively sorts every inner vector, then the vector itself.
template <class T> T canonical(T v) {
    if constexpr (is_vector_v<T>) {
        using U = typename T::value_type;
        if constexpr (is_vector_v<U>) {
            for (auto& x : v) x = canonical(std::move(x));
        }
        if constexpr (std::is_same_v<T, std::vector<bool>>) {
            std::sort(v.begin(), v.end());
        } else {
            std::sort(v.begin(), v.end(), [](const U& a, const U& b) { return less_than(a, b); });
        }
    }
    return v;
}

}  // namespace detail

template <class T> bool equal(const T& got, const T& want, bool any_order) {
    if constexpr (std::is_floating_point_v<T>) {
        return std::fabs((double)got - (double)want) <= 1e-5;
    } else if constexpr (is_vector_v<T>) {
        if (any_order) return equal(detail::canonical(got), detail::canonical(want), false);
        if (got.size() != want.size()) return false;
        for (size_t i = 0; i < got.size(); ++i)
            if (!equal<typename T::value_type>(got[i], want[i], false)) return false;
        return true;
    } else if constexpr (std::is_same_v<T, TreeNode*> || std::is_same_v<T, ListNode*>) {
        return show(got) == show(want);
    } else {
        return got == want;
    }
}

template <class T> std::string describe_diff(const T& got, const T& want) {
    if constexpr (is_vector_v<T>) {
        size_t n = std::min(got.size(), want.size()), i = 0;
        while (i < n && equal<typename T::value_type>(got[i], want[i], false)) ++i;
        if (i == n && got.size() == want.size()) return "";
        std::string o = "first difference at index " + std::to_string(i);
        if (got.size() != want.size())
            o += " (got " + std::to_string(got.size()) + " items, expected " + std::to_string(want.size()) + ")";
        return o;
    } else {
        return "";
    }
}

inline std::vector<std::string> split_top_level(std::string_view text) {
    size_t b = 0, e = text.size();
    while (b < e && std::isspace((unsigned char)text[b])) ++b;
    while (e > b && std::isspace((unsigned char)text[e - 1])) --e;
    if (e - b < 2 || text[b] != '[' || text[e - 1] != ']') throw ParseError("expected a [...] list");
    std::vector<std::string> out;
    auto trim = [](std::string_view t) {
        size_t x = 0, y = t.size();
        while (x < y && std::isspace((unsigned char)t[x])) ++x;
        while (y > x && std::isspace((unsigned char)t[y - 1])) --y;
        return std::string(t.substr(x, y - x));
    };
    size_t start = b + 1, end = e - 1;
    int depth = 0;
    bool in_str = false;
    for (size_t i = start; i < end; ++i) {
        char c = text[i];
        if (in_str) {
            if (c == '\\') ++i;
            else if (c == '"') in_str = false;
        } else if (c == '"') in_str = true;
        else if (c == '[') ++depth;
        else if (c == ']') --depth;
        else if (c == ',' && depth == 0) {
            out.push_back(trim(text.substr(start, i - start)));
            start = i + 1;
        }
    }
    std::string last = trim(text.substr(start, end - start));
    if (!last.empty() || !out.empty()) out.push_back(last);
    return out;
}

}  // namespace lc

#endif
