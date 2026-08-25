// Standalone faithful port of openMSX YMF278.cc PCM sample generation.
// This is the REAL-CHIP reference (analogous to Nuked-OPL3 for the FM side):
// the existing golden_pcm.py is a Python *re-implementation* that could share a
// bug with the RTL; this verifies golden_pcm.py itself against the actual chip
// code.  All math/tables copied verbatim from reference/YMF278.cc.
//
//   ref278 <mem.bin> <script.txt> <frames> <out.txt>
//   script lines: "<frame> <addr_hex> <data_hex> [<applycycle>]" (4th col ignored)
//   Writes for frame N are applied before frame N is generated; one stereo
//   sample is emitted per frame.  Output: "<L> <R>" per line (raw mix sum,
//   reg-0xF9 PCM mix level forced to 0dB to match the RTL TB which sets it 0dB).
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <array>
#include <algorithm>

static constexpr int MAX_ATT_INDEX = 0x280;
static constexpr int MIN_ATT_INDEX = 0;
static constexpr int TL_SHIFT = 2;
static constexpr unsigned LFO_SHIFT = 18;
static constexpr unsigned LFO_PERIOD = 1u << LFO_SHIFT;
static constexpr int EG_ATT=4, EG_DEC=3, EG_SUS=2, EG_REL=1, EG_OFF=0;

static const uint8_t pan_left[16]  = {0,8,16,24,32,40,48,255,255,0,0,0,0,0,0,0};
static const uint8_t pan_right[16] = {0,0,0,0,0,0,0,0,255,255,48,40,32,24,16,8};

static int16_t SC(int dB){ return int16_t(dB/3*0x20); }
static const int16_t dl_tab[16] = {
  SC(0),SC(3),SC(6),SC(9),SC(12),SC(15),SC(18),SC(21),
  SC(24),SC(27),SC(30),SC(33),SC(36),SC(39),SC(42),SC(93)};

static const uint8_t eg_inc[15*8] = {
  0,1,0,1,0,1,0,1, 0,1,0,1,1,1,0,1, 0,1,1,1,0,1,1,1, 0,1,1,1,1,1,1,1,
  1,1,1,1,1,1,1,1, 1,1,1,2,1,1,1,2, 1,2,1,2,1,2,1,2, 1,2,2,2,1,2,2,2,
  2,2,2,2,2,2,2,2, 2,2,2,4,2,2,2,4, 2,4,2,4,2,4,2,4, 2,4,4,4,2,4,4,4,
  4,4,4,4,4,4,4,4, 8,8,8,8,8,8,8,8, 0,0,0,0,0,0,0,0};
static uint8_t O(int a){ return uint8_t(a*8); }
static const uint8_t eg_rate_select[64] = {
  O(14),O(14),O(14),O(14),
  O(0),O(1),O(2),O(3), O(0),O(1),O(2),O(3), O(0),O(1),O(2),O(3),
  O(0),O(1),O(2),O(3), O(0),O(1),O(2),O(3), O(0),O(1),O(2),O(3),
  O(0),O(1),O(2),O(3), O(0),O(1),O(2),O(3), O(0),O(1),O(2),O(3),
  O(0),O(1),O(2),O(3), O(0),O(1),O(2),O(3), O(0),O(1),O(2),O(3),
  O(4),O(5),O(6),O(7), O(8),O(9),O(10),O(11), O(12),O(12),O(12),O(12)};
static const uint8_t eg_rate_shift[64] = {
  12,12,12,12,11,11,11,11,10,10,10,10,9,9,9,9,
  8,8,8,8,7,7,7,7,6,6,6,6,5,5,5,5,
  4,4,4,4,3,3,3,3,2,2,2,2,1,1,1,1,
  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0};
static int Lp(double a){ return int((LFO_PERIOD*a)/44100.0 + 0.5); }
static int lfo_period[8];
static const int16_t vib_depth[8] = {0,2,3,4,6,12,24,48};
static const uint8_t am_depth[8] = {0x00,0x14,0x20,0x28,0x30,0x40,0x50,0x80};

static int8_t sign_extend_4(int x){ return int8_t((x^8)-8); }
static unsigned calcStep(int8_t oct, uint16_t fn, int16_t vib=0){
  if (oct==-8) return 0;
  unsigned t = (unsigned)(fn + 1024 + vib) << (8 + oct);
  return t >> 3;
}

