class Solution {
public:
  bool isPalindrome(string s) {
    int s_size = s.size();
    int front = 0, rear = s_size - 1;
    while (front < s_size && rear >= 0 && front < rear) {
      if (!isalnum((unsigned char)s[front])) {
        ++front;
      } else if (!isalnum((unsigned char)s[rear])) {
        --rear;
      } else if (tolower((unsigned char)s[front]) !=
                 tolower((unsigned char)s[rear])) {
        return false;
      } else {
        ++front;
        --rear;
      }
    }
    return true;
  }
};
