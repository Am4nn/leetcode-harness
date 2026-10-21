class Solution {
public:
  bool isIsomorphic(string s, string t) {
    if (s.size() != t.size())
      return false;
    int n = s.size();
    unordered_map<char, char> mappings;
    unordered_set<char> visited;

    for (int i = 0; i < n; ++i) {
      auto it = mappings.find(s[i]);

      if (it == mappings.end()) {
        if (visited.find(t[i]) != visited.end()) {
          return false;
        }
        mappings[s[i]] = t[i];
        visited.insert(t[i]);
      } else if (it->second != t[i]) {
        return false;
      }
    }

    return true;
  }
};
