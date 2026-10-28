`default_nettype none
`include "mips_defs.vh"
// =============================================================================
// perf_counters -- cycle / event accumulation and retired-instruction mix.
//
// Counts are frozen once the core halts.  Instruction classification is done
// on the retired instruction word so it is identical for both cores.
// =============================================================================
module perf_counters (
    input  wire        clk,
    input  wire        rst,
    input  wire        halted,

    input  wire        ret_valid,
    input  wire [31:0] ret_instr,

    input  wire        evt_stall,
    input  wire        evt_ex_redirect,
    input  wire        evt_id_redirect,
    input  wire [1:0]  evt_squash,
    input  wire        evt_br,
    input  wire        evt_br_taken,
    input  wire [1:0]  evt_fwd_exmem,
    input  wire [1:0]  evt_fwd_memwb,

    output reg  [31:0] cycles,
    output reg  [31:0] instret,
    output reg  [31:0] stalls_loaduse,
    output reg  [31:0] redirects_ex,
    output reg  [31:0] redirects_id,
    output reg  [31:0] squashed,
    output reg  [31:0] branches,
    output reg  [31:0] branches_taken,
    output reg  [31:0] fwd_exmem,
    output reg  [31:0] fwd_memwb,
    // retired instruction mix
    output reg  [31:0] mix_alu,
    output reg  [31:0] mix_load,
    output reg  [31:0] mix_store,
    output reg  [31:0] mix_branch,
    output reg  [31:0] mix_jump
);
    wire [5:0] op = ret_instr[31:26];
    wire [5:0] fn = ret_instr[5:0];

    wire is_load   = (op == `OP_LB) | (op == `OP_LH) | (op == `OP_LW) | (op == `OP_LBU) | (op == `OP_LHU);
    wire is_store  = (op == `OP_SB) | (op == `OP_SH) | (op == `OP_SW);
    wire is_branch = (op == `OP_BEQ) | (op == `OP_BNE) | (op == `OP_BLEZ) | (op == `OP_BGTZ) |
                     ((op == `OP_REGIMM) & ((ret_instr[20:16] == `RI_BLTZ) | (ret_instr[20:16] == `RI_BGEZ)));
    wire is_jump   = (op == `OP_J) | (op == `OP_JAL) |
                     ((op == `OP_SPECIAL) & ((fn == `FN_JR) | (fn == `FN_JALR)));

    always @(posedge clk) begin
        if (rst) begin
            cycles <= 0; instret <= 0; stalls_loaduse <= 0; redirects_ex <= 0;
            redirects_id <= 0; squashed <= 0; branches <= 0; branches_taken <= 0;
            fwd_exmem <= 0; fwd_memwb <= 0;
            mix_alu <= 0; mix_load <= 0; mix_store <= 0; mix_branch <= 0; mix_jump <= 0;
        end else if (!halted) begin
            cycles         <= cycles + 1;
            stalls_loaduse <= stalls_loaduse + evt_stall;
            redirects_ex   <= redirects_ex   + evt_ex_redirect;
            redirects_id   <= redirects_id   + evt_id_redirect;
            squashed       <= squashed       + evt_squash;
            branches       <= branches       + evt_br;
            branches_taken <= branches_taken + evt_br_taken;
            fwd_exmem      <= fwd_exmem      + evt_fwd_exmem;
            fwd_memwb      <= fwd_memwb      + evt_fwd_memwb;
            if (ret_valid) begin
                instret <= instret + 1;
                if      (is_load)   mix_load   <= mix_load   + 1;
                else if (is_store)  mix_store  <= mix_store  + 1;
                else if (is_branch) mix_branch <= mix_branch + 1;
                else if (is_jump)   mix_jump   <= mix_jump   + 1;
                else                mix_alu    <= mix_alu    + 1;
            end
        end
    end
endmodule
`default_nettype wire
