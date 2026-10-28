`default_nettype none
`include "mips_defs.vh"
// =============================================================================
// Small, stateless memory-access helpers shared by both cores.
// =============================================================================

// ---- mem_check: alignment / range check -------------------------------------
module mem_check #(
    parameter ADDR_BITS = 16            // data memory spans 2**ADDR_BITS bytes
) (
    input  wire [31:0] addr,
    input  wire [1:0]  size,            // SZ_B / SZ_H / SZ_W
    output wire        fault            // misaligned or out of range
);
    wire misaligned = (size == `SZ_W && addr[1:0] != 2'b00) ||
                      (size == `SZ_H && addr[0]   != 1'b0);
    wire out_of_range = |(addr >> ADDR_BITS);
    assign fault = misaligned | out_of_range;
endmodule

// ---- load_fmt: extract + extend loaded data from the aligned word -----------
module load_fmt (
    input  wire [31:0] word,
    input  wire [1:0]  byte_off,        // addr[1:0]
    input  wire [1:0]  size,
    input  wire        sign_ext,
    output reg  [31:0] value
);
    reg [7:0]  b;
    reg [15:0] h;
    always @* begin
        case (byte_off)
            2'd0: b = word[7:0];
            2'd1: b = word[15:8];
            2'd2: b = word[23:16];
            default: b = word[31:24];
        endcase
        h = byte_off[1] ? word[31:16] : word[15:0];
        case (size)
            `SZ_B:   value = sign_ext ? {{24{b[7]}},  b} : {24'b0, b};
            `SZ_H:   value = sign_ext ? {{16{h[15]}}, h} : {16'b0, h};
            default: value = word;
        endcase
    end
endmodule

// ---- store_fmt: replicate store data into byte lanes + byte enables ---------
module store_fmt (
    input  wire [31:0] data,            // rt value
    input  wire [1:0]  byte_off,
    input  wire [1:0]  size,
    output reg  [31:0] wdata,
    output reg  [3:0]  be
);
    always @* begin
        case (size)
            `SZ_B: begin
                wdata = {4{data[7:0]}};
                be    = 4'b0001 << byte_off;
            end
            `SZ_H: begin
                wdata = {2{data[15:0]}};
                be    = byte_off[1] ? 4'b1100 : 4'b0011;
            end
            default: begin
                wdata = data;
                be    = 4'b1111;
            end
        endcase
    end
endmodule
