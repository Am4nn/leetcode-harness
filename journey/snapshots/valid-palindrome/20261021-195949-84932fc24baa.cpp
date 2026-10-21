class Solution {
public:
  bool isPalindrome(string s) {
    int s_size = 
    int front = 0, rear = s.size() - 1;
    while (front < s.size() && rear >= 0 && front < rear) {
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
