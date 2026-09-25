import os
import hashlib
import xml.etree.ElementTree as ET
import base64


ROM_DIR = 'ROM'
XML_DIR_COMP = 'Computer'
XML_DIR_FW = 'Extension'
EXTENSIONS  =  ["NONE"          , "ROM"           , "RAM"          , "FDC"              , 
                "FM_PAC"        , "MEGA_FLASH_ROM", "GM2"          , "EMPTY"            ,
                "MOONSOUND"     ]

MEM_DEVICE  =  ["NONE"          , "ROM"           , "RAM"          , "FDC"               ]

DEVICE_TYPES = ["NONE"          , "KANJI"         , "OPL3"         , "RESET_STATUS"      , "MOONSOUND", "MATSUSHITA"    , "MIDI"     ,
                "MIDI_EXT"]

CONFIG_TYPES = ["NONE"          , "FDC"           , "SLOT_A"       , "SLOT_B"           ,
                "SLOT_INTERNAL" , "KBD_LAYOUT"    , "CONFIG"       , "DEVICE"            ]
MAPPER_TYPES = ["MAPPER_UNUSED" , "MAPPER_RAM"    , "MAPPER_AUTO"  , "MAPPER_NONE"      ,
                "MAPPER_ASCII8" , "MAPPER_ASCII16", "MAPPER_KONAMI", "MAPPER_KONAMI_SCC",
                "MAPPER_KOEI"   , "MAPPER_LINEAR" , "MAPPER_RTYPE" , "MAPPER_WIZARDY"   ,
                "MAPPER_FMPAC"  , "MAPPER_OFFSET" , "MAPPER_MFRSD1", "MAPPER_MFRSD2"    ,
                "MAPPER_MFRSD3" , "MAPPER_GM2"    , "MAPPER_HALNOTE", "MAPPER_ASCII16X"  ,
                "MAPPER_YAMANOOTO", "MAPPER_NEO8" , "MAPPER_NEO16" , "MAPPER_MSXDOS2"   ,
                "MAPPER_TRFDC"  , "MAPPER_PANASONIC" ]
MSX_TYPES    = ["MSX1", "MSX2"]