static std::vector<uint8_t> MEM;
// openMSX setupMemPtrs model: ROM blocks 0-15 (0..0x1FFFFF) always mapped;
// RAM region (>=0x200000) mapped only up to the configured RAM size, beyond
// which readMem returns 0xFF (unmapped block).  RAM_BYTES=0 => no limit (flat).
static unsigned RAM_BYTES = 0;
static inline uint8_t readMem(unsigned a){
    a &= 0x3FFFFF;                                  // 4MB wrap (openMSX masks)
    if (RAM_BYTES && a >= 0x200000 && (a - 0x200000) >= RAM_BYTES)
        return 0xFF;                                // unmapped RAM block
    return a < MEM.size() ? MEM[a] : 0xFF;
}

struct Slot {
  uint16_t wave=0, FN=0;
  int8_t OCT=0;
  uint8_t TLdest=0, TL=0, pan=0, vib=0, AM=0, lfo=0;
  uint8_t AR=0,D1R=0,D2R=0,RC=0,RR=0;
  int16_t DL=0;
  bool PRVB=false, keyon=false, DAMP=false, lfo_active=false;
  uint8_t bits=0;
  unsigned startAddr=0;
  uint16_t loopAddr=0, endAddr=0;
  uint16_t pos=0;
  unsigned stepPtr=0, step=0;
  int env_vol=MAX_ATT_INDEX;
  int state=EG_OFF;
  unsigned lfo_cnt=0;

  uint8_t compute_rate(int val) const {
    if (val==0) return 0;
    if (val==15) return 63;
    int res = val*4;
    if (RC!=15){ res += 2*std::clamp((int)OCT+RC,0,15); res += (FN&0x200)?1:0; }
    return (uint8_t)std::clamp(res,0,63);
  }
  uint8_t compute_decay_rate(int val) const {
    if (DAMP) return (env_vol < dl_tab[4]) ? 48 : 63;
    if (PRVB){ if (env_vol >= dl_tab[6]) return 20; }
    return compute_rate(val);
  }
  int16_t compute_vib() const {
    int16_t lfo_fm = int16_t(lfo_cnt / (LFO_PERIOD/0x40));
    if (lfo_fm & 0x10) lfo_fm ^= 0x1F;
    if (lfo_fm & 0x20) lfo_fm = int16_t(-(lfo_fm & 0x0F));
    return int16_t((lfo_fm * vib_depth[vib]) / 12);
  }
  uint16_t compute_am() const {
    uint16_t lfo_am = uint16_t(lfo_cnt / (LFO_PERIOD/0x100));
    if (lfo_am >= 0x80) lfo_am ^= 0xFF;
    return uint16_t((lfo_am * am_depth[AM]) >> 7);
  }
};

static Slot slots[24];
static uint8_t regs2 = 0;
static unsigned eg_cnt = 0;

static int16_t getSample(const Slot& s, uint16_t pos){
  switch (s.bits){
    case 0: return int16_t(readMem(s.startAddr + pos) << 8);
    case 1: {
      unsigned addr = s.startAddr + ((pos/2)*3);
      if (pos & 1) return int16_t((readMem(addr+2)<<8) | (readMem(addr+1)&0xF0));
      else         return int16_t((readMem(addr+0)<<8) | ((readMem(addr+1)<<4)&0xF0));
    }
    case 2: {
      unsigned addr = s.startAddr + (pos*2);
      return int16_t((readMem(addr+0)<<8) | (readMem(addr+1)<<0));
    }
  }
  return 0;
}
static uint16_t nextPos(const Slot& s, uint16_t pos, uint16_t inc){
  pos += inc;
  if ((uint32_t(pos) + s.endAddr) >= 0x10000) pos += uint16_t(s.endAddr + s.loopAddr);
  return pos;
}
static int vol_factor(int x, unsigned envVol){
  if (envVol >= (unsigned)MAX_ATT_INDEX) return 0;
  int vol_mul = 0x80 - int(envVol & 0x3F);
  int vol_shift = 7 + int(envVol >> 6);
  return (x * ((0x8000 * vol_mul) >> vol_shift)) >> 15;
}

static void keyOnHelper(Slot& s){
  s.env_vol = MAX_ATT_INDEX;
  if (s.compute_rate(s.AR) < 63) s.state = EG_ATT;
  else { s.env_vol = MIN_ATT_INDEX; s.state = s.DL ? EG_DEC : EG_SUS; }
  s.stepPtr = 0; s.pos = 0;
}

