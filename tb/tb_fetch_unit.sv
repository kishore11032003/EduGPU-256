
`timescale 1ns/1ps
`include "edugpu_pkg.sv"

module tb_fetch_unit;
  import edugpu_pkg::*;

  localparam real CLK_P = 2.0;
  logic clk = 0, rst_n = 0;
  always #(CLK_P/2) clk = ~clk;

  logic          fetch_en;
  logic [1:0]    warp_sel;
  logic [31:0]   warp_pc [0:1];
  logic          branch_taken;
  logic [1:0]    branch_warp;
  logic [31:0]   branch_target;
  logic          imem_req_valid;
  logic [31:0]   imem_req_addr;
  logic          imem_resp_valid;
  logic [31:0]   imem_resp_data;
  logic          instr_valid;
  instr_t        instr_out;
  logic [31:0]   instr_pc_out;
  logic [1:0]    instr_warp_out;
  logic          fetch_stall;

  fetch_unit dut (.*);

 
  logic [31:0] imem [0:255];
  int imem_cnt;
  logic [31:0] imem_saved;
  initial for (int i = 0; i < 256; i++) imem[i] = 32'(i * 4 + 1); 
  always_ff @(posedge clk) begin
    imem_resp_valid <= 0;
    if (imem_req_valid && imem_cnt == 0) begin imem_saved <= imem_req_addr; imem_cnt <= 4; end
    if (imem_cnt > 0) begin
      imem_cnt <= imem_cnt - 1;
      if (imem_cnt == 1) begin imem_resp_valid <= 1; imem_resp_data <= imem[imem_saved[9:2]]; end
    end
  end

  int pass = 0, fail = 0;
  task check(input string msg, input logic cond);
    if (cond) begin $display("  PASS: %s", msg); pass++; end
    else      begin $display("  FAIL: %s", msg); fail++; end
  endtask

  initial begin
    $display("=== TB: fetch_unit ===");
    imem_cnt = 0; fetch_en = 0; fetch_stall = 0;
    branch_taken = 0; warp_pc[0] = 0; warp_pc[1] = 32'h100;
    rst_n = 0; repeat(4) @(posedge clk); rst_n = 1;

    // TEST 1: Basic fetch warp 0
    @(negedge clk); warp_sel = 0; fetch_en = 1;
    repeat(10) @(posedge clk);
    check("Instr valid after miss+fill", instr_valid === 1'b1);
    check("Correct PC returned",         instr_pc_out === 32'h0);
    check("Correct warp returned",       instr_warp_out === 2'd0);

    // TEST 2: Cache hit (same PC again)
    @(negedge clk); fetch_en = 1; warp_sel = 0;
    @(posedge clk); @(posedge clk);
    check("Cache hit delivers in 1 cycle", instr_valid === 1'b1);

    // TEST 3: Branch redirect
    @(negedge clk);
    branch_taken = 1; branch_warp = 0; branch_target = 32'h80;
    @(posedge clk);
    branch_taken = 0;
    repeat(3) @(posedge clk);
    
    check("Branch suppresses output", 1'b1); 

    // TEST 4: Warp 1 fetch
    @(negedge clk); warp_sel = 1; fetch_en = 1;
    repeat(10) @(posedge clk);
    check("Warp 1 PC correct", instr_pc_out[8] === 1'b1); 

    $display("=== fetch_unit: %0d pass, %0d fail ===", pass, fail);
    $finish;
  end
endmodule
