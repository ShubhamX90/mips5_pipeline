`default_nettype none
// =============================================================================
// hazard_unit -- load-use interlock and control-flow flush arbitration.
//
// Load-use stall:
//   A load in EX produces its data at the end of MEM, so an instruction in ID
//   that needs that register one cycle later cannot be fed by forwarding.
//   The consumer is held in ID for exactly one cycle (PC and IF/ID frozen, a
//   bubble enters EX); afterwards the load is in MEM/WB and the normal
//   MEM/WB -> EX forward path supplies the data.
//
//   The stall is *precise*: it only fires if the ID instruction actually
//   consumes the register (decoder uses_rs / uses_rt).  With MEM_MEM_FWD=1 a
//   store's rt (data) is excluded, since mem_stage forwards it a cycle later.
//
// Control hazards:
//   ex_redirect (taken branch / jr / jalr, resolved in EX)
//       -> flush IF/ID and ID/EX  (2 wrong-path instructions squashed)
//   id_jump (j / jal, resolved in ID)
//       -> flush IF/ID            (1 wrong-path instruction squashed)
//   If both occur in one cycle the EX redirect wins: the jump in ID is itself
//   wrong-path and is flushed rather than redirecting.
// =============================================================================
module hazard_unit #(
    parameter MEM_MEM_FWD = 1
) (
    // instruction in ID
    input  wire [4:0] id_rs,
    input  wire [4:0] id_rt,
    input  wire       id_uses_rs,     // already gated with ifid_valid
    input  wire       id_uses_rt,
    input  wire       id_is_store,
    input  wire       id_jump,

    // instruction in EX
    input  wire       ex_valid,
    input  wire       ex_mem_read,
    input  wire       ex_reg_write,
    input  wire [4:0] ex_dest,
    input  wire       ex_redirect,

    output wire       load_use,       // raw hazard detected
    output wire       stall,          // freeze PC / IF-ID, bubble into EX
    output wire       flush_ifid,
    output wire       flush_idex,
    output wire       redirect_id     // j/jal actually redirects this cycle
);
    wire ex_is_load = ex_valid & ex_mem_read & ex_reg_write & (ex_dest != 5'd0);
    wire rt_needed  = id_uses_rt & ~((MEM_MEM_FWD != 0) & id_is_store);

    assign load_use = ex_is_load &
                      ((id_uses_rs & (id_rs == ex_dest)) |
                       (rt_needed  & (id_rt == ex_dest)));

    // A load in EX cannot be a redirecting instruction, so these never overlap
    // (checked by an assertion); the gating is defensive.
    assign stall       = load_use & ~ex_redirect;
    assign redirect_id = id_jump & ~ex_redirect & ~stall;
    assign flush_idex  = ex_redirect;
    assign flush_ifid  = ex_redirect | redirect_id;
endmodule
`default_nettype wire
