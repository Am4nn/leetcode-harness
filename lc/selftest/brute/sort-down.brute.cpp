class Solution {
public:
    vector<int> arrange(vector<int>& nums) {
        sort(nums.rbegin(), nums.rend());
        return nums;
    }
};