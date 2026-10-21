class Solution {
public:
  bool containsNearbyDuplicate(vector<int> &nums, int k) {
    unordered_map<int, vector<int>> kv;

    for (int i = 0; i < nums.size(); ++i) {
      kv[nums[i]].push_back(i);
    }

    for (auto pair : kv) {
      if (pair.second.size() <= 1) {
        continue;
      }

      for (int i = 1; i < pair.second.size(); ++i) {
        if (pair.second[i] - pair.second[i - 1] <= k) {
          return true;
        }
      }
    }
    return false;
  }
};
