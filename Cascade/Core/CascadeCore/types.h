#pragma once
#include <cstdint>
#include <cstring>
#include <cmath>
#include <algorithm>
#include <cassert>

using u8  = uint8_t;
using u16 = uint16_t;
using u32 = uint32_t;
using u64 = uint64_t;
using i8  = int8_t;
using i16 = int16_t;
using i32 = int32_t;
using i64 = int64_t;
using f32 = float;
using f64 = double;

struct u128 {
    u64 lo = 0, hi = 0;
    u128() = default;
    u128(u64 lo, u64 hi) : lo(lo), hi(hi) {}
    explicit u128(u64 v) : lo(v), hi(0) {}
    u32 lo32() const { return (u32)(lo & 0xFFFF'FFFFu); }
    u64 lo64() const { return lo; }
    u128 operator+(const u128& o) const {
        u64 nl = lo + o.lo;
        u64 nh = hi + o.hi + (nl < lo ? 1u : 0u);
        return {nl, nh};
    }
    u128 operator-(const u128& o) const {
        u64 nl = lo - o.lo;
        u64 nh = hi - o.hi - (nl > lo ? 1u : 0u);
        return {nl, nh};
    }
    u128 operator&(const u128& o) const { return {lo & o.lo, hi & o.hi}; }
    u128 operator|(const u128& o) const { return {lo | o.lo, hi | o.hi}; }
    u128 operator^(const u128& o) const { return {lo ^ o.lo, hi ^ o.hi}; }
    u128 operator~() const { return {~lo, ~hi}; }
    bool operator==(const u128& o) const { return lo == o.lo && hi == o.hi; }
    bool operator!=(const u128& o) const { return !(*this == o); }
};

struct vec4f {
    f32 x = 0.f, y = 0.f, z = 0.f, w = 0.f;
    vec4f() = default;
    vec4f(f32 x, f32 y, f32 z, f32 w) : x(x), y(y), z(z), w(w) {}
    explicit vec4f(f32 s) : x(s), y(s), z(s), w(s) {}

    vec4f operator+(const vec4f& o) const { return {x+o.x, y+o.y, z+o.z, w+o.w}; }
    vec4f operator-(const vec4f& o) const { return {x-o.x, y-o.y, z-o.z, w-o.w}; }
    vec4f operator*(const vec4f& o) const { return {x*o.x, y*o.y, z*o.z, w*o.w}; }
    vec4f operator*(f32 s) const { return {x*s, y*s, z*s, w*s}; }
    vec4f operator+(f32 s) const { return {x+s, y+s, z+s, w+s}; }
    vec4f operator-(f32 s) const { return {x-s, y-s, z-s, w-s}; }
    vec4f& operator+=(const vec4f& o) { x+=o.x; y+=o.y; z+=o.z; w+=o.w; return *this; }
    vec4f& operator-=(const vec4f& o) { x-=o.x; y-=o.y; z-=o.z; w-=o.w; return *this; }
    vec4f& operator*=(const vec4f& o) { x*=o.x; y*=o.y; z*=o.z; w*=o.w; return *this; }

    f32& operator[](int i) { return (&x)[i]; }
    f32  operator[](int i) const { return (&x)[i]; }

    vec4f vmax(const vec4f& o) const {
        return {std::max(x,o.x), std::max(y,o.y), std::max(z,o.z), std::max(w,o.w)};
    }
    vec4f vmin(const vec4f& o) const {
        return {std::min(x,o.x), std::min(y,o.y), std::min(z,o.z), std::min(w,o.w)};
    }
    vec4f vabs() const { return {std::abs(x), std::abs(y), std::abs(z), std::abs(w)}; }

    static vec4f zero() { return {0,0,0,0}; }
    static vec4f identity_w() { return {0,0,0,1}; }
};

static inline f32 clamp01(f32 v) { return v < 0.f ? 0.f : v > 1.f ? 1.f : v; }
static inline f32 clampf(f32 v, f32 lo, f32 hi) { return v < lo ? lo : v > hi ? hi : v; }
static inline i32 clampi(i32 v, i32 lo, i32 hi) { return v < lo ? lo : v > hi ? hi : v; }

static inline u32 sign_extend16(u16 v) { return (u32)(i32)(i16)v; }
static inline u64 sign_extend32(u32 v) { return (u64)(i64)(i32)v; }
static inline u32 sign_extend8(u8 v)   { return (u32)(i32)(i8)v; }
static inline u64 sign_extend16_64(u16 v) { return (u64)(i64)(i16)v; }

template<typename T>
static inline T read_le(const u8* p) {
    T v;
    memcpy(&v, p, sizeof(T));
    return v;
}

template<typename T>
static inline void write_le(u8* p, T v) {
    memcpy(p, &v, sizeof(T));
}

static inline u32 rotr32(u32 v, int s) { return (v >> s) | (v << (32 - s)); }
static inline u64 rotr64(u64 v, int s) { return (v >> s) | (v << (64 - s)); }

static inline int count_leading_zeros(u32 v) {
    if (v == 0) return 32;
#if defined(__clang__) || defined(__GNUC__)
    return __builtin_clz(v);
#else
    int n = 0;
    if (!(v & 0xFFFF0000u)) { n += 16; v <<= 16; }
    if (!(v & 0xFF000000u)) { n +=  8; v <<=  8; }
    if (!(v & 0xF0000000u)) { n +=  4; v <<=  4; }
    if (!(v & 0xC0000000u)) { n +=  2; v <<=  2; }
    if (!(v & 0x80000000u)) { n +=  1; }
    return n;
#endif
}
