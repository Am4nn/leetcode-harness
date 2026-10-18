class Solution {
public:
  int firstMissingPositive(vector<int> &nums) {
    int size = nums.size();
    int index = 0;
    while (index < size) {
      // either in correct position or is duplicate loop or not in bound -> skip
      if (1 > nums[index] || nums[index] > size || index == nums[index] - 1 ||
          nums[index] == nums[nums[index] - 1]) {
        index++;
      } else {
        swap(nums[index], nums[nums[index] - 1]);
      }
    }

    for (index = 0; index < size; ++index) {
      if (index + 1 != nums[index]) {
        return index + 1;
      }
    }

    return size + 1;
  }
};
