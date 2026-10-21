class NumArray {
  vector<int> prefixSum;

public:
  NumArray(vector<int> &nums) {
    long long int runningSum = 0;
    for (int i : nums) {
      runningSum += i;
      prefixSum.push_back(runningSum);
    }
  }

  int sumRange(int left, int right) {
    if (left == 0)
      return prefixSum[right];
    return prefixSum[right] - prefixSum[left - 1];
  }
};

/**
 * Your NumArray object will be instantiated and called as such:
 * NumArray* obj = new NumArray(nums);
 * int param_1 = obj->sumRange(left,right);
 */
