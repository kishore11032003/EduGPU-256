

`timescale 1ns/1ps

module tb_edugpu_top;
  import edugpu_pkg::*;

  // ---------------------------------------------------------------------------
  // Clock & Reset
  // ---------------------------------------------------------------------------
  localparam real CLK_PERIOD = 2.0;  // 500 MHz → 2 ns

  logic clk  = 1'b0;
  logic rst_n = 1'b0;

  always #(CLK_PERIOD/2) clk = ~clk;

  // ---------------------------------------------------------------------------
  // DUT Ports
  // ---------------------------------------------------------------------------
  logic              host_wr_en;
  logic [15:0]       host_wr_addr;
  logic [31:0]       host_wr_data;
  logic              host_rd_en;
  logic [15:0]       host_rd_addr;
  logic [31:0]       host_rd_data;
  logic              host_rd_valid;

  logic              vram_req_valid;
  logic              vram_req_wr;
  logic [VRAM_ADDR_BITS-1:0] vram_req_addr;
  logic [127:0]      vram_req_wdata;
  logic              vram_resp_valid;
  logic [127:0]      vram_resp_data;

  logic              imem_req_valid;
  logic [31:0]       imem_req_addr;
  logic              imem_resp_valid;
  logic [31:0]       imem_resp_data;

  logic              vtx_valid;
  vertex_t           vtx_v0, vtx_v1, vtx_v2;
  logic              vtx_ready;

  logic              gpu_done;
  logic              gpu_busy;

  // ---------------------------------------------------------------------------
  // DUT Instantiation
  // ---------------------------------------------------------------------------
  edugpu_top dut (.*);

  // ---------------------------------------------------------------------------
  // VRAM Model 
  // ---------------------------------------------------------------------------
  
  localparam int VRAM_SIM_WORDS = 1048576; 
  logic [127:0] vram_mem [0:VRAM_SIM_WORDS-1];


  localparam int VRAM_LATENCY = 20;

  typedef struct {
    logic                       active;
    logic                       wr;
    logic [VRAM_ADDR_BITS-1:0]  addr;
    logic [127:0]               wdata;
    int                         countdown;
  } vram_pending_t;

  vram_pending_t vram_pending;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      vram_resp_valid  <= 1'b0;
      vram_resp_data   <= '0;
      vram_pending.active <= 1'b0;
    end else begin
      vram_resp_valid <= 1'b0;

      if (vram_req_valid && !vram_pending.active) begin
        vram_pending.active    <= 1'b1;
        vram_pending.wr        <= vram_req_wr;
        vram_pending.addr      <= vram_req_addr;
        vram_pending.wdata     <= vram_req_wdata;
        vram_pending.countdown <= VRAM_LATENCY;
      end

      if (vram_pending.active) begin
        if (vram_pending.countdown == 0) begin
          vram_pending.active <= 1'b0;
          if (vram_pending.wr) begin
            
            automatic int word_idx = int'(vram_pending.addr >> 4) % VRAM_SIM_WORDS;
            vram_mem[word_idx] <= vram_pending.wdata;
            vram_resp_valid    <= 1'b1;
            vram_resp_data     <= '0;
          end else begin
            
            automatic int word_idx = int'(vram_pending.addr >> 4) % VRAM_SIM_WORDS;
            vram_resp_valid <= 1'b1;
            vram_resp_data  <= vram_mem[word_idx];
          end
        end else begin
          vram_pending.countdown <= vram_pending.countdown - 1;
        end
      end
    end
  end


  localparam int IMEM_WORDS = 4096;
  logic [31:0] imem [0:IMEM_WORDS-1];


  function automatic logic [31:0] asm(
    input logic [5:0]  op,
    input logic [4:0]  rd, rs1, rs2,
    input logic [10:0] imm
  );
    return {op, rd, rs1, rs2, imm};
  endfunction


  task automatic init_kernel_vector_add;
    
    int pc = 0;
  
    imem[pc++] = asm(OP_TIDI, 5'd1, 5'd0, 5'd0, 11'd0);
   
    imem[pc++] = asm(OP_SHL,  5'd2, 5'd1, 5'd0, 11'd2);  
    
    imem[pc++] = asm(OP_LDG,  5'd4, 5'd2, 5'd0, 11'd0);  
   
    imem[pc++] = asm(OP_LDG,  5'd5, 5'd2, 5'd0, 11'd512);
   
    imem[pc++] = asm(OP_ADD,  5'd6, 5'd4, 5'd5, 11'd0);
    
    imem[pc++] = asm(OP_STG,  5'd0, 5'd2, 5'd6, 11'd1024);

    imem[pc++] = asm(OP_EXIT, 5'd0, 5'd0, 5'd0, 11'd0);
  endtask

  task automatic init_kernel_matrix_scale;
    int pc = 64; 
    imem[pc++] = asm(OP_TIDI,  5'd1, 5'd0, 5'd0, 11'd0); 
    imem[pc++] = asm(OP_SHL,   5'd2, 5'd1, 5'd0, 11'd2);   
    imem[pc++] = asm(OP_LDG,   5'd3, 5'd2, 5'd0, 11'd0);   

    imem[pc++] = asm(OP_LDG,   5'd4, 5'd0, 5'd0, 11'd2040); 
    imem[pc++] = asm(OP_FMUL,  5'd5, 5'd3, 5'd4, 11'd0);   
    imem[pc++] = asm(OP_STG,   5'd0, 5'd2, 5'd5, 11'd512); 
    imem[pc++] = asm(OP_EXIT,  5'd0, 5'd0, 5'd0, 11'd0);
  endtask

 
  localparam int IMEM_LATENCY = 4;
  int imem_countdown;
  logic [31:0] imem_saved_addr;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      imem_resp_valid <= 1'b0;
      imem_countdown  <= 0;
    end else begin
      imem_resp_valid <= 1'b0;
      if (imem_req_valid && imem_countdown == 0) begin
        imem_countdown  <= IMEM_LATENCY;
        imem_saved_addr <= imem_req_addr;
      end
      if (imem_countdown > 0) begin
        imem_countdown <= imem_countdown - 1;
        if (imem_countdown == 1) begin
          automatic int word_idx = int'(imem_saved_addr >> 2) % IMEM_WORDS;
          imem_resp_valid <= 1'b1;
          imem_resp_data  <= imem[word_idx];
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Helper Tasks
  // ---------------------------------------------------------------------------
  task write_reg(input logic [15:0] addr, input logic [31:0] data);
    @(negedge clk);
    host_wr_en   = 1'b1;
    host_wr_addr = addr;
    host_wr_data = data;
    @(negedge clk);
    host_wr_en   = 1'b0;
  endtask

  task read_reg(input logic [15:0] addr, output logic [31:0] data);
    @(negedge clk);
    host_rd_en   = 1'b1;
    host_rd_addr = addr;
    @(posedge clk);
    @(posedge clk);
    data         = host_rd_data;
    @(negedge clk);
    host_rd_en   = 1'b0;
  endtask

  task automatic wait_gpu_idle(input int timeout_cycles);
    int cycles = 0;
    while (gpu_busy && cycles < timeout_cycles) begin
      @(posedge clk);
      cycles++;
    end
    if (cycles >= timeout_cycles)
      $display("[TB] WARNING: GPU did not go idle within %0d cycles", timeout_cycles);
  endtask

 
  int test_start_cycle, test_end_cycle;
  longint total_cycles;

  task start_perf_counter;
    test_start_cycle = $time / int'(CLK_PERIOD);
  endtask

  task stop_perf_counter(input string test_name);
    test_end_cycle = $time / int'(CLK_PERIOD);
    total_cycles   = test_end_cycle - test_start_cycle;
    $display("[PERF] %s: %0d cycles = %.2f μs @ 500 MHz",
             test_name, total_cycles, real'(total_cycles) * 2.0e-3);
  endtask

  // ---------------------------------------------------------------------------
  // Main Simulation
  // ---------------------------------------------------------------------------
  logic [31:0] rd_val;

  initial begin
    $display("========================================================");
    $display(" EduGPU-256 Simulation                                  ");
    $display(" 256 Cores | 8 SMs | 500 MHz | 64 KB SharedMem | 1MB L2 ");
    $display("========================================================");

  
    for (int i = 0; i < VRAM_SIM_WORDS; i++) vram_mem[i] = '0;
    for (int i = 0; i < IMEM_WORDS;     i++) imem[i]     = '0;

    init_kernel_vector_add;
    init_kernel_matrix_scale;

    host_wr_en   = 1'b0;
    host_rd_en   = 1'b0;
    vtx_valid    = 1'b0;

    rst_n = 1'b0;
    repeat(10) @(posedge clk);
    rst_n = 1'b1;
    repeat(5) @(posedge clk);

    $display("[TB] Reset complete. Starting tests...");


    $display("\n[TEST 1] Vector Addition: C[i] = A[i] + B[i], N=128");


    for (int i = 0; i < 128; i++) begin
      automatic int word_idx_a = (i * 4)   / 16;
      automatic int lane_a     = (i * 4) % 16;        
      automatic int word_idx_b = (512 + i*4) / 16;
      automatic int lane_b     = (512 + i*4) % 16;
      vram_mem[word_idx_a][lane_a*8 +: 32] = i;        
      vram_mem[word_idx_b][lane_b*8 +: 32] = i * 2;   
    end

    // Configure GPU
    write_reg(16'h0000, 32'h0000_0000); 
    write_reg(16'h0004, 32'd4);         
    write_reg(16'h0008, 32'd32);        

    start_perf_counter;
    write_reg(16'h000C, 32'h1);         
    wait_gpu_idle(100000);
    stop_perf_counter("Vector Add (128 elements)");

    $display("[TEST 1] Verifying results...");
    for (int i = 0; i < 8; i++) begin
      automatic int word_idx_c = (1024 + i*4) / 16;
      automatic int lane_c     = (1024 + i*4) % 16;
      automatic logic [31:0] result   = vram_mem[word_idx_c][lane_c*8 +: 32];
      automatic logic [31:0] expected = i * 3;
      if (result === expected)
        $display("  C[%0d] = %0d ✓", i, result);
      else
        $display("  C[%0d] = %0d (expected %0d) ✗", i, result, expected);
    end

    // ==========================================================================
    // TEST 2: FP32 Matrix Scale
    // ==========================================================================
    $display("\n[TEST 2] FP32 Matrix Scale: B[i] = A[i] * 2.5, N=128");


    vram_mem[127][64+:32] = 32'h4020_0000; 

    write_reg(16'h0000, 32'h0000_0100); 
    write_reg(16'h0004, 32'd4);         
    write_reg(16'h0008, 32'd32);        

    start_perf_counter;
    write_reg(16'h000C, 32'h1);
    wait_gpu_idle(100000);
    stop_perf_counter("FP32 Matrix Scale (128 elements)");

    $display("[TEST 2] Complete.");

    // ==========================================================================
    // TEST 3: Triangle Rasterization
    // ==========================================================================
    $display("\n[TEST 3] Triangle Rasterization (screen-space triangle)");

    // Set framebuffer configuration
    write_reg(16'h0100, 32'h0000_0000); 
    write_reg(16'h0104, 32'h0100_0000); 
    write_reg(16'h0108, 32'd1280);      
    write_reg(16'h010C, 32'd720);       

    for (int i = 0; i < 1280*720/8; i++) 
      vram_mem[32'h0100_0000/16 + i] = 128'hFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF;

    
    @(negedge clk);
    vtx_valid  = 1'b1;
    vtx_v0.x = 16'sd100; vtx_v0.y = 16'sd100; vtx_v0.z = 16'h8000;
    vtx_v0.r = 8'hFF; vtx_v0.g = 8'h20; vtx_v0.b = 8'h20;
    vtx_v0.u = 8'h00; vtx_v0.v = 8'h00;

    vtx_v1.x = 16'sd500; vtx_v1.y = 16'sd100; vtx_v1.z = 16'h8000;
    vtx_v1.r = 8'h20; vtx_v1.g = 8'hFF; vtx_v1.b = 8'h20;
    vtx_v1.u = 8'hFF; vtx_v1.v = 8'h00;

    vtx_v2.x = 16'sd300; vtx_v2.y = 16'sd400; vtx_v2.z = 16'h8000;
    vtx_v2.r = 8'h20; vtx_v2.g = 8'h20; vtx_v2.b = 8'hFF;
    vtx_v2.u = 8'h80; vtx_v2.v = 8'hFF;

    @(posedge clk);
    while (!vtx_ready) @(posedge clk);
    vtx_valid = 1'b0;

    start_perf_counter;

    repeat(200000) @(posedge clk);
    stop_perf_counter("Triangle Rasterization (400×300 approx)");

    $display("[TEST 3] Triangle submitted. Fragments being processed by ROPs.");

    // ==========================================================================
    // Final Report
    // ==========================================================================
    $display("\n========================================================");
    $display(" EduGPU-128 Simulation Summary");
    $display("========================================================");
    $display(" Architecture:");
    $display("   SMs         : %0d", NUM_SMS);
    $display("   Cores/SM    : %0d", CORES_PER_SM);
    $display("   Total cores : %0d", NUM_SMS * CORES_PER_SM);
    $display("   Warp size   : %0d threads", WARP_SIZE);
    $display("   Warps/SM    : %0d", WARPS_PER_SM);
    $display("   SharedMem   : %0d KB/SM", SHMEM_BYTES/1024);
    $display("   L1 cache    : %0d KB/SM", L1_SIZE_BYTES/1024);
    $display("   L2 cache    : %0d KB unified", L2_SIZE_BYTES/1024);
    $display("   Clock       : %0d MHz", CLK_FREQ_MHZ);
    $display(" Peak FP32     : %0d GFLOPS", NUM_SMS * CORES_PER_SM * CLK_FREQ_MHZ / 1000);
    $display(" Peak Bandwidth: %0d GB/s (128-bit @ 500 MHz DDR)",
             128/8 * CLK_FREQ_MHZ * 2 / 1000);
    $display("========================================================");

    #100;
    $finish;
  end

  // ---------------------------------------------------------------------------
  // Waveform Dump
  // ---------------------------------------------------------------------------
  initial begin
    $dumpfile("edugpu_sim.vcd");
    $dumpvars(0, tb_edugpu_top);
  end

  // ---------------------------------------------------------------------------
  // Timeout watchdog
  // ---------------------------------------------------------------------------
  initial begin
    #10_000_000; // 10 ms simulation limit
    $display("[TB] TIMEOUT: simulation exceeded 10 ms limit");
    $finish;
  end

endmodule