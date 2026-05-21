#include "vu.h"
#include <cstdlib>
#include <cstring>
#include <cmath>

VU::VU(int idx) : index(idx) {
    dataSize  = idx == 0 ? VU0_MEM : VU1_MEM;
    microSize = idx == 0 ? VU0_MEM : VU1_MEM;
    dataMem   = (u8*)calloc((size_t)dataSize,  1);
    microMem  = (u8*)calloc((size_t)microSize, 1);
    reset();
}

VU::~VU() {
    free(dataMem);
    free(microMem);
}

void VU::reset() {
    memset(vf, 0, sizeof(vf));
    memset(vi, 0, sizeof(vi));
    vf[0] = vec4f{0,0,0,1};
    acc = {}; q = 0; p = 0; I = 0; r = 0x00411117u;
    microPC = 0; running = false; cycles = 0;
    statusFlag = macFlag = clipFlag = 0;
}

// ── Data memory ───────────────────────────────────────────────────────────────

vec4f VU::readDataQ(u16 qwAddr) const {
    int off = ((int)qwAddr * 16) % dataSize;
    if (off + 16 > dataSize) return {};
    vec4f v;
    for (int i = 0; i < 4; i++) {
        u32 bits = read_le<u32>(dataMem + off + i * 4);
        memcpy(&v[i], &bits, 4);
    }
    return v;
}

void VU::writeDataQ(u16 qwAddr, const vec4f& v) {
    int off = ((int)qwAddr * 16) % dataSize;
    if (off + 16 > dataSize) return;
    for (int i = 0; i < 4; i++) {
        u32 bits; memcpy(&bits, &v[i], 4);
        write_le<u32>(dataMem + off + i * 4, bits);
    }
}

u32 VU::readData32(u32 byteOff) const {
    u32 off = byteOff % (u32)dataSize;
    if (off + 4 > (u32)dataSize) return 0;
    return read_le<u32>(dataMem + off);
}

void VU::writeData32(u32 byteOff, u32 v) {
    u32 off = byteOff % (u32)dataSize;
    if (off + 4 > (u32)dataSize) return;
    write_le<u32>(dataMem + off, v);
}

void VU::writeData128(u32 byteOff, const vec4f& v) {
    int off = (int)(byteOff % (u32)dataSize);
    if (off + 16 > dataSize) return;
    for (int i = 0; i < 4; i++) {
        u32 bits; memcpy(&bits, &v[i], 4);
        write_le<u32>(dataMem + off + i * 4, bits);
    }
}

// ── Micro memory ──────────────────────────────────────────────────────────────

u64 VU::readMicro64(u32 qwIdx) const {
    u32 off = (qwIdx * 8) % (u32)microSize;
    if (off + 8 > (u32)microSize) return 0;
    return read_le<u64>(microMem + off);
}

void VU::writeMicro(u32 byteOff, const u8* src, u32 len) {
    u32 off = byteOff % (u32)microSize;
    u32 avail = (u32)microSize - off;
    u32 n = std::min(len, avail);
    memcpy(microMem + off, src, n);
}

// ── Run microprogram ──────────────────────────────────────────────────────────

