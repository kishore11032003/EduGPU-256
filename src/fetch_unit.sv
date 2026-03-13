
module fetch_unit
  import edugpu_pkg::*;
#(
  parameter int ICACHE_SIZE_BYTES = 4096,  
  parameter int ICACHE_WAYS       = 2,
  parameter int ICACHE_LINE_BYTES = 32
) (
  input  logic              clk,
  input  logic              rst_n,


  input  logic              fetch_en,         
  input  logic [1:0]        warp_sel,          
  input  logic [31:0]       warp_pc [0:1],     


  input  logic              branch_taken,
  input  logic [1:0]        branch_warp,
  input  logic [31:0]       branch_target,

 
  output logic              imem_req_valid,
  output logic [31:0]       imem_req_addr,
  input  logic              imem_resp_valid,
  input  logic [31:0]       imem_resp_data,    


  output logic              instr_valid,
  output instr_t            instr_out,
  output logic [31:0]       instr_pc_out,      
  output logic [1:0]        instr_warp_out,    

  
  input  logic              fetch_stall        
);


  localparam int ICACHE_LINES = ICACHE_SIZE_BYTES / ICACHE_LINE_BYTES;  
  localparam int OFFSET_W     = $clog2(ICACHE_LINE_BYTES);              
  localparam int INDEX_W      = $clog2(ICACHE_LINES);                   
  localparam int TAG_W        = 32 - INDEX_W - OFFSET_W;                
  localparam int WORDS_PER_LINE = ICACHE_LINE_BYTES / 4;                
  // Cache tag array
  logic [TAG_W-1:0]  icache_tag   [0:ICACHE_LINES-1];
  logic              icache_valid [0:ICACHE_LINES-1];
  // Cache data array  (each line = 8 × 32-bit words)
  logic [31:0]       icache_data  [0:ICACHE_LINES-1][0:WORDS_PER_LINE-1];


  logic [31:0]  fetch_pc;
  logic [1:0]   fetch_warp;

  logic [TAG_W-1:0]            pc_tag;
  logic [INDEX_W-1:0]          pc_index;
  logic [$clog2(WORDS_PER_LINE)-1:0] pc_word;

  logic         icache_hit;
  logic [31:0]  icache_hit_data;

  typedef enum logic [1:0] {
    FETCH_IDLE     = 2'd0,
    FETCH_MISS_REQ = 2'd1,
    FETCH_MISS_WAIT= 2'd2,
    FETCH_FILL     = 2'd3
  } fetch_state_t;

  fetch_state_t fetch_state;
  logic [31:0]  miss_pc;
  logic [1:0]   miss_warp;


  logic         instr_valid_r;
  instr_t       instr_out_r;
  logic [31:0]  instr_pc_r;
  logic [1:0]   instr_warp_r;


  always_comb begin
    fetch_pc    = warp_pc[warp_sel[0]];
    fetch_warp  = warp_sel;
    pc_tag      = fetch_pc[31 : INDEX_W+OFFSET_W];
    pc_index    = fetch_pc[INDEX_W+OFFSET_W-1 : OFFSET_W];
    pc_word     = fetch_pc[OFFSET_W-1 : 2];      
    icache_hit  = icache_valid[pc_index] &&
                  (icache_tag[pc_index] == pc_tag);
    icache_hit_data = icache_data[pc_index][pc_word];
  end


  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      fetch_state    <= FETCH_IDLE;
      instr_valid_r  <= 1'b0;
      imem_req_valid <= 1'b0;
   
      for (int i = 0; i < ICACHE_LINES; i++) begin
        icache_valid[i] = 1'b0;
        icache_tag[i]   = '0;
      end
    end else begin

  
      imem_req_valid <= 1'b0;
      instr_valid_r  <= 1'b0;

      if (branch_taken) begin

        instr_valid_r <= 1'b0;
      end else begin

        case (fetch_state)

          FETCH_IDLE: begin
            if (fetch_en && !fetch_stall) begin
              if (icache_hit) begin
               
                instr_valid_r  <= 1'b1;
                instr_out_r    <= icache_hit_data;
                instr_pc_r     <= fetch_pc;
                instr_warp_r   <= fetch_warp;
              end else begin
                
                fetch_state    <= FETCH_MISS_REQ;
                miss_pc        <= fetch_pc;
                miss_warp      <= fetch_warp;
              end
            end
          end


          FETCH_MISS_REQ: begin

            imem_req_valid <= 1'b1;
            imem_req_addr  <= {miss_pc[31:OFFSET_W], {OFFSET_W{1'b0}}};
            fetch_state    <= FETCH_MISS_WAIT;
          end


          FETCH_MISS_WAIT: begin
            if (imem_resp_valid) begin

              pc_index = miss_pc[INDEX_W+OFFSET_W-1 : OFFSET_W];
              icache_tag[pc_index]   <= miss_pc[31 : INDEX_W+OFFSET_W];
              icache_valid[pc_index] <= 1'b1;
              // Write the fetched word into the correct slot
              icache_data[pc_index][miss_pc[OFFSET_W-1:2]] <= imem_resp_data;
              fetch_state <= FETCH_FILL;
            end
          end


          FETCH_FILL: begin

            instr_valid_r  <= 1'b1;
            instr_out_r    <= icache_data
                                [miss_pc[INDEX_W+OFFSET_W-1:OFFSET_W]]
                                [miss_pc[OFFSET_W-1:2]];
            instr_pc_r     <= miss_pc;
            instr_warp_r   <= miss_warp;
            fetch_state    <= FETCH_IDLE;
          end

        endcase
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Output Assignments
  // ---------------------------------------------------------------------------
  assign instr_valid    = instr_valid_r;
  assign instr_out      = instr_out_r;
  assign instr_pc_out   = instr_pc_r;
  assign instr_warp_out = instr_warp_r;

endmodule