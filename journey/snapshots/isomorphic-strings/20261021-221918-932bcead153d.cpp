class Solution {
public:
  bool isIsomorphic(string s, string t) {
    if (s.size() != t.size())
      return false;
    int n = s.size();
    unordered_map<char, char> mappings;

    for (int i = 0; i < n; ++i) {
      auto it = mappings.find(s[i]);

      if (it == mappings.end()) {
        mappings[s[i]] = t[i];
      } else if (it->second != t[i]) {
        return false;
      }
    }

    return true;
  }
};
