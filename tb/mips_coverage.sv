// =============================================================================
// mips_coverage -- hazard / control-flow functional coverage.
//
// Hand-rolled cover points (counters) rather than covergroups so it runs on
// any simulator.  Every bin is something a verification engineer would call a
// "corner": each forwarding path per operand, forwarding priority, register
// file bypass, each flavour of load-use stall, every redirect source, EX-vs-ID
// redirect conflict, wrong-path instructions of each dangerous kind being
// squashed, $0 non-forwarding, and each halt cause.
//
// The regression driver merges the per-test COV lines and requires every bin
// that is reachable in the chosen configuration to be hit at least once.
// =============================================================================
`define COV(name, cond) \
    integer cov_``name = 0; \
    always @(posedge clk) if (!rst && (cond)) cov_``name = cov_``name + 1;
`define COVREP(name) $display("COV %s=%0d", `"name`", cov_``name);

module mips_coverage;
    `include "dut_probes.svh"

    // helpers ------------------------------------------------------------------
    wire id_valid_branch = ifid_valid && id_br_type != 3'd0;
    wire id_valid_jr     = ifid_valid && id_is_jr;
    wire flush_cause_ex  = ex_redirect;
    wire [5:0] id_op     = ifid_instr[31:26];
    wire [5:0] exmem_op  = exmem_instr[31:26];
    wire [5:0] memwb_op  = memwb_instr[31:26];
    wire memwb_is_load   = memwb_valid && (memwb_op == 6'h20 || memwb_op == 6'h21 || memwb_op == 6'h23 ||
                                           memwb_op == 6'h24 || memwb_op == 6'h25);
    wire a_exmem = fwd_a == 2'd1 && idex_valid && idex_uses_rs;
    wire b_exmem = fwd_b == 2'd1 && idex_valid && idex_uses_rt;
    wire a_memwb = fwd_a == 2'd2 && idex_valid && idex_uses_rs;
    wire b_memwb = fwd_b == 2'd2 && idex_valid && idex_uses_rt;

    // ---- forwarding ------------------------------------------------------------
    `COV(fwd_exmem_rs,          a_exmem)
    `COV(fwd_exmem_rt,          b_exmem)
    `COV(fwd_memwb_rs,          a_memwb)
    `COV(fwd_memwb_rt,          b_memwb)
    `COV(fwd_rs_exmem_rt_memwb, a_exmem && b_memwb)
    `COV(fwd_rs_memwb_rt_exmem, a_memwb && b_exmem)
    `COV(fwd_both_exmem,        a_exmem && b_exmem)
    `COV(fwd_both_memwb,        a_memwb && b_memwb)
    `COV(fwd_priority_rs,       idex_valid && idex_uses_rs && exmem_valid && exmem_reg_write && exmem_dest != 0 &&
                                exmem_dest == idex_rs && memwb_valid && memwb_reg_write && memwb_dest == idex_rs)
    `COV(fwd_priority_rt,       idex_valid && idex_uses_rt && exmem_valid && exmem_reg_write && exmem_dest != 0 &&
                                exmem_dest == idex_rt && memwb_valid && memwb_reg_write && memwb_dest == idex_rt)
    `COV(fwd_memwb_of_load,     (a_memwb || b_memwb) && memwb_is_load)
    `COV(fwd_exmem_of_jal,      a_exmem && exmem_op == 6'h03)
    `COV(fwd_into_mul,          idex_valid && idex_alu_op == 4'd12 && (a_exmem || b_exmem || a_memwb || b_memwb))
    `COV(fwd_to_store_data,      idex_valid && idex_mem_write && (b_exmem || b_memwb))
    `COV(fwd_to_store_addr,      idex_valid && idex_mem_write && (a_exmem || a_memwb))
    `COV(fwd_to_load_addr,       idex_valid && idex_mem_read  && (a_exmem || a_memwb))
    // a write to $0 (reg_write set, dest==0) must never be forwarded to a reader of $0
    `COV(zero_dest_producer_rs, idex_valid && idex_uses_rs && idex_rs == 0 && exmem_valid && exmem_reg_write && exmem_dest == 0 && fwd_a == 0)
    `COV(zero_dest_producer_rt, idex_valid && idex_uses_rt && idex_rt == 0 && exmem_valid && exmem_reg_write && exmem_dest == 0 && fwd_b == 0)
    `COV(rf_bypass_rs,          ifid_valid && id_uses_rs && rf_we && rf_waddr == rf_raddr1 && rf_waddr != 0)
    `COV(rf_bypass_rt,          ifid_valid && id_uses_rt && rf_we && rf_waddr == rf_raddr2 && rf_waddr != 0)

    // ---- load-use ---------------------------------------------------------------
    `COV(stall_rs_only,         stall && id_uses_rs && id_rs == idex_dest && !(id_uses_rt && id_rt == idex_dest))
    `COV(stall_rt_only,         stall && id_uses_rt && id_rt == idex_dest && !(id_uses_rs && id_rs == idex_dest))
    `COV(stall_rs_and_rt,       stall && id_uses_rs && id_rs == idex_dest && id_uses_rt && id_rt == idex_dest)
    `COV(stall_for_branch,      stall && id_valid_branch)
    `COV(stall_for_jr,          stall && id_valid_jr)
    `COV(stall_for_store_addr,  stall && id_is_store && id_uses_rs && id_rs == idex_dest)
    `COV(stall_for_load_addr,   stall && id_mem_read)
    `COV(stall_for_store_data,  stall && id_is_store && id_uses_rt && id_rt == idex_dest && id_rs != idex_dest)
    `COV(load_store_data_nostall, ifid_valid && id_is_store && idex_valid && idex_mem_read && idex_reg_write &&
                                idex_dest != 0 && id_rt == idex_dest && id_rs != idex_dest && !stall)
    `COV(st_fwd_mem_mem,        st_fwd)

    // ---- control flow -----------------------------------------------------------
    `COV(br_taken,              ex_br_taken)
    `COV(br_not_taken,          ex_br_cond && !ex_br_taken)
    `COV(br_taken_fwd_exmem,    ex_br_taken && (a_exmem || b_exmem))
    `COV(br_taken_fwd_memwb,    ex_br_taken && (a_memwb || b_memwb))
    `COV(br_back_to_back_taken, ex_br_taken && ifid_valid && id_valid_branch)
    `COV(jr_redirect,           ex_redirect && idex_is_jr && !idex_is_link)
    `COV(jalr_redirect,         ex_redirect && idex_is_jr && idex_is_link)
    `COV(jr_fwd_exmem,          ex_redirect && idex_is_jr && a_exmem)
    `COV(jr_fwd_memwb,          ex_redirect && idex_is_jr && a_memwb)
    `COV(j_redirect,            redirect_id && !id_is_link)
    `COV(jal_redirect,          redirect_id && id_is_link)
    `COV(ex_wins_over_id_jump,  ex_redirect && ifid_valid && id_jump)
    `COV(ex_redirect_ifid_bubble, ex_redirect && !ifid_valid)
    `COV(jump_in_branch_shadow, redirect_id && idex_valid && idex_br_type != 0 && !ex_br_taken)
    `COV(wrongpath_store_squashed,  ex_redirect && ifid_valid && id_is_store)
    `COV(wrongpath_load_squashed,   ex_redirect && ifid_valid && id_mem_read)
    `COV(wrongpath_halt_squashed,   ex_redirect && ifid_valid && id_exc != 0)
    `COV(wrongpath_idjump_halt_squashed, redirect_id && `DUT.imem_data[31:26] == 6'h3F)
    `COV(wrongpath_store_in_idjump_shadow, redirect_id && `DUT.imem_data[31:26] == 6'h2B)

    // ---- memory -------------------------------------------------------------------
    `COV(store_word,            dmem_we && dmem_be == 4'b1111)
    `COV(store_half,            dmem_we && (dmem_be == 4'b0011 || dmem_be == 4'b1100))
    `COV(store_byte,            dmem_we && (dmem_be == 4'b0001 || dmem_be == 4'b0010 ||
                                            dmem_be == 4'b0100 || dmem_be == 4'b1000))
    `COV(load_byte_half,        exmem_valid && exmem_mem_read && exmem_mem_size != 2'd2)
    `COV(back_to_back_loads,    exmem_valid && exmem_mem_read && memwb_valid && memwb_is_load)

    // ---- halts ------------------------------------------------------------------------
    `COV(halt_break,            halt_now && memwb_exc == 2'd1)
    `COV(halt_illegal,          halt_now && memwb_exc == 2'd2)
    `COV(halt_addr_load_store,  halt_now && memwb_exc == 2'd3 && (memwb_instr[31:26] >= 6'h20))
    `COV(halt_addr_jr,          halt_now && memwb_exc == 2'd3 && memwb_instr[31:26] == 6'h00)
    `COV(store_fault_suppressed, exmem_valid && exmem_mem_write && mem_fault)
    `COV(younger_store_killed_by_halt, halt_now && exmem_valid && exmem_mem_write)

    task report;
        begin
            `COVREP(fwd_exmem_rs) `COVREP(fwd_exmem_rt) `COVREP(fwd_memwb_rs) `COVREP(fwd_memwb_rt)
            `COVREP(fwd_rs_exmem_rt_memwb) `COVREP(fwd_rs_memwb_rt_exmem)
            `COVREP(fwd_both_exmem) `COVREP(fwd_both_memwb)
            `COVREP(fwd_priority_rs) `COVREP(fwd_priority_rt)
            `COVREP(fwd_memwb_of_load) `COVREP(fwd_exmem_of_jal) `COVREP(fwd_into_mul)
            `COVREP(fwd_to_store_data) `COVREP(fwd_to_store_addr) `COVREP(fwd_to_load_addr)
            `COVREP(zero_dest_producer_rs) `COVREP(zero_dest_producer_rt)
            `COVREP(rf_bypass_rs) `COVREP(rf_bypass_rt)
            `COVREP(stall_rs_only) `COVREP(stall_rt_only) `COVREP(stall_rs_and_rt)
            `COVREP(stall_for_branch) `COVREP(stall_for_jr) `COVREP(stall_for_store_addr)
            `COVREP(stall_for_load_addr) `COVREP(stall_for_store_data)
            `COVREP(load_store_data_nostall) `COVREP(st_fwd_mem_mem)
            `COVREP(br_taken) `COVREP(br_not_taken) `COVREP(br_taken_fwd_exmem) `COVREP(br_taken_fwd_memwb)
            `COVREP(br_back_to_back_taken)
            `COVREP(jr_redirect) `COVREP(jalr_redirect) `COVREP(jr_fwd_exmem) `COVREP(jr_fwd_memwb)
            `COVREP(j_redirect) `COVREP(jal_redirect)
            `COVREP(ex_wins_over_id_jump) `COVREP(ex_redirect_ifid_bubble) `COVREP(jump_in_branch_shadow)
            `COVREP(wrongpath_store_squashed) `COVREP(wrongpath_load_squashed) `COVREP(wrongpath_halt_squashed)
            `COVREP(wrongpath_idjump_halt_squashed) `COVREP(wrongpath_store_in_idjump_shadow)
            `COVREP(store_word) `COVREP(store_half) `COVREP(store_byte)
            `COVREP(load_byte_half) `COVREP(back_to_back_loads)
            `COVREP(halt_break) `COVREP(halt_illegal) `COVREP(halt_addr_load_store) `COVREP(halt_addr_jr)
            `COVREP(store_fault_suppressed) `COVREP(younger_store_killed_by_halt)
        end
    endtask
endmodule
