#include "tests/check.h"
#include "lc-io.h"
#include "lc-alloc.h"
#include "lc-gen.h"

namespace fs = std::filesystem;

static lc::ParamSpec ps_len_val(long long lmin, long long lmax, long long vmin, long long vmax) {
    lc::ParamSpec p;
    p.len_min = lmin; p.len_max = lmax; p.val_min = vmin; p.val_max = vmax;
    return p;
}

static int count_nodes(const TreeNode* t) { return t ? 1 + count_nodes(t->left) + count_nodes(t->right) : 0; }

template <class V> static bool all_distinct(const V& v) {
    auto s = v;
    std::sort(s.begin(), s.end());
    return std::adjacent_find(s.begin(), s.end()) == s.end();
}

int main(int, char** argv) {
    using namespace lc;
    std::mt19937_64 rng(42);

    // Length and value ranges.
    {
        ParamSpec p = ps_len_val(1, 5, -3, 3);
        bool ok = true;
        for (int i = 0; i < 100; ++i) {
            auto v = generate<vector<int>>(p, 1 + i % 10, rng);
            if (v.size() < 1 || v.size() > 5) ok = false;
            for (int x : v) if (x < -3 || x > 3) ok = false;
        }
        CHECK(ok);
        CHECK_EQ(generate<vector<int>>(p, 3, rng).size(), 3u);
    }

    // Strings use the given alphabet.
    {
        ParamSpec p;
        p.chars = "ab";
        string s = generate<string>(p, 200, rng);
        CHECK_EQ(s.size(), 200u);
        CHECK(s.find_first_not_of("ab") == string::npos);
        string d = generate<string>(ParamSpec{}, 300, rng);
        CHECK(d.find_first_not_of("abcdefghijklmnopqrstuvwxyz") == string::npos);
    }

    // Trees and lists have exactly n nodes.
    {
        TreeNode* t = generate<TreeNode*>(ParamSpec{}, 50, rng);
        CHECK_EQ(count_nodes(t), 50);
        ListNode* l = generate<ListNode*>(ParamSpec{}, 7, rng);
        int c = 0;
        bool in_range = true;
        for (ListNode* x = l; x; x = x->next, ++c) if (x->val < -10000 || x->val > 10000) in_range = false;
        CHECK_EQ(c, 7);
        CHECK(in_range);
    }

    // Same seed, same output.
    {
        std::mt19937_64 a(7), b(7);
        CHECK_EQ(show(generate<TreeNode*>(ParamSpec{}, 30, a)), show(generate<TreeNode*>(ParamSpec{}, 30, b)));
        CHECK_EQ(show(generate<vector<int>>(ParamSpec{}, 30, a)), show(generate<vector<int>>(ParamSpec{}, 30, b)));
        std::mt19937_64 c(8);
        CHECK(show(generate<vector<int>>(ParamSpec{}, 30, a)) != show(generate<vector<int>>(ParamSpec{}, 30, c)));
    }

    // Defaults when a range is missing.
    {
        bool ok = true, wide_int = false, wide_ll = false;
        for (int i = 0; i < 200; ++i) {
            int x = generate<int>(ParamSpec{}, 1, rng);
            long long y = generate<long long>(ParamSpec{}, 1, rng);
            double z = generate<double>(ParamSpec{}, 1, rng);
            if (x < -1000000000 || x > 1000000000) ok = false;
            if (y < -1000000000000000000LL || y > 1000000000000000000LL) ok = false;
            if (z < -1e4 || z > 1e4) ok = false;
            if (std::abs(x) > 1000000) wide_int = true;
            if (std::abs(y) > 1000000000000LL) wide_ll = true;
        }
        CHECK(ok);
        CHECK(wide_int);
        CHECK(wide_ll);
        ParamSpec p = ps_len_val(1, 1, 5, 5);
        CHECK_EQ(generate<int>(p, 1, rng), 5);
    }

    // 2-D vectors: ceil(sqrt(n)) rows of that many columns.
    {
        auto g = generate<vector<vector<int>>>(ParamSpec{}, 10, rng);
        CHECK_EQ(g.size(), 4u);
        bool ok = true;
        for (auto& r : g) if (r.size() != 4) ok = false;
        CHECK(ok);
        CHECK_EQ(generate<vector<vector<int>>>(ParamSpec{}, 16, rng).size(), 4u);
        // R36: a vector of strings has n strings (its size is its length), each 16 characters.
        auto w = generate<vector<string>>(ParamSpec{}, 9, rng);
        CHECK_EQ(w.size(), 9u);
        CHECK(!w.empty() && w[0].size() == 16u);
        CHECK_EQ(generate<vector<vector<char>>>(ParamSpec{}, 25, rng).at(4).size(), 5u);
        CHECK_EQ(generate<vector<ListNode*>>(ParamSpec{}, 4, rng).size(), 2u);
        CHECK_EQ(generate<vector<bool>>(ParamSpec{}, 6, rng).size(), 6u);
        CHECK_EQ(generate<vector<double>>(ParamSpec{}, 6, rng).size(), 6u);
        char c = generate<char>(ParamSpec{}, 1, rng);
        CHECK(c >= 'a' && c <= 'z');
    }

    // sorted: non-decreasing (small range forces repeats).
    {
        ParamSpec p = ps_len_val(1, 100, 0, 5);
        p.sorted = true;
        auto v = generate<vector<int>>(p, 100, rng);
        CHECK_EQ(v.size(), 100u);
        CHECK(std::is_sorted(v.begin(), v.end()));
        CHECK(!all_distinct(v));
        ParamSpec s;
        s.sorted = true;
        string str = generate<string>(s, 50, rng);
        CHECK(std::is_sorted(str.begin(), str.end()));
    }

    // distinct: no repeated values.
    {
        ParamSpec p = ps_len_val(1, 1000, 0, 1500);
        p.distinct = true;
        auto v = generate<vector<int>>(p, 1000, rng);
        CHECK_EQ(v.size(), 1000u);
        CHECK(all_distinct(v));
        CHECK(!std::is_sorted(v.begin(), v.end()));
        bool in_range = true;
        for (int x : v) if (x < 0 || x > 1500) in_range = false;
        CHECK(in_range);
        ParamSpec wide;
        wide.distinct = true;
        CHECK(all_distinct(generate<vector<long long>>(wide, 5000, rng)));
    }

    // sorted + distinct: strictly increasing.
    {
        ParamSpec p = ps_len_val(1, 100, -50, 60);
        p.sorted = p.distinct = true;
        auto v = generate<vector<int>>(p, 100, rng);
        CHECK_EQ(v.size(), 100u);
        CHECK(std::adjacent_find(v.begin(), v.end(), std::greater_equal<int>()) == v.end());
    }

    // distinct with a value range smaller than the length: length clamps to the range size.
    {
        ParamSpec p = ps_len_val(1, 100, 1, 5);
        p.distinct = true;
        auto v = generate<vector<int>>(p, 10, rng);
        CHECK_EQ(v.size(), 5u);
        CHECK(all_distinct(v));
        ParamSpec c;
        c.chars = "abc";
        c.distinct = true;
        string s = generate<string>(c, 10, rng);
        CHECK_EQ(s.size(), 3u);
        CHECK(all_distinct(s));
        ParamSpec d;
        d.distinct = d.sorted = true;
        CHECK_EQ(generate<string>(d, 100, rng), "abcdefghijklmnopqrstuvwxyz");
    }

    // Arguments: a scalar size parameter is n; eqlen scalars take the named parameter's length.
    {
        Spec spec;
        spec.size = "n";
        spec.params["n"] = ps_len_val(1, 1, 1, 45);
        auto [n] = generate_args<int>(spec, {"n"}, 30, rng);
        CHECK_EQ(n, 30);
        Spec s2;
        s2.size = "nums";
        s2.params["nums"] = ps_len_val(1, 100, 1, 3);
        s2.params["nums"].distinct = true;
        s2.params["k"].eqlen = "nums";
        auto [k, nums] = generate_args<int, vector<int>>(s2, {"k", "nums"}, 50, rng);
        CHECK_EQ(nums.size(), 3u);
        CHECK_EQ(k, 3);
        // Non-scalar types must compile through the size-scalar branch too.
        Spec s3;
        s3.size = "s";
        auto [s, d] = generate_args<string, double>(s3, {"s", "d"}, 7, rng);
        CHECK_EQ(s.size(), 7u);
        CHECK(d >= -10000 && d <= 10000);
    }

    // read_spec on the formats.md sample.
    {
        fs::path dir = fs::absolute(fs::path(argv[0])).parent_path() / "tmp";
        fs::create_directories(dir);
        fs::path sp = dir / "gen.spec.txt";
        {
            std::ofstream(sp, std::ios::binary) << "size nums\r\n"
                                                   "param nums len 1 100000 val -2147483648 2147483647\r\n"
                                                   "param k val 0 100000\n"
                                                   "param s chars abcdefghijklmnopqrstuvwxyz\n"
                                                   "param n eqlen nums\n"
                                                   "\n"
                                                   "param arr len 1 10000 val -10000 10000 sorted distinct\n"
                                                   "calls 200000\n";
        }
        Spec s = read_spec(sp.string());
        CHECK_EQ(s.size, "nums");
        CHECK(s.params["nums"].len_max == 100000LL);
        CHECK(s.params["nums"].val_min == -2147483648LL);
        CHECK(s.params["k"].val_max == 100000LL);
        CHECK(!s.params["k"].len_min);
        CHECK_EQ(s.params["s"].chars, "abcdefghijklmnopqrstuvwxyz");
        CHECK_EQ(s.params["n"].eqlen, "nums");
        CHECK(s.params["arr"].sorted && s.params["arr"].distinct);
        CHECK(!s.params["nums"].sorted && !s.params["nums"].distinct);
        CHECK(s.calls == 200000LL);

        { std::ofstream(sp, std::ios::binary) << "size nums\nbogus 1\n"; }
        bool threw = false;
        try { read_spec(sp.string()); } catch (const std::runtime_error&) { threw = true; }
        CHECK(threw);
        threw = false;
        try { read_spec((dir / "missing.spec.txt").string()); } catch (const std::runtime_error&) { threw = true; }
        CHECK(threw);
    }

    // Allocation counter.
    {
        reset_alloc_stats();
        AllocStats before = alloc_stats();
        CHECK_EQ(before.count, 0u);
        int* volatile p = new int(5);
        AllocStats mid = alloc_stats();
        CHECK(mid.count >= before.count + 1);
        CHECK(mid.bytes >= before.bytes + sizeof(int));
        CHECK(mid.live > before.live);
        CHECK(mid.peak >= mid.live);
        delete p;
        CHECK_EQ(alloc_stats().live, before.live);
        CHECK(alloc_stats().peak >= mid.live);
        struct alignas(64) Big { char c[64]; };
        Big* volatile b = new Big[3];
        CHECK(reinterpret_cast<uintptr_t>(b) % 64 == 0);
        CHECK(alloc_stats().live > before.live);
        delete[] b;
        CHECK_EQ(alloc_stats().live, before.live);
        vector<int> big(1000);
        CHECK(alloc_stats().peak >= before.live + 4000);
    }

    return lc_test_result();
}
