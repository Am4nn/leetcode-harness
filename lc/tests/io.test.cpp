#include "tests/check.h"
#include "lc-io.h"

template <class F> static bool throws_parse(F f) {
    try { f(); } catch (const lc::ParseError&) { return true; }
    return false;
}
#define CHECK_THROWS(expr) CHECK(throws_parse([&] { (void)(expr); }))

int main() {
    using namespace lc;
    CHECK((parse<vector<int>>(" [1, 2,\n 3] ") == vector<int>{1,2,3}));
    CHECK_EQ(show(vector<int>{1,2,3}), "[1,2,3]");
    CHECK_EQ(show(parse<vector<vector<int>>>("[[1,2],[]]")), "[[1,2],[]]");
    CHECK_EQ(parse<string>("\"a,b\\\"c\""), "a,b\"c");
    CHECK_EQ(show(string("a\"b")), "\"a\\\"b\"");
    CHECK_EQ(parse<char>("\"x\""), 'x');   CHECK_EQ(show('x'), "\"x\"");
    CHECK(parse<bool>("true"));             CHECK_EQ(show(false), "false");
    CHECK_EQ(parse<long long>("-9000000000"), -9000000000LL);
    CHECK_EQ(show(2.0), "2.00000");
    CHECK(equal(1.000001, 1.0, false));     CHECK(!equal(1.1, 1.0, false));
    CHECK_EQ(show(parse<TreeNode*>("[3,9,20,null,null,15,7]")), "[3,9,20,null,null,15,7]");
    CHECK_EQ(show(parse<TreeNode*>("[1,null,2]")), "[1,null,2]");
    CHECK(parse<TreeNode*>("[]") == nullptr);   CHECK_EQ(show((TreeNode*)nullptr), "[]");
    CHECK_EQ(show(parse<ListNode*>("[1,2,3]")), "[1,2,3]");
    CHECK(parse<ListNode*>("[]") == nullptr);
    CHECK(equal(vector<int>{1,0}, vector<int>{0,1}, true));
    CHECK(!equal(vector<int>{1,0}, vector<int>{0,1}, false));
    CHECK(equal(vector<vector<int>>{{1,2},{3}}, {{3},{1,2}}, true));
    CHECK(equal(vector<vector<int>>{{2,1},{3}}, {{1,2},{3}}, true));    // inner order ignored too
    CHECK(!equal(vector<vector<int>>{{2,1},{3}}, {{1,2},{3}}, false));
    CHECK(equal(vector<vector<string>>{{"tan","nat"},{"bat"}}, {{"bat"},{"nat","tan"}}, true));
    CHECK_EQ(describe_diff(vector<int>{1,3,2,1,1,3,2}, vector<int>{1,3,2,1,1,3,2,1}),
             "first difference at index 7 (got 7 items, expected 8)");
    CHECK_EQ(describe_diff(vector<int>{1,9}, vector<int>{1,2}), "first difference at index 1");
    CHECK((split_top_level("[[2],[1,1],[]]") == vector<string>{"[2]","[1,1]","[]"}));
    CHECK((split_top_level("[\"a,]\",\"b\"]") == vector<string>{"\"a,]\"","\"b\""}));
    CHECK_THROWS(parse<vector<int>>("[1,2"));
    CHECK_THROWS(parse<int>("abc"));
    CHECK_THROWS(parse<bool>("yes"));

    // extras
    CHECK_EQ(show(parse<vector<double>>("[1.5, 2]")), "[1.50000,2.00000]");
    CHECK(equal(vector<double>{1.0, 2.000001}, vector<double>{1.0, 2.0}, false));
    CHECK_EQ(describe_diff(3, 4), "");
    CHECK_EQ(json_escape("a\"b\\c\n"), "a\\\"b\\\\c\\n");
    CHECK_EQ(show(parse<vector<string>>("[\"a\",\"b c\"]")), "[\"a\",\"b c\"]");
    CHECK_EQ(show(parse<TreeNode*>("[1,2,3,null,4]")), "[1,2,3,null,4]");
    CHECK_EQ(show(parse<TreeNode*>(" [ 1 , null , 2 , null , null ] ")), "[1,null,2]");
    CHECK_EQ(show((ListNode*)nullptr), "[]");
    CHECK_EQ(show(parse<vector<char>>("[\"a\",\"b\"]")), "[\"a\",\"b\"]");
    CHECK_EQ(show(vector<bool>{true,false}), "[true,false]");
    CHECK_THROWS(parse<int>("1 2"));
    CHECK_THROWS(parse<int>("99999999999"));
    CHECK_THROWS(parse<string>("\"abc"));
    CHECK_THROWS(parse<char>("\"xy\""));
    CHECK_THROWS(parse<TreeNode*>("[1,x]"));
    CHECK_THROWS(parse<vector<int>>("[1,,2]"));
    return lc_test_result();
}
