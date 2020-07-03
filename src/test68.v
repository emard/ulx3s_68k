`default_nettype none
module test68
#(
  parameter c_sdram       = 0, // 1:SDRAM, 0:BRAM 32K
  parameter c_vga_out     = 0, // 0; Just HDMI, 1: VGA and HDMI
  parameter c_diag        = 1  // 0: No led diagnostcs, 1: led diagnostics 
)
(
  input         clk25_mhz,
  // Buttons
  input [6:0]   btn,
  // Switches
  input [3:0]   sw,
  // HDMI
  output [3:0]  gpdi_dp,
  // Keyboard
  output        usb_fpga_pu_dp,
  output        usb_fpga_pu_dn,
  inout         ps2Clk,
  inout         ps2Data,
  // Audio
  output [3:0]  audio_l,
  output [3:0]  audio_r,
  // ESP32 passthru
  input         ftdi_txd,
  output        ftdi_rxd,
  input         wifi_txd,
  output        wifi_rxd,  // SPI from ESP32
  input         wifi_gpio16,
  input         wifi_gpio5,
  output        wifi_gpio0,

  inout  sd_clk, sd_cmd,
  inout   [3:0] sd_d,
  output sdram_csn,       // chip select
  output sdram_clk,       // clock to SDRAM
  output sdram_cke,       // clock enable to SDRAM
  output sdram_rasn,      // SDRAM RAS
  output sdram_casn,      // SDRAM CAS
  output sdram_wen,       // SDRAM write-enable
  output [12:0] sdram_a,  // SDRAM address bus
  output  [1:0] sdram_ba, // SDRAM bank-address
  output  [1:0] sdram_dqm,// byte select
  inout  [15:0] sdram_d,  // data bus to/from SDRAM
  inout  [27:0] gp,gn,
  // Leds
  output [7:0]  leds
);

  // ===============================================================
  // System Clock generation
  // ===============================================================
  wire clk_sdram_locked;
  wire [3:0] clocks;

  ecp5pll
  #(
      .in_hz( 25*1000000),
    .out0_hz(125*1000000),
    .out1_hz( 25*1000000),
    .out2_hz(100*1000000),                // SDRAM core
    .out3_hz(100*1000000), .out3_deg(180) // SDRAM chip 45-330:ok 0-30:not
  )
  ecp5pll_inst
  (
    .clk_i(clk25_mhz),
    .clk_o(clocks),
    .locked(clk_sdram_locked)
  );

  wire clk_hdmi  = clocks[0];
  wire clk_vga   = clocks[1];
  wire cpuClock  = clocks[1];
  wire clk_sdram = clocks[2];
  wire sdram_clk = clocks[3]; // phase shifted for chip

  // ===============================================================
  // Reset generation
  // ===============================================================
  reg [15:0] pwr_up_reset_counter = 0;
  wire       pwr_up_reset_n = &pwr_up_reset_counter;

  always @(posedge clk25_mhz) begin
     if (!pwr_up_reset_n)
       pwr_up_reset_counter <= pwr_up_reset_counter + 1;
  end

  // Pull-ups for us2 connector
  assign usb_fpga_pu_dp = 1;
  assign usb_fpga_pu_dn = 1;

  // Passthru to ESP32 micropython serial console
  assign wifi_rxd = ftdi_txd;
  assign ftdi_rxd = wifi_txd;

  wire   [7:0]  red;
  wire   [7:0]  green;
  wire   [7:0]  blue;
  wire          hSync;
  wire          vSync;

  // ===============================================================
  // Optional VGA output
  // ===============================================================
  generate
    genvar i;
    if (c_vga_out) begin
      for(i = 0; i < 4; i = i+1) begin
        assign gp[10-i] = red[4+i];
        assign gn[3-i] = green[4+i];
        assign gn[10-i] = blue[4+i];
      end
      assign gp[2] = vSync;
      assign gp[3] = hSync;
    end
  endgenerate

  // ===============================================================
  // Diagnostic leds
  // ===============================================================
  reg [15:0] diag16;

  generate
    genvar i;
    if (c_diag) begin
      for(i = 0; i < 4; i = i+1) begin
        assign gn[17-i] = diag16[8+i];
        assign gp[17-i] = diag16[12+i];
        assign gn[24-i] = diag16[i];
        assign gp[24-i] = diag16[4+i];
      end
    end
  endgenerate

  // ===============================================================
  // 68000 CPU
  // ===============================================================
  reg  fx68_phi1;                // Phi 1 enable
  //reg  fx68_phi2;                // Phi 2 enable
  wire fx68_phi2 = !fx68_phi1;
  wire cpu_rw;                   // Read = 1, Write = 0
  wire cpu_as_n;                 // Address strobe
  wire cpu_lds_n;                // Lower byte
  wire cpu_uds_n;                // Upper byte
  wire cpu_E;                    // Peripheral enable
  wire vma_n;                    // Valid memory address
  reg  vpa_n = 1'b0;             // Valid peripheral address
  wire cpu_fc0;                  // Processor state
  wire cpu_fc1;
  wire cpu_fc2;
  reg  berr_n = 1'b0;            // Bus error. nextpnr fails if this is set to 1
  wire cpu_reset_n_o;            // Reset output signal
  reg  dtack_n = 1'b0;           // Data transfer ack (ready)
  reg  mcu_br_n;                 // Bus request
  wire bg_n;                     // Bus grant
  reg  bgack_n = 1'b1;           // Bus grant ack
  reg  ipl0_n = 1'b1;            // Interrupt request signals
  reg  ipl1_n = 1'b1;
  reg  ipl2_n = 1'b1;
  wire [15:0] ramOut;
  wire [15:0] cpu_din = ramOut;  // Data to CPU
  wire [15:0] cpu_dout;          // Data from CPU
  wire [23:1] cpu_a;             // Address
  reg  halt_n = 1'b1;            // Halt request

  reg [23:0] delay_cnt;
  always @(posedge clk25_mhz) delay_cnt <= delay_cnt + 1;

  // Run 68k cpu very slowly
  always @(posedge clk25_mhz) begin
    //fx68_phi1 <= delay_cnt == 0;
    //fx68_phi2 <= delay_cnt == 24'h80000;
    fx68_phi1 <= ~fx68_phi1;
  end

  fx68k fx68k (
    // input
    .clk( clk25_mhz),
    .HALTn(1'b1),
    .extReset(!btn[0] || !pwr_up_reset_n),
    //.pwrUp(!pwr_up_reset_n), // nextpnr fails timing analysis with this
    .pwrUp(1'b0),
    .enPhi1(fx68_phi1),
    .enPhi2(fx68_phi2),
    // output
    .eRWn(cpu_rw),
    .ASn( cpu_as_n),
    .LDSn(cpu_lds_n),
    .UDSn(cpu_uds_n),
    .E(cpu_E),
    .VMAn(vma_n),
    .FC0(cpu_fc0),
    .FC1(cpu_fc1),
    .FC2(cpu_fc2),
    .BGn(bg_n),
    .oRESETn(cpu_reset_n_o),
    .oHALTEDn(),
    // input
    .DTACKn(dtack_n),
    .VPAn(vpa_n),
    .BERRn(berr_n),
    .BRn(1'b1),       // No bus requests
    .BGACKn(1'b0),
    .IPL0n(ipl0_n),
    .IPL1n(ipl1_n),
    .IPL2n(ipl2_n),
    .iEdb(cpu_din),
    // output
    .oEdb(cpu_dout),
    .eab(cpu_a)
  );

  // ===============================================================
  // SDRAM
  // ===============================================================
  wire sdram_d_wr;
  wire [15:0] sdram_d_in;
  wire [15:0] sdram_d_out;
  assign sdram_d = sdram_d_wr ? sdram_d_out : 16'hzzzz;
  assign sdram_d_in = sdram_d;
  generate
  if(c_sdram)
  sdram
  sdram_i
  (
   .sd_data_in(sdram_d_in),
   .sd_data_out(sdram_d_out),
   .sd_addr(sdram_a),
   .sd_dqm(sdram_dqm),
   .sd_cs(sdram_csn),
   .sd_ba(sdram_ba),
   .sd_we(sdram_wen),
   .sd_ras(sdram_rasn),
   .sd_cas(sdram_casn),
   // system interface
   .clk(clk_sdram),
   .clkref(fx68_phi1),
   .init(!clk_sdram_locked),
   .we_out(sdram_d_wr),
   // cpu/chipset interface
   .weA(!cpu_rw),
   .addrA(cpu_a),
   .oeA(cpu_rw),
   .dinA(cpu_dout),
   .doutA(ramOut),
   // SPI interface
   .weB(spi_ram_wr && spi_ram_addr[31:24] == 8'h00),
   .addrB(spi_ram_addr[23:0]),
   .dinB(spi_ram_di),
   .oeB(0),
   .doutB()
  );
  else
  gamerom #(.MEM_INIT_FILE("../roms/test.mem")) 
  rom16 (
    .clk(clk25_mhz),
    .we_b(spi_ram_wr && spi_ram_addr[31:24] == 8'h00), // used by OSD
    .addr_b(spi_ram_addr[14:0]),
    .din_b(spi_ram_di),
    .addr(cpu_a),
    .dout(ramOut)
  );
  endgenerate

  // ===============================================================
  // Joystick for OSD control and games
  // ===============================================================
  reg [6:0] R_btn_joy;
  always @(posedge clk25_mhz)
    R_btn_joy <= btn;

  // ===============================================================
  // SPI Slave for RAM and CPU control
  // ===============================================================
  wire        spi_ram_wr, spi_ram_rd;
  wire [31:0] spi_ram_addr;
  wire  [7:0] spi_ram_di;
  wire  [7:0] spi_ram_do = ramOut;

  assign sd_d[0] = 1'bz;
  assign sd_d[3] = 1'bz; // FPGA pin pullup sets SD card inactive at SPI bus

  wire irq;
  
  spi_ram_btn
  #(
    .c_sclk_capable_pin(1'b0),
    .c_addr_bits(32)
  )
  spi_ram_btn_inst
  (
    .clk(clk25_mhz),
    .csn(~wifi_gpio5),
    .sclk(wifi_gpio16),
    .mosi(sd_d[1]), // wifi_gpio4
    .miso(sd_d[2]), // wifi_gpio12
    .btn(R_btn_joy),
    .irq(irq),
    .wr(spi_ram_wr),
    .rd(spi_ram_rd),
    .addr(spi_ram_addr),
    .data_in(spi_ram_do),
    .data_out(spi_ram_di)
  );
  
  // Used for interrupt to ESP32
  assign wifi_gpio0 = ~irq;

  // ===============================================================
  // Keyboard
  // ===============================================================
  wire [10:0] ps2_key;

  // Get PS/2 keyboard events
  ps2 ps2_kbd (
     .clk(clk25_mhz),
     .ps2_clk(ps2Clk),
     .ps2_data(ps2Data),
     .ps2_key(ps2_key)
  );

  // ===============================================================
  // VGA
  // ===============================================================
  wire [14:0] vid_addr;
  wire [7:0] vid_out;
  reg [14:0] vga_addr = 0;
  reg        vga_wr = 0;
  reg        vga_rd = 0;
  wire [7:0] vga_dout;
  reg [7:0]  vga_din = 0;
  wire       vga_de;

  vram video_ram (
    .clk_a(clk25_mhz),
    .addr_a(vga_addr),
    .we_a(vga_wr),
    .re_a(vga_rd),
    .din_a(vga_din),
    .dout_a(vga_dout),
    .clk_b(clk25_mhz),
    .addr_b(vid_addr),
    .dout_b(vid_out)
  );

  video vga (
    .clk(clk25_mhz),
    .vga_r(red),
    .vga_g(green),
    .vga_b(blue),
    .vga_de(vga_de),
    .vga_hs(hSync),
    .vga_vs(vSync),
    .vga_addr(vid_addr),
    .vga_data(vid_out)
  );

  // ===============================================================
  // SPI Slave for OSD display
  // ===============================================================

  wire [7:0] osd_vga_r, osd_vga_g, osd_vga_b;
  wire osd_vga_hsync, osd_vga_vsync, osd_vga_blank;
  spi_osd
  #(
    .c_start_x(62), .c_start_y(80),
    .c_chars_x(64), .c_chars_y(20),
    .c_init_on(0),
    .c_transparency(1),
    .c_char_file("osd.mem"),
    .c_font_file("font_bizcat8x16.mem")
  )
  spi_osd_inst
  (
    .clk_pixel(clk_vga), .clk_pixel_ena(1),
    .i_r(red  ),
    .i_g(green),
    .i_b(blue ),
    .i_hsync(~hSync), .i_vsync(~vSync), .i_blank(~vga_de),
    .i_csn(~wifi_gpio5), .i_sclk(wifi_gpio16), .i_mosi(sd_d[1]), // .o_miso(),
    .o_r(osd_vga_r), .o_g(osd_vga_g), .o_b(osd_vga_b),
    .o_hsync(osd_vga_hsync), .o_vsync(osd_vga_vsync), .o_blank(osd_vga_blank)
  );

  // Convert VGA to HDMI
  HDMI_out vga2dvid (
    .pixclk(clk_vga),
    .pixclk_x5(clk_hdmi),
    .red  (osd_vga_r),
    .green(osd_vga_g),
    .blue (osd_vga_b),
    .vde  (~osd_vga_blank),
    .hSync(~osd_vga_hsync),
    .vSync(~osd_vga_vsync),
    .gpdi_dp(gpdi_dp),
    .gpdi_dn()
  );

  assign audio_l = 0;
  assign audio_r = audio_l;

  //assign leds = {cpu_fc2, cpu_fc1, cpu_fc0};
  assign leds = cpu_dout;

  //always @(posedge clk25_mhz) diag16 = cpu_a[16:1];
  always @(posedge clk25_mhz) diag16 = cpu_a[16:1];

endmodule

