import os
import zlib
import struct
import json

MAPPER_FILE = "mappers.json"

# Definujeme vlastní výjimku
class InvalidFileSizeException(Exception):
    pass

def calculate_crc32(file_path):
    """Vypočítá CRC32 kontrolní součet souboru."""
    buf_size = 65536  # Čtení po částech o velikosti 64KB
    crc32 = 0

    with open(file_path, 'rb') as f:
        while chunk := f.read(buf_size):
            crc32 = zlib.crc32(chunk, crc32)

    # Zajistí, že kontrolní součet je ve formátu bez znaménka
    return crc32 & 0xFFFFFFFF

def extract_mapper_name(file_name):
    """Extrahuje název mapperu uzavřený ve hranatých závorkách z názvu souboru."""
    start = file_name.find('[')
    end = file_name.find(']', start)
    if start != -1 and end != -1:
        return file_name[start+1:end]
    return None

def load_existing_mappers(file_path):
    """Načte existující mappery ze souboru, pokud existuje."""
    if os.path.exists(file_path):
        with open(file_path, 'r', encoding='utf-8') as f:
            return json.load(f)
    return {}

def save_mappers_to_file(mappers, file_path):
    """Uloží mappery do souboru s každým mapperem a jeho polem na jednom řádku."""
    with open(file_path, 'w', encoding='utf-8') as f:
        f.write('{\n')
        for i, (mapper_name, values) in enumerate(mappers.items()):
            line = json.dumps({mapper_name: values}, ensure_ascii=False)
            # Odstraníme vnější složené závorky z každého mapperu
            line_content = line[1:-1]
            f.write(f"  {line_content}")
            # Pokud není poslední, přidej čárku
            if i < len(mappers) - 1:
                f.write(',')
            f.write('\n')
        f.write('}\n')

def update_mappers(existing_mappers, new_mapper_names):
    """Aktualizuje existující mappery o nové názvy, pokud jsou nalezeny."""
    # Najde nejvyšší číselnou hodnotu mapperu
    max_index = max([info[0] for info in existing_mappers.values()], default=-1)
    updated = False

    for mapper_name in new_mapper_names:
        if mapper_name not in existing_mappers:
            max_index += 1
            # Přidá nový mapper s první hodnotou jako inkrement a další hodnoty jako 0
            existing_mappers[mapper_name] = [max_index, 0, 0, 0]
            updated = True

    return existing_mappers, updated

def find_files(root_dir, extensions):
    """Rekurzivně vyhledává soubory s danými příponami v kořenovém adresáři."""
    for dirpath, _, filenames in os.walk(root_dir):
        for file in filenames:
            if any(file.endswith(ext) for ext in extensions):
                yield os.path.join(dirpath, file)

def analyze_rom(rom, offset, pages):
    """Analýza souboru"""
   
    # Kontrola podmínek s podobnou logikou
    if offset + 1 < len(rom) and (rom[offset] == ord('A') and rom[offset + 1] == ord('B')):
        offset += 2  # Postup s offsetem podobně jako v C++ kódu
        
        for i in range(4):  # xrange není dostupný, proto range
            if offset + 2 * i + 1 < len(rom):
                addr = rom[offset + 2 * i] + rom[offset + 2 * i + 1] * 256
                if addr:
                    page = (addr >> 14) - (offset >> 14)
                    if 0 <= page <= 2:
                        pages[page] += 1
    

def is_inside(address, window_base, window_size):
    # Kontrola, zda adresa leží uvnitř daného okna paměti.
    return window_base <= address < window_base + window_size

