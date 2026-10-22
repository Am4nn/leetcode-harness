#include "tests/check.h"
#include "lc-io.h"

// The hash-set answers LeetCode accepts: they only see the lists the judge builds.
static ListNode* intersect_of(ListNode* a, ListNode* b) {
    std::unordered_set<ListNode*> seen;
    for (; a; a = a->next) seen.insert(a);
    for (; b; b = b->next) if (seen.count(b)) return b;
    return nullptr;
}
static ListNode* cycle_start(ListNode* h) {
    std::unordered_set<ListNode*> seen;
    for (; h; h = h->next) if (!seen.insert(h).second) return h;
    return nullptr;
}

int main() {
    using namespace lc;
    // A judge's verdict is compared as the text LeetCode prints, unquoted
    CHECK_EQ(parse<JudgeText>("  Intersected at '8' ").text, "Intersected at '8'");
    CHECK_EQ(show(JudgeText{"No intersection"}), "No intersection");
    CHECK(equal(JudgeText{"no cycle"}, JudgeText{"no cycle"}, false));
    CHECK(!equal(JudgeText{"no cycle"}, JudgeText{"tail connects to node index 0"}, false));

    // #160: listB's node before skipB is joined to listA's node at skipA
    auto inter = [](int v, const char* a, const char* b, int sa, int sb) {
        return judge::intersection(v, parse<ListNode*>(a), parse<ListNode*>(b), sa, sb, intersect_of).text;
    };
    CHECK_EQ(inter(8, "[4,1,8,4,5]", "[5,6,1,8,4,5]", 2, 3), "Intersected at '8'");
    CHECK_EQ(inter(2, "[1,9,1,2,4]", "[3,2,4]", 3, 1), "Intersected at '2'");
    CHECK_EQ(inter(0, "[2,6,4]", "[1,5]", 3, 2), "No intersection");
    CHECK_EQ(inter(1, "[1,2]", "[1,2]", 0, 0), "Intersected at '1'");  // listB is listA itself
    CHECK_EQ(inter(5, "[1,2]", "[3]", 7, 9), "No intersection");      // skips past the ends: nothing to join
    // A node with the right value that isn't the shared one is wrong, as on LeetCode
    auto by_value = [](ListNode* a, ListNode* b) {
        for (; b; b = b->next) if (b->val == 1) return b;  // listB's own 1, before the shared 8,4,5
        (void)a;
        return (ListNode*)nullptr;
    };
    CHECK_EQ(judge::intersection(8, parse<ListNode*>("[4,1,8,4,5]"), parse<ListNode*>("[5,6,1,8,4,5]"), 2, 3, by_value).text,
             "Intersected at '1' (a node outside the shared tail)");
    // The lists are split again after the call
    ListNode* a = parse<ListNode*>("[4,1,8,4,5]");
    ListNode* b = parse<ListNode*>("[5,6,1,8,4,5]");
    (void)judge::intersection(8, a, b, 2, 3, intersect_of);
    CHECK_EQ(show(b), "[5,6,1,8,4,5]");

    // #141 / #142: the tail is linked to the node at pos (-1: no cycle), and unlinked after the call
    auto has = [](const char* l, int pos) {
        return judge::cycle(parse<ListNode*>(l), pos, [](ListNode* h) { return cycle_start(h) != nullptr; });
    };
    CHECK(has("[3,2,0,-4]", 1));
    CHECK(has("[1]", 0));
    CHECK(!has("[1]", -1));
    CHECK(!has("[]", -1));
    CHECK(!has("[1,2]", 5));  // pos past the end: no cycle
    auto entry = [](const char* l, int pos) {
        return judge::cycle_entry(parse<ListNode*>(l), pos, cycle_start).text;
    };
    CHECK_EQ(entry("[3,2,0,-4]", 1), "tail connects to node index 1");
    CHECK_EQ(entry("[1,2]", 0), "tail connects to node index 0");
    CHECK_EQ(entry("[1]", -1), "no cycle");
    CHECK_EQ(entry("[1]", 0), "tail connects to node index 0");
    ListNode* l = parse<ListNode*>("[3,2,0,-4]");
    (void)judge::cycle_entry(l, 1, cycle_start);
    CHECK_EQ(show(l), "[3,2,0,-4]");
    CHECK_EQ(judge::cycle_entry(parse<ListNode*>("[1,2]"), 0, [](ListNode*) { return new ListNode(1); }).text,
             "a node outside the list");
    return lc_test_result();
}
