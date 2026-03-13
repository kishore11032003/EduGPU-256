`timescale 1ns/1ps

module register_file
#(
  parameter THREADS = 32,
  parameter NUM_REGS = 32
)
(
  input  logic clk,
  input  logic rst_n,

  // READ PORT A
  input  logic rd_en_a,
  input  logic [4:0] rd_reg_a,
  input  logic [4:0] rd_thread_base_a,
  output logic [31:0] rd_data_a [0:THREADS-1],

  // READ PORT B
  input  logic rd_en_b,
  input  logic [4:0] rd_reg_b,
  input  logic [4:0] rd_thread_base_b,
  output logic [31:0] rd_data_b [0:THREADS-1],

  // WRITE PORT
  input  logic wr_en,
  input  logic [4:0] wr_reg,
  input  logic [4:0] wr_thread_base,
  input  logic [31:0] wr_data [0:THREADS-1],
  input  logic [THREADS-1:0] wr_thread_mask
);

  logic [31:0] bank [0:THREADS-1][0:NUM_REGS-1];


  logic              wr_en_r;
  logic [4:0]        wr_reg_r;
  logic [4:0]        wr_thread_base_r;
  logic [31:0]       wr_data_r [0:THREADS-1];
  logic [THREADS-1:0] wr_thread_mask_r;

  always_ff @(negedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wr_en_r           <= 1'b0;
      wr_reg_r          <= '0;
      wr_thread_base_r  <= '0;
      wr_thread_mask_r  <= '0;
      for (int i = 0; i < THREADS; i++) wr_data_r[i] <= '0;
    end else begin
      wr_en_r           <= wr_en;
      wr_reg_r          <= wr_reg;
      wr_thread_base_r  <= wr_thread_base;
      wr_thread_mask_r  <= wr_thread_mask;
      for (int i = 0; i < THREADS; i++) wr_data_r[i] <= wr_data[i];
    end
  end

  // RESET + WRITE
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int lane = 0; lane < THREADS; lane++)
        for (int r = 0; r < NUM_REGS; r++)
          bank[lane][r] <= 32'd0;
    end else if (wr_en_r && wr_reg_r != 5'd0) begin
      for (int lane = 0; lane < THREADS; lane++) begin
        int tid = int'(wr_thread_base_r) + lane;
        if (wr_thread_mask_r[tid])
          bank[tid][wr_reg_r] <= wr_data_r[lane];
      end
    end
  end

  // READ PORT A
  always_comb begin
    for (int lane = 0; lane < THREADS; lane++) begin
      int tid = int'(rd_thread_base_a) + lane;
      if (!rd_en_a || rd_reg_a == 5'd0)
        rd_data_a[lane] = 32'd0;
      else
        rd_data_a[lane] = bank[tid][rd_reg_a];
    end
  end

  // READ PORT B
  always_comb begin
    for (int lane = 0; lane < THREADS; lane++) begin
      int tid = int'(rd_thread_base_b) + lane;
      if (!rd_en_b || rd_reg_b == 5'd0)
        rd_data_b[lane] = 32'd0;
      else
        rd_data_b[lane] = bank[tid][rd_reg_b];
    end
  end

endmodule