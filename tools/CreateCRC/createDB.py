import urllib.request
import struct
import json
import re
from collections import defaultdict

MAPPER_CONFIG_PATH = 'mappers.json'
MAPPERS_OVERRIDE = 'mappersOverride.txt'
OUTPUT_BINARY_PATH = 'vampier.db'
ROMDB_URL = 'https://romdb.vampier.net/Archive//msxcoreromdb.txt'

def parse_line(line):
    parts = re.split(r'\s+', line.strip(), maxsplit=1)
    return parts[0], line

def merge_lines(lines1, lines2):
    merged = {}
    
    for line in lines1:
        crc, full_line = parse_line(line)
        merged[crc] = full_line

    for line in lines2:
        crc, full_line = parse_line(line)
        merged[crc] = full_line

    return list(merged.values())

with open(MAPPER_CONFIG_PATH, 'r', encoding='utf-8') as f:
    mapper_config = json.load(f)

with urllib.request.urlopen(ROMDB_URL) as response:
    lines = response.read().decode('utf-8').strip().splitlines()
    lines = [line + '\n' for line in lines]
    lines = list(set(lines))

with open(MAPPERS_OVERRIDE, "r") as f:
    lines2 = f.readlines()

lines = merge_lines(lines, lines2)
    
with open("mappersSplit.txt", 'w') as f:
    f.writelines(lines)

binary_data = bytearray()
known_mapper_usage = defaultdict(int)
unknown_mapper_usage = defaultdict(int)

for line in lines:
    if not line.strip():
        continue

    parts = line.strip().split(maxsplit=1)
    if len(parts) != 2:
        continue

    crc_str, mapper_name = parts
    try:
        crc32 = int(crc_str, 16)

    except ValueError:
        continue

    if mapper_name in mapper_config:
        values = mapper_config[mapper_name]
        if crc32 == 1055151280 :
            print("NALEZENO")
            print(mapper_name)
            print(values)
            print(mapper_config[mapper_name])
        if len(values) != 4:
            print(f"Error: mapper '{mapper_name}' not 4 parameters.")
            continue
        binary_data.extend(struct.pack('<I', crc32))
        binary_data.extend(struct.pack('4B', *values))
        known_mapper_usage[mapper_name] += 1
    else:
        unknown_mapper_usage[mapper_name] += 1

with open(OUTPUT_BINARY_PATH, 'wb') as f:
    f.write(binary_data)

print("Known mappers:")
max_count_len = max((len(str(count)) for count in known_mapper_usage.values()), default=1)
for mapper, count in sorted(known_mapper_usage.items(), key=lambda x: (-x[1], x[0])):
    print(f"{str(count).rjust(max_count_len)}  {mapper}")

print("\nUnknown mappers:")
max_count_len = max((len(str(count)) for count in unknown_mapper_usage.values()), default=1)
for mapper, count in sorted(unknown_mapper_usage.items(), key=lambda x: (-x[1], x[0])):
    print(f"{str(count).rjust(max_count_len)}  {mapper}")
