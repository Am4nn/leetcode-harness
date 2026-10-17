#include "tests/check.h"
#include "lc.h"

struct Solution {
    long long sum(vector<int>& nums) {
        long long s = 0;
        for (int x : nums) s += x;
        return s;
    }
    long long pairs(vector<int>& nums) {
        long long c = 0;
        for (size_t i = 0; i < nums.size(); ++i)
            for (size_t j = i + 1; j < nums.size(); ++j) c += (nums[i] ^ nums[j]) % 7 == 3;
        return c;
    }
    vector<int> dup(vector<int>& nums) { return nums; }
    int climb(int n) {
        int a = 1, b = 1;
        for (int i = 2; i <= n; ++i) { int c = a + b; a = b; b = c; }
        return b;
    }
    int climbSlow(int n) { return n <= 1 ? 1 : climbSlow(n - 1) + climbSlow(n - 2); }
    // Busy-waits (n/512)^3 ms: 1 ms at 512, 8 ms at 1024, 64 ms at 2048.
    int cubic(vector<int>& nums) {
        double ms = std::pow(nums.size() / 512.0, 3);
        auto t0 = std::chrono::steady_clock::now();
        while (std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count() < ms) {}
        return 0;
    }
    int picky(vector<int>& nums) {
        if (nums.size() > 100) throw std::runtime_error("too big");
        return 0;
    }
};

struct Counter {
    int v;
    Counter(int start) : v(start) {}
    void add(int x) { v += x; }
    int get() { return v; }
};

// pop/top/getMin abort on an empty stack, like a correct solution would misbehave on a precondition breach.
struct MinStack {
    vector<pair<int, int>> st;
    MinStack() {}
    void push(int val) { st.push_back({val, st.empty() ? val : min(val, st.back().second)}); }
    void pop() { if (st.empty()) std::abort(); st.pop_back(); }
    int top() { if (st.empty()) std::abort(); return st.back().first; }
    int getMin() { if (st.empty()) std::abort(); return st.back().second; }
};

// Records the inputs it receives, to compare bench's input with gen's.
static string recorded;
static vector<string> rec_ops, rec_args;
struct Recorder {
    Recorder(int s) { rec_ops = {"Recorder"}; rec_args = {"[" + to_string(s) + "]"}; }
    void put(int x) { rec_ops.push_back("put"); rec_args.push_back("[" + to_string(x) + "]"); }
    int peek() { rec_ops.push_back("peek"); rec_args.push_back("[]"); return 0; }
};
// Stands in for a class under another name, as a generated harness's proxy does.
struct Stand {
    void add(int) {}
};
namespace lc {
template <> struct DesignName<Stand> {
    static std::string get() { return "RealName"; }
};
}  // namespace lc

struct Rec {
    int record(vector<int>& nums) { recorded = lc::show(nums); return 0; }
    long long gridSum(vector<vector<int>>& g) {
        long long s = 0;
        for (auto& r : g) for (int x : r) s += x;
        return s;
    }
    int maxDepth(TreeNode* root) { return root ? 1 + max(maxDepth(root->left), maxDepth(root->right)) : 0; }
    int words(vector<string>& w) { recorded = lc::show(w); return 0; }
};

namespace fs = std::filesystem;
static fs::path tmp_dir;
static int run_no = 0;

static bool has(const string& line, const string& part) { return line.find(part) != string::npos; }

// The number after "key": in a JSON line, or NaN.
static double num(const string& line, const string& key) {
    size_t p = line.find("\"" + key + "\":");
    if (p == string::npos) return std::nan("");
    return std::strtod(line.c_str() + p + key.size() + 3, nullptr);
}

static vector<string> read_lines(const fs::path& p) {
    vector<string> lines;
    ifstream in(p, ios::binary);
    for (string l; getline(in, l);) lines.push_back(l);
    return lines;
}

// Writes `spec`, runs `call(argc, argv)` with `mode <spec> <out> extra...`, returns the output file's lines.
template <class F> static vector<string> run(const string& mode, const string& spec, vector<string> extra, F call) {
    ++run_no;
    fs::path sp = tmp_dir / ("bench-" + to_string(run_no) + ".spec.txt");
    fs::path op = tmp_dir / ("bench-" + to_string(run_no) + ".out.txt");
    { ofstream(sp, ios::binary) << spec; }
    vector<string> args{"bench.test", mode, sp.string(), op.string()};
    args.insert(args.end(), extra.begin(), extra.end());
    vector<char*> argv;
    for (auto& a : args) argv.push_back(a.data());
    argv.push_back(nullptr);
    CHECK_EQ(call((int)args.size(), argv.data()), 0);
    return read_lines(op);
}