static void writeRegDirect(uint8_t reg, uint8_t data){
  if (reg >= 0x08 && reg <= 0xF7){
    int sNum = (reg-8)%24;
    Slot& s = slots[sNum];
    switch ((reg-8)/24){
      case 0: {
        s.wave = (s.wave & 0x100) | data;
        int waveTblHdr = (regs2 >> 2) & 0x7;
        int base = (s.wave < 384 || !waveTblHdr) ? (s.wave*12)
                 : (waveTblHdr*0x80000 + ((s.wave-384)*12));
        uint8_t buf[12];
        for (int i=0;i<12;i++) buf[i]=readMem(base+i);
        s.bits = (buf[0]&0xC0)>>6;
        s.startAddr = buf[2] | (buf[1]<<8) | ((buf[0]&0x3F)<<16);
        s.loopAddr = uint16_t(buf[4] | (buf[3]<<8));
        s.endAddr  = uint16_t(buf[6] | (buf[5]<<8));
        for (int i=7;i<12;i++) writeRegDirect(uint8_t(8 + sNum + (i-2)*24), buf[i]);
        if (s.keyon) keyOnHelper(s); else { s.stepPtr=0; s.pos=0; }
        break;
      }
      case 1: s.wave=uint16_t((s.wave&0xFF)|((data&1)<<8)); s.FN=(s.FN&0x380)|(data>>1); s.step=calcStep(s.OCT,s.FN); break;
      case 2: s.FN=uint16_t((s.FN&0x07F)|((data&7)<<7)); s.PRVB=(data&8)!=0; s.OCT=sign_extend_4((data&0xF0)>>4); s.step=calcStep(s.OCT,s.FN); break;
      case 3: { uint8_t t=data>>1; s.TLdest=(t!=0x7f)?t:0xff; if (data&1) s.TL=s.TLdest; break; }
      case 4:
        s.pan = (data&0x10) ? 8 : (data&0x0F);
        if (data&0x20){ s.lfo_active=false; s.lfo_cnt=0; } else s.lfo_active=true;
        s.DAMP=(data&0x40)!=0;
        if (data&0x80){ if (!s.keyon){ s.keyon=true; keyOnHelper(s);} }
        else { if (s.keyon){ s.keyon=false; s.state=EG_REL; } }
        break;
      case 5: s.lfo=(data>>3)&7; s.vib=data&7; break;
      case 6: s.AR=data>>4; s.D1R=data&0xF; break;
      case 7: s.DL=dl_tab[data>>4]; s.D2R=data&0xF; break;
      case 8: s.RC=data>>4; s.RR=data&0xF; break;
      case 9: s.AM=data&7; break;
    }
  } else if (reg==2){ regs2 = data; }
  // reg 0xF9 (PCM mix) intentionally ignored: TB forces 0dB
}

static void advance(){
  eg_cnt++;
  unsigned tl_int_cnt = eg_cnt % 9;
  unsigned tl_int_step = (eg_cnt/9)%3;
  for (auto& op : slots){
    if (tl_int_cnt==0){
      if (tl_int_step==0){ if (op.TL < op.TLdest) ++op.TL; }
      else { if (op.TL > op.TLdest) --op.TL; }
    }
    if (op.lfo_active) op.lfo_cnt = (op.lfo_cnt + lfo_period[op.lfo]) & (LFO_PERIOD-1);
    switch (op.state){
      case EG_ATT: {
        uint8_t rate=op.compute_rate(op.AR);
        if (rate>=63) break;
        uint8_t shift=eg_rate_shift[rate];
        if (!(eg_cnt & ((1u<<shift)-1))){
          uint8_t sel=eg_rate_select[rate];
          op.env_vol = int16_t(op.env_vol + ((~op.env_vol * eg_inc[sel+((eg_cnt>>shift)&7)])>>4));
          if (op.env_vol <= MIN_ATT_INDEX){ op.env_vol=MIN_ATT_INDEX; op.state = op.DL?EG_DEC:EG_SUS; }
        }
        break;
      }
      case EG_DEC: {
        uint8_t rate=op.compute_decay_rate(op.D1R), shift=eg_rate_shift[rate];
        if (!(eg_cnt & ((1u<<shift)-1))){
          uint8_t sel=eg_rate_select[rate];
          op.env_vol = int16_t(op.env_vol + eg_inc[sel+((eg_cnt>>shift)&7)]);
          if (op.env_vol >= op.DL) op.state = (op.env_vol<MAX_ATT_INDEX)?EG_SUS:EG_OFF;
        }
        break;
      }
      case EG_SUS: {
        uint8_t rate=op.compute_decay_rate(op.D2R), shift=eg_rate_shift[rate];
        if (!(eg_cnt & ((1u<<shift)-1))){
          uint8_t sel=eg_rate_select[rate];
          op.env_vol = int16_t(op.env_vol + eg_inc[sel+((eg_cnt>>shift)&7)]);
          if (op.env_vol >= MAX_ATT_INDEX){ op.env_vol=MAX_ATT_INDEX; op.state=EG_OFF; }
        }
        break;
      }
      case EG_REL: {
        uint8_t rate=op.compute_decay_rate(op.RR), shift=eg_rate_shift[rate];
        if (!(eg_cnt & ((1u<<shift)-1))){
          uint8_t sel=eg_rate_select[rate];
          op.env_vol = int16_t(op.env_vol + eg_inc[sel+((eg_cnt>>shift)&7)]);
          if (op.env_vol >= MAX_ATT_INDEX){ op.env_vol=MAX_ATT_INDEX; op.state=EG_OFF; }
        }
        break;
      }
    }
  }
}

