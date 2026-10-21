class Solution {
public:
    bool isSubsequence(string s, string t) {
        size_t s_prt = 0, t_prt = 0, s_size = s.size(), t_size = t.size();

        while (s_prt < s_size && t_prt < t_size) {
            if (s[s_prt] == t[t_prt]) {
                ++s_prt;
                ++t_prt;
            } else {
                ++t_prt;
            }
        }

        return (s_prt == s_size);
    }
};
