#include "tests/check.h"
int main() {
    TreeNode t(1, new TreeNode(2), nullptr);
    CHECK_EQ(t.left->val, 2);
    ListNode l(3); CHECK(l.next == nullptr);
    vector<int> v{1}; CHECK_EQ(v.size(), 1u);   // using namespace std works
    return lc_test_result();
}
