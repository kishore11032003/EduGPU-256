
`timescale 1ns/1ps

module tb_decode_unit;
  import edugpu_pkg::*;

  localparam real CLK_P = 2.0;
  logic clk = 0, rst_n = 0;
  always #(CLK_P/2) clk = ~clk;

  logic              instr_valid_in;
  instr_t            instr_in;
  logic [31:0]       instr_pc_in;
  logic [1:0]        instr_warp_in;
  logic [31:0]       scoreboard [0:1];
  logic              decode_valid;
  decoded_instr_t    decoded_out;
  logic [31:0]       decode_pc;
  logic [1:0]        decode_warp;
  logic              decode_stall;
  logic              sb_set_en;
  logic [1:0]        sb_set_warp;
  logic [4:0]        sb_set_reg;
  logic              sb_clr_en;
  logic [1:0]        sb_clr_warp;
  logic [4:0]        sb_clr_reg;

  decode_unit dut (.*);

  // Helper: build instruction word
  function automatic instr_t mk_instr(
    input logic [5:0] op,
    input logic [4:0] rd, rs1, rs2,
    input logic [10:0] imm
  );
    return {op, rd, rs1, rs2, imm};
  endfunction

  int pass = 0, fail = 0;
  task check(input string msg, input logic cond);
    if (cond) begin $display("  PASS: %s", msg); pass++; end
    else      begin $display("  FAIL: %s", msg); fail++; end
  endtask

  initial begin
    $display("=== TB: decode_unit ===");
    instr_valid_in = 0; sb_clr_en = 0;
    scoreboard[0] = 0; scoreboard[1] = 0;
    rst_n = 0; repeat(4) @(posedge clk); rst_n = 1; repeat(2) @(posedge clk);

    // ---- TEST 1: Decode ADD R5, R1, R2 ----
    @(negedge clk);
    instr_valid_in = 1;
    instr_in       = mk_instr(OP_ADD, 5'd5, 5'd1, 5'd2, 11'd0);
    instr_pc_in    = 32'h100;
    instr_warp_in  = 2'd0;
    @(posedge clk); @(posedge clk);
    check("ADD: decode_valid",         decode_valid === 1'b1);
    check("ADD: opcode correct",       decoded_out.opcode === OP_ADD);
    check("ADD: rd=5",                 decoded_out.rd  === 5'd5);
    check("ADD: rs1=1",                decoded_out.rs1 === 5'd1);
    check("ADD: rs2=2",                decoded_out.rs2 === 5'd2);
    check("ADD: not mem/fp",           !decoded_out.is_mem && !decoded_out.is_fp);
    check("ADD: scoreboard set for R5",sb_set_en && sb_set_reg === 5'd5);

    // ---- TEST 2: Decode LDG R3, [R1+imm] ----
    @(negedge clk);
    instr_in = mk_instr(OP_LDG, 5'd3, 5'd1, 5'd0, 11'd8);
    @(posedge clk); @(posedge clk);
    check("LDG: is_mem",               decoded_out.is_mem);
    check("LDG: is_load",              decoded_out.is_load);
    check("LDG: not shmem",            !decoded_out.is_shmem);
    check("LDG: uses_imm",             decoded_out.uses_imm);

    // ---- TEST 3: Decode LDS R4, [R2+0] ----
    @(negedge clk);
    instr_in = mk_instr(OP_LDS, 5'd4, 5'd2, 5'd0, 11'd0);
    @(posedge clk); @(posedge clk);
    check("LDS: is_shmem",             decoded_out.is_shmem);
    check("LDS: is_load",              decoded_out.is_load);

    // ---- TEST 4: RAW Hazard — ADD R5, R5, R1 while R5 in-flight ----
    // R5 should still be in scoreboard from TEST 1
    @(negedge clk);
    instr_in      = mk_instr(OP_ADD, 5'd6, 5'd5, 5'd1, 11'd0); // reads R5
    instr_warp_in = 2'd0;
    @(posedge clk); @(posedge clk);
    check("RAW: decode_stall on in-flight rs1", decode_stall === 1'b1);
    check("RAW: decode_valid suppressed",       decode_valid === 1'b0);

    // ---- TEST 5: Clear scoreboard, hazard resolves ----
    @(negedge clk);
    sb_clr_en   = 1; sb_clr_warp = 0; sb_clr_reg = 5'd5;
    @(posedge clk);
    sb_clr_en   = 0;
    @(posedge clk); @(posedge clk);
    check("Hazard resolved after sb clear", decode_stall === 1'b0);

    // ---- TEST 6: FADD — floating-point flag ----
    @(negedge clk);
    instr_in = mk_instr(OP_FADD, 5'd7, 5'd1, 5'd2, 11'd0);
    @(posedge clk); @(posedge clk);
    check("FADD: is_fp set", decoded_out.is_fp === 1'b1);

    // ---- TEST 7: SYNC instruction ----
    @(negedge clk);
    instr_in = mk_instr(OP_SYNC, 5'd0, 5'd0, 5'd0, 11'd0);
    @(posedge clk); @(posedge clk);
    check("SYNC: is_sync set", decoded_out.is_sync === 1'b1);

    // ---- TEST 8: EXIT instruction ----
    @(negedge clk);
    instr_in = mk_instr(OP_EXIT, 5'd0, 5'd0, 5'd0, 11'd0);
    @(posedge clk); @(posedge clk);
    check("EXIT: is_exit set", decoded_out.is_exit === 1'b1);

    // ---- TEST 9: Branch instruction ----
    @(negedge clk);
    instr_in = mk_instr(OP_BRA, 5'd0, 5'd0, 5'd0, 11'h7FE); // branch +1022
    @(posedge clk); @(posedge clk);
    check("BRA: is_branch set", decoded_out.is_branch === 1'b1);
    check("BRA: imm correct",   decoded_out.imm === 11'h7FE);

    $display("=== decode_unit: %0d pass, %0d fail ===", pass, fail);
    $finish;
  end
endmodule