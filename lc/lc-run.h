// Runs a LeetCode solution against a cases file and writes one JSON line per event to a results file.
// The user's own stdout is never touched, so it can't mix with results. Relies on lc-io.h.
#ifndef LC_RUN_H
#define LC_RUN_H

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

struct TestCli {
    std::string cases, results;
    bool any_order = false;
};

// Parses `test <cases> <results> [--any-order]`. Returns 0, or the exit code after printing the problem.
inline int parse_test_cli(int argc, char** argv, TestCli& cli) {
    std::string mode = argc > 1 ? argv[1] : "";
    if (mode == "bench" || mode == "profile" || mode == "gen") {
        std::cerr << "mode not supported yet\n";
        return 2;
    }
    bool ok = mode == "test" && (argc == 4 || (argc == 5 && std::string(argv[4]) == "--any-order"));
    if (!ok) {
        std::cerr << "usage: test <cases> <results> [--any-order]\n";
        return 2;
    }
    cli.cases = argv[2];
    cli.results = argv[3];
    cli.any_order = argc == 5;
    return 0;
}

template <class S, class R, class M, class... A>
int run_function_impl(int argc, char** argv, M method, const std::vector<std::string>& names, int out_param) {
    constexpr size_t N = sizeof...(A);
    TestCli cli;
    if (int code = parse_test_cli(argc, argv, cli)) return code;

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
        cases = read_cases(cli.cases);
    } catch (const std::exception& e) {
        std::cerr << e.what() << '\n';
        return 2;
    }
    std::ofstream out(cli.results, std::ios::binary);
    if (!out) {
        std::cerr << "can't write results file " << cli.results << '\n';
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

}  // namespace lc

#endif
