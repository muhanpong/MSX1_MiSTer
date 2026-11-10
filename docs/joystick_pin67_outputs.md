# Joystick ports: the R#15 pin 6/7 outputs (not applied, 2026-11-10)

## What the core does now
`rtl/msx.sv` reads the triggers (pins 6/7, PSG R#14 bits 4/5) exactly as the pad gives
them. The PSG R#15 bits that drive pins 6/7 as outputs are ignored:

    joyA = joy_a;   joyB = joy_b;

## Why
- On a real MSX, R#15 bits 0-3 drive pins 6/7 of port A (bits 0, 1) and port B (bits 2, 3)
  through open-collector outputs. Writing 0 pulls the line low, so the trigger reads
  "pressed" (0) whatever the joystick does; 1 releases the line.
- On this core the pad comes from USB. Nothing is wired to pins 6/7 (no paddle, touch pad,
  NinjaTap, mouse), so there is no line for the output to drive; the AND only mattered if
  software pulled pins 6/7 low and then read them, which no supported title does.
- openMSX does not apply it either (the AND in `JoystickPort` is under `#if 0`; it broke
  NinjaTap).
- The AND that was there (inherited 2022, `edfb510` line) had the bits crossed:
  `joy_a & {psg_iob[0], psg_iob[1], 4'b1111}` put the pin 6 output on trigger B (bit 5) and
  the pin 7 output on trigger A (bit 4). WBML V9968, WBML ko V9990 and Knightmare write
  bits 0-3 = 1, so removing it changes nothing for them.

## If a real joystick port is ever wired (e.g. USER_IO instead of MIDI)
Then pins 6/7 are real lines and the outputs matter again: they are also how a paddle, a
touch pad, the JoyMega adapter on some machines or a mouse are clocked. Restore the AND
uncrossed (bit 4 = pin 6, bit 5 = pin 7):

    joyA = joy_a & {psg_iob[1], psg_iob[0], 4'b1111};
    joyB = joy_b & {psg_iob[3], psg_iob[2], 4'b1111};

and, with a real port, drive the pins themselves as open-collector (output 0 -> pin low,
output 1 -> high-Z with pull-up) instead of ANDing a USB value. The note in `rtl/msx.sv`
above `joyA` points here.
