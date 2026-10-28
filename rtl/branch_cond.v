`default_nettype none
`include "mips_defs.vh"
// =============================================================================
// branch_cond -- evaluates a conditional-branch predicate.
// =============================================================================
module branch_cond (
    input  wire [2:0]  br_type,
    input  wire [31:0] a,        // RS
    input  wire [31:0] b,        // RT
    output reg         taken
);
    always @* begin
        case (br_type)
            `BR_EQ:  taken = (a == b);
            `BR_NE:  taken = (a != b);
            `BR_LEZ: taken = a[31] | (a == 32'b0);
            `BR_GTZ: taken = ~a[31] & (a != 32'b0);
            `BR_LTZ: taken = a[31];
            `BR_GEZ: taken = ~a[31];
            default: taken = 1'b0;
        endcase
    end
endmodule
`default_nettype wire
