# buildgate — the build that cannot pass by not running

`tools/buildgate/build.sh [--expect <fit.rpt substring>]... [--signoff-only]`

What it enforces (each line is a lesson that cost a build or a day, see
docs/az80_migration_20260913.md §6):

| check | lesson |
|---|---|
| Quartus volume mounted, else refuse | reboot unmounted it; `tail` hid "command not found" for 3 builds |
| per-stage rc / elapsed / artifact time | never pipe a build through `tail` |
| fit < 3 min → warn | smart recompile skips the fit on qsf-only edits; results are stale |
| `--expect` instance present in fit.rpt | new module pruned or not in the qip |
| LogicLock unlicensed warning | Lite drops LL regions silently |
| two-corner signoff with `read_sdc` per model | a fast netlist without it is unconstrained (fake −40 ns hold) |
| clock-pair relationship assertions | a multicycle can move the check off the real capture edge |
| newly ignored SDC lines | a constraint that stopped matching hides violations |

Related harnesses: `sim/run_az80.sh` (CPU benches incl. the ch2 latency bench
with its negative control), `tools/dump_aztrace.tcl` + `tools/parse_aztrace.py`
(JTAG bus trace ring, rtl/cpu/az80/az80_trace.sv).