// one stereo sample, raw mix sum (no reg-F9, no software volume)
static void genSample(int32_t& outL, int32_t& outR){
  int32_t l=0, r=0;
  for (auto& sl : slots){
    if (sl.state==EG_OFF) {
      // still advance pos? No: real chip skips EG_OFF entirely in the loop.
      continue;
    }
    int16_t s0 = getSample(sl, sl.pos);
    int16_t s1 = getSample(sl, nextPos(sl, sl.pos, 1));
    int16_t sample = int16_t((s0*(0x10000 - sl.stepPtr) + s1*sl.stepPtr) >> 16);
    uint16_t envVol = uint16_t(std::min(sl.env_vol + ((sl.lfo_active && sl.AM)?sl.compute_am():0), MAX_ATT_INDEX));
    int smplOut = vol_factor(vol_factor(sample, envVol), sl.TL << TL_SHIFT);
    int32_t vL = pan_left[sl.pan], vR = pan_right[sl.pan];
    vL = (0x20 - (vL & 0x0f)) >> (vL >> 4);
    vR = (0x20 - (vR & 0x0f)) >> (vR >> 4);
    l += (smplOut * vL) >> 5;
    r += (smplOut * vR) >> 5;
    unsigned step = (sl.lfo_active && sl.vib) ? calcStep(sl.OCT, sl.FN, sl.compute_vib()) : sl.step;
    sl.stepPtr += step;
    if (sl.stepPtr >= 0x10000){ sl.pos = nextPos(sl, sl.pos, uint16_t(sl.stepPtr>>16)); sl.stepPtr &= 0xffff; }
  }
  // clip to int16 like the RTL accumulator output
  l = std::clamp(l, -32768, 32767);
  r = std::clamp(r, -32768, 32767);
  outL=l; outR=r;
}

int main(int argc, char** argv){
  if (argc < 5){ fprintf(stderr,"usage: ref278 mem.bin script.txt frames out.txt\n"); return 1; }
  for (int i=0;i<8;i++) lfo_period[i] = Lp((const double[]){0.168,2.019,3.196,4.206,5.215,5.888,6.224,7.066}[i]);
  FILE* mf=fopen(argv[1],"rb");
  fseek(mf,0,SEEK_END); long ms=ftell(mf); fseek(mf,0,SEEK_SET);
  MEM.resize(ms); fread(MEM.data(),1,ms,mf); fclose(mf);
  int frames = atoi(argv[3]);
  if (const char* rk = getenv("RAM_KB")) RAM_BYTES = unsigned(atoi(rk)) * 1024;
  // read script into per-frame write lists
  std::vector<std::vector<std::pair<int,int>>> wr(frames+2);
  FILE* sf=fopen(argv[2],"r"); char line[128];
  while (fgets(line,sizeof line,sf)){
    int fr,ad,da;
    if (sscanf(line,"%d %x %x",&fr,&ad,&da)>=3 && fr>=0 && fr<frames+2)
      wr[fr].push_back({ad,da});
  }
  fclose(sf);
  FILE* of=fopen(argv[4],"w");
  for (int f=0; f<frames; f++){
    for (auto& w : wr[f]) writeRegDirect(uint8_t(w.first), uint8_t(w.second));
    int32_t L,R; genSample(L,R);
    fprintf(of,"%d %d\n",L,R);
    advance();
  }
  fclose(of);
  fprintf(stderr,"ref278: %d frames -> %s\n", frames, argv[4]);
  return 0;
}
