module altddio_out #(parameter extend_oe_disable="OFF", intended_device_family="x",
  invert_output="OFF", lpm_hint="x", lpm_type="x", oe_reg="x", power_up_high="OFF", width=1)
( input datain_h, input datain_l, input outclock, output reg [width-1:0] dataout,
  input aclr, input aset, input oe, input outclocken, input sclr, input sset );
  always @(posedge outclock) dataout <= {width{datain_h}};
endmodule
