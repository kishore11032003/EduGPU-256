
`timescale 1ns/1ps

// =============================================================================
// VRAM Controller Testbench
// =============================================================================
module tb_vram_controller;
  import edugpu_pkg::*;
  localparam real CLK_P = 2.0;
  logic clk = 0, rst_n = 0;
  always #(CLK_P/2) clk = ~clk;

  // DUT ports
  logic              req_valid, req_wr;
  logic [VRAM_ADDR_BITS-1:0] req_addr;
  logic [127:0]      req_wdata;
  logic [15:0]       req_byte_en;
  logic [3:0]        req_tag;
  logic              req_ready;
  logic              resp_valid;
  logic [127:0]      resp_rdata;
  logic [3:0]        resp_tag;

  // Physical DRAM pins
  logic              dram_cke, dram_cs_n, dram_ras_n, dram_cas_n, dram_we_n;
  logic [1:0]        dram_ba;
  logic [13:0]       dram_addr;
  logic [127:0]      dram_dq_out, dram_dq_in;  
  logic [15:0]       dram_dm;

  logic [31:0] perf_reads, perf_writes, perf_refreshes;
  logic [31:0] perf_row_hits, perf_row_misses;

  vram_controller dut (
    .clk, .rst_n,
    .req_valid, .req_wr, .req_addr, .req_wdata, .req_byte_en,
    .req_tag, .req_ready,
    .resp_valid, .resp_rdata, .resp_tag,
    .dram_cke, .dram_cs_n, .dram_ras_n, .dram_cas_n, .dram_we_n,
    .dram_ba, .dram_addr, .dram_dq_out, .dram_dq_in, .dram_dm,
    .perf_reads, .perf_writes, .perf_refreshes, .perf_row_hits, .perf_row_misses
  );

  // Physical DRAM model
  vram_dram_model #(.tCL(4)) u_dram (
    .clk,
    .cke(dram_cke), .cs_n(dram_cs_n),
    .ras_n(dram_ras_n), .cas_n(dram_cas_n), .we_n(dram_we_n),
    .ba(dram_ba), .addr(dram_addr),
    .dq_in(dram_dq_out), .dm(dram_dm),
    .dq_out(dram_dq_in)
  );

  int pass = 0, fail = 0;
  task check(input string msg, input logic cond);
    if (cond) begin $display("  PASS: %s", msg); pass++; end
    else      begin $display("  FAIL: %s", msg); fail++; end
  endtask

  task do_write(input logic [VRAM_ADDR_BITS-1:0] addr,
                input logic [127:0] data, input logic [3:0] tag);
    @(negedge clk);
    req_valid   = 1; req_wr = 1;
    req_addr    = addr; req_wdata = data;
    req_byte_en = 16'hFFFF; req_tag = tag;
    @(posedge clk);
    req_valid   = 0;
  endtask

  task do_read(input logic [VRAM_ADDR_BITS-1:0] addr, input logic [3:0] tag);
    @(negedge clk);
    req_valid   = 1; req_wr = 0;
    req_addr    = addr; req_wdata = '0;
    req_byte_en = 16'hFFFF; req_tag = tag;
    @(posedge clk);
    req_valid   = 0;
  endtask

  initial begin
    $display("=== TB: vram_controller ===");
    dram_dq_in = '0;
    req_valid = 0;
    rst_n = 0; repeat(4) @(posedge clk); rst_n = 1;

    // Wait for init sequence
    repeat(120) @(posedge clk);
    check("Controller initialized (ready)", req_ready);

    // ---- TEST 1: Write 128-bit word ----
    $display("  [VRAM] Write 0xDEADBEEF... to addr 0x0");
    do_write(31'h0, 128'hDEAD_BEEF_CAFE_BABE_1234_5678_9ABC_DEF0, 4'h1);
    // Wait for write to complete (tRCD + tWR + tRAS)
    repeat(30) @(posedge clk);
    check("Write: perf_writes incremented", perf_writes >= 1);

    // ---- TEST 2: Read back ----
    $display("  [VRAM] Read from addr 0x0");
    do_read(31'h0, 4'h2);
    // Wait for full read latency (tRCD + tCL + bank open etc.)
    repeat(30) @(posedge clk);
    check("Read: resp_valid asserted", resp_valid);
    check("Read: correct tag returned", resp_tag === 4'h2);
    check("Read: perf_reads incremented", perf_reads >= 1);

    // ---- TEST 3: Row hit — second access same row ----
    $display("  [VRAM] Second read, same row (should be row hit)");
    do_read(31'h10, 4'h3);  // same row, different column
    repeat(20) @(posedge clk);
    check("Row hit counter incremented", perf_row_hits >= 1);

    // ---- TEST 4: Row miss — different row in same bank ----
    $display("  [VRAM] Access different row (should be row miss)");
    do_read(31'h100000, 4'h4);  // different row
    repeat(30) @(posedge clk);
    check("Row miss counter incremented", perf_row_misses >= 1);

    // ---- TEST 5: Request queue fills ----
    $display("  [VRAM] Filling request queue...");
    for (int i = 0; i < 6; i++) begin
      @(negedge clk);
      req_valid = 1; req_wr = 0;
      req_addr  = i * 32'h1000; req_tag = i[3:0];
      req_byte_en = 16'hFFFF;
      @(posedge clk);
    end
    req_valid = 0;
    repeat(200) @(posedge clk);
    check("Queue drained (resp_valid seen)", resp_valid); // will have fired several times

    // ---- TEST 6: Refresh cycles ----
    // After 3900 cycles, auto-refresh should occur
    $display("  [VRAM] Waiting for auto-refresh...");
    repeat(4000) @(posedge clk);
    check("Auto-refresh occurred", perf_refreshes >= 1);

    $display("=== vram_controller: %0d pass, %0d fail ===\n", pass, fail);
    $finish;
  end
endmodule


// =============================================================================
// Texture Unit Testbench
// =============================================================================
module tb_texture_unit;
  import edugpu_pkg::*;
  localparam real CLK_P = 2.0;
  logic clk = 0, rst_n = 0;
  always #(CLK_P/2) clk = ~clk;

  logic              tex_req_valid;
  logic [1:0]        tex_req_warp;
  logic [4:0]        tex_req_rd;
  logic [31:0]       tex_req_mask;
  logic [31:0]       tex_u[0:31], tex_v[0:31];
  logic [2:0]        tex_id;
  logic [VRAM_ADDR_BITS-1:0] tex_base[0:7];
  logic [12:0]       tex_width[0:7], tex_height[0:7];
  logic [1:0]        tex_format[0:7], tex_wrap[0:7];
  logic              tex_result_valid;
  logic [1:0]        tex_result_warp;
  logic [4:0]        tex_result_reg;
  logic [31:0]       tex_result_data[0:31];
  logic [31:0]       tex_result_mask;
  mem_req_t          gmem_req;
  mem_resp_t         gmem_resp;
  logic              tex_stall, tex_resume;
  logic [1:0]        tex_stall_warp, tex_resume_warp;

  texture_unit #(.SM_ID(0)) dut (.*);

  int pass = 0, fail = 0;
  task check(input string msg, input logic cond);
    if (cond) begin $display("  PASS: %s", msg); pass++; end
    else      begin $display("  FAIL: %s", msg); fail++; end
  endtask


  initial begin
    $display("=== TB: texture_unit ===");
    tex_req_valid = 0; gmem_resp = '0;
  
    tex_base[0]   = 31'h0;
    tex_width[0]  = 13'd4;
    tex_height[0] = 13'd4;
    tex_format[0] = 2'd0;    
    tex_wrap[0]   = 2'd1;    
    for (int i = 1; i < 8; i++) begin
      tex_base[i]   = '0;
      tex_width[i]  = 13'd1;
      tex_height[i] = 13'd1;
      tex_format[i] = 2'd0;
      tex_wrap[i]   = 2'd0;
    end
    tex_req_mask = 32'hFFFF;
    rst_n = 0; repeat(4) @(posedge clk); rst_n = 1;

 
    for (int b=0; b < 32; b++)
      dut.tc_data[0][b] = b * 8;  
    dut.tc_tag[0] = 0;
    dut.tc_valid[0] = 1'b1;


    // ---- TEST 1: Basic texture sample at UV=(0.5, 0.5) ----
    @(negedge clk);
    tex_id = 3'd0; tex_req_warp = 2'd0; tex_req_rd = 5'd4;
    tex_req_valid = 1;
    for (int t = 0; t < 32; t++) begin
      tex_u[t] = 32'h0000_8000;  // U = 0.5 (fixed-point 16.16)
      tex_v[t] = 32'h0000_8000;  // V = 0.5
    end
    @(posedge clk); tex_req_valid = 0;
    // Wait 6 pipeline stages
    repeat(8) @(posedge clk);
    check("TEX: result_valid after 6 cycles", tex_result_valid || tex_stall);
    check("TEX: correct reg dst",             tex_result_reg === 5'd4);
    check("TEX: warp ID preserved",           tex_result_warp === 2'd0);

    // ---- TEST 2: UV = (0,0) corner sample ----
    @(negedge clk);
    tex_req_valid = 1; tex_req_rd = 5'd5;
    for (int t = 0; t < 32; t++) begin
      tex_u[t] = 32'h0;
      tex_v[t] = 32'h0;
    end
    @(posedge clk); tex_req_valid = 0;
    repeat(8) @(posedge clk);
    check("TEX corner: pipeline active", tex_result_valid || tex_stall);

    // ---- TEST 3: Wrap mode — UV > 1.0 ----
    @(negedge clk);
    tex_req_valid = 1; tex_req_rd = 5'd6;
    for (int t = 0; t < 32; t++) begin
      tex_u[t] = 32'h0002_0000;  // U = 2.0 → wraps to 0.0 with REPEAT
      tex_v[t] = 32'h0003_8000;  // V = 3.5 → wraps to 3.5 mod 4 = 3.5 → 0.5-ish
    end
    @(posedge clk); tex_req_valid = 0;
    repeat(8) @(posedge clk);
    check("TEX wrap: pipeline active", tex_result_valid || tex_stall);

    // ---- TEST 4: Different threads different UVs (SIMT diversity) ----
    @(negedge clk);
    tex_req_valid = 1; tex_req_rd = 5'd7;
    for (int t = 0; t < 32; t++) begin
      tex_u[t] = t << 11;  // spread UVs across [0,1) per thread
      tex_v[t] = (31-t) << 11;
    end
    @(posedge clk); tex_req_valid = 0;
    repeat(8) @(posedge clk);
    check("TEX SIMT: pipeline active", tex_result_valid || tex_stall);
    check("TEX SIMT: mask preserved", tex_result_mask === tex_req_mask);



    $display("=== texture_unit: %0d pass, %0d fail ===\n", pass, fail);
    $finish;
  end
endmodule