template <class M> static auto fn(M m, vector<string> names) {
    return [m, names](int argc, char** argv) { return lc::run_function(argc, argv, m, names); };
}

static int counter(int argc, char** argv) {
    return lc::run_design<Counter, int>(argc, argv, {"start"},
                                        {{"add", lc::method(&Counter::add, {"x"})}, {"get", lc::method(&Counter::get, {})}});
}

static int min_stack(int argc, char** argv) {
    return lc::run_design<MinStack>(argc, argv, {},
                                    {{"push", lc::method(&MinStack::push, {"val"})},
                                     {"pop", lc::method(&MinStack::pop, {})},
                                     {"top", lc::method(&MinStack::top, {})},
                                     {"getMin", lc::method(&MinStack::getMin, {})}});
}

static int recorder(int argc, char** argv) {
    return lc::run_design<Recorder, int>(argc, argv, {"s"},
                                         {{"put", lc::method(&Recorder::put, {"x"})},
                                          {"peek", lc::method(&Recorder::peek, {})}});
}

// The last file written by run().
static fs::path last_out() { return tmp_dir / ("bench-" + to_string(run_no) + ".out.txt"); }

static bool strictly_increasing(const vector<string>& s) {
    for (size_t i = 1; i < s.size(); ++i)
        if (!(num(s[i], "n") > num(s[i - 1], "n"))) return false;
    return true;
}

static vector<string> size_lines(const vector<string>& lines) {
    vector<string> out;
    for (auto& l : lines)
        if (has(l, "\"reps\":")) out.push_back(l);
    return out;
}

