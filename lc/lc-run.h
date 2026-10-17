// Runs a LeetCode solution against a cases file and writes one JSON line per event to a results file.
// The user's own stdout is never touched, so it can't mix with results. Also has the bench and gen modes.
// Relies on lc-io.h, lc-alloc.h and lc-gen.h.
#ifndef LC_RUN_H
#define LC_RUN_H

#include <cxxabi.h>

namespace lc {

struct Case {
    int n = 0;
    std::vector<std::string> args;
    std::optional<std::string> expect;
    std::string ops, design_args;
};

// Reads the shared cases format (see formats.md). Throws std::runtime_error on a bad file.
inline std::vector<Case> read_cases(const std::string& path) {
    std::ifstream in(path, std::ios::binary);
    if (!in) throw std::runtime_error("can't read cases file " + path);
    std::vector<Case> out;
    std::optional<Case> cur;
    int ln = 0;
    auto bad = [&](const std::string& msg) {
        throw std::runtime_error("cases file line " + std::to_string(ln) + ": " + msg);
    };
    for (std::string line; std::getline(in, line);) {
        ++ln;
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.empty()) continue;
        size_t sp = line.find(' ');
        std::string key = line.substr(0, sp), val = sp == std::string::npos ? "" : line.substr(sp + 1);
        if (key == "case") {
            if (cur) bad("missing 'end'");
            cur.emplace();
            auto [e, ec] = std::from_chars(val.data(), val.data() + val.size(), cur->n);
            if (ec != std::errc() || e != val.data() + val.size()) bad("bad case number '" + val + "'");
        } else if (!cur) {
            bad("expected 'case'");
        } else if (key == "arg") {
            cur->args.push_back(val);
        } else if (key == "expect") {
            cur->expect = val;
        } else if (key == "ops") {
            cur->ops = val;
        } else if (key == "args") {
            cur->design_args = val;
        } else if (key == "end") {
            out.push_back(std::move(*cur));
            cur.reset();
        } else {
            bad("unknown line '" + key + "'");
        }
    }
    if (cur) bad("missing 'end'");
    return out;
}