def process_rom(file_name):
    # Načítání obsahu souboru
    with open(file_name, 'rb') as f:
        rom = bytearray(f.read())

    # Inicializace pole pages
    pages = [0, 0, 0]

    # Počet možných ukazatelů rutin
    if len(rom) >= 0x0010:
        analyze_rom(rom, 0x0000, pages)
    if len(rom) >= 0x4010:
        analyze_rom(rom, 0x4000, pages)

    window_base = 0x0000
    window_size = 0x10000
    # Kontrola, zda startovací adresa je uvnitř paměťového okna
    if not is_inside(0x0000, window_base, window_size):
        pages[0] = 0
    if not is_inside(0x4000, window_base, window_size):
        pages[1] = 0
    if not is_inside(0x8000, window_base, window_size):
        pages[2] = 0

    # Preferujeme adresu 0x4000, pak 0x0000 a nakonec 0x8000
    if pages[1] and (pages[1] >= pages[0]) and (pages[1] >= pages[2]):
        return 0x4000
    elif pages[0] and pages[0] >= pages[2]:
        return 0x0000
    elif pages[2]:
        return 0x8000

    # Heuristika nefungovala, vrátíme začátek okna
    return window_base

def redefine_mapper(mapper_name, file_path):
    """Vypočítá dvě hodnoty na základě názvu mapperu a velikosti souboru."""
    file_size = os.path.getsize(file_path)
    
    blocks = file_size // 16384
    if file_size % 16384 :
        blocks = blocks + 1 
    if mapper_name == "auto" or mapper_name == "Normal":
        if file_size > 0x10000 :
            raise InvalidFileSizeException(f"Velikost souboru {file_size} je příliš velká pro mapper {mapper_name}")
        
        start = process_rom(file_path)

        if start == 0x0000:
            return "0x0000"
        if start == 0x4000:
            return "0x4000"
        if start == 0x8000:
            return "0x8000"
        
        raise InvalidFileSizeException(f"Mapper Auto se dostal do nedefinované hodnoty. Velikost souboru {file_size} je příliš velká pro mapper {mapper_name}")
    
    if mapper_name == "basic":
        return "0x8000"

    if mapper_name == "Mirrored4000":
        return "0x4000"
    
    return mapper_name

def process_files(root_dir, existing_mappers):
    """Zpracovává soubory, vypočítává CRC32 a připravuje binární výstup."""
    file_extensions = ['.ROM', '.rom', '.BIN', '.bin']
    new_mapper_names = set()
    file_data = []

    # Najde a zpracuje soubory
    for file_path in find_files(root_dir, file_extensions):
        file_name = os.path.basename(file_path)
        mapper_name = extract_mapper_name(file_name)

        if mapper_name:
            new_mapper_names.add(mapper_name)

        crc32_checksum = calculate_crc32(file_path)
        file_data.append((file_path, file_name, crc32_checksum, mapper_name))

    # Aktualizuje seznam mapperů
    updated_mappers, updated = update_mappers(existing_mappers, new_mapper_names)

    # Připraví binární data
    binary_data = bytearray()
    for file_path, file_name, crc32_checksum, mapper_name in file_data:
        try:
            mapper_name = redefine_mapper(mapper_name, file_path )
            mapper_values = updated_mappers[mapper_name]
            binary_data.extend(struct.pack('<I', crc32_checksum))
            binary_data.extend(struct.pack('B', mapper_values[0]))  # Pouze první hodnota jako ID mapperu
            binary_data.extend(struct.pack('BBB',  mapper_values[1], 0, 0))  
        except InvalidFileSizeException as e:
                print(f"Chyba při zpracování souboru {file_name}: {e}")

    return binary_data, updated_mappers, updated, file_data

def write_binary_file(output_path, binary_data):
    """Zapíše binární data do souboru."""
    with open(output_path, 'wb') as f:
        f.write(binary_data)

# Hlavní část programu
if __name__ == '__main__':
    #root_directory = input("Zadejte kořenový adresář pro vyhledávání: ").strip()
    root_directory = "c:/Project/_OBSAH/ROMS"
    output_file_path = "mappers.db"

    # Načte existující seznam mapperů
    existing_mappers = load_existing_mappers(MAPPER_FILE)

    binary_data, updated_mappers, updated, file_data = process_files(root_directory, existing_mappers)
    write_binary_file(output_file_path, binary_data)

    # Uloží aktualizovaný seznam mapperů, pokud došlo ke změně
    if updated:
        save_mappers_to_file(updated_mappers, MAPPER_FILE)

    print(f"Zpracování dokončeno. Binární data zapsána do {output_file_path}.")
