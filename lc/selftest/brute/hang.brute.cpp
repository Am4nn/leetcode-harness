// Brute-check fixture: never returns on n == 5.
class Solution {
public:
    int climbStairs(int n) {
        volatile int spin = 0;
        if (n == 5) while (true) spin = spin + 1;
        int a = 1, b = 1;
        for (int i = 2; i <= n; i++) { int c = a + b; a = b; b = c; }
        return b;
    }
};