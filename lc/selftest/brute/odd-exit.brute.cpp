// Brute-check fixture: answers every case, then exits with code 3 (no case to blame).
static const int lc_fixture_exit = (atexit([] { _Exit(3); }), 0);
class Solution {
public:
    int climbStairs(int n) { return n <= 1 ? 1 : climbStairs(n - 1) + climbStairs(n - 2); }
};