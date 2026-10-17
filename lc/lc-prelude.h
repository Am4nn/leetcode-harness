// Force-included before LeetCode-style files (no #include, no main) so they compile as-is.
#ifndef LC_PRELUDE_H
#define LC_PRELUDE_H

#include <bits/stdc++.h>
using namespace std;

// LeetCode's exact definitions; their constructor parameters shadow members, so silence -Wshadow here only.
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wshadow"
struct TreeNode {
    int val;
    TreeNode *left;
    TreeNode *right;
    TreeNode() : val(0), left(nullptr), right(nullptr) {}
    TreeNode(int x) : val(x), left(nullptr), right(nullptr) {}
    TreeNode(int x, TreeNode *left, TreeNode *right) : val(x), left(left), right(right) {}
};

struct ListNode {
    int val;
    ListNode *next;
    ListNode() : val(0), next(nullptr) {}
    ListNode(int x) : val(x), next(nullptr) {}
    ListNode(int x, ListNode *next) : val(x), next(next) {}
};
#pragma GCC diagnostic pop

#endif
