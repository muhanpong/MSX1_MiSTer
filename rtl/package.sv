typedef enum logic [1:0] {AUTO,PAL,NTSC} video_mode_t;
typedef enum logic {CAS_AUDIO_FILE,CAS_AUDIO_ADC} cas_audio_src_t;
typedef enum logic [3:0] {CONFIG_NONE, CONFIG_FDC, CONFIG_SLOT_A, CONFIG_SLOT_B, CONFIG_SLOT_INTERNAL, CONFIG_KBD_LAYOUT, CONFIG_CONFIG, CONFIG_DEVICE} config_typ_t;
//  4 bits since MU-PACK: the 3-bit type was full.  New values go at the END so the
//  existing ones keep their numbers.
typedef enum logic [3:0] {CART_TYP_ROM, CART_TYP_SCC, CART_TYP_SCC2, CART_TYP_FM_PAC, CART_TYP_MFRSD, CART_TYP_GM2, CART_TYP_FDC, CART_TYP_EMPTY, CART_TYP_MUPACK } cart_typ_t;
typedef enum logic [4:0] {MAPPER_UNUSED, MAPPER_RAM, MAPPER_AUTO, MAPPER_NONE, MAPPER_ASCII8, MAPPER_ASCII16, MAPPER_KONAMI, MAPPER_KONAMI_SCC, MAPPER_KOEI, MAPPER_LINEAR, MAPPER_RTYPE, MAPPER_WIZARDY, /*NEXT INTERNAL*/ MAPPER_FMPAC,MAPPER_OFFSET, MAPPER_MFRSD1,MAPPER_MFRSD2, MAPPER_MFRSD3, MAPPER_GM2, MAPPER_HALNOTE, MAPPER_ASCII16X, MAPPER_YAMANOOTO, MAPPER_NEO8, MAPPER_NEO16, MAPPER_MSXDOS2, MAPPER_TRFDC, MAPPER_PANASONIC, MAPPER_MUPACK} mapper_typ_t;
typedef enum logic [3:0] {DEVICE_NONE, DEVICE_ROM, DEVICE_RAM, DEVICE_FDC,  DEVICE_MFRSD0} device_typ_t;
// What the user put in one subslot of an EXPANDED cart slot (OSD "Sub-slot n").
typedef enum logic [2:0] {SUB_NONE, SUB_ROM, SUB_SCC, SUB_SCC2, SUB_FMPAC, SUB_GM2} subslot_dev_t;
//  data_ID_t IS the FW pack's block ID: createMSXpack.py EXTENSIONS lists the same
//  names in the same order.  Append only.
typedef enum logic [3:0] {ROM_NONE, ROM_ROM, ROM_RAM, ROM_FDC, ROM_FMPAC, ROM_MFRSD, ROM_GM2, ROM_EMPTY, ROM_MOONSOUND, ROM_MUPACK } data_ID_t;
typedef enum logic {MSX1,MSX2} MSX_typ_t;

typedef logic [15:0] dev_typ_t;

/*msx*/
parameter DEV_NONE           = dev_typ_t'(0);
parameter DEV_KANJI          = dev_typ_t'(1 << 0);
parameter DEV_OPL3           = dev_typ_t'(1 << 1);
parameter DEV_RESET_STATUS   = dev_typ_t'(1 << 2);
parameter DEV_MOONSOUND      = dev_typ_t'(1 << 3);
parameter DEV_MATSUSHITA     = dev_typ_t'(1 << 4);   // Panasonic switched I/O 40H/41H (turbo)
parameter DEV_MIDI           = dev_typ_t'(1 << 5);   // FS-A1GT built-in MSX-MIDI: E9h status only
parameter DEV_MIDI_EXT       = dev_typ_t'(1 << 6);   // the MSX-MIDI cartridge: E2h decides the window
/*cart*/
parameter DEV_SCC            = dev_typ_t'(1 << 8);
parameter DEV_SCC2           = dev_typ_t'(1 << 9);
parameter DEV_MFRSD2         = dev_typ_t'(1 << 10);
parameter DEV_FLASH          = dev_typ_t'(1 << 11);
parameter DEV_PSG            = dev_typ_t'(1 << 12);
parameter DEV_MUPACK_RAM     = dev_typ_t'(1 << 13);  // MU-PACK subslot 1: its own 256kB memory mapper

package MSX;
    
    typedef struct {
        MSX_typ_t       typ;
        logic           scandoubler;
        logic           border;
        logic           vdp_id;
        video_mode_t    video_mode;
        cas_audio_src_t cas_audio_src;
        logic           moonsound_en;
        logic           midi_io_en;     // OSD "MIDI": an I/O-only MSX-MIDI at E8h-EFh
    } user_config_t;
    
    typedef struct {
        logic     [3:0] slot_expander_en;   
        MSX_typ_t       MSX_typ;
        logic     [7:0] ram_size;
        logic           use_FDC;
        logic     [7:0] ver;        // BIOS byte 002Dh of the slot 0-0 page-0 ROM: 0 MSX1, 1 MSX2,
                                    // 2 MSX2+, 3 turbo R; FFh until a pack has been read
    } bios_config_t;    
    
    typedef struct {
        logic  [3:0] ref_ram;
        logic  [1:0] ref_sram;
        logic  [1:0] offset_ram;
        mapper_typ_t mapper;
        device_typ_t device;
        logic        cart_num;
        logic        external;
    } block_t;    
    
    typedef struct {
        logic [26:0] addr;
        logic [15:0] size;
        logic        ro;
    } lookup_RAM_t;
    
    //  What device the SRAM belongs to.  nvram_backup keys the image layout on it:
    //  VD0 (slot A ROM .sav) stays raw; the SRAM file on VD1 holds one 64 kB entry
    //  per kind, entry = kind - 1 (docs/sram_images.md).  memory_upload derives it
    //  from the record's mapper and SRAM size; RTC is nvram_backup's own bank 4.
    //  APPEND ONLY, never reuse a number: the kind is the entry's position in users'
    //  SRAM.NVR files, and two devices with one kind overwrite each other's saves.
    parameter logic [7:0] SRAM_KIND_RAW    = 8'd0;   // slot A ROM cart (VD0), or unknown
    parameter logic [7:0] SRAM_KIND_FMPAC  = 8'd1;   // FM-PAC PAC, 8 kB
    parameter logic [7:0] SRAM_KIND_GM2    = 8'd2;   // GameMaster2, 8 kB
    parameter logic [7:0] SRAM_KIND_HALNOTE= 8'd3;   // Sony HB-F1XV Halnote, 16 kB
    parameter logic [7:0] SRAM_KIND_PAN16  = 8'd4;   // Panasonic firmware mapper, 16 kB (FS-A1ST)
    parameter logic [7:0] SRAM_KIND_PAN32  = 8'd5;   // Panasonic firmware mapper, 32 kB (FS-A1GT)
    parameter logic [7:0] SRAM_KIND_RTC    = 8'd6;   // RP5C01 settings memory (blocks 2-3), 1 kB entry

    typedef struct {
        logic [17:0] addr;
        logic [15:0] size;
        logic  [7:0] kind;      // SRAM_KIND_*
    } lookup_SRAM_t;

    typedef struct {
        cart_typ_t    typ;
        mapper_typ_t  selected_mapper;
        logic [7:0]   selected_sram_size;
        // Expanded cart slot.  When set, `typ` is ignored (its menu is hidden) and
        // each of the four subslots carries subslot_dev[n].  See cart_confDecoder.
        logic         expanded;
        subslot_dev_t subslot_dev[4];
    } config_cart_t;
        
endpackage