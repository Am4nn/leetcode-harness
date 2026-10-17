// Memoized, but off by one whenever n % 7 == 0 (the brute-force check's fixture).
class Solution {
    int memo[46] = {};
    int count(int n) {
        if (n <= 1) return 1;
        if (memo[n]) return memo[n];
        return memo[n] = count(n - 1) + count(n - 2);
    }
public:
    int climbStairs(int n) {
        int ways = count(n);
        if (n % 7 == 0) return ways + 1;
        return ways;
    }
};
