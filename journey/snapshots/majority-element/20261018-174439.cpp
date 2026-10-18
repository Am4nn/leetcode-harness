class Solution {
public:
  int majorityElement(vector<int> &nums) {
    unordered_map<int, int> counter;
    pair<int, int> majorityElement = {-1, -1}; // element, counter

    for (int element : nums) {
      ++counter[element];
      if (majorityElement.second < counter[element]) {
        majorityElement = {element, counter[element]};
      }
    }

    return majorityElement.first;
  }
};
