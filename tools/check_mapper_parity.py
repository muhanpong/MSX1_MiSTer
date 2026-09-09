#!/usr/bin/env python3
"""package.sv의 mapper_typ_t 열거형과 createMSXpack.py MAPPER_TYPES의 인덱스가
일치하는지 검사한다.  팩 파일은 매퍼를 '리스트 인덱스 숫자'로 기록하므로, 두 목록의
순서가 어긋나면 팩이 조용히 엉뚱한 매퍼를 고른다 -- 컴파일 에러가 안 난다."""
import re, sys, os
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
enum = re.search(r'typedef enum logic \[4:0\] \{(.*?)\} mapper_typ_t',
                 open(root+'/rtl/package.sv').read(), re.S).group(1)
enum = [re.sub(r'/\*.*?\*/', '', x).strip() for x in enum.replace('\n','').split(',')]
pb = re.search(r'MAPPER_TYPES = \[(.*?)\]',
               open(root+'/tools/CreateMSXpack/createMSXpack.py').read(), re.S).group(1)
pb = [x.strip().strip('"') for x in pb.replace('\n','').split(',') if x.strip()]
bad = [(i,a,b) for i,(a,b) in enumerate(zip(enum,pb)) if a != b]
for i,a,b in bad: print(f"MISMATCH idx {i}: enum={a} pack={b}")
print(f"enum {len(enum)} entries, pack {len(pb)} entries, common prefix "
      f"{'OK' if not bad else 'BROKEN'}")
sys.exit(1 if bad else 0)
