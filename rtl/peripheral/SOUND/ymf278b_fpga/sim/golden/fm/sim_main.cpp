// FM golden comparison: gtaylormb opl3 RTL (Verilator) vs Nuked-OPL3 (C ref).
// Same register script at the same sample indices into both; per-sample
// compare with small lag search.  Goal: quantify closeness (the two are
// independent implementations — bit-exactness is not expected) and catch
// integration-level errors (banking, addressing, timer side effects).
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <vector>
#include <cmath>
#include <algorithm>
#include "Vopl3.h"
#include "verilated.h"
extern "C" {
#include "../third_party/nuked_opl3.h"
}

struct Wr { int sample; uint16_t reg; uint8_t val; };

// ── scenario scripts ─────────────────────────────────────────────────────────
static void op_patch(std::vector<Wr>& s, int at, int ch, int bank,
                     uint8_t mult, uint8_t tl, uint8_t ar_dr, uint8_t sl_rr) {
    static const int op1[9] = {0,1,2,8,9,10,16,17,18};
    int b = bank ? 0x100 : 0;
    int o1 = op1[ch], o2 = o1 + 3;
    for (int o : {o1, o2}) {
        s.push_back({at, (uint16_t)(b+0x20+o), mult});
        s.push_back({at, (uint16_t)(b+0x40+o), (uint8_t)(o==o1 ? 0x10 : tl)});
        s.push_back({at, (uint16_t)(b+0x60+o), ar_dr});
        s.push_back({at, (uint16_t)(b+0x80+o), sl_rr});
    }
}
static void keyon(std::vector<Wr>& s, int at, int ch, int bank, int fnum, int blk) {
    int b = bank ? 0x100 : 0;
    s.push_back({at, (uint16_t)(b+0xC0+ch), 0x31});               // CHA|CHB, fb1, alg1(=additive? 0x30|alg)
    s.push_back({at, (uint16_t)(b+0xA0+ch), (uint8_t)(fnum & 0xFF)});
    s.push_back({at, (uint16_t)(b+0xB0+ch), (uint8_t)(0x20 | (blk<<2) | (fnum>>8))});
}
static void keyoff(std::vector<Wr>& s, int at, int ch, int bank, int fnum, int blk) {
    int b = bank ? 0x100 : 0;
    s.push_back({at, (uint16_t)(b+0xB0+ch), (uint8_t)((blk<<2) | (fnum>>8))});
}

struct Scen { const char* name; std::vector<Wr> wr; int samples; };

