// Verilator 4 driver for tb_panasonic: toggle clk until $finish.
#include "Vtb.h"
#include "verilated.h"
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vtb* top = new Vtb;
    top->clk = 0;
    while (!Verilated::gotFinish()) { top->clk = !top->clk; top->eval(); }
    top->final(); delete top; return 0;
}
