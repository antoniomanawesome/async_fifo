//async fifo with rdc?
//rd and wr in diff clk domains u know how it is

module async_fifo #(
    parameter int WIDTH = 32,
    DEPTH = 32
) (
    input  logic             wr_clk,
    input  logic             rd_clk,
    input  logic             rst,

    input  logic             wr_en,
    input  logic             rd_en,

    output logic             full,
    output logic             empty,

    input  logic [WIDTH-1:0] wr_data,
    output logic [WIDTH-1:0] rd_data
);

logic [WIDTH-1:0] mem[DEPTH];
logic valid_wr, valid_rd;

//checking the en w the flags too
assign valid_rd = rd_en && !empty;
assign valid_wr = wr_en && !full;

//diff than normal fifo they have to be gray coded and synchronized
localparam int ADDR_WIDTH = $clog2(DEPTH) + 1;
logic [ADDR_WIDTH-1:0] wr_addr_r, rd_addr_r;

always_ff@(posedge wr_clk) begin
    if(valid_wr) mem[wr_addr_r[ADDR_WIDTH-2:0]] <= wr_data;
end

always_ff@(posedge rd_clk) begin
    if(valid_rd) rd_data <= mem[rd_addr_r[ADDR_WIDTH-2:0]];
end

assign full = rd_addr_r[ADDR_WIDTH-2:0] == wr_addr_r[ADDR_WIDTH-2:0] && rd_addr_r[ADDR_WIDTH] != wr_addr_r[ADDR_WIDTH];
assign empty = rd_addr_r == wr_addr_r;

//add some assertions to check the flags
assert property (@(posedge wr_clk) valid_wr |-> !full);
assert property (@(posedge rd_clk) valid_rd |-> !empty);

endmodule
