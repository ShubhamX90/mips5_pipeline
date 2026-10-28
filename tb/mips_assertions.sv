// =============================================================================
// mips_assertions -- SystemVerilog assertion checker for the pipelined core.
//
// Written as clocked *immediate* assertions (`assert (...) else ...`) sampled at
// the rising edge, so it runs on any simulator with SystemVerilog-2012
// immediate-assertion support (verified with Icarus Verilog 12).  Each check is
// the temporal property noted in its comment, e.g.  A05 is
//     ex_redirect |=> !ifid_valid && !idex_valid && imem_addr == $past(ex_target)
//
// The properties restate the microarchitecture's *contract* independently of
// how hazard_unit / forwarding_unit happen to compute it, so a bug in either
// shows up as a disagreement rather than being silently self-consistent.
// =============================================================================
`define CHK(name, cond) \
    assert (cond) else begin \
        fails = fails + 1; \
        $display("ASSERT FAIL [%s] @%0t", name, $time); \
    end

module mips_assertions;
    `include "dut_probes.svh"

    integer fails = 0;
    integer checks = 0;

    // ---- one-cycle history ---------------------------------------------------
    reg         p_valid = 0;            // history is meaningful
    reg         p_stall, p_ex_redirect, p_redirect_id, p_halted, p_stop;
    reg  [31:0] p_ex_target, p_id_target, p_imem_addr, p_ifid_pc, p_ifid_instr;
    reg         p_ifid_valid;
    reg         l_valid = 0;            // a previous instruction has retired
    reg  [31:0] l_pc, l_instr;          // ... and this is the last one

    function automatic is_ctrl_flow(input [31:0] i);
        // branches, j, jal (opcodes 1..7), jr, jalr
        is_ctrl_flow = (i[31:26] >= 6'd1 && i[31:26] <= 6'd7) ||
                       (i[31:26] == 6'd0 && (i[5:0] == 6'h08 || i[5:0] == 6'h09));
    endfunction

    // independent restatement of the forwarding contract
    wire a_exmem_match = exmem_valid && exmem_reg_write && exmem_dest != 0 && exmem_dest == idex_rs;
    wire a_memwb_match = memwb_valid && memwb_reg_write && memwb_dest != 0 && memwb_dest == idex_rs;
    wire b_exmem_match = exmem_valid && exmem_reg_write && exmem_dest != 0 && exmem_dest == idex_rt;
    wire b_memwb_match = memwb_valid && memwb_reg_write && memwb_dest != 0 && memwb_dest == idex_rt;

    wire ex_is_load   = idex_valid && idex_mem_read && idex_reg_write && idex_dest != 0;
    wire dep_rs       = ex_is_load && id_uses_rs && id_rs == idex_dest;
    wire dep_rt       = ex_is_load && id_uses_rt && id_rt == idex_dest && !(MM != 0 && id_is_store);

    always @(posedge clk) if (!rst) begin
        checks = checks + 1;

        // ---- hazard unit --------------------------------------------------------
        // A01: a load-use stall and an EX redirect can never coincide
        `CHK("A01 stall !& ex_redirect", !(stall && ex_redirect))
        // A02: stall |=> ID/EX holds a bubble, PC and IF/ID are frozen
        if (p_valid && p_stall && !p_stop) begin
            `CHK("A02a stall -> bubble in EX", !idex_valid)
            `CHK("A02b stall -> PC frozen", imem_addr == p_imem_addr)
            `CHK("A02c stall -> IF/ID frozen", ifid_valid && ifid_pc == p_ifid_pc && ifid_instr == p_ifid_instr)
        end
        // A03: stall is *sound*  (a real RAW dependence on the load in EX exists)
        `CHK("A03 stall => true load-use dependence", !stall || dep_rs || dep_rt)
        // A04: stall is *complete* for the rs operand and for rt
        `CHK("A04a load-use(rs) => stall", !dep_rs || stall)
        `CHK("A04b load-use(rt) => stall", !dep_rt || stall)
        // A05: stalls never last more than one cycle in a row
        if (p_valid) `CHK("A05 no back-to-back stall", !(p_stall && stall))

        // ---- control hazards -----------------------------------------------------
        // A06: ex_redirect |=> IF/ID and ID/EX are bubbles, fetch is at the target
        if (p_valid && p_ex_redirect && !p_stop) begin
            `CHK("A06a ex_redirect -> IF/ID flushed", !ifid_valid)
            `CHK("A06b ex_redirect -> ID/EX flushed", !idex_valid)
            `CHK("A06c ex_redirect -> fetch at target", imem_addr == p_ex_target)
        end
        // A07: id redirect |=> IF/ID flushed, fetch at the jump target
        if (p_valid && p_redirect_id && !p_stop) begin
            `CHK("A07a id_redirect -> IF/ID flushed", !ifid_valid)
            `CHK("A07b id_redirect -> fetch at target", imem_addr == p_id_target)
        end
        // A08: a redirect can only come from a valid instruction; EX wins over ID
        `CHK("A08a ex_redirect => idex_valid", !ex_redirect || idex_valid)
        `CHK("A08b redirect_id excluded by ex_redirect", !(redirect_id && ex_redirect))
        `CHK("A08c redirect_id => valid j/jal in ID", !redirect_id || (ifid_valid && id_jump))
        // A08d: invariant behind the 2-slot branch penalty: a valid instruction always
        //       sits in ID behind a redirecting EX instruction (IF/ID can only hold a
        //       bubble after a flush, and a flush would have squashed the redirector too)
        `CHK("A08d ex_redirect => ifid_valid", !ex_redirect || ifid_valid)

        // ---- forwarding ----------------------------------------------------------
        // A09: select encoding legal
        `CHK("A09 fwd select legal", fwd_a != 2'd3 && fwd_b != 2'd3)
        // A10: select equals the contract: youngest matching in-flight writer wins
        `CHK("A10a fwd_a", fwd_a == (a_exmem_match ? 2'd1 : a_memwb_match ? 2'd2 : 2'd0))
        `CHK("A10b fwd_b", fwd_b == (b_exmem_match ? 2'd1 : b_memwb_match ? 2'd2 : 2'd0))
        // A11: a load's *address* (EX/MEM result) is never forwarded as data to
        //      an operand that matters.  Store data (rt) is exempt when MEM->MEM
        //      forwarding repairs it in the MEM stage.
        if (idex_valid && exmem_valid && exmem_mem_read) begin
            `CHK("A11a no load-addr fwd on rs", !(fwd_a == 2'd1 && idex_uses_rs))
            `CHK("A11b no load-addr fwd on rt",
                 !(fwd_b == 2'd1 && idex_uses_rt && !(MM != 0 && idex_mem_write)))
        end
        // A12: MEM->MEM store-data repair only for stores, only when enabled
        `CHK("A12 st_fwd only for stores w/ MEM_MEM_FWD", !st_fwd || (MM != 0 && exmem_mem_write))

        // ---- structural / hygiene -------------------------------------------------
        // A13: $0 is never modified
        `CHK("A13 $0 == 0", `DUT.u_rf.regs[0] == 32'b0)
        // A14: bubbles are inert in every stage
        if (!idex_valid)
            `CHK("A14a idex bubble inert", !idex_reg_write && !idex_mem_read && !idex_mem_write &&
                                           idex_br_type == 0 && !idex_is_jr && idex_exc == 0)
        if (!exmem_valid)
            `CHK("A14b exmem bubble inert", !exmem_reg_write && !exmem_mem_read && !exmem_mem_write && exmem_exc == 0)
        if (!memwb_valid)
            `CHK("A14c memwb bubble inert", !memwb_reg_write && memwb_exc == 0)
        // A15: stores only reach memory from a valid, un-faulted, un-halted instruction
        `CHK("A15 dmem_we => legal store", !dmem_we || (exmem_valid && exmem_mem_write && !mem_fault && !stop))
        // A16: byte enables legal (non-zero, contiguous) for any write
        `CHK("A16 dmem_be legal", !dmem_we || dmem_be == 4'b0001 || dmem_be == 4'b0010 || dmem_be == 4'b0100 ||
              dmem_be == 4'b1000 || dmem_be == 4'b0011 || dmem_be == 4'b1100 || dmem_be == 4'b1111)

        // ---- retirement ------------------------------------------------------------
        // A17: only the WB-stage instruction retires
        `CHK("A17 ret_valid => memwb_valid", !ret_valid || memwb_valid)
        // A18: retired PCs are word aligned and, absent a control-flow instruction,
        //      strictly sequential  (independent of the ISS)
        if (ret_valid) begin
            `CHK("A18a ret_pc aligned", ret_pc[1:0] == 2'b00)
            if (l_valid && !is_ctrl_flow(l_instr))
                `CHK("A18b sequential retire", ret_pc == l_pc + 32'd4)
        end
        // A19: nothing happens after halt
        if (p_valid && p_halted) begin
            `CHK("A19a no retire after halt", !ret_valid)
            `CHK("A19b no store after halt", !dmem_we)
            `CHK("A19c halted sticky", halted)
        end
        // A20: no unknowns on the architectural interface (reduction-XOR is X iff any bit is X/Z)
        `CHK("A20a control known", ((^{stall, ex_redirect, redirect_id, halted, ret_valid, imem_addr}) !== 1'bx))
        if (ret_valid)
            `CHK("A20b retire known", ((^{ret_pc, ret_instr, `DUT.ret_wen, `DUT.ret_waddr, `DUT.ret_wdata}) !== 1'bx))
    end

    // ---- history capture (after the checks, same edge) -----------------------------
    always @(posedge clk) begin
        if (rst) p_valid <= 1'b0;
        else begin
            p_valid       <= 1'b1;
            p_stall       <= stall;
            p_ex_redirect <= ex_redirect;
            p_redirect_id <= redirect_id;
            p_halted      <= halted;
            p_stop        <= stop;
            p_ex_target   <= ex_target;
            p_id_target   <= id_jump_target;
            p_imem_addr   <= imem_addr;
            p_ifid_pc     <= ifid_pc;
            p_ifid_instr  <= ifid_instr;
            p_ifid_valid  <= ifid_valid;
            if (ret_valid) begin l_valid <= 1'b1; l_pc <= ret_pc; l_instr <= ret_instr; end
        end
    end

    task report;
        begin
            $display("ASSERT checks=%0d fails=%0d", checks, fails);
        end
    endtask
endmodule
