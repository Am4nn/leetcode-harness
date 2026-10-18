class Solution {
public:
  int maxProfit(vector<int> &prices) {
    int profit = 0;

    for (size_t i = 1; i < prices.size(); i++) {
      int priceToday = prices[i], priceYesterday = prices[i - 1];
      profit += max(0, priceToday - priceYesterday);
    }

    return profit;
  }
};
