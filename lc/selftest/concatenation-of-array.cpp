class Solution {
public:
    vector<int> getConcatenation(vector<int>& nums) {
        cout << "debug!" << endl;
        vector<int> ans(nums);
        ans.insert(ans.end(), nums.begin(), nums.end());
        return ans;
    }
};
