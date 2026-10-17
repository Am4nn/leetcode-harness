// Random LeetCode inputs from a spec file (see formats.md). Deterministic for a given seed.
// Relies on lc-io.h (is_vector_v, always_false).
#ifndef LC_GEN_H
#define LC_GEN_H

namespace lc {

struct ParamSpec {
    std::optional<long long> len_min, len_max, val_min, val_max;
    std::string chars, eqlen;
    bool sorted = false, distinct = false;
};

struct Spec {
    std::map<std::string, ParamSpec> params;
    std::string size;
    std::optional<long long> calls;
};

// Reads the shared spec format. Throws std::runtime_error on a bad file.
inline Spec read_spec(const std::string& path) {
    std::ifstream in(path, std::ios::binary);
    if (!in) throw std::runtime_error("can't read spec file " + path);
    Spec spec;
    int ln = 0;
    auto bad = [&](const std::string& msg) {
        throw std::runtime_error("spec file line " + std::to_string(ln) + ": " + msg);
    };
    for (std::string line; std::getline(in, line);) {
        ++ln;
        std::istringstream ss(line);
        std::vector<std::string> t;
        for (std::string w; ss >> w;) t.push_back(w);
        if (t.empty()) continue;
        size_t i = 1;
        auto word = [&]() -> const std::string& {
            if (i >= t.size()) bad("missing value after '" + t[i - 1] + "'");
            return t[i++];
        };
        auto num = [&] {
            const std::string& w = word();
            long long v = 0;
            auto [e, ec] = std::from_chars(w.data(), w.data() + w.size(), v);
            if (ec != std::errc() || e != w.data() + w.size()) bad("bad number '" + w + "'");
            return v;
        };
        if (t[0] == "size") {
            spec.size = word();
        } else if (t[0] == "calls") {
            spec.calls = num();
        } else if (t[0] == "param") {
            ParamSpec& p = spec.params[word()];
            while (i < t.size()) {
                const std::string& k = t[i++];
                if (k == "len") { p.len_min = num(); p.len_max = num(); }
                else if (k == "val") { p.val_min = num(); p.val_max = num(); }
                else if (k == "chars") p.chars = word();
                else if (k == "eqlen") p.eqlen = word();
                else if (k == "sorted") p.sorted = true;
                else if (k == "distinct") p.distinct = true;
                else bad("unknown param key '" + k + "'");
            }
        } else {
            bad("unknown directive '" + t[0] + "'");
        }
        if (i < t.size()) bad("unexpected '" + t[i] + "'");
    }
    return spec;
}

template <class T> struct is_generated_container
    : std::bool_constant<is_vector_v<T> || std::is_same_v<T, std::string> || std::is_same_v<T, TreeNode*> ||
                         std::is_same_v<T, ListNode*>> {};

namespace detail {

inline long long clamp_len(const ParamSpec& p, long long n) {
    if (p.len_max) n = std::min(n, *p.len_max);
    if (p.len_min) n = std::max(n, *p.len_min);
    return std::max(n, 0LL);
}

inline long long ceil_sqrt(long long n) {
    long long s = (long long)std::sqrt((double)std::max(n, 0LL));
    while (s * s < n) ++s;
    while (s > 0 && (s - 1) * (s - 1) >= n) --s;
    return s;
}

// A finite set of values, indexed 0..size-1 in increasing order.
template <class E> struct Domain {
    unsigned long long size = 0;
    long long lo = 0;   // integral types
    std::string alpha;  // char: sorted distinct alphabet
    E at(unsigned long long k) const {
        if constexpr (std::is_same_v<E, char>) return alpha[k];
        else if constexpr (std::is_same_v<E, bool>) return k != 0;
        else return (E)(long long)((unsigned long long)lo + k);
    }
};

template <class E> Domain<E> domain(const ParamSpec& p) {
    Domain<E> d;
    if constexpr (std::is_same_v<E, char>) {
        d.alpha = p.chars.empty() ? "abcdefghijklmnopqrstuvwxyz" : p.chars;
        std::sort(d.alpha.begin(), d.alpha.end());
        d.alpha.erase(std::unique(d.alpha.begin(), d.alpha.end()), d.alpha.end());
        d.size = d.alpha.size();
    } else if constexpr (std::is_same_v<E, bool>) {
        d.size = 2;
    } else {
        constexpr long long def = std::is_same_v<E, int> ? 1000000000LL : 1000000000000000000LL;
        long long lo = p.val_min.value_or(-def), hi = p.val_max.value_or(def);
        lo = std::max(lo, (long long)std::numeric_limits<E>::min());
        hi = std::min(hi, (long long)std::numeric_limits<E>::max());
        if (lo > hi) std::swap(lo, hi);
        unsigned long long span = (unsigned long long)hi - (unsigned long long)lo;
        d.lo = lo;
        d.size = span == ~0ULL ? span : span + 1;
    }
    return d;
}

// `len` scalars honoring `sorted` and `distinct`. With `distinct`, len clamps to the number of values.
template <class E> std::vector<E> gen_seq(const ParamSpec& p, long long len, std::mt19937_64& rng) {
    std::vector<E> v;
    if constexpr (std::is_floating_point_v<E>) {
        double lo = (double)p.val_min.value_or(-10000), hi = (double)p.val_max.value_or(10000);
        if (lo > hi) std::swap(lo, hi);
        std::uniform_real_distribution<double> dist(lo, hi);
        std::unordered_set<double> seen;
        for (long long i = 0, tries = 0; i < len && tries < 4 * len + 100; ++tries) {
            double x = dist(rng);
            if (p.distinct && !seen.insert(x).second) continue;
            v.push_back((E)x);
            ++i;
        }
    } else {
        Domain<E> d = domain<E>(p);
        if (d.size == 0) return v;
        unsigned long long n = (unsigned long long)std::max(len, 0LL);
        if (p.distinct) {
            n = std::min(n, d.size);
            // Floyd's sampling: n distinct indices in [0, size) using n draws.
            std::unordered_set<unsigned long long> seen;
            std::vector<unsigned long long> ks;
            for (unsigned long long j = d.size - n; j < d.size; ++j) {
                unsigned long long k = std::uniform_int_distribution<unsigned long long>(0, j)(rng);
                if (!seen.insert(k).second) { k = j; seen.insert(j); }
                ks.push_back(k);
            }
            if (!p.sorted) std::shuffle(ks.begin(), ks.end(), rng);
            for (unsigned long long k : ks) v.push_back(d.at(k));
        } else {
            std::uniform_int_distribution<unsigned long long> dist(0, d.size - 1);
            for (unsigned long long i = 0; i < n; ++i) v.push_back(d.at(dist(rng)));
        }
    }
    if (p.sorted) std::sort(v.begin(), v.end());
    return v;
}

}  // namespace detail

// One random value of type T for parameter spec `p` at size n.
//  - vectors, strings, trees, lists: clamp(n, len_min, len_max) items/nodes
//  - vectors of containers (2-D): ceil(sqrt(n)) rows, each generated at size ceil(sqrt(n))
//  - scalars: uniform in [val_min, val_max]; defaults int +-1e9, long long +-1e18, double +-1e4,
//    chars a-z, tree/list values +-1e4
template <class T> T generate(const ParamSpec& p, long long n, std::mt19937_64& rng) {
    if constexpr (std::is_same_v<T, int> || std::is_same_v<T, long long> || std::is_same_v<T, double> ||
                  std::is_same_v<T, char> || std::is_same_v<T, bool>) {
        ParamSpec one = p;
        one.distinct = one.sorted = false;
        return detail::gen_seq<T>(one, 1, rng).at(0);
    } else if constexpr (std::is_same_v<T, std::string>) {
        auto v = detail::gen_seq<char>(p, detail::clamp_len(p, n), rng);
        return std::string(v.begin(), v.end());
    } else if constexpr (is_vector_v<T>) {
        using U = typename T::value_type;
        if constexpr (is_generated_container<U>::value) {
            long long side = detail::ceil_sqrt(n);
            T v;
            for (long long i = detail::clamp_len(p, side); i > 0; --i) v.push_back(generate<U>(p, side, rng));
            return v;
        } else {
            auto v = detail::gen_seq<U>(p, detail::clamp_len(p, n), rng);
            return T(v.begin(), v.end());
        }
    } else if constexpr (std::is_same_v<T, TreeNode*> || std::is_same_v<T, ListNode*>) {
        ParamSpec vp = p;
        if (!vp.val_min) vp.val_min = -10000;
        if (!vp.val_max) vp.val_max = 10000;
        std::vector<int> vals = detail::gen_seq<int>(vp, detail::clamp_len(p, n), rng);
        if constexpr (std::is_same_v<T, ListNode*>) {
            ListNode* head = nullptr;
            for (size_t i = vals.size(); i-- > 0;) head = new ListNode(vals[i], head);
            return head;
        } else {
            // Random shape: each new node takes a random free child slot.
            TreeNode* root = nullptr;
            std::vector<TreeNode**> slots{&root};
            for (int x : vals) {
                size_t i = std::uniform_int_distribution<size_t>(0, slots.size() - 1)(rng);
                TreeNode** s = slots[i];
                slots[i] = slots.back();
                slots.pop_back();
                *s = new TreeNode(x);
                slots.push_back(&(*s)->left);
                slots.push_back(&(*s)->right);
            }
            return root;
        }
    } else {
        static_assert(always_false<T>, "lc: unsupported parameter type");
    }
}

namespace detail {

template <class T> long long length_of(const T& v) {
    if constexpr (is_vector_v<T> || std::is_same_v<T, std::string>) return (long long)v.size();
    else if constexpr (std::is_same_v<T, ListNode*>) {
        long long c = 0;
        for (const ListNode* x = v; x; x = x->next) ++c;
        return c;
    } else if constexpr (std::is_same_v<T, TreeNode*>) {
        long long c = 0;
        std::vector<const TreeNode*> st;
        if (v) st.push_back(v);
        while (!st.empty()) {
            const TreeNode* x = st.back();
            st.pop_back();
            ++c;
            if (x->left) st.push_back(x->left);
            if (x->right) st.push_back(x->right);
        }
        return c;
    } else return (long long)v;
}

template <class T> constexpr bool is_size_scalar_v =
    std::is_integral_v<T> && !std::is_same_v<T, bool> && !std::is_same_v<T, char>;

}  // namespace detail

// All arguments of a function at size n, by parameter name. The `size` parameter, when it is an
// integer scalar, is n (clamped to its val range). A parameter with `eqlen other` is generated after
// the others: a scalar takes other's generated length, a container is generated at that length.
template <class... Ts>
std::tuple<Ts...> generate_args(const Spec& spec, const std::vector<std::string>& names, long long n,
                                std::mt19937_64& rng) {
    std::tuple<Ts...> args;
    std::map<std::string, long long> lens;
    auto ps = [&](size_t i) {
        if (i < names.size())
            if (auto it = spec.params.find(names[i]); it != spec.params.end()) return it->second;
        return ParamSpec{};
    };
    auto one = [&]<size_t I>(std::integral_constant<size_t, I>, bool eq_pass) {
        using T = std::tuple_element_t<I, std::tuple<Ts...>>;
        ParamSpec p = ps(I);
        if (p.eqlen.empty() == eq_pass) return;
        T& v = std::get<I>(args);
        if (eq_pass) {
            auto it = lens.find(p.eqlen);
            long long len = it != lens.end() ? it->second : n;
            if constexpr (detail::is_size_scalar_v<T>) v = (T)len;
            else v = generate<T>(p, len, rng);
        } else if (I < names.size() && names[I] == spec.size && detail::is_size_scalar_v<T>) {
            long long x = n;
            if (p.val_max) x = std::min(x, *p.val_max);
            if (p.val_min) x = std::max(x, *p.val_min);
            v = (T)x;
        } else {
            v = generate<T>(p, n, rng);
        }
        if (I < names.size()) lens[names[I]] = detail::length_of(v);
    };
    [&]<size_t... I>(std::index_sequence<I...>) {
        (one(std::integral_constant<size_t, I>{}, false), ...);
        (one(std::integral_constant<size_t, I>{}, true), ...);
    }(std::index_sequence_for<Ts...>{});
    return args;
}

}  // namespace lc

#endif
