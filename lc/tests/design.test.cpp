#include "tests/check.h"
#include "lc.h"

struct Counter {
    int v;
    Counter(int start) : v(start) {}
    void add(int x) { v += x; }
    int get() { return v; }
    int peek(int a, int b) const { return v + a + b; }
    int boom() { throw std::runtime_error("bad"); }
};

struct Empty {
    int one() { return 1; }
};

namespace fs = std::filesystem;
static fs::path tmp_dir;
static int run_no = 0;

static vector<string> run(const string& cases) {
    ++run_no;
    fs::path cp = tmp_dir / ("design-" + to_string(run_no) + ".cases.txt");
    fs::path rp = tmp_dir / ("design-" + to_string(run_no) + ".results.jsonl");
    { ofstream(cp, ios::binary) << cases; }
    vector<string> args{"design.test", "test", cp.string(), rp.string()};
    vector<char*> argv;
    for (auto& a : args) argv.push_back(a.data());
    argv.push_back(nullptr);
    CHECK_EQ((lc::run_design<Counter, int>((int)args.size(), argv.data(), {"start"},
                                           {{"add", lc::method(&Counter::add, {"x"})},
                                            {"get", lc::method(&Counter::get, {})},
                                            {"peek", lc::method(&Counter::peek, {"a", "b"})},
                                            {"boom", lc::method(&Counter::boom, {})}})),
             0);
    vector<string> lines;
    ifstream in(rp, ios::binary);
    for (string l; getline(in, l);) lines.push_back(l);
    return lines;
}

static bool has(const string& line, const string& part) { return line.find(part) != string::npos; }

// Runs one case and returns its completion line.
static string one(const string& body) {
    auto r = run("case 1\n" + body + "end\n");
    CHECK_EQ(r.size(), 2u);
    return r.size() == 2 ? r[1] : "";
}

int main(int, char** argv) {
    tmp_dir = fs::absolute(fs::path(argv[0])).parent_path() / "tmp";
    fs::create_directories(tmp_dir);
    const string ops = "ops [\"Counter\",\"add\",\"get\"]\nargs [[5],[2],[]]\n";

    auto r = run("case 1\n" + ops + "expect [null,null,7]\nend\n");
    CHECK_EQ(r.size(), 2u);
    if (r.size() == 2) {
        CHECK_EQ(r[0], "{\"n\":1,\"status\":\"start\"}");
        CHECK(has(r[1], "\"status\":\"pass\""));
        CHECK(has(r[1], "\"got\":\"[null,null,7]\""));
        CHECK(has(r[1], "\"ms\":"));
    }

    string l = one(ops + "expect [null,null,8]\n");
    CHECK(has(l, "\"status\":\"fail\""));
    CHECK(has(l, "\"diff\":\"call 3 (get): got 7, expected 8\""));
    CHECK(has(l, "\"expected\":\"[null,null,8]\""));

    l = one("ops [\"Counter\",\"mul\"]\nargs [[5],[2]]\n");
    CHECK(has(l, "\"status\":\"error\""));
    CHECK(has(l, "\"error\":\"unknown method mul\""));

    l = one(ops.substr(0, ops.find("args")) + "args [[5],[2]]\n");
    CHECK(has(l, "\"error\":\"ops has 3 entries but args has 2\""));

    l = one(ops);
    CHECK(has(l, "\"status\":\"print\""));
    CHECK(has(l, "\"got\":\"[null,null,7]\""));

    l = one("ops [\"Counter\",\"peek\",\"get\"]\nargs [[1],[2,3],[]]\nexpect [null,6,1]\n");
    CHECK(has(l, "\"status\":\"pass\""));  // const method

    l = one("ops [\"Counter\",\"add\"]\nargs [[5],[]]\n");
    CHECK(has(l, "\"error\":\"call 2 (add): expected 1 argument (x), got 0\""));
    l = one("ops [\"Counter\",\"peek\"]\nargs [[5],[1]]\n");
    CHECK(has(l, "\"error\":\"call 2 (peek): expected 2 arguments (a, b), got 1\""));
    l = one("ops [\"Counter\",\"add\"]\nargs [[],[1]]\n");
    CHECK(has(l, "\"error\":\"call 1 (Counter): expected 1 argument (start), got 0\""));
    l = one("ops [\"Counter\",\"add\"]\nargs [[5],[\"x\"]]\n");
    CHECK(has(l, "call 2 (add): can't read x"));
    l = one("ops [\"Counter\",\"boom\"]\nargs [[5],[]]\n");
    CHECK(has(l, "\"error\":\"exception: bad\""));
    l = one(ops + "expect [null,null]\n");
    CHECK(has(l, "\"error\":\"expect has 2 entries but ops has 3\""));

    // Several cases in one file; an error in one doesn't stop the next.
    r = run("case 1\nops [\"Counter\",\"mul\"]\nargs [[5],[2]]\nend\ncase 2\n" + ops + "end\n");
    CHECK_EQ(r.size(), 4u);

    // Empty class (GCC -Warray-bounds false positive guard): must compile warning-free.
    auto m = lc::method(&Empty::one, {});
    Empty e;
    CHECK_EQ(m.call(e, {}), "1");
    return lc_test_result();
}