namespace detail {

struct Result {
    int n = 0;
    std::string status, got, expected, diff, error;
    std::optional<double> ms;
};

inline void write_start(std::ostream& o, int n) {
    o << "{\"n\":" << n << ",\"status\":\"start\"}\n" << std::flush;
}

inline void write_result(std::ostream& o, const Result& r) {
    auto field = [&](const char* k, const std::string& v) {
        if (!v.empty()) o << ",\"" << k << "\":\"" << json_escape(v) << '"';
    };
    o << "{\"n\":" << r.n << ",\"status\":\"" << r.status << '"';
    field("got", r.got);
    field("expected", r.expected);
    if (r.ms) {
        char b[32];
        std::snprintf(b, sizeof b, "%.3f", *r.ms);
        o << ",\"ms\":" << b;
    }
    field("diff", r.diff);
    field("error", r.error);
    o << "}\n" << std::flush;
}

// Fills `got`, and for a case with `expect`, `expected`, `status` and `diff`.
template <class T> void judge(Result& r, const T& got, const Case& c, bool any_order) {
    r.got = show(got);
    if (!c.expect) { r.status = "print"; return; }
    std::optional<T> want;
    try {
        want = parse<T>(*c.expect);
    } catch (const ParseError& e) {
        r.status = "error";
        r.error = std::string("can't read expected: ") + e.what();
        return;
    }
    r.expected = show(*want);
    if (equal(got, *want, any_order)) {
        r.status = "pass";
    } else {
        r.status = "fail";
        r.diff = describe_diff(got, *want);
    }
}

struct Cli {
    std::string mode, in, out;  // in: cases or spec file; out: results or cases file
    bool any_order = false;
    unsigned long long seed = 0;
    double max_ms = 0;
    long long count = 0, max_n = 0;
};

// Parses the runner CLI (see formats.md). Returns 0, or the exit code after printing the problem.
inline int parse_cli(int argc, char** argv, Cli& cli) {
    static const std::string test_use = "test <cases> <results> [--any-order]",
                             bench_use = "bench <spec> <results> --seed S --max-ms M",
                             gen_use = "gen <spec> <out-cases> --count C --max-n N --seed S";
    auto usage = [](const std::string& text) {
        std::cerr << "usage: " << text << '\n';
        return 2;
    };
    cli.mode = argc > 1 ? argv[1] : "";
    if (cli.mode == "profile") {
        std::cerr << "mode not supported yet\n";
        return 2;
    }
    if (cli.mode == "test") {
        if (!(argc == 4 || (argc == 5 && std::string(argv[4]) == "--any-order"))) return usage(test_use);
        cli.in = argv[2];
        cli.out = argv[3];
        cli.any_order = argc == 5;
        return 0;
    }
    if (cli.mode != "bench" && cli.mode != "gen") return usage(test_use + " | " + bench_use + " | " + gen_use);
    bool bench = cli.mode == "bench";
    const std::string& use = bench ? bench_use : gen_use;
    if (argc < 4 || argc % 2) return usage(use);
    cli.in = argv[2];
    cli.out = argv[3];
    std::set<std::string> seen;
    for (int i = 4; i + 1 < argc; i += 2) {
        std::string k = argv[i], v = argv[i + 1];
        auto number = [&](auto& x) {
            auto [e, ec] = std::from_chars(v.data(), v.data() + v.size(), x);
            return ec == std::errc() && e == v.data() + v.size();
        };
        bool ok = false;
        if (k == "--seed") ok = number(cli.seed);
        else if (bench && k == "--max-ms") ok = number(cli.max_ms) && cli.max_ms > 0;
        else if (!bench && k == "--count") ok = number(cli.count) && cli.count >= 0;
        else if (!bench && k == "--max-n") ok = number(cli.max_n) && cli.max_n >= 1;
        if (!ok || !seen.insert(k).second) return usage(use);
    }
    if (seen.size() != (bench ? 2u : 3u)) return usage(use);
    return 0;
}

// ---- bench and gen helpers ----

// Keeps the compiler from dropping or moving a computation whose result is otherwise unused.
template <class T> inline void keep(T& v) { asm volatile("" : : "g"(&v) : "memory"); }

template <class T> struct is_tuple : std::false_type {};
template <class... U> struct is_tuple<std::tuple<U...>> : std::true_type {};

// A fresh copy of generated arguments (a value or a tuple of them); trees and lists are copied node by node.
template <class T> T clone(const T& v) {
    if constexpr (std::is_same_v<T, TreeNode*>) {
        if (!v) return nullptr;
        TreeNode* root = new TreeNode(v->val);
        std::vector<std::pair<const TreeNode*, TreeNode*>> st{{v, root}};
        while (!st.empty()) {
            auto [s, d] = st.back();
            st.pop_back();
            if (s->left) st.push_back({s->left, d->left = new TreeNode(s->left->val)});
            if (s->right) st.push_back({s->right, d->right = new TreeNode(s->right->val)});
        }
        return root;
    } else if constexpr (std::is_same_v<T, ListNode*>) {
        ListNode head;
        ListNode* t = &head;
        for (const ListNode* x = v; x; x = x->next) t = t->next = new ListNode(x->val);
        return head.next;
    } else if constexpr (is_tuple<T>::value) {
        return std::apply([](const auto&... x) { return T{clone(x)...}; }, v);
    } else if constexpr (is_vector_v<T>) {
        using U = typename T::value_type;
        if constexpr (std::is_pointer_v<U> || is_vector_v<U>) {
            T out;
            out.reserve(v.size());
            for (const auto& x : v) out.push_back(clone(x));
            return out;
        } else {
            return v;
        }
    } else {
        return v;
    }
}

// "[a,b,...]": the values in cases format.
template <class Tuple> std::string show_tuple(const Tuple& t) {
    std::string s = "[";
    std::apply([&](const auto&... a) {
        size_t k = 0;
        ((s += (k++ ? "," : "") + show(a)), ...);
    }, t);
    return s + "]";
}

inline std::string num_text(double x) {
    char b[48];
    std::snprintf(b, sizeof b, "%.6f", x);
    return b;
}

inline bool load_spec(const Cli& cli, Spec& spec) {
    try {
        spec = read_spec(cli.in);
        return true;
    } catch (const std::exception& e) {
        std::cerr << e.what() << '\n';
        return false;
    }
}

// Method-call arguments in design bench/gen are generated at this size (clamped to their own len range),
// so a sequence of n calls stays O(n) to build.
inline constexpr long long design_arg_n = 16;

// Bench sizes, ascending: maxN, maxN/2, ... down to >= 8, at most 10. For a scalar size parameter with
// maxN <= 64: up to 10 evenly spaced sizes from max(1, maxN/10) to maxN (ruling R5).
inline std::vector<long long> bench_sizes(long long max_n, bool scalar) {
    std::vector<long long> v;
    max_n = std::max(max_n, 1LL);
    if (scalar && max_n <= 64) {
        long long lo = std::max(1LL, max_n / 10), k = std::min(10LL, max_n - lo + 1);
        for (long long i = 0; i < k; ++i) {
            long long n = k == 1 ? max_n : lo + ((max_n - lo) * i * 2 + (k - 1)) / (2 * (k - 1));
            if (v.empty() || n > v.back()) v.push_back(n);
        }
    } else {
        for (long long n = max_n; v.size() < 10 && (n >= 8 || v.empty()); n /= 2) v.push_back(n);
        std::reverse(v.begin(), v.end());
    }
    return v;
}

// Runs bench over `sizes` and writes the results lines. `prepare(n)` sets up one size and returns
// `once(AllocStats*) -> ms`, which runs one timed call (or design sequence) on fresh inputs. Given an
// AllocStats, `once` resets the stats right before the timed part and fills count/bytes since then and
// peak above the live bytes at the reset.
template <class Prepare> int bench_loop(const Cli& cli, const std::vector<long long>& sizes, bool design, Prepare prepare) {
    std::ofstream out(cli.out, std::ios::binary);
    if (!out) {
        std::cerr << "can't write results file " << cli.out << '\n';
        return 2;
    }
    auto per_call = [&](long long n, double ms) {
        return design ? ",\"per_call_us\":" + num_text(ms * 1000 / (double)n) : std::string();
    };
    auto capped = [&](long long n, double ms, bool predicted) {
        out << "{\"capped\":true,\"n\":" << n << ",\"ms\":" << num_text(ms) << per_call(n, ms)
            << (predicted ? ",\"predicted\":true" : "") << "}\n" << std::flush;
    };
    std::vector<std::pair<long long, double>> done;  // completed sizes and their min ms
    long long cur = 0;
    try {
        for (long long n : sizes) {
            cur = n;
            if (done.size() >= 2) {
                auto [n1, t1] = done[done.size() - 2];
                auto [n2, t2] = done.back();
                if (t1 > 0 && t2 > 0) {
                    double t = t2 * std::pow(t2 / t1, std::log((double)n / (double)n2) / std::log((double)n2 / (double)n1));
                    if (!(t <= 2 * cli.max_ms)) { capped(n, std::min(t, 1e12), true); break; }
                }
            }
            out << "{\"status\":\"start\",\"n\":" << n << ",\"seed\":" << cli.seed << "}\n" << std::flush;
            auto once = prepare(n);
            double best = 0, total = 0;
            int reps = 0;
            bool over = false;
            while (true) {
                double t = once(nullptr);
                best = reps ? std::min(best, t) : t;
                total += t;
                ++reps;
                if (reps == 1 && t > cli.max_ms) { over = true; break; }
                if (total >= 30 || reps >= 50) break;
            }
            if (over) { capped(n, best, false); break; }
            out << "{\"n\":" << n << ",\"ms\":" << num_text(best) << ",\"reps\":" << reps << per_call(n, best) << "}\n"
                << std::flush;
            done.push_back({n, best});
        }
        if (!done.empty()) {
            cur = done.back().first;
            AllocStats a{};
            prepare(cur)(&a);
            out << "{\"alloc\":{\"count\":" << a.count << ",\"bytes\":" << a.bytes << ",\"peak\":" << a.peak
                << "},\"n\":" << cur << "}\n";
        }
    } catch (const std::exception& e) {
        out << "{\"n\":" << cur << ",\"status\":\"error\",\"error\":\"" << json_escape(std::string("exception: ") + e.what())
            << "\"}\n";
    } catch (...) {
        out << "{\"n\":" << cur << ",\"status\":\"error\",\"error\":\"exception: unknown\"}\n";
    }
    return 0;
}

// Timing for one call: the start resets the alloc stats when asked; the stop reads them back.
struct Stopwatch {
    AllocStats* alloc;
    uint64_t base = 0;
    std::chrono::steady_clock::time_point t0{};
    void start() {
        if (alloc) {
            reset_alloc_stats();
            base = alloc_stats().live;
        }
        t0 = std::chrono::steady_clock::now();
    }
    double stop() {
        double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
        if (alloc) {
            const AllocStats& s = alloc_stats();
            *alloc = {s.count, s.bytes, s.live, s.peak - base};
        }
        return ms;
    }
};

template <class S, class R, class M, class... A>
int bench_function(const Cli& cli, M method, const std::vector<std::string>& names) {
    Spec spec;
    if (!load_spec(cli, spec)) return 2;
    using Args = std::tuple<std::remove_cvref_t<A>...>;
    using Seq = std::index_sequence_for<A...>;
    bool scalar = false;
    [&]<size_t... I>(std::index_sequence<I...>) {
        ((scalar = scalar || (I < names.size() && names[I] == spec.size &&
                              is_size_scalar_v<std::tuple_element_t<I, Args>>)), ...);
    }(Seq{});
    long long max_n = 100000;
    if (auto it = spec.params.find(spec.size); !spec.size.empty() && it != spec.params.end()) {
        const auto& lim = scalar ? it->second.val_max : it->second.len_max;
        if (lim) max_n = *lim;
    }
    auto prepare = [&](long long n) {
        std::mt19937_64 rng(cli.seed);
        Args args = generate_args<std::remove_cvref_t<A>...>(spec, names, n, rng);
        return [method, args = std::move(args)](AllocStats* alloc) -> double {
            Args a = clone(args);
            S sol;
            Stopwatch w{alloc};
            auto call = [&]<size_t... I>(std::index_sequence<I...>) -> decltype(auto) {
// GCC false positive: on an empty Solution it flags the (dead) virtual-call branch of a member pointer call.
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Warray-bounds"
                return (sol.*method)(std::get<I>(a)...);
#pragma GCC diagnostic pop
            };
            keep(a);
            w.start();
            if constexpr (std::is_void_v<R>) {
                call(Seq{});
                keep(a);
                return w.stop();
            } else {
                auto&& got = call(Seq{});
                keep(got);
                return w.stop();
            }
        };
    };
    return bench_loop(cli, bench_sizes(max_n, scalar), false, prepare);
}

// Opens the gen output; on failure prints the problem.
inline bool open_cases_out(const Cli& cli, std::ofstream& out) {
    out.open(cli.out, std::ios::binary);
    if (!out) std::cerr << "can't write cases file " << cli.out << '\n';
    return (bool)out;
}

// The size n of each gen case, uniform in [1, max-n], drawn from a generator of their own. Case i's values
// then come from a generator seeded with just seed + i, as bench's do from its seed, so at the same size
// and seed both produce the same input.
inline std::vector<long long> gen_sizes(const Cli& cli) {
    std::mt19937_64 pick(cli.seed ^ 0x9E3779B97F4A7C15ULL);
    std::uniform_int_distribution<long long> dist(1, cli.max_n);
    std::vector<long long> v;
    for (long long i = 0; i < cli.count; ++i) v.push_back(dist(pick));
    return v;
}

template <class... A> int gen_function(const Cli& cli, const std::vector<std::string>& names) {
    Spec spec;
    if (!load_spec(cli, spec)) return 2;
    std::ofstream out;
    if (!open_cases_out(cli, out)) return 2;
    std::vector<long long> sizes = gen_sizes(cli);
    for (long long i = 0; i < cli.count; ++i) {
        long long n = sizes[i];
        std::mt19937_64 rng(cli.seed + (unsigned long long)i);
        auto args = generate_args<std::remove_cvref_t<A>...>(spec, names, n, rng);
        out << "case " << i + 1 << '\n';
        std::apply([&](const auto&... a) { ((out << "arg " << show(a) << '\n'), ...); }, args);
        out << "end\n";
    }
    return 0;
}

template <class S, class R, class M, class... A>
int run_function_impl(int argc, char** argv, M method, const std::vector<std::string>& names, int out_param) {
    constexpr size_t N = sizeof...(A);
    Cli cli;
    if (int code = parse_cli(argc, argv, cli)) return code;
    if (cli.mode == "bench") return bench_function<S, R, M, A...>(cli, method, names);
    if (cli.mode == "gen") return gen_function<A...>(cli, names);

    if constexpr (std::is_void_v<R>) {
        constexpr bool mut[] = {false, (std::is_lvalue_reference_v<A> && !std::is_const_v<std::remove_reference_t<A>>)...};
        if (out_param < 0)
            for (size_t i = 0; i < N; ++i)
                if (mut[i + 1]) { out_param = (int)i; break; }
        if (out_param < 0 || out_param >= (int)N) {
            std::cerr << "void method has no output parameter\n";
            return 2;
        }
    }

    std::vector<Case> cases;
    try {
        cases = read_cases(cli.in);
    } catch (const std::exception& e) {
        std::cerr << e.what() << '\n';
        return 2;
    }
    std::ofstream out(cli.out, std::ios::binary);
    if (!out) {
        std::cerr << "can't write results file " << cli.out << '\n';
        return 2;
    }

    auto name = [&](size_t i) { return i < names.size() ? names[i] : "argument " + std::to_string(i + 1); };
    using Args = std::tuple<std::remove_cvref_t<A>...>;
    using Seq = std::index_sequence_for<A...>;

    for (const Case& c : cases) {
        write_start(out, c.n);
        Result r;
        r.n = c.n;
        r.status = "error";
        if (c.args.size() != N) {
            std::string list;
            for (size_t i = 0; i < N; ++i) list += (i ? ", " : " (") + name(i);
            if (N) list += ")";
            r.error = "expected " + std::to_string(N) + (N == 1 ? " argument" : " arguments") + list + ", got " +
                      std::to_string(c.args.size());
            write_result(out, r);
            continue;
        }

        Args args;
        bool parsed = [&]<size_t... I>(std::index_sequence<I...>) {
            auto one = [&]<size_t J>(std::integral_constant<size_t, J>) {
                try {
                    std::get<J>(args) = parse<std::tuple_element_t<J, Args>>(c.args[J]);
                    return true;
                } catch (const ParseError& e) {
                    r.error = "can't read " + name(J) + ": " + e.what();
                    return false;
                }
            };
            return (one(std::integral_constant<size_t, I>{}) && ...);
        }(Seq{});
        if (!parsed) { write_result(out, r); continue; }

        try {
            S sol;
            auto call = [&]<size_t... I>(std::index_sequence<I...>) -> decltype(auto) {
// GCC false positive: on an empty Solution it flags the (dead) virtual-call branch of a member pointer call.
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Warray-bounds"
                return (sol.*method)(std::get<I>(args)...);
#pragma GCC diagnostic pop
            };
            auto t0 = std::chrono::steady_clock::now();
            auto elapsed = [&] {
                return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
            };
            if constexpr (std::is_void_v<R>) {
                call(Seq{});
                r.ms = elapsed();
                [&]<size_t... I>(std::index_sequence<I...>) {
                    ((I == (size_t)out_param ? judge(r, std::get<I>(args), c, cli.any_order) : void()), ...);
                }(Seq{});
            } else {
                std::remove_cvref_t<R> got = call(Seq{});
                r.ms = elapsed();
                judge(r, got, c, cli.any_order);
            }
        } catch (const std::exception& e) {
            r.status = "error";
            r.error = std::string("exception: ") + e.what();
            r.ms.reset();
        } catch (...) {
            r.status = "error";
            r.error = "exception: unknown";
            r.ms.reset();
        }
        write_result(out, r);
    }
    return 0;
}

}  // namespace detail

