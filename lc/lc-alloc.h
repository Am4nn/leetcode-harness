// Counts heap allocations by replacing every global operator new/delete (Windows UCRT).
// The replacements are plain (non-inline) definitions, as the standard requires, so include this
// header in exactly one translation unit: the generated wrapper. Relies on lc-prelude.h.
#ifndef LC_ALLOC_H
#define LC_ALLOC_H

#include <malloc.h>

namespace lc {

struct AllocStats {
    uint64_t count, bytes, live, peak;  // allocations, total bytes, bytes in use now, max of live since reset
};

inline AllocStats& alloc_stats() {
    static AllocStats s{};
    return s;
}

inline void reset_alloc_stats() {
    AllocStats& s = alloc_stats();
    s.count = s.bytes = 0;
    s.peak = s.live;
}

namespace detail {

inline void note_alloc(size_t n) {
    AllocStats& s = alloc_stats();
    ++s.count;
    s.bytes += n;
    s.live += n;
    if (s.live > s.peak) s.peak = s.live;
}

inline void note_free(size_t n) {
    AllocStats& s = alloc_stats();
    s.live = n <= s.live ? s.live - n : 0;
}

inline void* alloc_plain(size_t n, bool nothrow) {
    while (true) {
        if (void* p = std::malloc(n ? n : 1)) {
            note_alloc(_msize(p));
            return p;
        }
        std::new_handler h = std::get_new_handler();
        if (!h) {
            if (nothrow) return nullptr;
            throw std::bad_alloc();
        }
        h();
    }
}

inline void* alloc_aligned(size_t n, std::align_val_t al, bool nothrow) {
    size_t a = (size_t)al;
    while (true) {
        if (void* p = _aligned_malloc(n ? n : 1, a)) {
            note_alloc(_aligned_msize(p, a, 0));
            return p;
        }
        std::new_handler h = std::get_new_handler();
        if (!h) {
            if (nothrow) return nullptr;
            throw std::bad_alloc();
        }
        h();
    }
}

inline void free_plain(void* p) noexcept {
    if (!p) return;
    note_free(_msize(p));
    std::free(p);
}

inline void free_aligned(void* p, std::align_val_t al) noexcept {
    if (!p) return;
    note_free(_aligned_msize(p, (size_t)al, 0));
    _aligned_free(p);
}

}  // namespace detail
}  // namespace lc

void* operator new(size_t n) { return lc::detail::alloc_plain(n, false); }
void* operator new[](size_t n) { return lc::detail::alloc_plain(n, false); }
void* operator new(size_t n, const std::nothrow_t&) noexcept {
    try { return lc::detail::alloc_plain(n, true); } catch (...) { return nullptr; }
}
void* operator new[](size_t n, const std::nothrow_t&) noexcept {
    try { return lc::detail::alloc_plain(n, true); } catch (...) { return nullptr; }
}
void* operator new(size_t n, std::align_val_t al) { return lc::detail::alloc_aligned(n, al, false); }
void* operator new[](size_t n, std::align_val_t al) { return lc::detail::alloc_aligned(n, al, false); }
void* operator new(size_t n, std::align_val_t al, const std::nothrow_t&) noexcept {
    try { return lc::detail::alloc_aligned(n, al, true); } catch (...) { return nullptr; }
}
void* operator new[](size_t n, std::align_val_t al, const std::nothrow_t&) noexcept {
    try { return lc::detail::alloc_aligned(n, al, true); } catch (...) { return nullptr; }
}

void operator delete(void* p) noexcept { lc::detail::free_plain(p); }
void operator delete[](void* p) noexcept { lc::detail::free_plain(p); }
void operator delete(void* p, size_t) noexcept { lc::detail::free_plain(p); }
void operator delete[](void* p, size_t) noexcept { lc::detail::free_plain(p); }
void operator delete(void* p, const std::nothrow_t&) noexcept { lc::detail::free_plain(p); }
void operator delete[](void* p, const std::nothrow_t&) noexcept { lc::detail::free_plain(p); }
void operator delete(void* p, std::align_val_t al) noexcept { lc::detail::free_aligned(p, al); }
void operator delete[](void* p, std::align_val_t al) noexcept { lc::detail::free_aligned(p, al); }
void operator delete(void* p, size_t, std::align_val_t al) noexcept { lc::detail::free_aligned(p, al); }
void operator delete[](void* p, size_t, std::align_val_t al) noexcept { lc::detail::free_aligned(p, al); }
void operator delete(void* p, std::align_val_t al, const std::nothrow_t&) noexcept { lc::detail::free_aligned(p, al); }
void operator delete[](void* p, std::align_val_t al, const std::nothrow_t&) noexcept { lc::detail::free_aligned(p, al); }

#endif
