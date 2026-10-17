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
        CHECK_EQ(bad({"x", "profile", "a", "b", "--n", "1", "--seed", "1"}), 2);
        CHECK_EQ(bad({"x", "bench", (tmp_dir / "missing.spec").string(), "b", "--seed", "1", "--max-ms", "5"}), 2);
    }

    return lc_test_result();
}
