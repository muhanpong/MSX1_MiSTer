module ready (
    input  logic        clk,
    input  logic        reset,
    input  logic        USEL,
    input  logic  [1:0] motor_run,
    output logic        READYn,
    output logic        sides,
    output logic        WPROTn,

    input logic   [1:0] img_mounted,
    input logic   [1:0] img_readonly,
    input logic  [63:0] img_size[2]
);

    logic [1:0] comb_sides;
    logic [1:0] comb_wprotect;
    logic [1:0] comb_enable;

    genvar i;
    generate
        for (i=0; i < 2; i++) begin : IMAGE_READY_I
            always_comb begin    
                if (img_mounted[i]) begin
                    if (img_size[i] == 737280) begin
                        comb_sides[i]    = 1;
                        comb_wprotect[i] = img_readonly[i];
                        comb_enable[i]   = 1;
                    end else 
                    if (img_size[i] == 368640) begin
                        comb_sides[i]    = 0;
                        comb_wprotect[i] = img_readonly[i];
                        comb_enable[i]   = 1;
                    end else begin
                        comb_sides[i]    = 0;
                        comb_wprotect[i] = 1;
                        comb_enable[i]   = 0;
                    end
                end else begin
                    comb_sides[i]    = 0;
                    comb_wprotect[i] = 1;
                    comb_enable[i]   = 0;
                end
            end
        end
    endgenerate

    always_comb begin
        sides    = comb_sides[USEL];
        WPROTn   = !comb_wprotect[USEL];
        READYn   = !(comb_enable[USEL] && motor_run[USEL]);
    end

endmodule