int main(int, char** argv) {
    tmp_dir = fs::absolute(fs::path(argv[0])).parent_path() / "tmp";
    fs::create_directories(tmp_dir);
    const vector<string> bench_flags{"--seed", "7", "--max-ms", "2000"};

    // O(n): halving sizes up to 4096, ascending, then an alloc line.
    {
        auto r = run("bench", "size nums\nparam nums len 1 4096\n", bench_flags, fn(&Solution::sum, {"nums"}));
        auto s = size_lines(r);
        CHECK(s.size() >= 5);
        CHECK_EQ(s.size(), 10u);
        bool inc = true;
        for (size_t i = 1; i < s.size(); ++i) inc = inc && num(s[i], "n") > num(s[i - 1], "n");
        CHECK(inc);
        if (!s.empty()) {
            CHECK_EQ(num(s.back(), "n"), 4096.0);
            CHECK_EQ(num(s.front(), "n"), 8.0);
            CHECK(num(s.back(), "ms") >= 0);
            CHECK(num(s.back(), "reps") >= 1 && num(s.back(), "reps") <= 50);
        }
        CHECK(!r.empty() && has(r.back(), "\"alloc\":{") && num(r.back(), "n") == 4096.0);
        CHECK(!r.empty() && r[0] == "{\"status\":\"start\",\"n\":8,\"seed\":7}");
        CHECK(!r.empty() && num(r.back(), "count") == 0);
        for (auto& l : r) CHECK(!has(l, "capped"));
    }

    // Allocation line counts only the solution's memory.
    {
        auto r = run("bench", "size nums\nparam nums len 1 4096\n", bench_flags, fn(&Solution::dup, {"nums"}));
        CHECK(!r.empty() && has(r.back(), "\"alloc\":{"));
        if (!r.empty()) {
            CHECK(num(r.back(), "count") >= 1);
            CHECK(num(r.back(), "bytes") >= 4 * 4096);
            CHECK(num(r.back(), "peak") >= 4 * 4096);
            CHECK(num(r.back(), "peak") < 2 * 4 * 4096);
        }
    }

    // Quadratic with a small cap stops with a capped line.
    {
        auto t0 = std::chrono::steady_clock::now();
        auto r = run("bench", "size nums\nparam nums len 1 100000\n", {"--seed", "1", "--max-ms", "5"},
                     fn(&Solution::pairs, {"nums"}));
        double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
        bool capped = false;
        for (auto& l : r) capped = capped || has(l, "\"capped\":true");
        CHECK(capped);
        CHECK(secs < 10);
        CHECK(!r.empty() && has(r.back(), "\"alloc\":{"));
    }

    // Scalar size with maxN <= 64: up to 10 evenly spaced sizes from maxN/10 to maxN.
    {
        auto r = run("bench", "size n\nparam n val 1 45\n", bench_flags, fn(&Solution::climb, {"n"}));
        auto s = size_lines(r);
        CHECK_EQ(s.size(), 10u);
        if (s.size() == 10) {
            CHECK_EQ(num(s.front(), "n"), 4.0);
            CHECK_EQ(num(s.back(), "n"), 45.0);
        }
    }

    // Exponential: the next size is predicted over the cap and skipped.
    {
        auto t0 = std::chrono::steady_clock::now();
        auto r = run("bench", "size n\nparam n val 1 64\n", {"--seed", "1", "--max-ms", "20"},
                     fn(&Solution::climbSlow, {"n"}));
        double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
        CHECK(secs < 10);
        string cap;
        for (auto& l : r) if (has(l, "\"capped\":true")) cap = l;
        CHECK(has(cap, "\"predicted\":true") || num(cap, "ms") > 20);
        CHECK(num(cap, "n") < 64);
    }

    // Prediction from the last two sizes: 1 ms, 8 ms -> 64 ms at 2048 > 2 x 20, so 2048 is never started.
    {
        auto r = run("bench", "size nums\nparam nums len 1 4096\n", {"--seed", "1", "--max-ms", "20"},
                     fn(&Solution::cubic, {"nums"}));
        string cap;
        bool started = false;
        for (auto& l : r) {
            if (has(l, "\"capped\":true")) cap = l;
            if (has(l, "\"status\":\"start\",\"n\":2048")) started = true;
        }
        CHECK(has(cap, "\"predicted\":true"));
        CHECK_EQ(num(cap, "n"), 2048.0);
        CHECK(num(cap, "ms") > 40 && num(cap, "ms") < 100);
        CHECK(!started);
        CHECK(!r.empty() && has(r.back(), "\"alloc\":{") && num(r.back(), "n") == 1024.0);
    }

    // An exception ends bench with an error line for that size.
    {
        auto r = run("bench", "size nums\nparam nums len 1 4096\n", bench_flags, fn(&Solution::picky, {"nums"}));
        CHECK(!r.empty() && r.back() == "{\"n\":128,\"status\":\"error\",\"error\":\"exception: too big\"}");
    }

    // Design: n = number of calls, per-call time, alloc line.
    {
        auto r = run("bench", "calls 2000\nparam start val 0 10\nparam x val 1 5\n", bench_flags, counter);
        auto s = size_lines(r);
        CHECK(s.size() >= 5);
        if (!s.empty()) {
            CHECK_EQ(num(s.back(), "n"), 2000.0);
            CHECK(num(s.back(), "per_call_us") >= 0);
            CHECK(std::abs(num(s.back(), "per_call_us") * 2000 / 1000 - num(s.back(), "ms")) < 1e-3);
        }
        CHECK(!r.empty() && has(r.back(), "\"alloc\":{") && num(r.back(), "n") == 2000.0);
    }

    // gen: function cases.
    {
        auto r = run("gen", "size nums\nparam nums len 1 4096 val -5 5\n", {"--count", "20", "--max-n", "4", "--seed", "3"},
                     fn(&Solution::sum, {"nums"}));
        fs::path p = tmp_dir / ("bench-" + to_string(run_no) + ".out.txt");
        auto cases = lc::read_cases(p.string());
        CHECK_EQ(cases.size(), 20u);
        bool ok = true;
        for (size_t i = 0; i < cases.size(); ++i) {
            ok = ok && cases[i].n == (int)i + 1 && cases[i].args.size() == 1 && !cases[i].expect;
            if (cases[i].args.size() == 1) {
                auto v = lc::parse<vector<int>>(cases[i].args[0]);
                ok = ok && v.size() >= 1 && v.size() <= 4;
            }
        }
        CHECK(ok);
        // Deterministic for a seed.
        auto again = run("gen", "size nums\nparam nums len 1 4096 val -5 5\n",
                         {"--count", "20", "--max-n", "4", "--seed", "3"}, fn(&Solution::sum, {"nums"}));
        CHECK(r == again);
    }

    // gen: design cases with the class name first.
    {
        auto r = run("gen", "calls 100\nparam start val 0 10\nparam x val 1 5\n",
                     {"--count", "5", "--max-n", "6", "--seed", "1"}, counter);
        fs::path p = tmp_dir / ("bench-" + to_string(run_no) + ".out.txt");
        auto cases = lc::read_cases(p.string());
        CHECK_EQ(cases.size(), 5u);
        bool ok = true;
        for (auto& c : cases) {
            auto ops = lc::parse<vector<string>>(c.ops);
            auto args = lc::split_top_level(c.design_args);
            ok = ok && !ops.empty() && ops[0] == "Counter" && ops.size() == args.size() && ops.size() >= 2 &&
                 ops.size() <= 7 && !c.expect;
        }
        CHECK(ok);
        // The generated cases run in test mode.
        vector<string> targs{"bench.test", "test", p.string(), (tmp_dir / "bench-design-run.txt").string()};
        vector<char*> tv;
        for (auto& a : targs) tv.push_back(a.data());
        tv.push_back(nullptr);
        CHECK_EQ(counter((int)targs.size(), tv.data()), 0);
        int prints = 0;
        for (auto& l : read_lines(tmp_dir / "bench-design-run.txt")) prints += has(l, "\"status\":\"print\"");
        CHECK_EQ(prints, 5);
    }

    // R18: the first half of a design sequence only uses methods with arguments, so pop/top/getMin never
    // see an empty stack in bench or gen.
    {
        auto r = run("bench", "calls 2000\nparam val val -100 100\n", bench_flags, min_stack);
        CHECK(!r.empty() && has(r.back(), "\"alloc\":{") && num(r.back(), "n") == 2000.0);
        run("gen", "calls 100\nparam val val -100 100\n", {"--count", "30", "--max-n", "9", "--seed", "4"}, min_stack);
        auto cases = lc::read_cases(last_out().string());
        CHECK_EQ(cases.size(), 30u);
        bool first_is_push = true;
        for (auto& c : cases) {
            auto ops = lc::parse<vector<string>>(c.ops);
            first_is_push = first_is_push && ops.size() >= 2 && ops[0] == "MinStack" && ops[1] == "push";
        }
        CHECK(first_is_push);
        vector<string> targs{"bench.test", "test", last_out().string(), (tmp_dir / "bench-minstack-run.txt").string()};
        vector<char*> tv;
        for (auto& a : targs) tv.push_back(a.data());
        tv.push_back(nullptr);
        CHECK_EQ(min_stack((int)targs.size(), tv.data()), 0);
        int prints = 0;
        for (auto& l : read_lines(tmp_dir / "bench-minstack-run.txt")) prints += has(l, "\"status\":\"print\"");
        CHECK_EQ(prints, 30);
    }

    // R14: gen --n N --seed S reproduces bench's input at size N and seed S (the last input bench used is
    // the alloc run at the largest size).
    {
        const string spec = "size nums\nparam nums len 1 64 val -9 9\n";
        run("bench", spec, {"--seed", "11", "--max-ms", "2000"}, fn(&Rec::record, {"nums"}));
        string bench_input = recorded;
        run("gen", spec, {"--count", "1", "--n", "64", "--seed", "11"}, fn(&Rec::record, {"nums"}));
        auto cases = lc::read_cases(last_out().string());
        CHECK_EQ(cases.size(), 1u);
        CHECK(!cases.empty() && cases[0].args.size() == 1 && cases[0].args[0] == bench_input);
        CHECK_EQ(lc::parse<vector<int>>(bench_input).size(), 64u);

        const string dspec = "calls 64\nparam s val 0 99\nparam x val 0 99\n";
        auto r = run("bench", dspec, {"--seed", "11", "--max-ms", "2000"}, recorder);
        CHECK(!r.empty() && num(r.back(), "n") == 64.0);
        string ops = lc::show(rec_ops), args = "[";
        for (size_t i = 0; i < rec_args.size(); ++i) args += (i ? "," : "") + rec_args[i];
        args += "]";
        run("gen", dspec, {"--count", "1", "--n", "64", "--seed", "11"}, recorder);
        cases = lc::read_cases(last_out().string());
        CHECK_EQ(cases.size(), 1u);
        CHECK(!cases.empty() && cases[0].ops == ops && cases[0].design_args == args);
        CHECK_EQ(rec_ops.size(), 65u);

        // --n overrides --max-n; gen needs one of them.
        run("gen", spec, {"--count", "3", "--max-n", "2", "--n", "5", "--seed", "1"}, fn(&Rec::record, {"nums"}));
        bool all5 = true;
        for (auto& c : lc::read_cases(last_out().string())) all5 = all5 && lc::parse<vector<int>>(c.args[0]).size() == 5;
        CHECK(all5);
    }

    // gen names the class through DesignName.
    {
        run("gen", "calls 10\nparam x val 1 5\n", {"--count", "2", "--max-n", "3", "--seed", "1"},
            [](int ac, char** av) { return lc::run_design<Stand>(ac, av, {}, {{"add", lc::method(&Stand::add, {"x"})}}); });
        auto cases = lc::read_cases(last_out().string());
        CHECK_EQ(cases.size(), 2u);
        bool named = true;
        for (auto& c : cases) named = named && c.ops.starts_with("[\"RealName\",");
        CHECK(named);
    }

    // R36: a vector<string> size parameter's n is its number of strings (LeetCode's words.length), the
    // unit of its len_max; gen --n N reproduces bench's input at that n (R14).
    {
        const string spec = "size w\nparam w len 1 64 chars ab\n";
        auto r = run("bench", spec, {"--seed", "5", "--max-ms", "2000"}, fn(&Rec::words, {"w"}));
        auto s = size_lines(r);
        CHECK(s.size() >= 3);
        CHECK(strictly_increasing(s));
        if (!s.empty()) CHECK_EQ(num(s.back(), "n"), 64.0);
        CHECK(!r.empty() && has(r.back(), "\"alloc\":{") && num(r.back(), "n") == 64.0);
        string bench_input = recorded;
        CHECK_EQ(lc::parse<vector<string>>(bench_input).size(), 64u);
        run("gen", spec, {"--count", "1", "--n", "64", "--seed", "5"}, fn(&Rec::words, {"w"}));
        auto cases = lc::read_cases(last_out().string());
        CHECK(cases.size() == 1 && cases[0].args.size() == 1 && cases[0].args[0] == bench_input);
    }

    // R16: a 2-D size parameter runs up to len_max x len_max cells, and reports cells.
    {
        auto r = run("bench", "size g\nparam g len 1 64 val 0 9\n", bench_flags, fn(&Rec::gridSum, {"g"}));
        auto s = size_lines(r);
        CHECK(s.size() >= 5);
        CHECK(strictly_increasing(s));
        if (!s.empty()) CHECK_EQ(num(s.back(), "n"), 4096.0);
        CHECK(!r.empty() && has(r.back(), "\"alloc\":{") && num(r.back(), "n") == 4096.0);
    }

    // R19: sizes below the minimum are dropped, and a size that generates no more than the previous one is
    // skipped, so every n is the real input size.
    {
        auto r = run("bench", "size nums\nparam nums len 100 4096\n", bench_flags, fn(&Solution::sum, {"nums"}));
        auto s = size_lines(r);
        CHECK(!s.empty() && num(s.front(), "n") == 128.0);
        r = run("bench", "size nums\nparam nums len 1 4096 val 1 300 distinct\n", bench_flags, fn(&Solution::sum, {"nums"}));
        s = size_lines(r);
        CHECK(strictly_increasing(s));
        CHECK(!s.empty() && num(s.back(), "n") == 300.0);
        int starts = 0;
        for (auto& l : r) starts += has(l, "\"status\":\"start\"");
        CHECK_EQ((size_t)starts, s.size());
    }

    // R17: tree inputs cap reps so generated nodes per size stay within 2,000,000.
    {
        auto r = run("bench", "size root\nparam root len 1 100000\n", bench_flags, fn(&Rec::maxDepth, {"root"}));
        auto s = size_lines(r);
        CHECK(!s.empty() && num(s.back(), "n") == 100000.0 && num(s.back(), "reps") <= 19);
    }

    // Usage errors.
    {
        auto bad = [](vector<string> args) {
            vector<char*> av;
            for (auto& a : args) av.push_back(a.data());
            av.push_back(nullptr);
            return lc::run_function((int)args.size(), av.data(), &Solution::sum, {"nums"});
        };
        CHECK_EQ(bad({"x", "bench", "a", "b"}), 2);
        CHECK_EQ(bad({"x", "bench", "a", "b", "--seed", "1"}), 2);
        CHECK_EQ(bad({"x", "gen", "a", "b", "--count", "1", "--max-n", "x", "--seed", "1"}), 2);
        CHECK_EQ(bad({"x", "gen", "a", "b", "--count", "1", "--seed", "1"}), 2);
        CHECK_EQ(bad({"x", "gen", "a", "b", "--count", "1", "--n", "0", "--seed", "1"}), 2);
        CHECK_EQ(bad({"x", "profile", "a", "b", "--seed", "1"}), 2);
        CHECK_EQ(bad({"x", "profile", "a", "b", "--n", "1", "--seed", "1", "--max-ms", "5"}), 2);
        CHECK_EQ(bad({"x", "bench", (tmp_dir / "missing.spec").string(), "b", "--seed", "1", "--max-ms", "5"}), 2);
    }

    return lc_test_result();
}
