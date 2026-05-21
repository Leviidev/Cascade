#pragma once
#include "types.h"

// Minimal CDVD interface exposed to C++ IOP.
// Full implementation remains in Swift (CDVD.swift) and is bridged at
// link time; this header provides the C++ type declaration only.

struct CDVD {
    u32  readIO (u32 offset) { (void)offset; return 0; }
    void writeIO(u32 offset, u32 value) { (void)offset; (void)value; }
};
