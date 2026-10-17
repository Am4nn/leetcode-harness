// Call counts and recursion depth per function for analyze's profile build. Only the user TU is compiled
// with -finstrument-functions, so only the user's own functions call the hooks below; this header lives in
// the (uninstrumented) harness TU. The hooks exist only under LC_PROFILE.
#ifndef LC_PROF_H
#define LC_PROF_H

namespace lc {

// One instrumented function: its address, calls so far, current and max simultaneous depth of itself.
struct ProfEntry {
    void* fn;
    uint64_t calls;
    uint64_t depth, max_depth;
};

namespace detail {

// Open addressing, fixed size: no allocation inside the hooks (lc-alloc.h counts every operator new).
inline constexpr size_t prof_cap = 1 << 12;
inline ProfEntry prof_table[prof_cap];
inline ProfEntry* prof_last = prof_table;  // the last entry found: recursion hits it every time

// The entry for fn (claimed on first use), or nullptr when the table is full.
__attribute__((no_instrument_function)) inline ProfEntry* prof_slot(void* fn) {
    if (prof_last->fn == fn) return prof_last;
    size_t i = (size_t)(((uintptr_t)fn * 0x9E3779B97F4A7C15ULL) >> 52) & (prof_cap - 1);
    for (size_t k = 0; k < prof_cap; ++k, i = (i + 1) & (prof_cap - 1)) {
        ProfEntry& e = prof_table[i];
        if (!e.fn) e.fn = fn;
        if (e.fn == fn) return prof_last = &e;
    }
    return nullptr;
}

}  // namespace detail

inline void reset_prof() {
    for (ProfEntry& e : detail::prof_table) e = {};
}

// The functions entered since the last reset.
inline std::vector<ProfEntry> prof_entries() {
    std::vector<ProfEntry> v;
    for (const ProfEntry& e : detail::prof_table)
        if (e.fn && e.calls) v.push_back(e);
    return v;
}

}  // namespace lc

#ifdef LC_PROFILE
extern "C" {
__attribute__((no_instrument_function)) void __cyg_profile_func_enter(void* fn, void*) {
    if (lc::ProfEntry* e = lc::detail::prof_slot(fn)) {
        ++e->calls;
        if (++e->depth > e->max_depth) e->max_depth = e->depth;
    }
}
__attribute__((no_instrument_function)) void __cyg_profile_func_exit(void* fn, void*) {
    if (lc::ProfEntry* e = lc::detail::prof_slot(fn))
        if (e->depth) --e->depth;
}
}
#endif

#endif
