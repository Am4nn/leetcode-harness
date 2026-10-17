class Solution {
public:
    void rotate(vector<int>& nums, int k) {
        nums[nums.size()] = k;  // deliberate out-of-range write
    }
};