void VU::run(int maxCycles) {
    running = true;
    for (int n = 0; n < maxCycles && running; n++) {
        u32 rawPC = microPC;
        // Each microinstruction is a 64-bit pair (upper + lower words)
        u32 off = (rawPC * 8) % (u32)microSize;
        if (off + 8 > (u32)microSize) { running = false; break; }

        u32 lower = read_le<u32>(microMem + off);
        u32 upper = read_le<u32>(microMem + off + 4);

        bool eop  = (upper >> 30) & 1;
        bool ibit = (upper >> 31) & 1;

        microPC++;

        executeUpper(upper & 0x7FFF'FFFFu);
        if (ibit) {
            // Lower 32 bits is an immediate value loaded into I register
            memcpy(&I, &lower, 4);
        } else {
            executeLower(lower);
        }

        cycles++;
        if (eop) { running = false; break; }
    }
}

// ── UPPER instruction set ─────────────────────────────────────────────────────
// [31:30] E/D flags (stripped before here)
// [29:25] ft  [24:20] fs  [19:15] fd
// [14:10] opcode (bits [12:7] of raw upper)
// Actually: bits [12:8] = DEST mask, bits [7:2] = opcode
//
// Standard encoding used by all bc-type instructions:
//   [29:25] = ft (broadcast source)
//   [24:20] = fs
//   [19:15] = fd (destination)
//   [14:11] = DEST mask (XYZW)
//   [1:0]   = BC (broadcast component: 0=x, 1=y, 2=z, 3=w)
//   [7:2]   = opcode

void VU::executeUpper(u32 raw) {
    int ft   = (raw >> 16) & 0x1F;
    int fs   = (raw >> 11) & 0x1F;
    int fd   = (raw >>  6) & 0x1F;
    int dest = (raw >>  2) & 0xF;
    int bc   = raw & 0x3;
    int opc  = (raw >> 2) & 0x3F; // bits [7:2]

    // For the "special" group (0x3C-0x3F), bits [5:0] encode sub-op
    // Effectively: upper bits [12:2] give a 11-bit opcode space
    // Simple mapping: use bits [12:2] → (raw >> 2) & 0x7FF
    // But conventional: opcode = (raw >> 2) & 0x3F

    switch (opc) {
    // ADDbc.xyzw
    case 0x00: case 0x01: case 0x02: case 0x03:
        setVF(fd, applyDest(dest, getVF(fd), getVF(fs) + broadcast(getVF(ft), bc))); break;
    // SUBbc
    case 0x04: case 0x05: case 0x06: case 0x07:
        setVF(fd, applyDest(dest, getVF(fd), getVF(fs) - broadcast(getVF(ft), bc))); break;
    // MADDbc: fd = acc + fs * ft[bc]
    case 0x08: case 0x09: case 0x0A: case 0x0B:
        setVF(fd, applyDest(dest, getVF(fd), acc + getVF(fs) * broadcast(getVF(ft), bc))); break;
    // MSUBbc
    case 0x0C: case 0x0D: case 0x0E: case 0x0F:
        setVF(fd, applyDest(dest, getVF(fd), acc - getVF(fs) * broadcast(getVF(ft), bc))); break;
    // MAXbc
    case 0x10: case 0x11: case 0x12: case 0x13:
        setVF(fd, applyDest(dest, getVF(fd), getVF(fs).vmax(broadcast(getVF(ft), bc)))); break;
    // MINIbc
    case 0x14: case 0x15: case 0x16: case 0x17:
        setVF(fd, applyDest(dest, getVF(fd), getVF(fs).vmin(broadcast(getVF(ft), bc)))); break;
    // MULbc
    case 0x18: case 0x19: case 0x1A: case 0x1B:
        setVF(fd, applyDest(dest, getVF(fd), getVF(fs) * broadcast(getVF(ft), bc))); break;
    case 0x1C: setVF(fd, applyDest(dest, getVF(fd), getVF(fs) * vec4f(q))); break; // MULq
    case 0x1D: setVF(fd, applyDest(dest, getVF(fd), getVF(fs).vmax(vec4f(I)))); break; // MAXi
    case 0x1E: setVF(fd, applyDest(dest, getVF(fd), getVF(fs) * vec4f(I))); break; // MULi
    case 0x1F: setVF(fd, applyDest(dest, getVF(fd), getVF(fs).vmin(vec4f(I)))); break; // MINIi
    case 0x20: setVF(fd, applyDest(dest, getVF(fd), getVF(fs) + vec4f(q))); break; // ADDq
    case 0x21: setVF(fd, applyDest(dest, getVF(fd), acc + getVF(fs) * vec4f(q))); break; // MADDq
    case 0x22: setVF(fd, applyDest(dest, getVF(fd), getVF(fs) + vec4f(I))); break; // ADDi
    case 0x23: setVF(fd, applyDest(dest, getVF(fd), acc + getVF(fs) * vec4f(I))); break; // MADDi
    case 0x24: setVF(fd, applyDest(dest, getVF(fd), getVF(fs) - vec4f(q))); break; // SUBq
    case 0x25: setVF(fd, applyDest(dest, getVF(fd), acc - getVF(fs) * vec4f(q))); break; // MSUBq
    case 0x26: setVF(fd, applyDest(dest, getVF(fd), getVF(fs) - vec4f(I))); break; // SUBi
    case 0x27: setVF(fd, applyDest(dest, getVF(fd), acc - getVF(fs) * vec4f(I))); break; // MSUBi
    case 0x28: setVF(fd, applyDest(dest, getVF(fd), getVF(fs) + getVF(ft))); break; // ADD
    case 0x29: setVF(fd, applyDest(dest, getVF(fd), acc + getVF(fs) * getVF(ft))); break; // MADD
    case 0x2A: setVF(fd, applyDest(dest, getVF(fd), getVF(fs) * getVF(ft))); break; // MUL
    case 0x2B: setVF(fd, applyDest(dest, getVF(fd), getVF(fs).vmax(getVF(ft)))); break; // MAX
    case 0x2C: setVF(fd, applyDest(dest, getVF(fd), getVF(fs) - getVF(ft))); break; // SUB
    case 0x2D: setVF(fd, applyDest(dest, getVF(fd), acc - getVF(fs) * getVF(ft))); break; // MSUB
    case 0x2E: { // OPMSUB: fd.xyz = acc.xyz - fs.yzx × ft.zxy
        vec4f s=getVF(fs), t=getVF(ft);
        vec4f r{acc.x-s.y*t.z, acc.y-s.z*t.x, acc.z-s.x*t.y, getVF(fd).w};
        setVF(fd, applyDest(dest & 0xE, getVF(fd), r)); break;
    }
    case 0x2F: setVF(fd, applyDest(dest, getVF(fd), getVF(fs).vmin(getVF(ft)))); break; // MINI
    case 0x3C: case 0x3D: case 0x3E: case 0x3F:
        executeUpperSpecial(raw); break;
    default: break;
    }
}

void VU::executeUpperSpecial(u32 raw) {
    int ft   = (raw >> 16) & 0x1F;
    int fs   = (raw >> 11) & 0x1F;
    int fd   = (raw >>  6) & 0x1F;
    int dest = (raw >>  2) & 0xF;
    int sub  = raw & 0x3F;

    switch (sub) {
    case 0x00: case 0x01: case 0x02: case 0x03: // ADDAbc
        acc = applyDest(dest, acc, acc + broadcast(getVF(ft), sub & 3)); break;
    case 0x04: case 0x05: case 0x06: case 0x07: // SUBAbc
        acc = applyDest(dest, acc, getVF(fs) - broadcast(getVF(ft), sub & 3)); break;
    case 0x08: case 0x09: case 0x0A: case 0x0B: // MADDAbc
        acc = applyDest(dest, acc, acc + getVF(fs) * broadcast(getVF(ft), sub & 3)); break;
    case 0x0C: case 0x0D: case 0x0E: case 0x0F: // MSUBAbc
        acc = applyDest(dest, acc, acc - getVF(fs) * broadcast(getVF(ft), sub & 3)); break;
    case 0x10: { // ITOF0
        vec4f s = getVF(fs); vec4f r{};
        for (int i=0;i<4;i++){u32 b;memcpy(&b,&s[i],4);r[i]=(f32)(i32)b;}
        setVF(fd, applyDest(dest, getVF(fd), r)); break;
    }
    case 0x11: { // ITOF4
        vec4f s=getVF(fs); vec4f r{};
        for(int i=0;i<4;i++){u32 b;memcpy(&b,&s[i],4);r[i]=(f32)(i32)b/16.f;}
        setVF(fd,applyDest(dest,getVF(fd),r)); break;
    }
    case 0x12: { // ITOF12
        vec4f s=getVF(fs); vec4f r{};
        for(int i=0;i<4;i++){u32 b;memcpy(&b,&s[i],4);r[i]=(f32)(i32)b/4096.f;}
        setVF(fd,applyDest(dest,getVF(fd),r)); break;
    }
    case 0x13: { // ITOF15
        vec4f s=getVF(fs); vec4f r{};
        for(int i=0;i<4;i++){u32 b;memcpy(&b,&s[i],4);r[i]=(f32)(i32)b/32768.f;}
        setVF(fd,applyDest(dest,getVF(fd),r)); break;
    }
    case 0x14: { // FTOI0
        vec4f s=getVF(fs); vec4f r{};
        for(int i=0;i<4;i++){i32 v=(i32)clampf(s[i],-2147483648.f,2147483647.f);u32 b;memcpy(&b,&v,4);r[i]=*(f32*)&b;}
        setVF(fd,applyDest(dest,getVF(fd),r)); break;
    }
    case 0x15: { // FTOI4
        vec4f s=getVF(fs)*16.f; vec4f r{};
        for(int i=0;i<4;i++){i32 v=(i32)clampf(s[i],-2147483648.f,2147483647.f);u32 b;memcpy(&b,&v,4);r[i]=*(f32*)&b;}
        setVF(fd,applyDest(dest,getVF(fd),r)); break;
    }
    case 0x16: { // FTOI12
        vec4f s=getVF(fs)*4096.f; vec4f r{};
        for(int i=0;i<4;i++){i32 v=(i32)clampf(s[i],-2147483648.f,2147483647.f);u32 b;memcpy(&b,&v,4);r[i]=*(f32*)&b;}
        setVF(fd,applyDest(dest,getVF(fd),r)); break;
    }
    case 0x17: { // FTOI15
        vec4f s=getVF(fs)*32768.f; vec4f r{};
        for(int i=0;i<4;i++){i32 v=(i32)clampf(s[i],-2147483648.f,2147483647.f);u32 b;memcpy(&b,&v,4);r[i]=*(f32*)&b;}
        setVF(fd,applyDest(dest,getVF(fd),r)); break;
    }
    case 0x18: acc = applyDest(dest, acc, getVF(fs) * vec4f(q)); break; // MULAq
    case 0x19: setVF(ft, applyDest(dest, getVF(ft), getVF(fs).vabs())); break; // ABS
    case 0x1A: acc = applyDest(dest, acc, getVF(fs) * vec4f(I)); break; // MULAi
    case 0x1B: { // CLIP: set clipFlag bits
        vec4f s=getVF(fs); f32 w=std::abs(getVF(ft).w);
        u32 cf=(clipFlag<<6)&0x00FF'FFC0u;
        if(s.x> w) cf|=0x01; if(s.x<-w) cf|=0x02;
        if(s.y> w) cf|=0x04; if(s.y<-w) cf|=0x08;
        if(s.z> w) cf|=0x10; if(s.z<-w) cf|=0x20;
        clipFlag=cf; break;
    }
    case 0x1C: acc = applyDest(dest, acc, acc + getVF(fs) * vec4f(q)); break; // MADDAq
    case 0x1D: acc = applyDest(dest, acc, getVF(fs) * getVF(ft)); break; // MULA
    case 0x1E: acc = applyDest(dest, acc, acc + getVF(fs) * vec4f(I)); break; // MADDAi
    case 0x1F: acc = applyDest(dest, acc, acc - getVF(fs) * vec4f(I)); break; // MSUBAi
    case 0x20: acc = applyDest(dest, acc, getVF(fs) + getVF(ft)); break; // ADDA
    case 0x21: acc = applyDest(dest, acc, acc + getVF(fs) * getVF(ft)); break; // MADDA
    case 0x22: acc = applyDest(dest, acc, getVF(fs) * getVF(ft)); break; // MULA
    case 0x24: acc = applyDest(dest, acc, getVF(fs) - getVF(ft)); break; // SUBA
    case 0x25: acc = applyDest(dest, acc, acc - getVF(fs) * getVF(ft)); break; // MSUBA
    case 0x28: { // OPMULA: acc.xyz = fs.yzx × ft.zxy
        vec4f s=getVF(fs), t=getVF(ft);
        acc = applyDest(dest & 0xE, acc, vec4f{s.y*t.z, s.z*t.x, s.x*t.y, acc.w}); break;
    }
    case 0x29: break; // NOP
    case 0x2F: break; // NOP
    default: break;
    }
    (void)ft; (void)fs; (void)fd; (void)dest;
}

// ── LOWER instruction set ─────────────────────────────────────────────────────

void VU::executeLower(u32 raw) {
    int opc  = (raw >> 25) & 0x7F;
    int it   = (raw >> 16) & 0xF;  // VI dest (4-bit)
    int is_  = (raw >> 11) & 0xF;  // VI source
    int id   = (raw >>  6) & 0xF;
    int ft   = (raw >> 16) & 0x1F; // VF ft
    int fs   = (raw >> 11) & 0x1F; // VF fs
    int dest = (raw >>  2) & 0xF;
    // Signed 11-bit immediate
    i32 imm11= (i32)((raw & 0x400) ? (raw | 0xFFFF'F800u) : (raw & 0x3FF));
    // Signed 15-bit immediate
    i32 imm15= (i32)((raw & 0x4000) ? (raw | 0xFFFF'8000u) : (raw & 0x3FFF));

    switch (opc) {
    case 0x00: { // LQ — vf[ft] = dataMem[vi[is_] + imm11]
        int addr = ((int)getVI(is_) + imm11) & ((dataSize/16) - 1);
        setVF(ft, applyDest(dest, getVF(ft), readDataQ((u16)addr)));
        break;
    }
    case 0x01: { // SQ — dataMem[vi[it] + imm11] = vf[fs]
        int addr = ((int)getVI(it) + imm11) & ((dataSize/16) - 1);
        writeDataQ((u16)addr, applyDest(dest, readDataQ((u16)addr), getVF(fs)));
        break;
    }
    case 0x04: { // ILW — vi[it] = dataMem[vi[is_] + imm11].field
        int addr = ((int)getVI(is_) + imm11) & ((dataSize/16) - 1);
        vec4f qw = readDataQ((u16)addr);
        int field = (raw >> 21) & 0xF; // XYZW dest field
        f32 val = (field & 8) ? qw.x : (field & 4) ? qw.y : (field & 2) ? qw.z : qw.w;
        u32 bits; memcpy(&bits, &val, 4);
        setVI(it, (u16)(i16)(i32)bits);
        break;
    }
    case 0x05: { // ISW — dataMem[vi[is_] + imm11].field = vi[it]
        int addr = ((int)getVI(is_) + imm11) & ((dataSize/16) - 1);
        vec4f qw = readDataQ((u16)addr);
        f32 fv = (f32)(i32)(i16)getVI(it);
        int field = (raw >> 21) & 0xF;
        if (field & 8) qw.x = fv;
        if (field & 4) qw.y = fv;
        if (field & 2) qw.z = fv;
        if (field & 1) qw.w = fv;
        writeDataQ((u16)addr, qw);
        break;
    }
    case 0x06: { // LQI — vf[ft] = dataMem[vi[is_]++]
        int addr = (int)getVI(is_) & ((dataSize/16)-1);
        setVF(ft, applyDest(dest, getVF(ft), readDataQ((u16)addr)));
        setVI(is_, getVI(is_) + 1);
        break;
    }
    case 0x07: { // SQI — dataMem[vi[it]++] = vf[fs]
        int addr = (int)getVI(it) & ((dataSize/16)-1);
        writeDataQ((u16)addr, applyDest(dest, readDataQ((u16)addr), getVF(fs)));
        setVI(it, getVI(it) + 1);
        break;
    }
    case 0x08: { // IADDIU — vi[it] = vi[is_] + imm15
        setVI(it, (u16)((i32)(i16)getVI(is_) + imm15));
        break;
    }
    case 0x09: { // ISUBIU — vi[it] = vi[is_] - imm15
        setVI(it, (u16)((i32)(i16)getVI(is_) - imm15));
        break;
    }
    case 0x10: { // FCEQ — statusFlag = (clipFlag == imm24)
        u32 imm24 = raw & 0xFFFFFF;
        vi[1] = (clipFlag == imm24) ? 1 : 0;
        break;
    }
    case 0x12: { // FCSET — clipFlag = imm24
        clipFlag = raw & 0xFFFFFF; break;
    }
    case 0x13: { // FCAND — vi[1] = (clipFlag & imm24) != 0
        vi[1] = (clipFlag & (raw & 0xFFFFFF)) ? 1 : 0; break;
    }
    case 0x14: { // FSEQ
        u32 imm12 = raw & 0xFFF;
        vi[1] = ((statusFlag & 0xFFF) == imm12) ? 1 : 0; break;
    }
    case 0x16: { // FSSET
        statusFlag = (statusFlag & ~0xFFFu) | (raw & 0xFFF); break;
    }
    case 0x17: { // FSAND
        vi[1] = (statusFlag & (raw & 0xFFF)) != 0 ? 1 : 0; break;
    }
    case 0x20: { // IADD — vi[id] = vi[is_] + vi[it]
        setVI(id, (u16)((i32)(i16)getVI(is_) + (i32)(i16)getVI(it))); break;
    }
    case 0x21: { // ISUB
        setVI(id, (u16)((i32)(i16)getVI(is_) - (i32)(i16)getVI(it))); break;
    }
    case 0x22: { // IADDI — vi[it] = vi[is_] + imm5 (sign-extend)
        i32 imm5 = (raw >> 6) & 0x1F;
        if (imm5 & 0x10) imm5 |= ~0x1F;
        setVI(it, (u16)((i32)(i16)getVI(is_) + imm5)); break;
    }
    case 0x24: { // IAND
        setVI(id, getVI(is_) & getVI(it)); break;
    }
    case 0x25: { // IOR
        setVI(id, getVI(is_) | getVI(it)); break;
    }
    case 0x28: { // MOVE — vf[ft] = vf[fs]
        setVF(ft, applyDest(dest, getVF(ft), getVF(fs))); break;
    }
    case 0x29: { // LQD — vf[ft] = dataMem[--vi[is_]]
        u16 newaddr = (u16)(getVI(is_) - 1);
        setVI(is_, newaddr);
        int addr = (int)newaddr & ((dataSize/16)-1);
        setVF(ft, applyDest(dest, getVF(ft), readDataQ((u16)addr))); break;
    }
    case 0x2A: { // SQD — dataMem[--vi[it]] = vf[fs]
        u16 newaddr = (u16)(getVI(it) - 1);
        setVI(it, newaddr);
        int addr = (int)newaddr & ((dataSize/16)-1);
        writeDataQ((u16)addr, applyDest(dest, readDataQ((u16)addr), getVF(fs))); break;
    }
    case 0x2B: { // DIV — Q = fs[field0] / ft[field1]
        int f0 = (raw >> 21) & 3, f1 = (raw >> 23) & 3;
        f32 n = getVF(fs)[f0], d = getVF(ft)[f1];
        q = (d != 0.f) ? n / d : (n >= 0.f ? 3.40282347e+38f : -3.40282347e+38f); break;
    }
    case 0x2C: { // SQRT — Q = sqrt(|ft[field]|)
        int field = (raw >> 23) & 3;
        q = std::sqrt(std::abs(getVF(ft)[field])); break;
    }
    case 0x2D: { // RSQRT
        int f0=(raw>>21)&3, f1=(raw>>23)&3;
        f32 d=std::sqrt(std::abs(getVF(ft)[f1]));
        q = (d!=0.f) ? getVF(fs)[f0]/d : 3.40282347e+38f; break;
    }
    case 0x2E: { // WAITQ — pipeline stall (NOP here) break; }
        break;
    }
    case 0x30: { // MTIR — vi[it] = lower 16 bits of fs[field]
        int field = (raw >> 21) & 3;
        u32 bits; f32 v=getVF(fs)[field]; memcpy(&bits,&v,4);
        setVI(it, (u16)bits); break;
    }
    case 0x31: { // MFIR — vf[ft][field] = sign-extend(vi[is_]) to float
        int field = (raw >> 21) & 3;
        f32 fv = (f32)(i32)(i16)getVI(is_);
        vec4f res = getVF(ft);
        res[field] = fv;
        setVF(ft, applyDest(1<<(3-field), getVF(ft), res)); break;
    }
    case 0x32: { // ILWR — vi[it] = dataMem[vi[is_]].field (lower word)
        int field = (raw >> 21) & 3;
        int addr = (int)getVI(is_) & ((dataSize/16)-1);
        u32 bits = readData32((u32)(addr*16 + field*4));
        setVI(it, (u16)bits); break;
    }
    case 0x33: { // ISWR — dataMem[vi[is_]].field = vi[it]
        int field = (raw >> 21) & 3;
        int addr = (int)getVI(is_) & ((dataSize/16)-1);
        u32 bits = (u32)(i32)(i16)getVI(it);
        writeData32((u32)(addr*16 + field*4), bits); break;
    }
    case 0x34: { // RINIT — R = 0x3F800000 | (fs[field] & 0x7FFFFF)
        int field = (raw >> 21) & 3;
        u32 bits; f32 v=getVF(fs)[field]; memcpy(&bits,&v,4);
        r = 0x3F800000u | (bits & 0x7FFFFFu); break;
    }
    case 0x35: { // RGET — vf[ft][field] = R
        int field = (raw >> 21) & 3;
        vec4f res = getVF(ft);
        memcpy(&res[field], &r, 4);
        setVF(ft, applyDest(1<<(3-field), getVF(ft), res)); break;
    }
    case 0x36: rnextStep(); { // RNEXT
        int field = (raw >> 21) & 3;
        vec4f res = getVF(ft);
        memcpy(&res[field], &r, 4);
        setVF(ft, applyDest(1<<(3-field), getVF(ft), res)); break;
    }
    case 0x37: rnextStep(); break; // RXOR
    case 0x3A: { // ELENG — P = sqrt(fs.x^2 + fs.y^2 + fs.z^2)
        vec4f s=getVF(fs);
        p = std::sqrt(s.x*s.x + s.y*s.y + s.z*s.z); break;
    }
    case 0x3B: { // ESQRT — P = sqrt(|fs[field]|)
        int field=(raw>>21)&3; p=std::sqrt(std::abs(getVF(fs)[field])); break;
    }
    case 0x3C: { // ERSQRT
        int field=(raw>>21)&3; f32 v=std::sqrt(std::abs(getVF(fs)[field]));
        p = (v!=0.f)?1.f/v:3.40282347e+38f; break;
    }
    case 0x3D: { // ESIN — P = sin(fs[field])
        int field=(raw>>21)&3; p=std::sin(getVF(fs)[field]); break;
    }
    case 0x3E: { // EATAN
        int field=(raw>>21)&3; p=std::atan(getVF(fs)[field]); break;
    }
    case 0x3F: { // EEXP
        int field=(raw>>21)&3; p=std::exp(-getVF(fs)[field]); break;
    }
    // Branch instructions
    case 0x40: { // B — unconditional branch
        i32 off = (i32)((raw & 0x7FF) | ((raw & 0x400) ? ~0x7FF : 0));
        microPC = (u32)((i32)microPC + off); break;
    }
    case 0x41: { // BAL — branch and link
        i32 off = (i32)((raw & 0x7FF) | ((raw & 0x400) ? ~0x7FF : 0));
        setVI(it, (u16)(microPC));
        microPC = (u32)((i32)microPC + off); break;
    }
    case 0x44: { // IBEQ — if vi[it] == vi[is_]
        i32 off=(raw&0x7FF)|((raw&0x400)?~0x7FF:0);
        if (getVI(is_)==getVI(it)) microPC=(u32)((i32)microPC+off); break;
    }
    case 0x45: { // IBNE
        i32 off=(raw&0x7FF)|((raw&0x400)?~0x7FF:0);
        if (getVI(is_)!=getVI(it)) microPC=(u32)((i32)microPC+off); break;
    }
    case 0x46: { // IBLTZ
        i32 off=(raw&0x7FF)|((raw&0x400)?~0x7FF:0);
        if ((i16)getVI(is_)<0) microPC=(u32)((i32)microPC+off); break;
    }
    case 0x47: { // IBGTZ
        i32 off=(raw&0x7FF)|((raw&0x400)?~0x7FF:0);
        if ((i16)getVI(is_)>0) microPC=(u32)((i32)microPC+off); break;
    }
    case 0x4A: { // IBLEZ
        i32 off=(raw&0x7FF)|((raw&0x400)?~0x7FF:0);
        if ((i16)getVI(is_)<=0) microPC=(u32)((i32)microPC+off); break;
    }
    case 0x4B: { // IBGEZ
        i32 off=(raw&0x7FF)|((raw&0x400)?~0x7FF:0);
        if ((i16)getVI(is_)>=0) microPC=(u32)((i32)microPC+off); break;
    }
    case 0x70: { // XGKICK — send VU1 data to GS via GIF
        if (index == 1 && onXGKICK) {
            u32 addr = (u32)getVI(is_) * 16;
            // Pass dataMem slice from addr
            u32 avail = (u32)dataSize - addr;
            if (addr < (u32)dataSize)
                onXGKICK(dataMem + addr, avail);
        }
        break;
    }
    case 0x71: break; // XTOP (top of GIF path — returns address in VI[it])
    case 0x72: { // XITOP
        setVI(it, 0); // simplified
        break;
    }
    default: break;
    }
    (void)id; (void)ft; (void)fs; (void)dest;
}

// ── PRNG (used by R instructions) ────────────────────────────────────────────

void VU::rnextStep() {
    r = ((r << 4) ^ (r >> 27) ^ (r & 0x7FFFFFu)) | 0x3F800000u;
}
