const fs=require('fs'), C=require('./core.js');
const ROM="/run/media/muhanpong/NewElements12TB/Games/셀리카님_한글화/Golvellius2/patched/GOLVE2_KR.ROM";
const SRAM="/home/muhanpong/.openMSX/persistent/roms/GOLVE2_KR.ROM/GOLVE2_KR.ROM.SRAM";
const rom=new Uint8Array(fs.readFileSync(ROM)), img=new Uint8Array(fs.readFileSync(SRAM));
let fail=0; const ok=(n,c)=>{console.log((c?"  PASS  ":"  FAIL  ")+n); if(!c)fail++;};

// --- EXTRACT ---
const base=C.paddedBase(rom); const dirty=[];
for(let i=0;i<C.NBLOCKS;i++) if(C.blockDiffers(base,img,i)) dirty.push(i);
console.log("dirty blocks:",dirty.join(","));
const sav=C.buildSav(img,dirty);
const ref=new Uint8Array(fs.readFileSync('GOLVE2_KR.sav'));
ok("app .sav == python reference (byte-identical)", Buffer.compare(Buffer.from(sav),Buffer.from(ref))===0);
ok("size 131,584", sav.length===131584);

// --- header re-parse ---
const p=C.parseSav(sav);
ok("parseSav round-trips the bitmap", !p.error && p.dirty.join()===dirty.join());
ok("mode byte 0x02", p.mode===0x02);

// --- APPLY (reverse) ---
const rebuilt=C.paddedBase(rom);
p.dirty.forEach((b,n)=>rebuilt.set(sav.subarray(C.SECTOR+n*C.BLOCK,C.SECTOR+(n+1)*C.BLOCK), b*C.BLOCK));
ok("apply(.sav) == original openMSX SRAM", Buffer.compare(Buffer.from(rebuilt),Buffer.from(img))===0);

// --- negative controls ---
const bad=sav.slice(); bad[0]^=0xFF;
ok("bad magic rejected", !!C.parseSav(bad).error);
const trunc=sav.slice(0,sav.length-10);
ok("size mismatch rejected", !!C.parseSav(trunc).error);
ok("short file rejected", !!C.parseSav(new Uint8Array(100)).error);
const noSave=C.paddedBase(rom); const none=[];
for(let i=0;i<C.NBLOCKS;i++) if(C.blockDiffers(base,noSave,i)) none.push(i);
ok("identical image -> zero dirty blocks", none.length===0);

// --- real core-written .sav from the board ---
if(fs.existsSync('ff_hdr.bin')){
  const hdr=new Uint8Array(fs.readFileSync('ff_hdr.bin'));
  const full=new Uint8Array(512+65536); full.set(hdr);
  const q=C.parseSav(full);
  ok("board's Final Fantasy header parses, block 13", !q.error && q.dirty.join()==="13");
}
console.log(fail? `\n${fail} FAILED` : "\nall checks passed");
process.exit(fail?1:0);
