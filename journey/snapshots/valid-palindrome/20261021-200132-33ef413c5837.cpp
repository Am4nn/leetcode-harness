class Solution {
public:
  bool isPalindrome(string s) {
    int s_size = s.size();
    int front = 0, rear = s_size - 1;
    while (front < s_size && rear >= 0 && front < rear) {
      if (!isalnum(s[front]))
        ++front;
      if (!isalnum(s[rear]))
        --rear;
      if (s[front] != s[rear])
        return false;
    }
    return true;
  }
};