static std::vector<Scen> build_scenarios() {
    std::vector<Scen> v;
    { Scen s{"2op_tone", {}, 8000};
      s.wr.push_back({0, 0x105, 0x01});                            // NEW
      op_patch(s.wr, 1, 0, 0, 0x21, 0x18, 0xF4, 0x7A);
      keyon(s.wr, 2, 0, 0, 0x2AE, 4);
      keyoff(s.wr, 6000, 0, 0, 0x2AE, 4);
      v.push_back(s); }
    { Scen s{"envelope", {}, 9000};
      s.wr.push_back({0, 0x105, 0x01});
      op_patch(s.wr, 1, 1, 0, 0x22, 0x08, 0x83, 0x35);             // slow attack
      keyon(s.wr, 2, 1, 0, 0x1C0, 3);
      keyoff(s.wr, 5000, 1, 0, 0x1C0, 3);
      v.push_back(s); }
    { Scen s{"chord_dualbank", {}, 8000};
      s.wr.push_back({0, 0x105, 0x01});
      int fn[6] = {0x16B, 0x1C9, 0x222, 0x16B, 0x1C9, 0x222};
      for (int i = 0; i < 6; i++) {
          int ch = i % 3, bank = i / 3;
          op_patch(s.wr, 1, ch, bank, 0x21, (uint8_t)(0x10+i*2), 0xD5, 0x49);
          keyon(s.wr, 2+i, ch, bank, fn[i], 3 + bank);
      }
      v.push_back(s); }
    { Scen s{"rhythm", {}, 8000};
      s.wr.push_back({0, 0x105, 0x01});
      // bd/sd/tom/cym/hh operators (slots 12-17 → regs offset 0x10-0x15)
      for (int o : {0x10,0x11,0x12,0x13,0x14,0x15}) {
          s.wr.push_back({1, (uint16_t)(0x20+o), 0x01});
          s.wr.push_back({1, (uint16_t)(0x40+o), 0x00});
          s.wr.push_back({1, (uint16_t)(0x60+o), 0xF7});
          s.wr.push_back({1, (uint16_t)(0x80+o), 0xF7});
      }
      for (int ch : {6,7,8}) {
          s.wr.push_back({1, (uint16_t)(0xC0+ch), 0x30});
          s.wr.push_back({1, (uint16_t)(0xA0+ch), 0x57});
          s.wr.push_back({1, (uint16_t)(0xB0+ch), 0x0C});
      }
      s.wr.push_back({2,    0xBD, 0x3F});                          // rhythm all on
      s.wr.push_back({3000, 0xBD, 0x20});
      s.wr.push_back({3500, 0xBD, 0x3F});
      v.push_back(s); }
    { Scen s{"vib_trem", {}, 12000};
      s.wr.push_back({0, 0x105, 0x01});
      s.wr.push_back({0, 0xBD, 0xC0});                             // DVB|DAM deep
      static const int op1ch2 = 2;
      op_patch(s.wr, 1, op1ch2, 0, (uint8_t)(0x21|0xC0), 0x14, 0xF2, 0x36); // AM|VIB on mult byte? (0x20=sustain,0x80=AM,0x40=VIB)
      keyon(s.wr, 2, op1ch2, 0, 0x205, 4);
      v.push_back(s); }
    { Scen s{"vib_only", {}, 12000};
      s.wr.push_back({0, 0x105, 0x01});
      s.wr.push_back({0, 0xBD, 0x40});                             // DVB deep, no DAM
      op_patch(s.wr, 1, 2, 0, (uint8_t)(0x21|0x40), 0x14, 0xF2, 0x36);  // VIB only
      keyon(s.wr, 2, 2, 0, 0x205, 4);
      v.push_back(s); }
    { Scen s{"trem_only", {}, 12000};
      s.wr.push_back({0, 0x105, 0x01});
      s.wr.push_back({0, 0xBD, 0x80});                             // DAM deep, no DVB
      op_patch(s.wr, 1, 2, 0, (uint8_t)(0x21|0x80), 0x14, 0xF2, 0x36);  // AM only
      keyon(s.wr, 2, 2, 0, 0x205, 4);
      v.push_back(s); }
    { Scen s{"4op", {}, 8000};
      s.wr.push_back({0, 0x105, 0x01});
      s.wr.push_back({1, 0x104, 0x01});                            // ch0+ch3 4-op
      static const int ops[4] = {0, 3, 8, 11};
      uint8_t tls[4] = {0x10, 0x12, 0x0E, 0x16};
      for (int i = 0; i < 4; i++) {
          s.wr.push_back({1, (uint16_t)(0x20+ops[i]), 0x21});
          s.wr.push_back({1, (uint16_t)(0x40+ops[i]), tls[i]});
          s.wr.push_back({1, (uint16_t)(0x60+ops[i]), 0xE4});
          s.wr.push_back({1, (uint16_t)(0x80+ops[i]), 0x59});
      }
      s.wr.push_back({2, 0xC0, 0x32});
      s.wr.push_back({2, 0xC3, 0x30});
      s.wr.push_back({2, 0xA0, 0x44});
      s.wr.push_back({2, 0xB0, 0x32});
      v.push_back(s); }
    return v;
}

