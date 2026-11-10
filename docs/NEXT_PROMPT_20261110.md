Continue the MSX1 MiSTer work from docs/handoff_20261110_packforge_joymega.md
(worktree ~/data/MiSTer_build/MSX1_MiSTer, branch nextz80). Report to me in Korean.

Read the handoff first. Nothing from the last session is pushed. Ask me before you push,
and ask before any board run (hardware tests are expensive).

Waiting on my decisions:
1. Push the Pack Forge commits on nextz80, nextz80_v9990, V9968_Geo3D, opl4_scratch.
2. JoyMega: apply the prototype in /data/_claude/tmp/4091ee2a/jm/fix (edge-only stepping +
   OSD 3/6-button), and choose for the crossed trigger AND (drop it like openMSX, or uncross it).
3. Tell knightmare-v2 that WBML V9968 applies MODE on the title/menus too (V9990 only in a game)?
4. V9990: full BSD-3 text in the Readme; ADVN/PSET; interlace; the upload guard; the
   B4/B7/B5/B6 output path.
5. The board checks listed in section 4 of the handoff.

Before changing Pack Forge again, run tools/CreateMSXpack/test_packbuilder.sh (and with
PACK_FW_SUBST=1) and keep both PASS.