template <class S, class R, class... A>
int run_function(int argc, char** argv, R (S::*method)(A...), std::vector<std::string> param_names, int out_param = -1) {
    return detail::run_function_impl<S, R, decltype(method), A...>(argc, argv, method, param_names, out_param);
}

template <class S, class R, class... A>
int run_function(int argc, char** argv, R (S::*method)(A...) const, std::vector<std::string> param_names,
                 int out_param = -1) {
    return detail::run_function_impl<S, R, decltype(method), A...>(argc, argv, method, param_names, out_param);
}

// ---- design problems ----

namespace detail {

// A problem with one call's arguments; the runner adds the "call N (name): " prefix.
struct CallError : std::runtime_error {
    using std::runtime_error::runtime_error;
};

// Parses `texts` into a tuple of the (decayed) parameter types, checking the count first.
template <class Tuple> Tuple parse_args(const std::vector<std::string>& texts, const std::vector<std::string>& names) {
    constexpr size_t N = std::tuple_size_v<Tuple>;
    auto name = [&](size_t i) { return i < names.size() ? names[i] : "argument " + std::to_string(i + 1); };
    if (texts.size() != N) {
        std::string list;
        for (size_t i = 0; i < N; ++i) list += (i ? ", " : " (") + name(i);
        if (N) list += ")";
        throw CallError("expected " + std::to_string(N) + (N == 1 ? " argument" : " arguments") + list + ", got " +
                        std::to_string(texts.size()));
    }
    return [&]<size_t... I>(std::index_sequence<I...>) {
        auto one = [&]<size_t J>(std::integral_constant<size_t, J>) {
            try {
                return parse<std::tuple_element_t<J, Tuple>>(texts[J]);
            } catch (const ParseError& e) {
                throw CallError("can't read " + name(J) + ": " + e.what());
            }
        };
        return Tuple{one(std::integral_constant<size_t, I>{})...};
    }(std::make_index_sequence<N>{});
}

}  // namespace detail

