class Solution {
public:
  int majorityElement(vector<int> &nums) {
    int count = 0, candidate = 0;

    // 1 on 1 duel with each element
    for (size_t i = 0; i < nums.size(); i++) {
      if (count == 0) {
        candidate = i;
        ++count;
      } else if (nums[candidate] != nums[i]) {
        --count;
      } else {
        ++count;
      }
    }

    // Check if the candidate is in majority
    int candidateCount = 0;
    for (int element : nums) {
      if (nums[candidate] == element)
        ++candidateCount;
    }

    if (candidateCount > floor(nums.size() / 2)) {
      return nums[candidate];
    }

    return -1;
  }
};
