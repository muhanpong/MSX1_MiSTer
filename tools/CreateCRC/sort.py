import urllib.request
import os
import shutil
import zlib

ROMDB_URL = 'https://romdb.vampier.net/Archive//msxcoreromdb.txt'
ROM_DIR = 'ROM'
ROM_FOUND_DIR = 'ROM_NALEZENO'

# 1. Načti ROM databázi
#with urllib.request.urlopen(ROMDB_URL) as response:
#    lines = response.read().decode('utf-8').strip().splitlines()

with open("mappersSplit.txt", "r") as f:
    lines = f.readlines()

# 2. Vytvoř mapu CRC32 -> mapper
crc_to_mapper = {}
for line in lines:
    if not line.strip():
        continue
    parts = line.strip().split(maxsplit=1)
    if len(parts) != 2:
        continue
    crc_str, mapper = parts
    try:
        crc32 = int(crc_str, 16)
        crc_to_mapper[crc32] = mapper
    except ValueError:
        continue

# 3. Projdi všechny soubory ve složce ROM
if not os.path.isdir(ROM_DIR):
    print(f"Složka '{ROM_DIR}' neexistuje.")
    exit(1)

os.makedirs(ROM_FOUND_DIR, exist_ok=True)

for filename in os.listdir(ROM_DIR):
    filepath = os.path.join(ROM_DIR, filename)
    if not os.path.isfile(filepath):
        continue

    # 4. Spočítej CRC32
    with open(filepath, 'rb') as f:
        data = f.read()
        crc32 = zlib.crc32(data) & 0xFFFFFFFF
    
    # 5. Pokud CRC32 odpovídá známému mapperu, přesuň soubor
    if crc32 in crc_to_mapper:
        mapper_name = crc_to_mapper[crc32]
        target_dir = os.path.join(ROM_FOUND_DIR, mapper_name)
        os.makedirs(target_dir, exist_ok=True)

        target_path = os.path.join(target_dir, filename)
        shutil.move(filepath, target_path)
        print(f"Přesunuto: {filename} → {target_dir}")
