class Solution {
public:
  vector<int> productExceptSelf(vector<int> &nums) {
    size_t numSize = nums.size();
    vector<int> prefixProduct(numSize), suffixProduct(numSize),
        productArray(numSize);

    int runningMultiplication = 1;
    for (int i = 0; i < numSize; ++i) {
      prefixProduct[i] = runningMultiplication;
      runningMultiplication *= nums[i];
    }

    runningMultiplication = 1;
    for (int i = numSize - 1; i >= 0; --i) {
      suffixProduct[i] = runningMultiplication;
      runningMultiplication *= nums[i];
    }

    for (int i = 0; i < numSize; ++i) {
      productArray[i] = prefixProduct[i] * suffixProduct[i];
    }

    return productArray;
  }
};
