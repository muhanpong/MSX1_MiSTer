import os
import hashlib
import shutil

ROM_DIR = 'ROM'
ROM_FOUND_DIR = 'ROM_NALEZENO'
PLATFORM_FILE = 'platform.txt'

# 1. Načti platform.txt a vytvoř mapu SHA1 -> platforma
sha1_to_platform = {}

with open(PLATFORM_FILE, 'r', encoding='utf-8') as f:
    for line in f:
        if not line.strip():
            continue
        parts = line.strip().split(maxsplit=1)
        if len(parts) != 2:
            continue
        sha1, platform = parts
        sha1_to_platform[sha1.lower()] = platform

# 2. Projdi všechny soubory ve složce ROM
if not os.path.isdir(ROM_DIR):
    print(f"Složka '{ROM_DIR}' neexistuje.")
    exit(1)

os.makedirs(ROM_FOUND_DIR, exist_ok=True)

for filename in os.listdir(ROM_DIR):
    filepath = os.path.join(ROM_DIR, filename)
    if not os.path.isfile(filepath):
        continue

    # 3. Spočítej SHA1 hash
    with open(filepath, 'rb') as f:
        data = f.read()
        sha1 = hashlib.sha1(data).hexdigest().lower()

    # 4. Pokud SHA1 odpovídá známé platformě, přesuň soubor
    if sha1 in sha1_to_platform:
        platform_name = sha1_to_platform[sha1]
        target_dir = os.path.join(ROM_FOUND_DIR, platform_name)
        os.makedirs(target_dir, exist_ok=True)

        target_path = os.path.join(target_dir, filename)
        shutil.move(filepath, target_path)
        print(f"Přesunuto: {filename} → {target_dir}")
