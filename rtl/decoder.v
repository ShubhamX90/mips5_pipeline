`default_nettype none
`include "mips_defs.vh"
// =============================================================================
// decoder -- purely combinational instruction decode, shared by the
//            single-cycle and pipelined cores.
//
// Reserved/"should-be-zero" instruction fields are ignored (as in most MIPS
// implementations).  Undefined encodings yield exc = EXC_ILLEGAL with every
// side-effecting control forced to zero, so an illegal instruction can never
// change architectural state.
//
// Operand convention (shared by every consumer of these signals):
//   ALU operand A = shamt_sel ? zext(shamt) : RS
//   ALU operand B = alu_src_imm ? imm        : RT
//   Shift ops compute  B <<|>> A[4:0]  (so immediate and variable shifts
//   share the datapath).
// =============================================================================
module decoder (
    input  wire [31:0] instr,

    output wire [4:0]  rs,
    output wire [4:0]  rt,
    output wire [4:0]  rd,
    output wire [4:0]  shamt,

    output reg  [4:0]  dest,         // architectural destination register
    output reg         reg_write,
    output reg         uses_rs,      // RS value is consumed (by EX)
    output reg         uses_rt,      // RT value is consumed (ALU operand, compare, or store data)
    output reg  [3:0]  alu_op,
    output reg         alu_src_imm,  // B operand is the immediate
    output reg         shamt_sel,    // A operand is the shift-amount field
    output reg         imm_zext,     // immediate is zero-extended (else sign-extended)
    output reg  [2:0]  br_type,      // conditional branch kind (BR_*)
    output reg         is_jr,        // register-indirect jump (jr / jalr)
    output reg         is_link,      // writes PC+4 to dest (jal / jalr)
    output reg         is_jump,      // absolute jump resolved in ID (j / jal)
    output reg         mem_read,
    output reg         mem_write,
    output reg  [1:0]  mem_size,
    output reg         mem_signed,
    output reg  [1:0]  exc
);

    wire [5:0] opcode = instr[31:26];
    wire [5:0] funct  = instr[5:0];

    assign rs    = instr[25:21];
    assign rt    = instr[20:16];
    assign rd    = instr[15:11];
    assign shamt = instr[10:6];

    always @* begin
        // Safe defaults: a NOP with no side effects.
        dest        = 5'd0;
        reg_write   = 1'b0;
        uses_rs     = 1'b0;
        uses_rt     = 1'b0;
        alu_op      = `ALU_ADD;
        alu_src_imm = 1'b0;
        shamt_sel   = 1'b0;
        imm_zext    = 1'b0;
        br_type     = `BR_NONE;
        is_jr       = 1'b0;
        is_link     = 1'b0;
        is_jump     = 1'b0;
        mem_read    = 1'b0;
        mem_write   = 1'b0;
        mem_size    = `SZ_W;
        mem_signed  = 1'b0;
        exc         = `EXC_NONE;

        case (opcode)
        // --------------------------------------------------------------- R-type
        `OP_SPECIAL: begin
            case (funct)
                `FN_SLL:  begin dest = rd; reg_write = 1; uses_rt = 1; alu_op = `ALU_SLL; shamt_sel = 1; end
                `FN_SRL:  begin dest = rd; reg_write = 1; uses_rt = 1; alu_op = `ALU_SRL; shamt_sel = 1; end
                `FN_SRA:  begin dest = rd; reg_write = 1; uses_rt = 1; alu_op = `ALU_SRA; shamt_sel = 1; end
                `FN_SLLV: begin dest = rd; reg_write = 1; uses_rs = 1; uses_rt = 1; alu_op = `ALU_SLL; end
                `FN_SRLV: begin dest = rd; reg_write = 1; uses_rs = 1; uses_rt = 1; alu_op = `ALU_SRL; end
                `FN_SRAV: begin dest = rd; reg_write = 1; uses_rs = 1; uses_rt = 1; alu_op = `ALU_SRA; end
                `FN_JR:   begin uses_rs = 1; is_jr = 1; end
                `FN_JALR: begin dest = rd; reg_write = 1; uses_rs = 1; is_jr = 1; is_link = 1; end
                `FN_BREAK: begin exc = `EXC_BREAK; end
                // ADD/SUB never trap in this core (no overflow exceptions); they
                // behave exactly like ADDU/SUBU.  Documented in docs/ISA.md.
                `FN_ADD,
                `FN_ADDU: begin dest = rd; reg_write = 1; uses_rs = 1; uses_rt = 1; alu_op = `ALU_ADD; end
                `FN_SUB,
                `FN_SUBU: begin dest = rd; reg_write = 1; uses_rs = 1; uses_rt = 1; alu_op = `ALU_SUB; end
                `FN_AND:  begin dest = rd; reg_write = 1; uses_rs = 1; uses_rt = 1; alu_op = `ALU_AND; end
                `FN_OR:   begin dest = rd; reg_write = 1; uses_rs = 1; uses_rt = 1; alu_op = `ALU_OR;  end
                `FN_XOR:  begin dest = rd; reg_write = 1; uses_rs = 1; uses_rt = 1; alu_op = `ALU_XOR; end
                `FN_NOR:  begin dest = rd; reg_write = 1; uses_rs = 1; uses_rt = 1; alu_op = `ALU_NOR; end
                `FN_SLT:  begin dest = rd; reg_write = 1; uses_rs = 1; uses_rt = 1; alu_op = `ALU_SLT; end
                `FN_SLTU: begin dest = rd; reg_write = 1; uses_rs = 1; uses_rt = 1; alu_op = `ALU_SLTU; end
                default:  begin exc = `EXC_ILLEGAL; end
            endcase
        end

        `OP_SPECIAL2: begin
            if (funct == `FN2_MUL) begin
                dest = rd; reg_write = 1; uses_rs = 1; uses_rt = 1; alu_op = `ALU_MUL;
            end else begin
                exc = `EXC_ILLEGAL;
            end
        end

        // -------------------------------------------------------- branches/jumps
        `OP_REGIMM: begin
            case (rt)
                `RI_BLTZ: begin uses_rs = 1; br_type = `BR_LTZ; end
                `RI_BGEZ: begin uses_rs = 1; br_type = `BR_GEZ; end
                default:  begin exc = `EXC_ILLEGAL; end
            endcase
        end
        `OP_J:    begin is_jump = 1; end
        `OP_JAL:  begin is_jump = 1; is_link = 1; dest = 5'd31; reg_write = 1; end
        `OP_BEQ:  begin uses_rs = 1; uses_rt = 1; br_type = `BR_EQ;  end
        `OP_BNE:  begin uses_rs = 1; uses_rt = 1; br_type = `BR_NE;  end
        `OP_BLEZ: begin uses_rs = 1; br_type = `BR_LEZ; end
        `OP_BGTZ: begin uses_rs = 1; br_type = `BR_GTZ; end

        // ------------------------------------------------------------ I-type ALU
        `OP_ADDI,
        `OP_ADDIU: begin dest = rt; reg_write = 1; uses_rs = 1; alu_src_imm = 1; alu_op = `ALU_ADD;  end
        `OP_SLTI:  begin dest = rt; reg_write = 1; uses_rs = 1; alu_src_imm = 1; alu_op = `ALU_SLT;  end
        `OP_SLTIU: begin dest = rt; reg_write = 1; uses_rs = 1; alu_src_imm = 1; alu_op = `ALU_SLTU; end
        `OP_ANDI:  begin dest = rt; reg_write = 1; uses_rs = 1; alu_src_imm = 1; imm_zext = 1; alu_op = `ALU_AND; end
        `OP_ORI:   begin dest = rt; reg_write = 1; uses_rs = 1; alu_src_imm = 1; imm_zext = 1; alu_op = `ALU_OR;  end
        `OP_XORI:  begin dest = rt; reg_write = 1; uses_rs = 1; alu_src_imm = 1; imm_zext = 1; alu_op = `ALU_XOR; end
        `OP_LUI:   begin dest = rt; reg_write = 1; alu_src_imm = 1; imm_zext = 1; alu_op = `ALU_LUI; end

        // ------------------------------------------------------------ load/store
        `OP_LB:  begin dest = rt; reg_write = 1; uses_rs = 1; alu_src_imm = 1; mem_read = 1; mem_size = `SZ_B; mem_signed = 1; end
        `OP_LH:  begin dest = rt; reg_write = 1; uses_rs = 1; alu_src_imm = 1; mem_read = 1; mem_size = `SZ_H; mem_signed = 1; end
        `OP_LW:  begin dest = rt; reg_write = 1; uses_rs = 1; alu_src_imm = 1; mem_read = 1; mem_size = `SZ_W; end
        `OP_LBU: begin dest = rt; reg_write = 1; uses_rs = 1; alu_src_imm = 1; mem_read = 1; mem_size = `SZ_B; end
        `OP_LHU: begin dest = rt; reg_write = 1; uses_rs = 1; alu_src_imm = 1; mem_read = 1; mem_size = `SZ_H; end
        `OP_SB:  begin uses_rs = 1; uses_rt = 1; alu_src_imm = 1; mem_write = 1; mem_size = `SZ_B; end
        `OP_SH:  begin uses_rs = 1; uses_rt = 1; alu_src_imm = 1; mem_write = 1; mem_size = `SZ_H; end
        `OP_SW:  begin uses_rs = 1; uses_rt = 1; alu_src_imm = 1; mem_write = 1; mem_size = `SZ_W; end

        default: begin exc = `EXC_ILLEGAL; end
        endcase
    end

endmodule
`default_nettype wire
