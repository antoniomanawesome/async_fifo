//async fifo with rdc?
//rd and wr in diff clk domains u know how it is

module async_fifo #(
    parameter int WIDTH = 32,
    DEPTH = 32
) (
    input  logic             wr_clk,
    input  logic             rd_clk,
    input  logic             rst,       //active high async rst

    input  logic             wr_en,
    input  logic             rd_en,

    output logic             full,
    output logic             empty,

    input  logic [WIDTH-1:0] wr_data,
    output logic [WIDTH-1:0] rd_data
);

//gray ptr only works if depth is a power of 2
if (DEPTH < 2 || (DEPTH & (DEPTH - 1)) != 0) begin : g_depth_check
    $error("async_fifo: DEPTH (%0d) must be a power of 2 >= 2", DEPTH);
end

//rdc: one rst feeds both domains, so each domain needs its own synchronizer

//async assert, sync deassert
(* ASYNC_REG = "TRUE" *) logic [1:0] wr_rst_sync, rd_rst_sync;
logic wr_rst, rd_rst;

always_ff @(posedge wr_clk or posedge rst) begin
    if (rst) wr_rst_sync <= 2'b11;
    else     wr_rst_sync <= {wr_rst_sync[0], 1'b0};
end

always_ff @(posedge rd_clk or posedge rst) begin
    if (rst) rd_rst_sync <= 2'b11;
    else     rd_rst_sync <= {rd_rst_sync[0], 1'b0};
end

assign wr_rst = wr_rst_sync[1];
assign rd_rst = rd_rst_sync[1];

logic [WIDTH-1:0] mem[DEPTH];
logic valid_wr, valid_rd;

//checking the en w the flags too
assign valid_rd = rd_en && !empty;
assign valid_wr = wr_en && !full;


localparam int ADDR_WIDTH = $clog2(DEPTH) + 1;
logic [ADDR_WIDTH-1:0] wr_addr_r, rd_addr_r;          //binary for indexing memory
logic [ADDR_WIDTH-1:0] wr_addr_next, rd_addr_next;

logic [ADDR_WIDTH-1:0] wr_gray_r, rd_gray_r;          //gray for crossing da domains
logic [ADDR_WIDTH-1:0] wr_gray_next, rd_gray_next;

//2ff synchronizers for the ptrs
(* ASYNC_REG = "TRUE" *) logic [ADDR_WIDTH-1:0] rd_gray_sync1, rd_gray_sync2;   //rd ptr in wr domain
(* ASYNC_REG = "TRUE" *) logic [ADDR_WIDTH-1:0] wr_gray_sync1, wr_gray_sync2;   //wr ptr in rd domain

//function challenge 
function automatic logic [ADDR_WIDTH-1:0] bin2gray(input logic [ADDR_WIDTH-1:0] b);
    return b ^ (b >> 1);
endfunction

//writing in wr_clk domain
always_ff@(posedge wr_clk) begin
    if(valid_wr && !wr_rst) mem[wr_addr_r[ADDR_WIDTH-2:0]] <= wr_data;
end

//reading in rd_clk domain
always_ff@(posedge rd_clk) begin
    if(valid_rd) rd_data <= mem[rd_addr_r[ADDR_WIDTH-2:0]];
end

//incrementing the pointers
//next values are computed comb so the gray ptr and flags can be registered off them
assign wr_addr_next = wr_addr_r + ADDR_WIDTH'(valid_wr);
assign wr_gray_next = bin2gray(wr_addr_next);
assign rd_addr_next = rd_addr_r + ADDR_WIDTH'(valid_rd);
assign rd_gray_next = bin2gray(rd_addr_next);

//full and empty challenge
//full = same addr but one lap ahead, in gray thats the top 2 bits flipped
localparam logic [ADDR_WIDTH-1:0] FULL_MASK = 2'b11 << (ADDR_WIDTH - 2);

//wr domain, sync the rd_ptr
always_ff @(posedge wr_clk or posedge wr_rst) begin
    if (wr_rst) begin
        wr_addr_r <= '0;
        wr_gray_r <= '0;
        full      <= 1'b0;
    end else begin
        wr_addr_r <= wr_addr_next;
        wr_gray_r <= wr_gray_next;
        full      <= wr_gray_next == (rd_gray_sync2 ^ FULL_MASK);
    end
end

always_ff @(posedge wr_clk or posedge wr_rst) begin
    if (wr_rst) {rd_gray_sync2, rd_gray_sync1} <= '0;
    else        {rd_gray_sync2, rd_gray_sync1} <= {rd_gray_sync1, rd_gray_r};
end

//rd domain, synch the wr_ptr
always_ff @(posedge rd_clk or posedge rd_rst) begin
    if (rd_rst) begin
        rd_addr_r <= '0;
        rd_gray_r <= '0;
        empty     <= 1'b1;
    end else begin
        rd_addr_r <= rd_addr_next;
        rd_gray_r <= rd_gray_next;
        empty     <= rd_gray_next == wr_gray_sync2;
    end
end

always_ff @(posedge rd_clk or posedge rd_rst) begin
    if (rd_rst) {wr_gray_sync2, wr_gray_sync1} <= '0;
    else        {wr_gray_sync2, wr_gray_sync1} <= {wr_gray_sync1, wr_gray_r};
end

//add some assertions to check the flags, sim only (synth skips them)
`ifndef SYNTHESIS

//write while full / read while empty shouldn't move ptrs
assert property (@(posedge wr_clk) disable iff (wr_rst) (wr_en && full)  |=> $stable(wr_addr_r));
assert property (@(posedge rd_clk) disable iff (rd_rst) (rd_en && empty) |=> $stable(rd_addr_r));

//gray ptrs can only change 1 bit per clk or the sync breaks
assert property (@(posedge wr_clk) disable iff (wr_rst) $onehot0(wr_gray_r ^ $past(wr_gray_r)));
assert property (@(posedge rd_clk) disable iff (rd_rst) $onehot0(rd_gray_r ^ $past(rd_gray_r)));
`endif

endmodule
