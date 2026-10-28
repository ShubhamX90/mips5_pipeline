`default_nettype none
`include "mips_defs.vh"
// =============================================================================
// alu -- 32-bit integer ALU.
//
// Shifts take the shift amount from a[4:0] and the value to shift from b, so
// that both immediate (SLL/SRL/SRA) and variable (SLLV/SRLV/SRAV) shifts map to
// the same operand ordering.  MUL returns the low 32 bits of the product
// (SPECIAL2 MUL); it is modelled as a single-cycle operation.
// =============================================================================
module alu (
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire [3:0]  op,
    output reg  [31:0] y
);
    wire signed [31:0] sa = a;
    wire signed [31:0] sb = b;
    wire [4:0]         sh = a[4:0];

    always @* begin
        case (op)
            `ALU_ADD:  y = a + b;
            `ALU_SUB:  y = a - b;
            `ALU_AND:  y = a & b;
            `ALU_OR:   y = a | b;
            `ALU_XOR:  y = a ^ b;
            `ALU_NOR:  y = ~(a | b);
            `ALU_SLT:  y = {31'b0, (sa < sb)};
            `ALU_SLTU: y = {31'b0, (a < b)};
            `ALU_SLL:  y = b << sh;
            `ALU_SRL:  y = b >> sh;
            `ALU_SRA:  y = sb >>> sh;
            `ALU_LUI:  y = {b[15:0], 16'b0};
            `ALU_MUL:  y = a * b;
            default:   y = 32'b0;
        endcase
    end
endmodule
`default_nettype wire