BLOCK_TYPES = {"NONE"       : {"MEMORY": "NONE", "DEVICE" : "NONE" , "MAPPER" : "MAPPER_UNUSED" , "CONFIG" : "NONE"         , "SRAM": 0  },
               "RAM"        : {"MEMORY": "RAM" , "DEVICE" : "NONE" , "MAPPER" : "MAPPER_NONE"   , "CONFIG" : "SLOT_INTERNAL", "SRAM": 0  },
               "RAM MAPPER" : {"MEMORY": "RAM" , "DEVICE" : "NONE" , "MAPPER" : "MAPPER_RAM"    , "CONFIG" : "SLOT_INTERNAL", "SRAM": 0  },
               "ROM"        : {"MEMORY": "ROM",  "DEVICE" : "NONE" , "MAPPER" : "MAPPER_NONE"   , "CONFIG" : "SLOT_INTERNAL", "SRAM": 0  },
               "FDC"        : {"MEMORY": "FDC" , "DEVICE" : "NONE" , "MAPPER" : "MAPPER_NONE"   , "CONFIG" : "SLOT_INTERNAL", "SRAM": 0  },
               "SLOT A"     : {"MEMORY": "ROM" , "DEVICE" : "NONE" , "MAPPER" : "MAPPER_UNUSED" , "CONFIG" : "SLOT_A"       , "SRAM": 0  },
               "SLOT B"     : {"MEMORY": "ROM" , "DEVICE" : "NONE" , "MAPPER" : "MAPPER_UNUSED" , "CONFIG" : "SLOT_B"       , "SRAM": 0  },
               "KBD LAYOUT" : {"MEMORY": "NONE", "DEVICE" : "NONE" , "MAPPER" : "MAPPER_UNUSED" , "CONFIG" : "KBD_LAYOUT"   , "SRAM": 0  },
               "ROM_MIRROR" : {"MEMORY": "NONE", "DEVICE" : "NONE" , "MAPPER" : "MAPPER_NONE"   , "CONFIG" : "SLOT_INTERNAL", "SRAM": 0  },
               "IO_MIRROR"  : {"MEMORY": "NONE", "DEVICE" : "NONE" , "MAPPER" : "MAPPER_UNUSED" , "CONFIG" : "SLOT_INTERNAL", "SRAM": 0  },
               "MIRROR"     : {"MEMORY": "NONE", "DEVICE" : "NONE" , "MAPPER" : "MAPPER_NONE"   , "CONFIG" : "SLOT_INTERNAL", "SRAM": 0  },
               "HALNOTE"    : {"MEMORY": "ROM" , "DEVICE" : "NONE" , "MAPPER" : "MAPPER_HALNOTE", "CONFIG" : "SLOT_INTERNAL", "SRAM": 16 },
               "ASCII8"     : {"MEMORY": "ROM" , "DEVICE" : "NONE" , "MAPPER" : "MAPPER_ASCII8" , "CONFIG" : "SLOT_INTERNAL", "SRAM": 0  },
               "MSX-MUSIC"  : {"MEMORY": "ROM" , "DEVICE" : "OPL3" , "MAPPER" : "MAPPER_NONE"   , "CONFIG" : "SLOT_INTERNAL", "SRAM": 0  },
               "MSXDOS2"    : {"MEMORY": "ROM" , "DEVICE" : "NONE" , "MAPPER" : "MAPPER_MSXDOS2", "CONFIG" : "SLOT_INTERNAL", "SRAM": 0  },
               # turbo R disk ROM block: 64 kB (4 x 16 kB) DOS 2 kernel banked by a write to
               # 7FF0h, WITH the WD2793 register set at 7FF8-7FFF in the same page (Sony
               # layout, as the FDC block).  Carries the synthesized ROM from
               # tools/turbor_diskrom (DOS 2.30/2.31 kernel + hb-f1xd WD2793 driver).
               "TURBOR_FDC" : {"MEMORY": "FDC" , "DEVICE" : "NONE" , "MAPPER" : "MAPPER_TRFDC"  , "CONFIG" : "SLOT_INTERNAL", "SRAM": 0  },
               # turbo R slot 3-3: the firmware ROM behind the Panasonic 8 kB-region
               # mapper, with its battery SRAM.  Two entries because the SRAM size
               # differs per machine (openMSX <sramsize>: ST 16, GT 32).
               "PANASONIC16": {"MEMORY": "ROM" , "DEVICE" : "NONE" , "MAPPER" : "MAPPER_PANASONIC", "CONFIG" : "SLOT_INTERNAL", "SRAM": 16 },
               "PANASONIC32": {"MEMORY": "ROM" , "DEVICE" : "NONE" , "MAPPER" : "MAPPER_PANASONIC", "CONFIG" : "SLOT_INTERNAL", "SRAM": 32 },
               }

def file_hash(filename):
    """Return the SHA1 hash of the file at `filename`."""
    with open(filename, 'rb') as f:
        return hashlib.sha1(f.read()).hexdigest()

def get_msx_type_id(typ):
    """Return the index of the given MSX type."""
    return MSX_TYPES.index(typ)


def create_MSX_block(primary, secondary, values):
    slotSubslot = ((int(primary) & 3) << 2) | ((int(secondary) & 3))
    head = bytearray()
    head.extend('MSX'.encode('ascii'))
    
    config = BLOCK_TYPES[values["type"]]
    head.append(CONFIG_TYPES.index(config['CONFIG']) << 4 | slotSubslot)
    
    mem_device = config['MEMORY']
    if values["type"] in ["IO_MIRROR", "MIRROR"] :
        mem_device = BLOCK_TYPES[values['ref']['type']]["MEMORY"]
    head.append(MEM_DEVICE.index(mem_device))
    if config['MEMORY'] == "NONE" :
        head.append(0x00)
        head.append(0x00)
    else :
        head.append((int(values['count']) >> 8) & 255)
        head.append(int(values['count']) & 255)
    
    device = config['DEVICE']
    if device != "NONE" :
        head.append(DEVICE_TYPES.index(device) - 1)
    else :
        head.append(0xFF)
    head.append(MAPPER_TYPES.index(config['MAPPER']))

    mode = 0x00
    param = 0x00

    if "start" in values :
        block = values['start']
        offset = 0
        for i in range(0,4) if values['count'] > 4 else range(values['count']) :
            if values["type"] in ["ROM_MIRROR", "MIRROR"] :
                mode  |= 1 << (2*block)
                param |= ((values["ref"]["start"] + i) & 3) << (2*block)
            elif values["type"] in ["IO_MIRROR"] :
                mode  |= 3 << (2*block)
            elif config['MAPPER'] != "MAPPER_UNUSED" :
                mode  |= 2 << (2*block)
                param |= offset << (2*block)
            elif config['DEVICE'] != "NONE" :
                mode |= 3 << (2*block)
            block  = (block + 1) & 3
            offset = (offset + 1) & 3
        head.append(mode)
        head.append(param)
        head.append(values["pattern"])
        head.append(config['SRAM'])

    for i in range(len(head),16) :
        head.append(0)
    return head