template <class C> struct Method {
    std::vector<std::string> names;
    // Returns show(result), or "null" for void.
    std::function<std::string(C&, const std::vector<std::string>& args)> call;
    // Parses both texts into the return type and compares them.
    std::function<bool(const std::string& got, const std::string& want)> same;
    // For bench/gen: random arguments (by parameter name) at size n. Returns a call that uses them, and
    // when `text` is given, writes them in cases format ("[a,b]").
    std::function<std::function<void(C&)>(const Spec&, long long n, std::mt19937_64&, std::string* text)> random;
};

namespace detail {

template <class C, class R, class M, class... A> Method<C> make_method(M m, std::vector<std::string> names) {
    Method<C> mt;
    mt.names = names;
    mt.call = [m, names](C& obj, const std::vector<std::string>& texts) -> std::string {
        using Args = std::tuple<std::remove_cvref_t<A>...>;
        Args args = parse_args<Args>(texts, names);
        auto invoke = [&]<size_t... I>(std::index_sequence<I...>) -> decltype(auto) {
// GCC false positive: on an empty class it flags the (dead) virtual-call branch of a member pointer call.
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Warray-bounds"
            return (obj.*m)(std::get<I>(args)...);
#pragma GCC diagnostic pop
        };
        if constexpr (std::is_void_v<R>) {
            invoke(std::index_sequence_for<A...>{});
            return "null";
        } else {
            return show<std::remove_cvref_t<R>>(invoke(std::index_sequence_for<A...>{}));
        }
    };
    mt.same = [](const std::string& got, const std::string& want) {
        if constexpr (std::is_void_v<R>) {
            return got == want;
        } else {
            using T = std::remove_cvref_t<R>;
            return equal(parse<T>(got), parse<T>(want), false);
        }
    };
    mt.random = [m, names](const Spec& spec, long long n, std::mt19937_64& rng,
                           std::string* text) -> std::function<void(C&)> {
        auto args = generate_args<std::remove_cvref_t<A>...>(spec, names, n, rng);
        if (text) *text = show_tuple(args);
        return [m, args](C& obj) mutable {
            std::apply([&](auto&... a) {
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Warray-bounds"
                if constexpr (std::is_void_v<R>) {
                    (obj.*m)(a...);
                } else {
                    auto&& got = (obj.*m)(a...);
                    keep(got);
                }
#pragma GCC diagnostic pop
            }, args);
        };
    };
    return mt;
}

// The class name as written in the source (ops[0] of a design case), from the type's RTTI name.
template <class C> std::string class_name() {
    int status = 0;
    char* d = abi::__cxa_demangle(typeid(C).name(), nullptr, nullptr, &status);
    std::string s = status == 0 && d ? d : typeid(C).name();
    std::free(d);
    return s;
}

template <class C> using MethodList = std::vector<std::pair<std::string, const Method<C>*>>;

// One random design sequence at n calls: constructor arguments, then n uniformly random methods with
// random arguments. Fills `ops`/`args_text` (cases format) when given. Bench and gen share it, so a
// seed gives the same sequence in both.
template <class C, class... CtorA>
std::tuple<std::remove_cvref_t<CtorA>...> random_sequence(const Spec& spec, const std::vector<std::string>& ctor_names,
                                                         const MethodList<C>& ms, long long n, std::mt19937_64& rng,
                                                         std::vector<std::function<void(C&)>>& calls,
                                                         std::vector<std::string>* ops, std::string* args_text) {
    auto ct = generate_args<std::remove_cvref_t<CtorA>...>(spec, ctor_names, n, rng);
    if (args_text) *args_text = "[" + show_tuple(ct);
    calls.clear();
    calls.reserve(ms.empty() ? 0 : (size_t)n);
    std::string t;
    for (long long k = 0; k < n && !ms.empty(); ++k) {
        const auto& [name, mt] = ms[std::uniform_int_distribution<size_t>(0, ms.size() - 1)(rng)];
        calls.push_back(mt->random(spec, design_arg_n, rng, args_text ? &t : nullptr));
        if (ops) ops->push_back(name);
        if (args_text) *args_text += "," + t;
    }
    if (args_text) *args_text += "]";
    return ct;
}

template <class C, class... CtorA>
int bench_design(const Cli& cli, const std::vector<std::string>& ctor_names, const MethodList<C>& ms) {
    Spec spec;
    if (!load_spec(cli, spec)) return 2;
    auto prepare = [&](long long n) {
        // The sequence is rebuilt from the seed for every run (untimed), so each run gets fresh arguments.
        return [&, n](AllocStats* alloc) -> double {
            std::mt19937_64 rng(cli.seed);
            std::vector<std::function<void(C&)>> calls;
            auto ct = random_sequence<C, CtorA...>(spec, ctor_names, ms, n, rng, calls, nullptr, nullptr);
            Stopwatch w{alloc};
            keep(ct);
            keep(calls);
            w.start();
            std::unique_ptr<C> obj = std::apply([](auto&... a) { return std::make_unique<C>(a...); }, ct);
            for (auto& f : calls) f(*obj);
            keep(obj);
            return w.stop();
        };
    };
    return bench_loop(cli, bench_sizes(spec.calls.value_or(100000), false), true, prepare);
}

template <class C, class... CtorA>
int gen_design(const Cli& cli, const std::vector<std::string>& ctor_names, const MethodList<C>& ms) {
    Spec spec;
    if (!load_spec(cli, spec)) return 2;
    std::ofstream out;
    if (!open_cases_out(cli, out)) return 2;
    const std::string cls = class_name<C>();
    std::vector<long long> sizes = gen_sizes(cli);
    std::vector<std::function<void(C&)>> calls;
    for (long long i = 0; i < cli.count; ++i) {
        std::mt19937_64 rng(cli.seed + (unsigned long long)i);
        std::vector<std::string> ops{cls};
        std::string args;
        random_sequence<C, CtorA...>(spec, ctor_names, ms, sizes[i], rng, calls, &ops, &args);
        out << "case " << i + 1 << "\nops " << show(ops) << "\nargs " << args << "\nend\n";
    }
    return 0;
}

}  // namespace detail

