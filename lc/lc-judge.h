// Judges for LeetCode problems whose inputs describe how to build the test rather than the method's own
// parameters ("manual": true in metaData), such as #160's intersectVal/skipA/skipB or #141's pos.
// Included by lc-io.h (harness TU) and by the generated user TU of such a problem. Relies on lc-prelude.h.
#ifndef LC_JUDGE_H
#define LC_JUDGE_H

namespace lc {

// A judge's verdict, compared and printed as the text LeetCode shows: "Intersected at '8'", "no cycle".
struct JudgeText {
    std::string text;
    bool operator==(const JudgeText&) const = default;
};

namespace judge {

inline ListNode* nth(ListNode* h, long long i) {
    while (h && i-- > 0) h = h->next;
    return h;
}

// #160: listB's node before skipB is joined to listA's node at skipA, so both lists share that tail
// (none when intersectVal is 0 or a skip runs past its list). The lists are split again after the call.
template <class F>
JudgeText intersection(int intersect_val, ListNode* a, ListNode* b, int skip_a, int skip_b, F call) {
    ListNode* meet = intersect_val != 0 && skip_a >= 0 ? nth(a, skip_a) : nullptr;
    ListNode* before = skip_b > 0 ? nth(b, skip_b - 1) : nullptr;
    bool join = meet && (skip_b == 0 || before);
    ListNode* head_b = join && skip_b == 0 ? meet : b;
    ListNode* rest_b = before ? before->next : nullptr;
    if (join && before) before->next = meet;
    ListNode* got = call(a, head_b);
    if (join && before) before->next = rest_b;
    if (!got) return {"No intersection"};
    std::string t = "Intersected at '" + std::to_string(got->val) + "'";
    if (got != meet) t += " (a node outside the shared tail)";
    return {t};
}

// #141 and #142: the tail is linked to the node at pos (no cycle for -1 or a pos past the end) for the
// call, and unlinked after it.
template <class F> auto cycle(ListNode* head, int pos, F call) {
    ListNode* tail = head;
    while (tail && tail->next) tail = tail->next;
    ListNode* to = pos >= 0 ? nth(head, pos) : nullptr;
    if (to) tail->next = to;
    auto got = call(head);
    if (to) tail->next = nullptr;
    return got;
}

// #142: the returned node as LeetCode prints it, by its index in the list.
template <class F> JudgeText cycle_entry(ListNode* head, int pos, F call) {
    ListNode* got = cycle(head, pos, call);
    if (!got) return {"no cycle"};
    long long i = 0;
    for (ListNode* n = head; n; n = n->next, ++i)
        if (n == got) return {"tail connects to node index " + std::to_string(i)};
    return {"a node outside the list"};
}

}  // namespace judge
}  // namespace lc

#endif