def create_MSX_config(config) :
    
    head = bytearray()
    head.extend('MSX'.encode('ascii'))
    head.append(CONFIG_TYPES.index("CONFIG") << 4)
    head.append(config)
    for i in range(len(head),16) :
        head.append(0)
    return head

def create_MSX_device(typ, size) :
    head = bytearray()
    head.extend('MSX'.encode('ascii'))
    head.append(CONFIG_TYPES.index("DEVICE") << 4)
    head.append(0x00)
    head.append((size >> 8) & 255)
    head.append(size & 255)
    head.append(DEVICE_TYPES.index(typ) - 1)
    for i in range(len(head),16) :
        head.append(0)
    return head

def sha_list(node) :
    """Accepted SHA-1s for one entry.  Several <SHA1> elements may be listed when more
    than one dump is usable (different revisions of the same firmware image); the first
    one that is actually in the ROM store wins, so the choice is deterministic.
    <sha1> is accepted as well because the device entries spell it lowercase."""
    out = []
    for tag in ('SHA1', 'sha1') :
        for e in node.findall(tag) :
            if e.text is not None and e.text.strip() and e.text.strip() not in out :
                out.append(e.text.strip())
    return out


def pick_sha(hashes) :
    """The first accepted SHA-1 present in the store, else None."""
    for h in hashes :
        if h in rom_hashes :
            return h
    return None


def create_FW_block(type, size):
    """Create and return a bytearray representing a block."""
    head = bytearray()
    head.extend('MSX'.encode('ascii'))
    head.append(0)
    head.append(type)
    head.append(size >> 8)
    head.append(size & 255)
    for i in range(len(head),16) :
        head.append(0)
    return head

def createFWpack(root, fileHandle) :
    try :
        for fw in root.findall("./fw"):
            fw_name = fw.attrib["name"]
            fw_filename = fw.find('filename').text if fw.find('filename') is not None else None
            fw_SHA1s = sha_list(fw)
            fw_SHA1 = pick_sha(fw_SHA1s)
            fw_size = int(fw.find('size').text) if fw.find('size') is not None else None
            fw_skip = int(fw.find('skip').text) if fw.find('skip') is not None else None
            if fw_name in EXTENSIONS :
                typ = EXTENSIONS.index(fw_name)
                if fw_SHA1s :
                    if fw_SHA1 is not None :
                        inFileName = rom_hashes[fw_SHA1]
                        fileSize = os.path.getsize(inFileName)
                        size = fw_size if fw_size is not None else fileSize
                        head = create_FW_block(typ, size  >> 14)
                        fileHandle.write(head)
                        infile = open(inFileName, "rb")
                        if fw_skip is not None :
                            infile.seek(fw_skip, os.SEEK_SET)
                        if fw_size is not None :
                            fileHandle.write(infile.read(size))
                        else :
                            fileHandle.write(infile.read())
                        if size > fileSize :
                            fileHandle.write(bytes([0xFF] * (size - fileSize)))
                    else :
                        fileHandle.close()
                        raise Exception(f"Skip: {filename} Not found ROM {fw_filename} SHA1:{'/'.join(fw_SHA1s)}")
        fileHandle.close()
        return False
    except Exception as e:
        print(e)
        return True

def getRefereced(secondary, reference) :
    block = secondary.find((f'.//block[@start="{reference}"]'))
    return getValues(block, None)

def getValues(block, secondary) :
    values = {}
    values['start']    = int(block.attrib["start"]) & 3
    values['type']     = block.find('type').text if block.find('type') is not None else None
    values['count']    = int(block.find('block_count').text) if block.find('block_count') is not None else 0
    values['filename'] = block.find('filename').text if block.find('filename') is not None else None
    values['SHA1S']    = sha_list(block)
    values['SHA1']     = pick_sha(values['SHA1S'])
    values['pattern']  = int(block.find('pattern').text) if block.find('pattern') is not None else 3 
    values['skip']     = int(block.find('skip').text) if block.find('skip') is not None else None 
    if secondary is not None and block.find('ref') is not None :
        values['ref'] = getRefereced(secondary, block.find('ref').text)

    return (values)

