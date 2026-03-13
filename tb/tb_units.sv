
`timescale 1ns/1ps

// =============================================================================
// ALU / FPU Unit Test
// =============================================================================
module tb_alu_fpu;
  import edugpu_pkg::*;
  localparam real CLK_P = 2.0;
  logic clk = 0, rst_n = 0;
  always #(CLK_P/2) clk = ~clk;

  logic              exec_valid;
  decoded_instr_t    exec_instr;
  logic [31:0]       exec_pc, op_a[0:31], op_b[0:31];
  logic [1:0]        exec_warp;
  logic [31:0]       exec_mask;
  logic [31:0]       thread_ids[0:31];
  logic [31:0]       block_id, block_dim;
  logic              result_valid;
  logic [1:0]        result_warp;
  logic [4:0]        result_reg;
  logic [31:0]       result_data[0:31];
  logic [31:0]       result_mask;
  logic              branch_taken;
  logic [31:0]       branch_target;
  logic [1:0]        branch_warp_out;
  logic              sfu_busy;

  alu_fpu_unit dut (.*);

  int pass = 0, fail = 0;
  task check(input string msg, input logic cond);
    if (cond) begin $display("  PASS: %s", msg); pass++; end
    else      begin $display("  FAIL: %s", msg); fail++; end
  endtask

  // Helper: build decoded_instr_t
  function automatic decoded_instr_t mk_dec(input opcode_t op,
    input logic [4:0] rd, rs1, rs2);
    decoded_instr_t d = '0;
    d.opcode = op; d.rd = rd; d.rs1 = rs1; d.rs2 = rs2;
    d.is_fp = (op >= OP_FADD && op <= OP_FCMP);
    d.is_sfu= (op >= OP_FRCP && op <= OP_FCOS);
    d.is_special = (op >= OP_TIDI && op <= OP_WARPID);
    return d;
  endfunction

  initial begin
    $display("\n=== TB: alu_fpu_unit ===");
    exec_valid = 0; exec_mask = 32'hFFFFFFFF;
    block_id = 0; block_dim = 32;
    for (int t = 0; t < 32; t++) thread_ids[t] = t;
    rst_n = 0; repeat(4) @(posedge clk); rst_n = 1;

    // ---- TEST 1: ADD all lanes ----
    @(negedge clk);
    exec_instr = mk_dec(OP_ADD, 5'd5, 5'd1, 5'd2);
    for (int t = 0; t < 32; t++) begin op_a[t] = t; op_b[t] = t*2; end
    exec_valid = 1; exec_warp = 0;
    @(posedge clk); @(posedge clk);
    check("ADD: valid",       result_valid);
    check("ADD: lane 0 = 0",  result_data[0] === 32'd0);
    check("ADD: lane 5 = 15", result_data[5] === 32'd15);
    check("ADD: lane 31= 93", result_data[31] === 32'd93);

    // ---- TEST 2: SUB ----
    @(negedge clk);
    exec_instr = mk_dec(OP_SUB, 5'd6, 5'd1, 5'd2);
    for (int t = 0; t < 32; t++) begin op_a[t] = 100; op_b[t] = t; end
    exec_valid = 1;
    @(posedge clk); @(posedge clk);
    check("SUB: lane 0 = 100", result_data[0] === 32'd100);
    check("SUB: lane 1 = 99",  result_data[1] === 32'd99);

    // ---- TEST 3: AND ----
    @(negedge clk);
    exec_instr = mk_dec(OP_AND, 5'd7, 5'd1, 5'd2);
    for (int t = 0; t < 32; t++) begin op_a[t] = 32'hFFFF_0000; op_b[t] = 32'hFF00_FF00; end
    exec_valid = 1;
    @(posedge clk); @(posedge clk);
    check("AND: result = 0xFF000000", result_data[0] === 32'hFF00_0000);

    // ---- TEST 4: SHL ----
    @(negedge clk);
    exec_instr = mk_dec(OP_SHL, 5'd8, 5'd1, 5'd2);
    for (int t = 0; t < 32; t++) begin op_a[t] = 1; op_b[t] = t % 8; end
    exec_valid = 1;
    @(posedge clk); @(posedge clk);
    check("SHL: lane 0 = 1",  result_data[0] === 32'd1);
    check("SHL: lane 3 = 8",  result_data[3] === 32'd8);

    // ---- TEST 5: FADD ----
    @(negedge clk);
    exec_instr = mk_dec(OP_FADD, 5'd9, 5'd1, 5'd2);
    for (int t = 0; t < 32; t++) begin
      op_a[t] = 32'h3FC00000; // 1.5f
      op_b[t] = 32'h40200000; // 2.5f
    end
    exec_valid = 1;
    @(posedge clk); @(posedge clk);
    check("FADD: 1.5+2.5=4.0", result_data[0] === 32'h40800000); // 4.0f

    // ---- TEST 6: FMUL ----
    @(negedge clk);
    exec_instr = mk_dec(OP_FMUL, 5'd10, 5'd1, 5'd2);
    for (int t = 0; t < 32; t++) begin
      op_a[t] = 32'h40000000; // 2.0f
      op_b[t] = 32'h40400000; // 3.0f
    end
    exec_valid = 1;
    @(posedge clk); @(posedge clk);
    check("FMUL: 2.0*3.0=6.0", result_data[0] === 32'h40C00000); // 6.0f

    // ---- TEST 7: TIDI — thread ID read ----
    @(negedge clk);
    exec_instr = mk_dec(OP_TIDI, 5'd1, 5'd0, 5'd0);
    exec_instr.is_special = 1'b1;
    exec_valid = 1;
    @(posedge clk); @(posedge clk);
    check("TIDI: lane 0 = 0",   result_data[0]  === 32'd0);
    check("TIDI: lane 15 = 15", result_data[15] === 32'd15);
    check("TIDI: lane 31 = 31", result_data[31] === 32'd31);

    // ---- TEST 8: Branch BEQ taken ----
    @(negedge clk);
    exec_instr = mk_dec(OP_BEQ, 5'd0, 5'd1, 5'd2);
    exec_instr.is_branch = 1'b1;
    exec_instr.imm = 11'd4;  // offset = +4 words = +16 bytes
    exec_pc = 32'h100;
    for (int t = 0; t < 32; t++) begin op_a[t] = 5; op_b[t] = 5; end // equal
    exec_valid = 1;
    @(posedge clk);
    check("BEQ taken: branch_taken=1",       branch_taken);
    check("BEQ taken: target=0x110",         branch_target === 32'h110);

    // ---- TEST 9: Branch BEQ not taken ----
    @(negedge clk);
    for (int t = 0; t < 32; t++) begin op_a[t] = 5; op_b[t] = 6; end // not equal
    exec_valid = 1;
    @(posedge clk);
    check("BEQ not taken: branch_taken=0", !branch_taken);

    $display("=== alu_fpu_unit: %0d pass, %0d fail ===\n", pass, fail);
    $finish;
  end
endmodule


// =============================================================================
// Register File Test
// =============================================================================
module tb_register_file;
  import edugpu_pkg::*;
  localparam real CLK_P = 2.0;
  logic clk = 0, rst_n = 0;
  always #(CLK_P/2) clk = ~clk;

  logic              rd_en_a, rd_en_b, wr_en;
  logic [4:0]        rd_reg_a, rd_reg_b, wr_reg;
  logic [4:0]        rd_thread_base_a, rd_thread_base_b, wr_thread_base;
  logic [31:0]       rd_data_a[0:31], rd_data_b[0:31];
  logic [31:0]       wr_data[0:31];
  logic [31:0]       wr_thread_mask;

  register_file dut (.*);

  int pass = 0, fail = 0;
  task check(input string msg, input logic cond);
    if (cond) begin $display("  PASS: %s", msg); pass++; end
    else      begin $display("  FAIL: %s", msg); fail++; end
  endtask

  initial begin
    $display("=== TB: register_file ===");
    rd_en_a = 0; rd_en_b = 0; wr_en = 0;
    wr_thread_mask = '0; wr_thread_base = 0;
    rd_thread_base_a = 0; rd_thread_base_b = 0;
    rst_n = 0; repeat(4) @(posedge clk); rst_n = 1;

    // ---- TEST 1: Write R5 for all threads, read back ----
    @(negedge clk);
    wr_en   = 1; wr_reg = 5'd5;
    wr_thread_mask = 32'hFFFFFFFF;
    for (int t = 0; t < 32; t++) wr_data[t] = 32'(t * 100);
    @(posedge clk);
    wr_en = 0;
    @(negedge clk);
    rd_en_a = 1; rd_reg_a = 5'd5;
    @(posedge clk);
    check("RF Write/Read lane 0",  rd_data_a[0]  === 32'd0);
    check("RF Write/Read lane 7",  rd_data_a[7]  === 32'd700);
    check("RF Write/Read lane 15", rd_data_a[15] === 32'd1500);

    // ---- TEST 2: R0 always reads as 0 ----
    @(negedge clk);
    wr_en = 1; wr_reg = 5'd0;
    for (int t = 0; t < 32; t++) wr_data[t] = 32'hDEAD_BEEF;
    wr_thread_mask = 32'hFFFFFFFF;
    @(posedge clk);
    wr_en = 0;
    @(negedge clk);
    rd_en_a = 1; rd_reg_a = 5'd0;
    @(posedge clk);
    check("R0 hardwired zero lane 0",  rd_data_a[0]  === 32'd0);
    check("R0 hardwired zero lane 15", rd_data_a[15] === 32'd0);

    // ---- TEST 3: Dual-port read ----
    @(negedge clk);
    wr_en = 1; wr_reg = 5'd10;
    for (int t = 0; t < 32; t++) wr_data[t] = 32'hAAAA_0000 + t;
    wr_thread_mask = 32'hFFFFFFFF;
    @(posedge clk); wr_en = 0;
    wr_en = 1; wr_reg = 5'd11;
    for (int t = 0; t < 32; t++) wr_data[t] = 32'hBBBB_0000 + t;
    @(posedge clk); wr_en = 0;

    @(negedge clk);
    rd_en_a = 1; rd_reg_a = 5'd10;
    rd_en_b = 1; rd_reg_b = 5'd11;
    @(posedge clk);
    check("Dual port A[10] lane 0",  rd_data_a[0] === 32'hAAAA_0000);
    check("Dual port B[11] lane 0",  rd_data_b[0] === 32'hBBBB_0000);
    check("Dual port A[10] lane 5",  rd_data_a[5] === 32'hAAAA_0005);
    check("Dual port B[11] lane 5",  rd_data_b[5] === 32'hBBBB_0005);

    // ---- TEST 4: Thread mask — only even threads write ----
    @(negedge clk);
    wr_en = 1; wr_reg = 5'd20;
    wr_thread_mask = 32'h5555_5555;  // even threads only
    for (int t = 0; t < 32; t++) wr_data[t] = 32'hCAFE_CAFE;
    @(posedge clk); wr_en = 0;
    @(negedge clk);
    rd_en_a = 1; rd_reg_a = 5'd20;
    @(posedge clk);
    check("Masked write: even thread 0 written", rd_data_a[0] === 32'hCAFE_CAFE);

    $display("=== register_file: %0d pass, %0d fail ===\n", pass, fail);
    $finish;
  end
endmodule


// =============================================================================
// Warp Scheduler Test
// =============================================================================
module tb_warp_scheduler;
  import edugpu_pkg::*;
  localparam real CLK_P = 2.0;
  logic clk = 0, rst_n = 0;
  always #(CLK_P/2) clk = ~clk;

  logic              dispatch_valid, dispatch_ready;
  logic [31:0]       dispatch_block_id, dispatch_kernel_pc, dispatch_thread_count;
  logic              fetch_en;
  logic [1:0]        fetch_warp;
  logic [31:0]       fetch_pc [0:1];
  logic              decode_stall;
  logic [1:0]        decode_warp;
  logic              branch_taken;
  logic [1:0]        branch_warp;
  logic [31:0]       branch_target;
  logic              instr_issued;
  logic [1:0]        issued_warp;
  logic              mem_stall, mem_resume;
  logic [1:0]        mem_stall_warp, mem_resume_warp;
  logic              sync_reached;
  logic [1:0]        sync_warp;
  logic              thread_exit;
  logic [1:0]        exit_warp;
  logic [31:0]       exit_mask;
  warp_ctx_t         warp_ctx[0:1];
  logic              all_warps_done;

  warp_scheduler #(.SM_ID(0)) dut (.*);

  int pass = 0, fail = 0;
  task check(input string msg, input logic cond);
    if (cond) begin $display("  PASS: %s", msg); pass++; end
    else      begin $display("  FAIL: %s", msg); fail++; end
  endtask

  initial begin
    $display("=== TB: warp_scheduler ===");
    dispatch_valid = 0; decode_stall = 0; branch_taken = 0;
    instr_issued = 0; mem_stall = 0; mem_resume = 0;
    sync_reached = 0; thread_exit = 0;
    rst_n = 0; repeat(4) @(posedge clk); rst_n = 1; repeat(2) @(posedge clk);

    // ---- TEST 1: Dispatch a block ----
    check("dispatch_ready initially", dispatch_ready);
    @(negedge clk);
    dispatch_valid = 1; dispatch_block_id = 0;
    dispatch_kernel_pc = 32'h1000_0000; dispatch_thread_count = 64;
    @(posedge clk);
    dispatch_valid = 0;
    repeat(2) @(posedge clk);
    check("Warp 0 state = RUNNING or READY", warp_ctx[0].state != WARP_IDLE);
    check("Warp 0 PC = kernel PC",           warp_ctx[0].pc === 32'h1000_0000);
    check("Warp 1 state != IDLE (64 threads)",warp_ctx[1].state != WARP_IDLE);
    check("dispatch_ready = 0 (SM busy)",    !dispatch_ready);
    check("fetch_en asserted",               fetch_en);

    // ---- TEST 2: Issue instructions, PC advances ----
    @(negedge clk);
    instr_issued = 1; issued_warp = 0;
    @(posedge clk);
    instr_issued = 0;
    @(posedge clk);
    check("PC advances after issue", warp_ctx[0].pc === 32'h1000_0004);

    // ---- TEST 3: Memory stall warp 0, warp 1 runs ----
    @(negedge clk);
    mem_stall = 1; mem_stall_warp = 0;
    @(posedge clk); mem_stall = 0;
    repeat(2) @(posedge clk);
    check("Warp 0 stalled",          warp_ctx[0].state === WARP_STALL);
    check("Scheduler picks warp 1",  fetch_warp === 2'd1);

    // ---- TEST 4: Memory resume ----
    @(negedge clk);
    mem_resume = 1; mem_resume_warp = 0;
    @(posedge clk); mem_resume = 0;
    repeat(2) @(posedge clk);
    check("Warp 0 resumed", warp_ctx[0].state === WARP_READY ||
                             warp_ctx[0].state === WARP_RUNNING);

    // ---- TEST 5: Sync barrier ----
    @(negedge clk); sync_reached = 1; sync_warp = 0;
    @(posedge clk); sync_reached = 0;
    @(negedge clk); sync_reached = 1; sync_warp = 1;
    @(posedge clk); sync_reached = 0;
    repeat(2) @(posedge clk);
    check("Both warps released from barrier",
          warp_ctx[0].state != WARP_BARRIER &&
          warp_ctx[1].state != WARP_BARRIER);

    // ---- TEST 6: Thread exit, all done ----
    @(negedge clk);
    thread_exit = 1; exit_warp = 0; exit_mask = 32'hFFFFFFFF;
    @(posedge clk); thread_exit = 0;
    @(negedge clk);
    thread_exit = 1; exit_warp = 1; exit_mask = 32'hFFFFFFFF;
    @(posedge clk); thread_exit = 0;
    repeat(4) @(posedge clk);
    check("all_warps_done asserted",  all_warps_done);
    check("dispatch_ready restored",  dispatch_ready);

    $display("=== warp_scheduler: %0d pass, %0d fail ===\n", pass, fail);
    $finish;
  end
endmodule


// =============================================================================
// L1 / L2 Cache Test
// =============================================================================
module tb_cache;
  import edugpu_pkg::*;
  localparam real CLK_P = 2.0;
  logic clk = 0, rst_n = 0;
  always #(CLK_P/2) clk = ~clk;

  // L1 DUT
  mem_req_t  sm_req,  l2_req_from_l1;
  mem_resp_t sm_resp, l2_resp_to_l1;
  logic      l1_hit, l1_miss;

  l1_cache #(.SM_ID(0)) u_l1 (
    .clk, .rst_n,
    .sm_req, .sm_resp,
    .l2_req(l2_req_from_l1), .l2_resp(l2_resp_to_l1),
    .l1_hit_o(l1_hit), .l1_miss_o(l1_miss)
  );

  // L2 DUT
  mem_req_t  l2_req;
  mem_resp_t l2_resp;
  logic      vram_req_valid, vram_req_wr;
  logic [VRAM_ADDR_BITS-1:0] vram_req_addr;
  logic [127:0] vram_req_wdata, vram_resp_data;
  logic         vram_resp_valid;
  logic [31:0]  l2_hits, l2_misses;

  l2_cache u_l2 (
    .clk, .rst_n,
    .req(l2_req), .resp(l2_resp),
    .vram_req_valid, .vram_req_wr,
    .vram_req_addr, .vram_req_wdata,
    .vram_resp_valid, .vram_resp_data,
    .l2_hit_count(l2_hits), .l2_miss_count(l2_misses)
  );

  // Simple VRAM model (8-cycle latency)
  logic [127:0] vram [0:255];
  int vram_cnt;
  always_ff @(posedge clk) begin
    vram_resp_valid <= 0;
    if (vram_req_valid && vram_cnt == 0) vram_cnt <= 8;
    if (vram_cnt > 0) begin
      vram_cnt <= vram_cnt - 1;
      if (vram_cnt == 1) begin
        vram_resp_valid <= 1;
        vram_resp_data  <= vram_req_wr ? '0 : {96'h0, vram_req_addr[31:0]};
      end
    end
  end

  int pass = 0, fail = 0;
  task check(input string msg, input logic cond);
    if (cond) begin $display("  PASS: %s", msg); pass++; end
    else      begin $display("  FAIL: %s", msg); fail++; end
  endtask

  initial begin
    $display("=== TB: cache_subsystem (L1 + L2) ===");
    sm_req    = '0; l2_req = '0; vram_cnt = 0;
    l2_resp_to_l1 = '0;
    for (int i = 0; i < 256; i++) vram[i] = 128'(i);
    rst_n = 0; repeat(4) @(posedge clk); rst_n = 1;

    // ---- TEST 1: L1 miss → L2 miss → VRAM fill ----
    $display("  [L2] Issuing cold miss request...");
    @(negedge clk);
    l2_req.valid   = 1; l2_req.op = MEM_LOAD;
    l2_req.sm_id   = 0; l2_req.warp_id = 0; l2_req.reg_dst = 5;
    l2_req.addr    = 31'h0000_0040;  // address 64
    l2_req.byte_en = 4'hF;
    @(posedge clk); l2_req.valid = 0;

    // Wait for VRAM fill and response
    repeat(30) @(posedge clk);
    check("L2 miss incremented",  l2_misses >= 1);

    // ---- TEST 2: L2 hit (same address again) ----
    @(negedge clk);
    l2_req.valid = 1; l2_req.addr = 31'h0000_0040;
    @(posedge clk); l2_req.valid = 0;
    repeat(5) @(posedge clk);
    check("L2 hit incremented",   l2_hits >= 1);

    // ---- TEST 3: L2 write ----
    @(negedge clk);
    l2_req.valid   = 1; l2_req.op = MEM_STORE;
    l2_req.addr    = 31'h0000_0040;
    l2_req.data    = 32'hDEAD_BEEF;
    l2_req.byte_en = 4'hF;
    @(posedge clk); l2_req.valid = 0;
    repeat(3) @(posedge clk);
    check("L2 write accepted (resp valid)", l2_resp.valid);

    $display("=== cache_subsystem: %0d pass, %0d fail ===\n", pass, fail);
    $finish;
  end
endmodule


// =============================================================================
// LD/ST Unit Test
// =============================================================================
module tb_ldst;
  import edugpu_pkg::*;
  localparam real CLK_P = 2.0;
  logic clk = 0, rst_n = 0;
  always #(CLK_P/2) clk = ~clk;

  logic              ldst_valid;
  decoded_instr_t    ldst_instr;
  logic [1:0]        ldst_warp;
  logic [31:0]       ldst_mask;
  logic [31:0]       ldst_addr[0:31], ldst_wdata[0:31];
  mem_req_t          gmem_req;
  mem_resp_t         gmem_resp;
  logic              ldst_result_valid;
  logic [1:0]        ldst_result_warp;
  logic [4:0]        ldst_result_reg;
  logic [31:0]       ldst_result_data[0:31];
  logic [31:0]       ldst_result_mask;
  logic              ldst_stall, ldst_resume;
  logic [1:0]        ldst_stall_warp, ldst_resume_warp;

  ldst_unit #(.SM_ID(0)) dut (.*);

  int pass = 0, fail = 0;
  task check(input string msg, input logic cond);
    if (cond) begin $display("  PASS: %s", msg); pass++; end
    else      begin $display("  FAIL: %s", msg); fail++; end
  endtask

  function automatic decoded_instr_t mk_mem(
    input opcode_t op, input logic [4:0] rd);
    decoded_instr_t d = '0;
    d.opcode = op; d.rd = rd;
    d.is_mem    = 1'b1;
    d.is_load   = (op == OP_LDS || op == OP_LDG || op == OP_LDC);
    d.is_store  = (op == OP_STS || op == OP_STG);
    d.is_shmem  = (op == OP_LDS || op == OP_STS);
    d.uses_imm  = 1'b1;
    return d;
  endfunction


  always_ff @(posedge clk) begin
    gmem_resp.valid <= 1'b0;
    if (gmem_req.valid && gmem_req.op == MEM_LOAD) begin
      repeat(5) @(posedge clk);
      gmem_resp.valid   <= 1'b1;
      gmem_resp.sm_id   <= gmem_req.sm_id;
      gmem_resp.warp_id <= gmem_req.warp_id;
      gmem_resp.reg_dst <= gmem_req.reg_dst;
      gmem_resp.data    <= gmem_req.addr[31:0];  
    end
  end

  initial begin
    $display("=== TB: ldst_unit ===");
    ldst_valid = 0; gmem_resp = '0;
    ldst_mask  = 32'hFFFF; 
    rst_n = 0; repeat(4) @(posedge clk); rst_n = 1;

    // ---- TEST 1: Shared memory write ----
    @(negedge clk);
    ldst_instr = mk_mem(OP_STS, 5'd0);
    ldst_warp  = 0; ldst_valid = 1;
    for (int t = 0; t < 32; t++) begin
      ldst_addr[t]  = t * 4;       
      ldst_wdata[t] = 32'(t * 10); 
    end
    @(posedge clk); ldst_valid = 0;
    repeat(4) @(posedge clk);
    check("STS: no result (store has no writeback)", !ldst_result_valid);

    // ---- TEST 2: Shared memory read back ----
    @(negedge clk);
    ldst_instr = mk_mem(OP_LDS, 5'd3);
    ldst_valid = 1;
    for (int t = 0; t < 32; t++) ldst_addr[t] = t * 4;
    @(posedge clk); ldst_valid = 0;
    repeat(6) @(posedge clk);
    check("LDS: result valid",      ldst_result_valid);
    check("LDS: reg dst = 3",       ldst_result_reg === 5'd3);
    check("LDS: lane 0 = 0",        ldst_result_data[0] === 32'd0);
    check("LDS: lane 1 = 10",       ldst_result_data[1] === 32'd10);
    check("LDS: lane 5 = 50",       ldst_result_data[5] === 32'd50);

    // ---- TEST 3: Global memory load (stall + resume) ----
    @(negedge clk);
    ldst_instr = mk_mem(OP_LDG, 5'd5);
    ldst_warp  = 0; ldst_valid = 1;
    for (int t = 0; t < 32; t++) ldst_addr[t] = 32'h1000 + t * 4;
    @(posedge clk); ldst_valid = 0;
    @(posedge clk);
    check("LDG: warp stalled",    ldst_stall);
    repeat(50) @(posedge clk);
    check("LDG: warp resumed",    ldst_resume || ldst_result_valid);

    // ---- TEST 4: Bank conflict detection (shared mem) ----
 
    @(negedge clk);
    ldst_instr = mk_mem(OP_LDS, 5'd7);
    ldst_valid = 1;
    for (int t = 0; t < 32; t++) ldst_addr[t] = t * 128; 
    @(posedge clk); ldst_valid = 0;
  
    repeat(8) @(posedge clk);
    check("Bank conflict handled (result eventually valid)", ldst_result_valid);

    $display("=== ldst_unit: %0d pass, %0d fail ===\n", pass, fail);
    $finish;
  end
endmodule