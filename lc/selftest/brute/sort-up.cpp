// Brute-check fixture for any-order: sorts up, while sort-down.brute.cpp sorts down.
class Solution {
public:
    vector<int> arrange(vector<int>& nums) {
        sort(nums.begin(), nums.end());
        return nums;
    }
};