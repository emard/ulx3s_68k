module vram (
  input            clk_a,
  input            we_a,
  input            re_a,
  input [14:1]     addr_a,
  input [15:0]      din_a,
  output reg [7:0] dout_a,
  input            ub_a,
  input            lb_a,
  input            clk_b,
  input [14:0]     addr_b,
  output reg [7:0] dout_b

);

  reg [7:0] ram_ub [0:16383];
  reg [7:0] ram_lb [0:16383];

  always @(posedge clk_a) begin
    if (we_a) begin
      if (ub_a) ram_ub[addr_a] <= din_a[15:8];
      if (lb_a) ram_lb[addr_a] <= din_a[7:0];
    end
    if (re_a) dout_a <= {ram_ub[addr_a], ram_lb[addr_a]};
  end

  always @(posedge clk_b) begin
    if (addr_b[0]) dout_b <= ram_ub[addr_b[14:1]];
    else dout_b <= ram_lb[addr_b[14:1]];
  end

endmodule
