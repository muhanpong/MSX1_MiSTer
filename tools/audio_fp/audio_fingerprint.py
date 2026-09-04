#!/usr/bin/env python3
"""Fingerprint a core/emulator audio capture and compare it against a reference.

    audio_fingerprint.py capture.mp4 [reference.wav]

Built 2026-09-04 to chase an SCC+ crackle that only showed in cartridge slot A.
The three numbers that mattered, and why:

  spikes/s   samples that jump more than 8x the local envelope while exceeding
             500 LSB.  A wrong waveform BYTE lands here: the value has nothing
             to do with the music, so it towers over a quiet passage.  The
             openMSX reference scored 0; the board scored 2.8/s.
  2-10 kHz   share of spectral energy in the same loudness bracket.  Clicks are
             broadband; music of this era is not.  Reference 1.7%, board 22.1%.
  50/60 Hz   rank of the frame rate in the envelope spectrum.  Anything driven
             by the VDP interrupt shows here.  Neither capture did, which is
             how the frame-sync theories died.

Peak/clipping is reported too but proved to be a dead end: neither side ever
came near full scale, which is what killed the headroom theory.
"""
import sys, os, subprocess, tempfile, wave
import numpy as np

def load(path):
    if path.lower().endswith(('.wav',)):
        w = wave.open(path); sr = w.getframerate()
        x = np.frombuffer(w.readframes(w.getnframes()), dtype='<i2').astype(np.float64)
        return x, sr
    tmp = tempfile.mktemp(suffix='.wav')
    subprocess.run(['ffmpeg','-nostdin','-loglevel','error','-y','-i',path,
                    '-vn','-ac','1','-ar','44100','-acodec','pcm_s16le',tmp], check=True)
    try:    return load(tmp)
    finally: os.unlink(tmp)

def db(v): return 20*np.log10(max(float(v),1e-9)/32768)

def fingerprint(x, sr):
    r = {'sec': len(x)/sr}
    pk = np.abs(x).max(); rms = np.sqrt((x**2).mean())
    r['peak_db'], r['rms_db'] = db(pk), db(rms)
    r['crest'] = 20*np.log10(pk/max(rms,1e-9))
    r['clip'] = int((np.abs(x) >= 30000).sum())

    env = np.convolve(np.abs(x), np.ones(441)/441, mode='same')
    d = np.abs(np.diff(x))
    idx = np.where((d/np.maximum(env[:-1],1) > 8) & (d > 500))[0]
    groups = 0
    if len(idx):
        groups = 1 + int((np.diff(idx) > 4).sum())     # 4샘플 이내는 한 이벤트
    r['spikes'], r['spikes_s'] = groups, groups/(len(x)/sr)

    L = len(x)//441*441
    frm = x[:L].reshape(-1,441)
    loud = frm[np.sqrt((frm**2).mean(axis=1)) >= np.percentile(np.sqrt((frm**2).mean(axis=1)),90)]
    N = 1024; win = np.hanning(N); s = loud.ravel()
    segs = [s[i:i+N]*win for i in range(0, len(s)-N, N)]
    S = np.mean([np.abs(np.fft.rfft(z))**2 for z in segs], axis=0)
    f = np.fft.rfftfreq(N, 1/sr)
    r['hf_pct'] = 100*S[(f>=2000)&(f<10000)].sum()/S.sum()

    e = np.abs(x[:L]).reshape(-1,441).max(axis=1)
    E = np.abs(np.fft.rfft(e - e.mean())); fe = np.fft.rfftfreq(len(e), 0.01)
    for t in (50, 60):
        i = np.argmin(np.abs(fe - t))
        r[f'rank{t}'] = f"{int((E>E[i]).sum())+1}/{len(E)}"
    return r

def show(rows):
    keys = [('sec','길이 s','%8.1f'), ('peak_db','peak dBFS','%+8.2f'),
            ('rms_db','RMS dBFS','%+8.2f'), ('crest','crest dB','%8.2f'),
            ('clip','|x|>=30000','%8d'), ('spikes','스파이크','%8d'),
            ('spikes_s','스파이크/초','%8.2f'), ('hf_pct','2-10kHz %','%8.2f'),
            ('rank50','50Hz 순위','%>8s'), ('rank60','60Hz 순위','%>8s')]
    names = [n for n,_ in rows]
    print(f"{'':<16}" + "".join(f"{n[:14]:>16}" for n in names))
    print("-"*(16+16*len(names)))
    for k, label, fmt in keys:
        line = f"{label:<16}"
        for _, r in rows:
            v = r[k]
            line += f"{v:>16}" if isinstance(v,str) else f"{(fmt % v):>16}"
        print(line)

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print(__doc__); sys.exit(1)
    rows = [(os.path.basename(p), fingerprint(*load(p))) for p in sys.argv[1:]]
    show(rows)
