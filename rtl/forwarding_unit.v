`default_nettype none
// =============================================================================
// forwarding_unit -- operand bypass select for the EX stage.
//
//   sel = 2'd0 : value read from the register file in ID (held in ID/EX)
//   sel = 2'd1 : forward EX/MEM result      (producer is 1 instruction ahead)
//   sel = 2'd2 : forward MEM/WB write value (producer is 2 instructions ahead)
//
// Producers 3 instructions ahead are handled by the register file's
// write-through bypass.  EX/MEM has priority over MEM/WB so the *youngest*
// in-flight writer wins.  $0 never forwards.
//
// A load in EX/MEM cannot legally be forwarded from here (its data is only
// available at the end of MEM); the hazard unit stalls the consumer so that
// the producer is in MEM/WB by the time the consumer reaches EX.  The single
// exception is store *data* (rt of SB/SH/SW) when MEM->MEM forwarding is
// enabled -- that is repaired inside mem_stage.
// =============================================================================
module forwarding_unit (
    input  wire [4:0] ex_rs,
    input  wire [4:0] ex_rt,

    input  wire       exmem_we,      // EX/MEM holds a valid register-writing instruction
    input  wire [4:0] exmem_dest,
    input  wire       memwb_we,
    input  wire [4:0] memwb_dest,

    output wire [1:0] fwd_a,
    output wire [1:0] fwd_b
);
    wire a_exmem = exmem_we && (exmem_dest != 5'd0) && (exmem_dest == ex_rs);
    wire a_memwb = memwb_we && (memwb_dest != 5'd0) && (memwb_dest == ex_rs);
    wire b_exmem = exmem_we && (exmem_dest != 5'd0) && (exmem_dest == ex_rt);
    wire b_memwb = memwb_we && (memwb_dest != 5'd0) && (memwb_dest == ex_rt);

    assign fwd_a = a_exmem ? 2'd1 : a_memwb ? 2'd2 : 2'd0;
    assign fwd_b = b_exmem ? 2'd1 : b_memwb ? 2'd2 : 2'd0;
endmodule
`default_nettype wire
