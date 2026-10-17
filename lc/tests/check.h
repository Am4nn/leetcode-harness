// Minimal test macros. Include after the prelude (run-all.ps1 force-includes it).
#pragma once
#include <iostream>

inline int lc_test_failures = 0;

#define CHECK(cond)                                                             \
    do {                                                                        \
        if (!(cond)) {                                                          \
            std::cerr << __FILE__ << ":" << __LINE__ << ": CHECK failed: "      \
                      << #cond << "\n";                                         \
            ++lc_test_failures;                                                 \
        }                                                                       \
    } while (0)

#define CHECK_EQ(a, b)                                                          \
    do {                                                                        \
        auto&& lc_a_ = (a);                                                     \
        auto&& lc_b_ = (b);                                                     \
        if (!(lc_a_ == lc_b_)) {                                                \
            std::cerr << __FILE__ << ":" << __LINE__ << ": CHECK_EQ failed: "   \
                      << #a << " == " << #b << " (" << lc_a_ << " vs "          \
                      << lc_b_ << ")\n";                                        \
            ++lc_test_failures;                                                 \
        }                                                                       \
    } while (0)

inline int lc_test_result() {
    if (lc_test_failures) std::cout << lc_test_failures << " failures\n";
    else std::cout << "all passed\n";
    return lc_test_failures;
}
