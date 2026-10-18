class Solution {
public:
    // nums.length == 2n, so this walks nums itself: O(n) in the length bench grows.
    vector<int> shuffle(vector<int>& nums, int n) {
        size_t half = nums.size() / 2;
        vector<int> ans;
        ans.reserve(nums.size());
        for (size_t i = 0; i < half; ++i) {
            ans.push_back(nums[i]);
            ans.push_back(nums[half + i]);
        }
        (void)n;
        return ans;
    }
};