template <class C, class R, class... A> Method<C> method(R (C::*m)(A...), std::vector<std::string> names) {
    return detail::make_method<C, R, decltype(m), A...>(m, std::move(names));
}

template <class C, class R, class... A> Method<C> method(R (C::*m)(A...) const, std::vector<std::string> names) {
    return detail::make_method<C, R, decltype(m), A...>(m, std::move(names));
}

template <class C, class... CtorA>
int run_design(int argc, char** argv, std::vector<std::string> ctor_names, std::map<std::string, Method<C>> methods) {
    detail::Cli cli;
    if (int code = detail::parse_cli(argc, argv, cli)) return code;
    if (cli.mode == "bench" || cli.mode == "gen") {
        detail::MethodList<C> ms;
        for (const auto& [name, mt] : methods) ms.push_back({name, &mt});
        return cli.mode == "bench" ? detail::bench_design<C, CtorA...>(cli, ctor_names, ms)
                                   : detail::gen_design<C, CtorA...>(cli, ctor_names, ms);
    }
    std::vector<Case> cases;
    try {
        cases = read_cases(cli.in);
    } catch (const std::exception& e) {
        std::cerr << e.what() << '\n';
        return 2;
    }
    std::ofstream out(cli.out, std::ios::binary);
    if (!out) {
        std::cerr << "can't write results file " << cli.out << '\n';
        return 2;
    }

    using namespace detail;
    for (const Case& c : cases) {
        write_start(out, c.n);
        Result r;
        r.n = c.n;
        r.status = "error";

        std::vector<std::string> ops, calls, wants;
        try {
            ops = parse<std::vector<std::string>>(c.ops);
            calls = split_top_level(c.design_args);
            if (c.expect) wants = split_top_level(*c.expect);
        } catch (const ParseError& e) {
            r.error = std::string("can't read ops/args/expect: ") + e.what();
            write_result(out, r);
            continue;
        }
        if (ops.empty()) { r.error = "ops is empty"; write_result(out, r); continue; }
        if (ops.size() != calls.size()) {
            r.error = "ops has " + std::to_string(ops.size()) + " entries but args has " + std::to_string(calls.size());
            write_result(out, r);
            continue;
        }
        if (c.expect && wants.size() != ops.size()) {
            r.error = "expect has " + std::to_string(wants.size()) + " entries but ops has " + std::to_string(ops.size());
            write_result(out, r);
            continue;
        }
        for (size_t k = 1; k < ops.size() && r.error.empty(); ++k)
            if (!methods.count(ops[k])) r.error = "unknown method " + ops[k];
        if (!r.error.empty()) { write_result(out, r); continue; }

        std::vector<std::string> gots;
        size_t i = 0;
        auto where = [&] { return "call " + std::to_string(i + 1) + " (" + ops[i] + ")"; };
        auto split_args = [](const std::string& text) {
            try {
                return split_top_level(text);
            } catch (const ParseError& e) {
                throw CallError(std::string("can't read args: ") + e.what());
            }
        };
        try {
            using CtorArgs = std::tuple<std::remove_cvref_t<CtorA>...>;
            CtorArgs ct = parse_args<CtorArgs>(split_args(calls[0]), ctor_names);
            auto t0 = std::chrono::steady_clock::now();
            std::unique_ptr<C> obj = std::apply([](auto&... a) { return std::make_unique<C>(a...); }, ct);
            gots.push_back("null");
            for (i = 1; i < ops.size(); ++i) gots.push_back(methods.at(ops[i]).call(*obj, split_args(calls[i])));
            r.ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
        } catch (const CallError& e) {
            r.error = where() + ": " + e.what();
            write_result(out, r);
            continue;
        } catch (const std::exception& e) {
            r.error = std::string("exception: ") + e.what();
            write_result(out, r);
            continue;
        } catch (...) {
            r.error = "exception: unknown";
            write_result(out, r);
            continue;
        }

        auto join = [](const std::vector<std::string>& v) {
            std::string s = "[";
            for (size_t k = 0; k < v.size(); ++k) s += (k ? "," : "") + v[k];
            return s + "]";
        };
        r.got = join(gots);
        if (!c.expect) { r.status = "print"; write_result(out, r); continue; }
        r.expected = join(wants);
        r.status = "pass";
        for (i = 1; i < ops.size() && r.status == "pass"; ++i) {
            bool same;
            try {
                same = (gots[i] == "null" || wants[i] == "null") ? gots[i] == wants[i]
                                                                   : methods.at(ops[i]).same(gots[i], wants[i]);
            } catch (const ParseError& e) {
                r.status = "error";
                r.error = std::string("can't read expected for ") + where() + ": " + e.what();
                break;
            }
            if (!same) {
                r.status = "fail";
                r.diff = where() + ": got " + gots[i] + ", expected " + wants[i];
            }
        }
        write_result(out, r);
    }
    return 0;
}

}  // namespace lc

#endif