// ── RTL driving ─────────────────────────────────────────────────────────────
static Vopl3* top;
static vluint64_t tcyc = 0;
static void tick() {
    top->clk = 0; top->clk_host = 0; top->clk_dac = 0; top->eval();
    top->clk = 1; top->clk_host = 1; top->clk_dac = 1; top->eval();
    tcyc++;
}
static void rtl_write(uint16_t reg, uint8_t val) {
    // ymf278b_top 3-phase protocol: addr (address[0]=0), gap, data (address[0]=1)
    top->cs_n = 0; top->wr_n = 0; top->address = (reg >> 8) ? 2 : 0; top->din = reg & 0xFF;
    tick();
    top->cs_n = 1; top->wr_n = 1; tick();
    top->cs_n = 0; top->wr_n = 0; top->address = ((reg >> 8) ? 2 : 0) | 1; top->din = val;
    tick();
    top->cs_n = 1; top->wr_n = 1; tick();
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    auto scens = build_scenarios();
    int total_fail = 0;

    for (auto& sc : scens) {
        // fresh RTL + reference per scenario
        top = new Vopl3;
        top->ic_n = 0; top->cs_n = 1; top->rd_n = 1; top->wr_n = 1;
        top->address = 0; top->din = 0;
        for (int i = 0; i < 64; i++) tick();
        top->ic_n = 1;
        for (int i = 0; i < 64; i++) tick();

        opl3_chip ref;
        OPL3_Reset(&ref, 49716);

        std::vector<int32_t> rl, rr, nl, nr;
        size_t wi = 0;
        std::sort(sc.wr.begin(), sc.wr.end(),
                  [](const Wr&a, const Wr&b){ return a.sample < b.sample; });

        int sample = 0;
        int guard = 0;
        while (sample < sc.samples && guard < sc.samples * 400) {
            // apply this sample's writes (RTL + ref)
            while (wi < sc.wr.size() && sc.wr[wi].sample == sample) {
                rtl_write(sc.wr[wi].reg, sc.wr[wi].val);
                OPL3_WriteReg(&ref, sc.wr[wi].reg, sc.wr[wi].val);
                wi++;
            }
            // run RTL until next sample_valid
            int prev = top->sample_valid;
            do { tick(); guard++; }
            while (!(top->sample_valid && !prev) &&
                   (prev = top->sample_valid, guard < sc.samples * 400));
            rl.push_back(((int32_t)top->sample_l << 8) >> 8 >> 5);   // 24b → 16b
            rr.push_back(((int32_t)top->sample_r << 8) >> 8 >> 5);
            int16_t buf[2];
            OPL3_Generate(&ref, buf);
            nl.push_back(buf[0]); nr.push_back(buf[1]);
            sample++;
        }
        delete top;

        // lag search + metrics
        auto metrics = [&](int lag, double& rms, int& maxd, double& corr) {
            int n = sample - abs(lag) - 8;
            double se = 0, sx = 0, sy = 0, sxy = 0, sx2 = 0, sy2 = 0;
            maxd = 0;
            for (int i = 0; i < n; i++) {
                double x = rl[i + std::max(lag,0)], y = nl[i + std::max(-lag,0)];
                int d = (int)std::abs(x - y);
                maxd = std::max(maxd, d);
                se += (x-y)*(x-y);
                sx += x; sy += y; sxy += x*y; sx2 += x*x; sy2 += y*y;
            }
            rms = std::sqrt(se / n);
            double cov = sxy/n - (sx/n)*(sy/n);
            double vx = sx2/n - (sx/n)*(sx/n), vy = sy2/n - (sy/n)*(sy/n);
            corr = (vx > 0 && vy > 0) ? cov / std::sqrt(vx*vy) : (vx==vy ? 1.0 : 0.0);
        };
        double best_rms = 1e18, rms; int best_lag = 0, maxd; double corr, best_corr=0; int best_maxd=0;
        for (int lag = -4; lag <= 4; lag++) {
            metrics(lag, rms, maxd, corr);
            if (rms < best_rms) { best_rms = rms; best_lag = lag; best_maxd = maxd; best_corr = corr; }
        }
        // signal level for context
        double ref_rms = 0; for (auto v : nl) ref_rms += (double)v*v;
        ref_rms = std::sqrt(ref_rms / nl.size());
        double rel = ref_rms > 1 ? best_rms / ref_rms * 100.0 : 0.0;

        // Phase-robust secondary metric: correlation of 256-sample RMS
        // envelopes.  Noise (rhythm LFSR) and LFO phase offsets destroy
        // sample-wise correlation while the sound is audibly equivalent;
        // the energy envelope tracks timbre/level/decay behavior instead.
        auto env_of = [&](std::vector<int32_t>& v) {
            std::vector<double> e;
            for (size_t i = 0; i + 256 <= v.size(); i += 256) {
                double a = 0;
                for (size_t k = i; k < i + 256; k++) a += (double)v[k]*v[k];
                e.push_back(std::sqrt(a / 256));
            }
            return e;
        };
        auto el = env_of(rl), en = env_of(nl);
        size_t ne = std::min(el.size(), en.size());
        double ex=0, ey=0, exy=0, ex2=0, ey2=0;
        for (size_t i = 0; i < ne; i++) {
            ex += el[i]; ey += en[i]; exy += el[i]*en[i];
            ex2 += el[i]*el[i]; ey2 += en[i]*en[i];
        }
        double ecov = exy/ne - (ex/ne)*(ey/ne);
        double evx = ex2/ne - (ex/ne)*(ex/ne), evy = ey2/ne - (ey/ne)*(ey/ne);
        double env_corr = (evx > 0 && evy > 0) ? ecov / std::sqrt(evx*evy) : 1.0;
        double lvl_ratio = (ey/ne) > 1 ? (ex/ne)/(ey/ne) : 1.0;

        bool ok = (best_corr > 0.99) ||
                  (env_corr > 0.97 && lvl_ratio > 0.7 && lvl_ratio < 1.4) ||
                  (ref_rms < 1 && best_rms < 1);
        printf("[%-15s] n=%d lag=%+d  RMSerr=%.1f (ref %.1f, %.2f%%)  maxd=%d  corr=%.5f  envcorr=%.4f lvl=%.3f  %s\n",
               sc.name, sample, best_lag, best_rms, ref_rms, rel, best_maxd, best_corr,
               env_corr, lvl_ratio,
               ok ? (best_corr > 0.99 ? "OK" : "OK(envelope)") : "** DIVERGENT **");
        if (!ok) total_fail++;
    }
    printf("════════════════════════════════\n");
    printf(total_fail ? "FM GOLDEN: %d scenario(s) divergent\n" : "FM GOLDEN: all scenarios track the reference\n", total_fail);
    return total_fail ? 1 : 0;
}
