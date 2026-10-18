class Solution {
public:
  void moveZeroes(vector<int> &nums) {
    size_t ptr1 = 0;
    // ptr1 starts from the first occurance of zero
    while (nums[ptr1] != 0) {
      ++ptr1;
    }

    // Always ptr1 < ptr2
    size_t ptr2 = ptr1 + 1;

    while (ptr2 < nums.size()) {
      if (nums[ptr1] == 0 && nums[ptr2] != 0) {
        // swap position
        int temp = nums[ptr1];
        nums[ptr1] = nums[ptr2];
        nums[ptr2] = temp;
        ++ptr1;
      }
      ++ptr2;
    }
  }
};