def createMSXpack(root, fileHandle) :
    config = 0x00
    try :
        heads = []
        msx_type_value = None
        msx_type = root.find('type')
        if msx_type is not None:
            msx_type_value = msx_type.text
        for primary in root.findall("./primary"):
            primary_slot = primary.attrib["slot"]
            for secondary in primary.findall("./secondary"):
                secondary_slot = secondary.attrib["slot"]
                for block in secondary.findall("./block"):
                    block_ref = block.find('ref').text if block.find('ref') is not None else None
                    values = getValues(block, secondary)
                    head = create_MSX_block(primary_slot, secondary_slot, values) 
                    #print(' '.join([f'{byte:02X}' for byte in head[3:15]]) + " {0}/{1} ".format(primary_slot, secondary_slot) + str(values))
                    if block_ref is None :
                        fileHandle.write(head)                      
                        if values["SHA1S"] :
                            if values["SHA1"] is not None :
                                infile = open(rom_hashes[values["SHA1"]], "rb")
                                if values["skip"] is not None :
                                    infile.seek(values["skip"], os.SEEK_SET)
                                write_size = fileHandle.write(infile.read(values['count'] * 16 * 1024))
                                if write_size < values['count'] * 16 * 1024 :
                                    fileHandle.write(bytes([0xFF] * (values['count'] * 16 * 1024 - write_size)))
                                infile.close()
                            else :
                                fileHandle.close()
                                raise Exception(f"Skip: {filename} Not found ROM {0} SHA1:{1}",values["filename"],'/'.join(values["SHA1S"]))
                    else :
                        heads.append(head)
                if int(secondary_slot) > 0 :
                    config = config | (0x1 << int(primary_slot))            
        for head in heads :             
            fileHandle.write(head)
        
        for device in root.findall("./device"):
            device_typ = device.attrib["typ"]
            rom = device.find("./rom")
            rom_size = 0
            if rom is not None:
                rom_name = rom.find('filename').text if rom.find('filename') is not None else None
                rom_SHA1 = pick_sha(sha_list(rom))
                if rom_SHA1 is not None:
                        rom_size = os.path.getsize(rom_hashes[rom_SHA1]) >> 14
                        
            head = create_MSX_device(device_typ, rom_size);
            fileHandle.write(head)
            if rom_size > 0 :
                infile = open(rom_hashes[rom_SHA1], "rb") 
                fileHandle.write(infile.read())
                infile.close()

        kbd_layout = root.find('kbd_layout')
        if kbd_layout is not None:
            values = {'type':"KBD LAYOUT", 'count':0}           
            head = create_MSX_block(0,0,values) 
            #print(' '.join([f'{byte:02X}' for byte in head[3:15]]) + " -/- " + str(values))
            fileHandle.write(head)
            fileHandle.write(base64.b64decode(kbd_layout.text))
        
        config = config | ((get_msx_type_id(msx_type_value) & 0x3) << 4)
        head = create_MSX_config(config)
        #print(' '.join([f'{byte:02X}' for byte in head[3:15]]))
        fileHandle.write(head)
        fileHandle.close()
        return False
    except Exception as e:
        print(e)
        return True

# Traverse the XML directory and create blocks for each XML file
def parseDir(dir) :
    for dirpath, dirnames, filenames in os.walk(dir):
        for filename in filenames:
            if filename.endswith('.xml'):
                filepath = os.path.join(dirpath, filename)
                filename_without_extension, extension = os.path.splitext(filename)
                print(filepath)
                dir_save = "MSX" + dirpath[len(dir):]
                output_filename = os.path.join(dir_save, filename_without_extension) + ".MSX"
                if not os.path.exists(dir_save):
                    os.makedirs(dir_save)

                tree = ET.parse(filepath)
                root = tree.getroot()
                outfile = open(output_filename, "wb")               
                print(output_filename)
                error = True
                if root.tag == "msxConfig" :
                    error = createMSXpack(root, outfile)
                if root.tag == "fwConfig" :
                    error = createFWpack(root, outfile)
                if error :
                    outfile.close()
                    os.remove(output_filename)


# Traverse the ROM directory and save the hashes of the files in a dictionary
rom_hashes = {}
for dirpath, dirnames, filenames in os.walk(ROM_DIR):
    for filename in filenames:
        filepath = os.path.join(dirpath, filename)
        rom_hashes[file_hash(filepath)] = filepath


parseDir(XML_DIR_COMP)
parseDir(XML_DIR_FW)

            

                
