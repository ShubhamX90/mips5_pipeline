// =============================================================================
// mips_defs.vh -- shared encodings for the MIPS-5 core family
//
// Single source of truth for opcode / funct / internal control encodings used
// by the RTL.  tools/isa.py mirrors the *architectural* encodings (opcodes,
// functs); the internal control encodings (ALU_*, BR_*, SZ_*, EXC_*) are
// RTL-private.
// =============================================================================
`ifndef MIPS_DEFS_VH
`define MIPS_DEFS_VH

// ---- Primary opcodes (instr[31:26]) -----------------------------------------
`define OP_SPECIAL   6'h00
`define OP_REGIMM    6'h01
`define OP_J         6'h02
`define OP_JAL       6'h03
`define OP_BEQ       6'h04
`define OP_BNE       6'h05
`define OP_BLEZ      6'h06
`define OP_BGTZ      6'h07
`define OP_ADDI      6'h08
`define OP_ADDIU     6'h09
`define OP_SLTI      6'h0A
`define OP_SLTIU     6'h0B
`define OP_ANDI      6'h0C
`define OP_ORI       6'h0D
`define OP_XORI      6'h0E
`define OP_LUI       6'h0F
`define OP_SPECIAL2  6'h1C
`define OP_LB        6'h20
`define OP_LH        6'h21
`define OP_LW        6'h23
`define OP_LBU       6'h24
`define OP_LHU       6'h25
`define OP_SB        6'h28
`define OP_SH        6'h29
`define OP_SW        6'h2B

// ---- SPECIAL funct codes (instr[5:0]) ---------------------------------------
`define FN_SLL      6'h00
`define FN_SRL      6'h02
`define FN_SRA      6'h03
`define FN_SLLV     6'h04
`define FN_SRLV     6'h06
`define FN_SRAV     6'h07
`define FN_JR       6'h08
`define FN_JALR     6'h09
`define FN_BREAK    6'h0D
`define FN_ADD      6'h20
`define FN_ADDU     6'h21
`define FN_SUB      6'h22
`define FN_SUBU     6'h23
`define FN_AND      6'h24
`define FN_OR       6'h25
`define FN_XOR      6'h26
`define FN_NOR      6'h27
`define FN_SLT      6'h2A
`define FN_SLTU     6'h2B
// SPECIAL2 funct
`define FN2_MUL     6'h02

// ---- REGIMM rt codes --------------------------------------------------------
`define RI_BLTZ     5'h00
`define RI_BGEZ     5'h01

// ---- Internal ALU operation encoding ----------------------------------------
`define ALU_ADD     4'd0
`define ALU_SUB     4'd1
`define ALU_AND     4'd2
`define ALU_OR      4'd3
`define ALU_XOR     4'd4
`define ALU_NOR     4'd5
`define ALU_SLT     4'd6
`define ALU_SLTU    4'd7
`define ALU_SLL     4'd8
`define ALU_SRL     4'd9
`define ALU_SRA     4'd10
`define ALU_LUI     4'd11
`define ALU_MUL     4'd12

// ---- Conditional-branch type encoding ---------------------------------------
`define BR_NONE     3'd0
`define BR_EQ       3'd1
`define BR_NE       3'd2
`define BR_LEZ      3'd3
`define BR_GTZ      3'd4
`define BR_LTZ      3'd5
`define BR_GEZ      3'd6

// ---- Memory access size (log2 bytes) ----------------------------------------
`define SZ_B        2'd0
`define SZ_H        2'd1
`define SZ_W        2'd2

// ---- Retirement memory-op class ---------------------------------------------
`define MOP_NONE    2'd0
`define MOP_LOAD    2'd1
`define MOP_STORE   2'd2

// ---- Exception / halt codes -------------------------------------------------
// A non-zero code halts the core when the instruction reaches write-back.
// BREAK retires (it appears in the retirement trace); ILLEGAL and ADDR do not.
`define EXC_NONE    2'd0
`define EXC_BREAK   2'd1
`define EXC_ILLEGAL 2'd2
`define EXC_ADDR    2'd3

// ---- Misc constants ---------------------------------------------------------
`define NOP_INSTR       32'h0000_0000   // sll $0,$0,0
`define ILLEGAL_FETCH   32'hFFFF_FFFF   // returned for unmapped fetches (opcode 0x3F)

`endif
