#include "tests/check.h"
#include "lc.h"

struct Solution {
    vector<int> getConcatenation(vector<int>& nums) { auto r = nums; r.insert(r.end(), nums.begin(), nums.end()); return r; }
    void rotate(vector<int>& nums, int k) { k %= nums.size(); std::rotate(nums.begin(), nums.end() - k, nums.end()); }
    int boom(int) { throw std::runtime_error("bad"); }
    int byValue(string s) const { return s.size(); }
};

namespace fs = std::filesystem;
static fs::path tmp_dir;
static int run_no = 0;

static int run_raw(vector<string> args) {
    vector<char*> argv;
    for (auto& a : args) argv.push_back(a.data());
    argv.push_back(nullptr);
    vector<string> names{"nums", "k"};
    return lc::run_function((int)args.size(), argv.data(), &Solution::rotate, names);
}

// Writes `cases` to a temp cases file, runs `m` in test mode, returns the results lines.
template <class M>
static vector<string> run(M m, vector<string> names, const string& cases, bool any_order = false) {
    ++run_no;
    fs::path cp = tmp_dir / ("run-" + to_string(run_no) + ".cases.txt");
    fs::path rp = tmp_dir / ("run-" + to_string(run_no) + ".results.jsonl");
    { ofstream(cp, ios::binary) << cases; }
    vector<string> args{"run.test", "test", cp.string(), rp.string()};
    if (any_order) args.push_back("--any-order");
    vector<char*> argv;
    for (auto& a : args) argv.push_back(a.data());
    argv.push_back(nullptr);
    CHECK_EQ(lc::run_function((int)args.size(), argv.data(), m, names), 0);
    vector<string> lines;
    ifstream in(rp, ios::binary);
    for (string l; getline(in, l);) lines.push_back(l);
    return lines;
}

static bool has(const string& line, const string& part) { return line.find(part) != string::npos; }

int main(int, char** argv) {
    tmp_dir = fs::absolute(fs::path(argv[0])).parent_path() / "tmp";
    fs::create_directories(tmp_dir);
    vector<string> nk{"nums", "k"};

    auto r = run(&Solution::getConcatenation, {"nums"}, "case 1\narg [1,2,1]\nexpect [1,2,1,1,2,1]\nend\n");
    CHECK_EQ(r.size(), 2u);
    if (r.size() == 2) {
        CHECK_EQ(r[0], "{\"n\":1,\"status\":\"start\"}");
        CHECK(has(r[1], "\"status\":\"pass\""));
        CHECK(has(r[1], "\"ms\":"));
        CHECK(has(r[1], "\"got\":\"[1,2,1,1,2,1]\""));
    }

    r = run(&Solution::getConcatenation, {"nums"}, "case 1\narg [1,2,1]\nexpect [1,2,1,1,2]\nend\n");
    CHECK_EQ(r.size(), 2u);
    if (r.size() == 2) {
        CHECK(has(r[1], "\"status\":\"fail\""));
        CHECK(has(r[1], "\"got\":\"[1,2,1,1,2,1]\""));
        CHECK(has(r[1], "\"expected\":\"[1,2,1,1,2]\""));
        CHECK(has(r[1], "\"diff\":\"first difference at index 5 (got 6 items, expected 5)\""));
    }

    r = run(&Solution::getConcatenation, {"nums"}, "case 1\narg [1,2,1]\nend\n");
    CHECK_EQ(r.size(), 2u);
    if (r.size() == 2) {
        CHECK(has(r[1], "\"status\":\"print\""));
        CHECK(has(r[1], "\"got\":\"[1,2,1,1,2,1]\""));
        CHECK(!has(r[1], "\"expected\""));
    }

    // void + in-place out parameter; several cases in one file, CRLF line endings
    r = run(&Solution::rotate, nk,
            "case 1\r\narg [1,2,3,4,5,6,7]\r\narg 3\r\nexpect [5,6,7,1,2,3,4]\r\nend\r\n"
            "case 2\r\narg [1,2,3,4,5,6,7]\r\nend\r\n"
            "case 3\r\narg [1,2,3,4,5,6,7]\r\narg 3\r\nend\r\n");
    CHECK_EQ(r.size(), 6u);
    if (r.size() == 6) {
        CHECK(has(r[1], "\"n\":1,\"status\":\"pass\""));
        CHECK(has(r[1], "\"got\":\"[5,6,7,1,2,3,4]\""));
        CHECK_EQ(r[2], "{\"n\":2,\"status\":\"start\"}");
        CHECK(has(r[3], "\"status\":\"error\""));
        CHECK(has(r[3], "\"error\":\"expected 2 arguments (nums, k), got 1\""));
        CHECK(has(r[5], "\"n\":3,\"status\":\"print\""));
        CHECK(has(r[5], "\"got\":\"[5,6,7,1,2,3,4]\""));
    }

    r = run(&Solution::rotate, nk, "case 1\narg [1,2\narg 3\nend\n");
    CHECK_EQ(r.size(), 2u);
    if (r.size() == 2) {
        CHECK(has(r[1], "\"status\":\"error\""));
        CHECK(has(r[1], "\"error\":\"can't read nums:"));
    }

    r = run(&Solution::boom, {"x"}, "case 1\narg 1\nend\n");
    CHECK_EQ(r.size(), 2u);
    if (r.size() == 2) {
        CHECK(has(r[1], "\"status\":\"error\""));
        CHECK(has(r[1], "\"error\":\"exception: bad\""));
    }

    r = run(&Solution::byValue, {"s"}, "case 1\narg \"abc\"\nexpect 3\nend\n");
    CHECK_EQ(r.size(), 2u);
    if (r.size() == 2) CHECK(has(r[1], "\"status\":\"pass\""));

    const string any = "case 1\narg [1,2]\nexpect [2,1,1,2]\nend\n";
    r = run(&Solution::getConcatenation, {"nums"}, any, true);
    CHECK(r.size() == 2 && has(r[1], "\"status\":\"pass\""));
    r = run(&Solution::getConcatenation, {"nums"}, any, false);
    CHECK(r.size() == 2 && has(r[1], "\"status\":\"fail\""));

    // usage and file errors
    string cp = (tmp_dir / "run-1.cases.txt").string(), rp = (tmp_dir / "run-x.results.jsonl").string();
    CHECK_EQ(run_raw({"x"}), 2);
    CHECK_EQ(run_raw({"x", "test", cp}), 2);
    CHECK_EQ(run_raw({"x", "nope", cp, rp}), 2);
    CHECK_EQ(run_raw({"x", "bench", cp, rp}), 2);
    CHECK_EQ(run_raw({"x", "test", (tmp_dir / "missing.txt").string(), rp}), 2);
    return lc_test_result();
}
