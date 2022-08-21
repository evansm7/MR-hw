/* Decode stage
 *
 *
 * ME 18/2/20
 *
 * Copyright 2020-2022 Matt Evans
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * Licensed under the Solderpad Hardware License v 2.1 (the “License”); you may
 * not use this file except in compliance with the License, or, at your option,
 * the Apache License version 2.0. You may obtain a copy of the License at
 *
 *  https://solderpad.org/licenses/SHL-2.1/
 *
 * Unless required by applicable law or agreed to in writing, any work
 * distributed under the License is distributed on an “AS IS” BASIS, WITHOUT
 * WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 * License for the specific language governing permissions and limitations
 * under the License.
 */

`include "decode_signals.vh"
`include "decode_enums.vh"
`include "arch_defs.vh"


module decode(input wire                        clk,
              input wire                        reset,

              // Inputs:
              input wire                        ifetch_valid,
              input wire [3:0]                  ifetch_fault,
              input wire [`REGSZ-1:0]           ifetch_pc,
              input wire [31:0]                 ifetch_instr,
              input wire [31:0]                 ifetch_msr, // FIXME

              input wire                        execute_stall,

              // FIXME: writeback reg inputs, to write gpr0/gpr1,
              // spr, spr_Special, xercr

              input wire                        writeback_gpr_port0_en,
              input wire [4:0]                  writeback_gpr_port0_reg,
              input wire [`REGSZ-1:0]           writeback_gpr_port0_value,
              input wire                        writeback_gpr_port1_en,
              input wire [4:0]                  writeback_gpr_port1_reg,
              input wire [`REGSZ-1:0]           writeback_gpr_port1_value,
              input wire                        writeback_xercr_en,
              input wire [`XERCRSZ-1:0]         writeback_xercr_value,
              // FIXME WB for SR
              input wire                        writeback_spr_en,
              input wire [`DE_NR_SPRS_LOG2-1:0] writeback_spr_reg,
              input wire [`REGSZ-1:0]           writeback_spr_value,
              input wire                        writeback_sspr_en,
              input wire [`DE_NR_SPRS_LOG2-1:0] writeback_sspr_reg,
              input wire [`REGSZ-1:0]           writeback_sspr_value,

              input wire                        writeback_unlock_generic,

              input wire                        execute_annul,
              input wire                        writeback_annul,

	      input wire [`REGSZ-1:0]           execute_bypass,
	      input wire [4:0]                  execute_bypass_reg,
	      input wire                        execute_bypass_valid,
              input wire [`XERCRSZ-1:0]         execute_bypass_xercr,
              input wire                        execute_bypass_xercr_valid,
	      input wire [`REGSZ-1:0]           memory_bypass,
	      input wire [4:0]                  memory_bypass_reg,
	      input wire                        memory_bypass_valid,
              input wire [`XERCRSZ-1:0]         memory_bypass_xercr,
              input wire                        memory_bypass_xercr_valid,

              input wire                        execute_writes_gpr0,
              input wire [4:0]                  execute_writes_gpr0_reg,
              input wire                        execute_writes_gpr1,
              input wire [4:0]                  execute_writes_gpr1_reg,
              input wire                        execute_writes_xercr,
              input wire                        execute2_writes_gpr0,
              input wire [4:0]                  execute2_writes_gpr0_reg,
              input wire                        execute2_writes_gpr1,
              input wire [4:0]                  execute2_writes_gpr1_reg,
              input wire                        memory_writes_gpr0,
              input wire [4:0]                  memory_writes_gpr0_reg,
              input wire                        memory_writes_gpr1,
              input wire [4:0]                  memory_writes_gpr1_reg,
              input wire                        memory_writes_xercr,

              // Outputs:
              output wire [`REGSZ-1:0]          decode_out_a,
              output wire [`REGSZ-1:0]          decode_out_b,
              output wire [`REGSZ-1:0]          decode_out_c,
              output wire [`XERCRSZ-1:0]        decode_out_d,

              output wire [`DEC_SIGS_SIZE-1:0]  decode_ibundle_out,
              output wire                       decode_valid,
              output wire [3:0]                 decode_fault,
              output wire [`REGSZ-1:0]          decode_pc,
              output wire [31:0]                decode_msr, // FIXME
              // FIXME: need instr for branch BI/BO fields, but squash/encode this!
	      output wire [31:0]                decode_instr,
              output wire                       decode_stall,

	      // Export IBATs:
	      output wire [(64*`NR_BATs)-1:0]   i_bats,
	      // Export DBATs:
	      output wire [(64*`NR_BATs)-1:0]   d_bats,
	      // Export SDR1:
	      output wire [`REGSZ-1:0]          sdr1,

	      // Perfctrs:
	      output wire                       pctr_de_stall_operands,

	      output wire                       DEC_msb,
	      /* Debug stuff */
	      output reg [7:0]                  debug_bits /* Set via SPR_DEBUG */
              );

   parameter ENABLE_GPR_BYPASS = 1;
   parameter ENABLE_COND_BYPASS = 1;
   parameter ENABLE_GPR_WAW = 1;
   parameter ENABLE_COND_WAW = 1;
   parameter WITH_BATS = 1;
   parameter WITH_MMU = 1;

   /* Architected state */
   reg [`XERCRSZ-1:0] 			     as_XERCR /*verilator public*/;

   wire [63:0] 				     as_TB /*verilator public*/;
   wire [31:0] 				     as_DEC /*verilator public*/;

   /* Local state */
   reg [`REGSZ-1:0] 			     decode_out_a_r;
   reg [`REGSZ-1:0] 			     decode_out_b_r;
   reg [`REGSZ-1:0] 			     decode_out_c_r;
   reg [`XERCRSZ-1:0] 			     decode_out_d_r;
   reg [3:0]                                 decode_fault_r;
   reg [31:0]                                decode_pc_r;
   reg [31:0]                                decode_msr_r /* verilator public */;
   reg [31:0]                                decode_instr_r /* verilator public */;
   reg [4:0]                                 de_RX;
   reg [2:0]                                 state_r;

   /* Connective tissue: */
   wire [`REGSZ-1:0] 			     gpr_a;
   wire [`REGSZ-1:0] 			     gpr_b;
   wire [`REGSZ-1:0] 			     gpr_c;

   wire [`REGSZ-1:0] 			     spr_a;
   wire [`REGSZ-1:0] 			     spr_c;

   wire [4:0] 				     INST_RT_RS = ifetch_instr[25:21];
   reg [4:0] 				     portc_gpr; // Wire

   wire [`DEC_SIGS_SIZE-1:0] 		     db;
   reg [`DEC_SIGS_SIZE-1:0] 		     decode_ibundle_out_r;
   `DEC_SIGS_DECLARE;


   always @(*) begin
      /* Gives access to the zillion sub-components in the decode bundle in
       * this module's scope: */
      {`DEC_SIGS_BUNDLE} = db;
   end

   /////////////////////////////////////////////////////////////////////////////
   // Decoder

   decode_inst DECODER(.instruction(ifetch_instr),
                       .decode_bundle(db));


   /////////////////////////////////////////////////////////////////////////////
   // Integer registers

   always @(*) begin
      if (state_r == `DE_STATE_STMW) begin
         /* For STMW, the de_RX register holds an indirected reg name
          * for store data; read that instead of what's encoded in the
          * instruction.
          */
         portc_gpr = de_RX;
      end else begin
         portc_gpr = de_portc_read_gpr_name;
      end
   end

   gpregs GPRF(.clk(clk),
               .reset(reset),

               .write_a_val(writeback_gpr_port0_value),
               .write_a_select(writeback_gpr_port0_reg),
               .write_a_en(writeback_gpr_port0_en),

               .write_b_val(writeback_gpr_port1_value),
               .write_b_select(writeback_gpr_port1_reg),
               .write_b_en(writeback_gpr_port1_en),

               .read_a_select(de_porta_read_gpr_name),
               .read_a_val(gpr_a),

               .read_b_select(de_portb_read_gpr_name),
               .read_b_val(gpr_b),

               .read_c_select(portc_gpr),
               .read_c_val(gpr_c)
               );


   /////////////////////////////////////////////////////////////////////////////
   // SPRs

   wire debug_strobe;

   decode_sprf #(.WITH_BATS(WITH_BATS),
		 .WITH_MMU(WITH_MMU)
		 )
               SPRF (.clk(clk),
		     .reset(reset),

		     .sdr1(sdr1),
		     .i_bats(i_bats),
		     .d_bats(d_bats),

		     // Read port reg selects:
		     .read_a_name(de_porta_read_spr_name),
		     .read_c_name(de_portc_read_spr_name),
		     // Read port values:
		     .spr_a(spr_a),
		     .spr_c(spr_c),

		     // Write ports:
		     .wr_spr_en(writeback_spr_en),
		     .wr_spr_name(writeback_spr_reg),
		     .wr_spr_value(writeback_spr_value),
		     .wr_sspr_en(writeback_sspr_en),
		     .wr_sspr_name(writeback_sspr_reg),
		     .wr_sspr_value(writeback_sspr_value),

		     // Special regs from elsewhere
		     .as_TB(as_TB),
		     .as_DEC(as_DEC),

		     // Debug SPR decoding:
		     .debug_written(debug_strobe)
		     );

`ifdef SIM
   always @(*) begin
      /* Port B does not read SPRs: */
      if (de_portb_type == `DE_SPR)
	$fatal(1, "DE: Unsupported port B read of SPR!");
   end

   always @(posedge clk) begin
      if (debug_strobe)
	debug_written(writeback_spr_value);
   end
`endif
   // FIXME:  Debating whether to move BATs to MEM (and plumb through to IF):


   /////////////////////////////////////////////////////////////////////////////
   // Immediate decoders
   wire [`REGSZ-1:0]                         imm_a;
   wire [`REGSZ-1:0]                         imm_b;
   wire [`REGSZ-1:0]                         imm_c;

   /* FIXME: Reduce the number of immediate-using ports, try to keep to 2 or 1,
    * rather than all of them... :P
    */

   decode_imm immA(.instruction(ifetch_instr),
		   .select(de_porta_imm_name),
		   .out(imm_a));

   decode_imm immB(.instruction(ifetch_instr),
		   .select(de_portb_imm_name),
		   .out(imm_b));

   decode_imm immC(.instruction(ifetch_instr),
		   .select(de_portc_imm_name),
		   .out(imm_c));


   ////////////////////////////////////////////////////////////////////////////////
   // Calculate GPR bypass values

   wire 				     gpr_a_bypassed_raw;
   wire 				     gpr_b_bypassed_raw;
   wire 				     gpr_c_bypassed_raw;
   wire 				     gpr_a_bypassed;
   wire 				     gpr_b_bypassed;
   wire 				     gpr_c_bypassed;
   wire [`REGSZ-1:0] 			     gpr_a_bypass_val;
   wire [`REGSZ-1:0] 			     gpr_b_bypass_val;
   wire [`REGSZ-1:0] 			     gpr_c_bypass_val;
   wire                                      xercr_bypassed_raw;
   wire                                      xercr_bypassed;
   wire [`XERCRSZ-1:0]                       xercr_bypass_val;

   decode_bypass BYPASS(.db(db),
                        .enable(ifetch_valid),// FIXME unnecessary...

                        .writeback_gpr_port0_en(writeback_gpr_port0_en),
                        .writeback_gpr_port0_reg(writeback_gpr_port0_reg),
                        .writeback_gpr_port0_value(writeback_gpr_port0_value),
                        .writeback_gpr_port1_en(writeback_gpr_port1_en),
                        .writeback_gpr_port1_reg(writeback_gpr_port1_reg),
                        .writeback_gpr_port1_value(writeback_gpr_port1_value),
                        .writeback_xercr_en(writeback_xercr_en),
                        .writeback_xercr_value(writeback_xercr_value),

                        .execute_bypass(execute_bypass),
	                .execute_bypass_reg(execute_bypass_reg),
	                .execute_bypass_valid(execute_bypass_valid),
                        .execute_bypass_xercr(execute_bypass_xercr),
                        .execute_bypass_xercr_valid(execute_bypass_xercr_valid),
	                .memory_bypass(memory_bypass),
	                .memory_bypass_reg(memory_bypass_reg),
	                .memory_bypass_valid(memory_bypass_valid),
                        .memory_bypass_xercr(memory_bypass_xercr),
                        .memory_bypass_xercr_valid(memory_bypass_xercr_valid),
                        .execute_writes_gpr0(execute_writes_gpr0),
                        .execute_writes_gpr0_reg(execute_writes_gpr0_reg),
                        .execute_writes_gpr1(execute_writes_gpr1),
                        .execute_writes_gpr1_reg(execute_writes_gpr1_reg),
                        .execute_writes_xercr(execute_writes_xercr),
                        .execute2_writes_gpr0(execute2_writes_gpr0),
                        .execute2_writes_gpr0_reg(execute2_writes_gpr0_reg),
                        .execute2_writes_gpr1(execute2_writes_gpr1),
                        .execute2_writes_gpr1_reg(execute2_writes_gpr1_reg),
                        .memory_writes_gpr0(memory_writes_gpr0),
                        .memory_writes_gpr0_reg(memory_writes_gpr0_reg),
                        .memory_writes_gpr1(memory_writes_gpr1),
                        .memory_writes_gpr1_reg(memory_writes_gpr1_reg),
                        .memory_writes_xercr(memory_writes_xercr),

                        /* Outputs */
                        .gpr_a_bypassed(gpr_a_bypassed_raw),
                        .gpr_b_bypassed(gpr_b_bypassed_raw),
                        .gpr_c_bypassed(gpr_c_bypassed_raw),
                        .xercr_bypassed(xercr_bypassed_raw),
                        .gpr_a_bypass_val(gpr_a_bypass_val),
                        .gpr_b_bypass_val(gpr_b_bypass_val),
                        .gpr_c_bypass_val(gpr_c_bypass_val),
                        .xercr_bypass_val(xercr_bypass_val)
                        );

   assign gpr_a_bypassed = gpr_a_bypassed_raw && ENABLE_GPR_BYPASS;
   assign gpr_b_bypassed = gpr_b_bypassed_raw && ENABLE_GPR_BYPASS;
   assign gpr_c_bypassed = gpr_c_bypassed_raw && ENABLE_GPR_BYPASS;
   assign xercr_bypassed = xercr_bypassed_raw && ENABLE_COND_BYPASS;

   /////////////////////////////////////////////////////////////////////////////
   // Register usage & dependency tracking, stall calculation

   // get/put terminology, ref++/ref--
   reg                                       get_xercr; // Wire
   reg                                       put_xercr; // Wire
   // Two "ports" for GPR get/put (corresponding to two 2R2W)
   reg                                       get_gpr_a; // Wire
   reg [4:0]                                 get_gpr_a_name; // Wire
   reg                                       get_gpr_b; // Wire
   reg [4:0]                                 get_gpr_b_name; // Wire
   reg                                       put_gpr_a; // Wire
   reg [4:0]                                 put_gpr_a_name; // Wire
   reg                                       put_gpr_b; // Wire
   reg [4:0]                                 put_gpr_b_name; // Wire
   // Two "ports" for SPR (and SpecialSPR) get/put
   reg                                       get_spr; // Wire
   reg [5:0]                                 get_spr_name; // Wire
   reg                                       get_sspr; // Wire
   reg [5:0]                                 get_sspr_name; // Wire
   reg                                       put_spr; // Wire
   reg [5:0]                                 put_spr_name; // Wire
   reg                                       put_sspr; // Wire
   reg [5:0]                                 put_sspr_name; // Wire
   // "Generic" (coarse-grained) SPR locking
   reg                                       get_spr_generic; // Wire
   reg                                       put_spr_generic; // Wire
   wire                                      stall_for_operands;
   wire                                      stall_for_fsm;

   decode_regdeps #(.ENABLE_GPR_WAW(ENABLE_GPR_WAW),
                    .ENABLE_COND_WAW(ENABLE_COND_WAW))
                  DEPS(.clk(clk),
	               .reset(reset),
                       /* Full current instruction information: */
                       .db(db),
                       .instr_valid(ifetch_valid),
                       .decode_state(state_r),
                       .de_RX(de_RX),
                       .lsm_reg(INST_RT_RS),

                       /* Bypass information */
                       .gpr_a_bypassed(gpr_a_bypassed),
                       .gpr_b_bypassed(gpr_b_bypassed),
                       .gpr_c_bypassed(gpr_c_bypassed),
                       .xercr_bypassed(xercr_bypassed),

                       /* Register get (issue) and writeback (put) flags: */
                       .get_xercr(get_xercr),
                       .put_xercr(put_xercr),
                       .get_gpr_a(get_gpr_a),
                       .get_gpr_a_name(get_gpr_a_name),
                       .get_gpr_b(get_gpr_b),
                       .get_gpr_b_name(get_gpr_b_name),
                       .put_gpr_a(put_gpr_a),
                       .put_gpr_a_name(put_gpr_a_name),
                       .put_gpr_b(put_gpr_b),
                       .put_gpr_b_name(put_gpr_b_name),
                       .get_spr(get_spr),
                       .get_spr_name(get_spr_name),
                       .get_sspr(get_sspr),
                       .get_sspr_name(get_sspr_name),
                       .put_spr(put_spr),
                       .put_spr_name(put_spr_name),
                       .put_sspr(put_sspr),
                       .put_sspr_name(put_sspr_name),
                       .get_spr_generic(get_spr_generic),
                       .put_spr_generic(put_spr_generic),

                       /* WB annul causes unlock of all regs (all
                        * younger instrs disappear).  Not
                        * required when EX annuls due to a branch, because
                        * older instrs need to complete/will retire regs.
                        */
                       .reset_scoreboard(writeback_annul),

                       /* Outputs:  Do we issue or stall? */
                       .stall_for_operands(stall_for_operands),
                       .stall_for_fsm(stall_for_fsm)
                       );


   /////////////////////////////////////////////////////////////////////////////
   // Pipeline capture & control

   wire plc_stall;
   wire enable_change;

   plc PLC(.clk(clk),
	   .reset(reset),
	   /* To/from previous stage */
	   .valid_in(ifetch_valid),
	   .stall_out(plc_stall),

	   /* Note: stall_for_operands affects output/forward progress,
	    * whereas stall_for_fsm acts backwards to stall/hold IF!
	    */
	   .self_stall(stall_for_operands),

	   .valid_out(decode_valid),
	   .stall_in(execute_stall),
	   .annul_in(writeback_annul || execute_annul),

	   .enable_change(enable_change)
	   );


   /////////////////////////////////////////////////////////////////////////////
   // Instruction issue and register locking (or fault issue)

   always @(posedge clk) begin
`ifdef DEBUG
      if (!enable_change) begin
         $display("DE: Nothing (IF valid %d, EXE annul %d, WB annul %d)",
                  ifetch_valid, execute_annul, writeback_annul);

	 if (execute_stall) begin
	    $display("DE: EX stalled");
	 end

         if (ifetch_valid && stall_for_operands) begin
            /* If we don't have operands, can't issue. */
	    $display("DE: '%s' stalling for operands, PC %08x", name, ifetch_pc);
         end
      end
`endif
      /* If a later stage annuls us, we effectively reset.
       *
       * Otherwise, if enable_change, we issue a new instruction (or,
       * in the case of "fsm_op" multicycle instructions, issue a
       * new uop).
       */
      if (writeback_annul || execute_annul) begin
         state_r <= `DE_STATE_IDLE;
      end

      ///////////////////////////////////////////////////////////////////////
      // Issue instructions (or pass on valid fault)

      if (enable_change) begin // exclusive to annul
	 if (ifetch_fault != 0) begin
            /* If presented with a fault from IF, pass it on.
	     */
            decode_fault_r <= ifetch_fault;
	    decode_pc_r <= ifetch_pc;
	    decode_msr_r <= ifetch_msr;
`ifdef DEBUG  $display("DE: Passing fault %d through", ifetch_fault);  `endif

         end else begin
	    /* General case:  presented with an instruction, issue it with
	     * operands.
	     */

	    if (state_r == `DE_STATE_IDLE) begin
	       //////////////////////////////////////////////////////////////
	       /* Operand A: */
	       case (de_porta_type)
                 `DE_NONE: 	begin end
		 `DE_GPR: 	if (de_porta_checkz_gpr) begin
		    decode_out_a_r <= 0;
		 end else begin
		    if (gpr_a_bypassed) begin
		       decode_out_a_r <= gpr_a_bypass_val;
		    end else begin
		       /* GPRF is reading de_porta_read_gpr_name into gpr_a, async: */
		       decode_out_a_r <= gpr_a;
		    end
		 end
		 `DE_SPR: 	decode_out_a_r <= spr_a; /* From de_porta_read_spr_name */
		 `DE_IMM: 	decode_out_a_r <= imm_a; /* From de_porta_imm_name */

`ifdef SIM	    default:	$fatal(1, "DE: Unexpected port A read type %d at PC %08x",
			               de_porta_type, ifetch_pc);
`endif
	       endcase

	       /* Operand B: */
	       case (de_portb_type)
                 `DE_NONE: 	begin end
		 `DE_GPR: 	if (gpr_b_bypassed) begin
		    decode_out_b_r <= gpr_b_bypass_val;
		 end else begin
		    /* GPRF is reading de_portb_read_gpr_name into gpr_b, async: */
		    decode_out_b_r <= gpr_b;
		 end
		 `DE_IMM: 	decode_out_b_r <= imm_b; /* From de_portb_imm_name */

`ifdef SIM	    default: 	$fatal(1, "DE: Unexpected port B read type %d at PC %08x",
			               de_portb_type, ifetch_pc);
`endif
	       endcase

	       /* Operand C: */
	       case (de_portc_type)
                 `DE_NONE: 	begin end
		 `DE_GPR: 	if (gpr_c_bypassed) begin
		    decode_out_c_r <= gpr_c_bypass_val;
		 end else begin
		    /* GPRF is reading de_portc_read_gpr_name into gpr_c, async: */
		    decode_out_c_r <= gpr_c;
		 end
		 `DE_SPR: 	decode_out_c_r <= spr_c; /* From de_portc_read_spr_name */
		 `DE_IMM:	decode_out_c_r <= imm_c; /* From de_portc_imm_name */

`ifdef SIM	    default: 	$fatal(1, "DE: Unexpected port C read type %d at PC %08x",
			               de_portc_type, ifetch_pc);
`endif
	       endcase

	       /* Operand D: */
	       if (de_portd_xercr_enable_cond) begin
		  decode_out_d_r <= xercr_bypassed ? xercr_bypass_val : as_XERCR;
	       end


	       //////////////////////////////////////////////////////////////
               /* FSM/multi-cycle ops: select next state */
               case (de_fsm_op)
                 0: begin
                 end

                 `DE_STATE_LMW: begin
                    /* First cycle of LMW:
                     * Check RT, as we only do subsequent cycles if it's
                     * < 31.
                     */
                    if (INST_RT_RS != 5'h1f) begin
                       state_r <= `DE_STATE_LMW;
                       de_RX <= INST_RT_RS + 1;
                    end
                 end

                 `DE_STATE_STMW: begin
                    /* First cycle of STMW:
                     * Similarly, only do >1 cycle if RS is <31:
                     */
                    if (INST_RT_RS != 5'h1f) begin
                       state_r <= `DE_STATE_STMW;
                       de_RX <= INST_RT_RS + 1;
                    end
                 end

`ifdef SIM	    default:	$fatal(1, "DE: Unsupported FSM op %d at PC %08x",
			               de_fsm_op, ifetch_pc);
`endif
	       endcase

	       /* Pass on decode bundle to subsequent stages: */
	       decode_ibundle_out_r <= db;


            end else if (state_r == `DE_STATE_LMW) begin
	       //////////////////////////////////////////////////////////////
               /* This is an LMW secondary cycle.
                * Don't need to read any regs, but do need to increment the
                * reg counter (de_RX) and lock that value as an output reg.
                */
               if (de_RX == 5'h1f) begin
`ifdef DEBUG         $display("DE: Issuing final LMW");  `endif
                  state_r <= `DE_STATE_IDLE;
               end else begin
                  de_RX <= de_RX + 1;
               end

               /* Synthesise a load instruction for EXE/MEM/WB
                *
                * The following syntax zeroes the output ibundle, and then
                * selectively overrides fields to create an instruction
                * with actions in EXE, MEM and WB:
                */
               decode_ibundle_out_r <= {`DEC_SIGS_SIZE{1'b0}};

               decode_ibundle_out_r[`DEC_RANGE_NAME] <= "lmw-multi";
               decode_ibundle_out_r[`DEC_RANGE_EXE_INT_OP] <= `EXOP_ALU_ADD_R0_4;
               decode_ibundle_out_r[`DEC_RANGE_EXE_R0] <= `EXUNIT_INT;
               decode_ibundle_out_r[`DEC_RANGE_MEM_OP] <= `MEM_LOAD;
               decode_ibundle_out_r[`DEC_RANGE_MEM_OP_SIZE] <= `MEM_OP_SIZE_32;
               decode_ibundle_out_r[`DEC_RANGE_WB_WRITE_GPR_PORT0] <= 1;
               decode_ibundle_out_r[`DEC_RANGE_WB_WRITE_GPR_PORT0_REG] <= de_RX;
               decode_ibundle_out_r[`DEC_RANGE_WB_WRITE_GPR_PORT0_FROM] <= `WB_PORT_MEM_RES;


            end else if (state_r == `DE_STATE_STMW) begin
	       //////////////////////////////////////////////////////////////
               /* This is a STMW secondary cycle.  Read the source reg
                * indirected by RX, and increment that counter.
                *
                * The reg must be readable in order to get in here, because
                * otherwise the stall logic would've stalled.
                */

               /* GPRF is reading from de_RX into gpr_c, async: */
               decode_out_c_r <= gpr_c;
               if (de_RX == 5'h1f) begin
`ifdef DEBUG         $display("DE: Issuing final STMW");  `endif
                  state_r <= `DE_STATE_IDLE;
               end else begin
                  de_RX <= de_RX + 1;
               end

               /* Synthesise a store instruction for EXE/MEM/WB */
               decode_ibundle_out_r <= {`DEC_SIGS_SIZE{1'b0}};

               decode_ibundle_out_r[`DEC_RANGE_NAME] <= "stmw-multi";
               decode_ibundle_out_r[`DEC_RANGE_EXE_INT_OP] <= `EXOP_ALU_ADD_R0_4;
               decode_ibundle_out_r[`DEC_RANGE_EXE_R0] <= `EXUNIT_INT;
               decode_ibundle_out_r[`DEC_RANGE_EXE_R2] <= `EXUNIT_PORT_C;
               decode_ibundle_out_r[`DEC_RANGE_MEM_OP] <= `MEM_STORE;
               decode_ibundle_out_r[`DEC_RANGE_MEM_OP_SIZE] <= `MEM_OP_SIZE_32;


            end else begin
`ifdef SIM        $fatal(1, "DE: Unsupported state %d", state_r);
`endif
	    end

	    /* Common outputs to EX: */
	    decode_pc_r <= ifetch_pc;
	    decode_msr_r <= ifetch_msr;
	    decode_instr_r <= ifetch_instr;
	    /* IF faults in an earlier case, but DE can also produce faults from decode: */
	    decode_fault_r <= de_gen_fault_type;

`ifdef DEBUG
	    $display("DE: '%s' %08x, PC %08x:  a %08x, b %08x, c %08x, d %016x (isf %d)",
		     name, ifetch_instr, ifetch_pc,
		     // NB assignments may make this hard to print here?
		     decode_out_a_r, decode_out_b_r, decode_out_c_r,
		     decode_out_d_r, de_gen_fault_type);
`endif
	 end // else: !if(ifetch_fault != 0)
      end // if (enable_change)

      if (reset) begin
         state_r        <= `DE_STATE_IDLE;
	 debug_bits     <= 8'h0;
      end
   end // always @ (posedge clk)


   /////////////////////////////////////////////////////////////////////////////
   // Register usage tracking

   /* Conditions for register usage tracking (scoreboarding/lock/unlock),
    * reflecting the sequential logic/states above:
    */
   wire regular_issue = enable_change && (ifetch_fault == 0) && (state_r == `DE_STATE_IDLE);
   wire lmw_issue = enable_change && (ifetch_fault == 0) && (state_r == `DE_STATE_LMW);

   always @(*) begin
      //////////////////// XERCR ////////////////////

      get_xercr = regular_issue && wb_write_xercr;
      put_xercr = writeback_xercr_en;

      //////////////////// GPRs ////////////////////

      if (regular_issue && wb_write_gpr_port0) begin
         get_gpr_a      = 1;
         get_gpr_a_name = wb_write_gpr_port0_reg;
      end else if (lmw_issue) begin
         get_gpr_a      = 1;
         get_gpr_a_name = de_RX;
      end else begin
         get_gpr_a      = 0;
         get_gpr_a_name = 5'h0;
      end
      get_gpr_b       = regular_issue && wb_write_gpr_port1;
      get_gpr_b_name  = wb_write_gpr_port1_reg;

      put_gpr_a       = writeback_gpr_port0_en;
      put_gpr_a_name  = writeback_gpr_port0_reg;
      put_gpr_b       = writeback_gpr_port1_en;
      put_gpr_b_name  = writeback_gpr_port1_reg;

      //////////////////// SPRs ////////////////////

      /* Most SPRs don't have individual refcounting and use LOCK_GENERIC.  The
       * remainder are commonly-used enough to warrant individual tracking.
       */
      get_spr         = 0;
      get_spr_name    = 0;
      get_sspr        = 0;
      get_sspr_name   = 0;
      get_spr_generic = 0;

      if (regular_issue) begin
         if (wb_unlocks_generic) begin
	    get_spr_generic = 1;
         end else begin
	    if (wb_write_spr && wb_write_spr_num < `DE_NR_SPRS_RLOCK) begin
               get_spr = 1;
	       get_spr_name = wb_write_spr_num;
            end

	    if (wb_write_spr_special && wb_write_spr_special_num < `DE_NR_SPRS_RLOCK) begin
               get_sspr = 1;
	       get_sspr_name = wb_write_spr_special_num;
	    end
	 end
      end

      put_spr         = 0;
      put_spr_name    = 0;
      put_sspr        = 0;
      put_sspr_name   = 0;
      put_spr_generic = 0;

      //////////////////// SPR generic ////////////////////

      if (writeback_unlock_generic) begin
         put_spr_generic = 1;
      end else begin
         if (writeback_spr_en) begin
            put_spr = 1;
            put_spr_name = writeback_spr_reg;
         end
         if (writeback_sspr_en) begin
            put_sspr = 1;
            put_sspr_name = writeback_sspr_reg;
         end
      end
   end

   /* Register value writeback:
    * - XERCR is done here
    * - GPRF takes writeback_gpr_port{0,1}_{value,reg,en}
    * - SPRF takes writeback_{spr,sspr}_{value,reg,en}
    */
   /* Writeback port for XERCR */
   always @(posedge clk) begin
      if (writeback_xercr_en) begin
         as_XERCR <= writeback_xercr_value;
      end
   end


   /////////////////////////////////////////////////////////////////////////////
   // Timebase & Decrementer

   decode_tbdec TBDEC(.clk(clk),
		      .reset(reset),

		      .write_tbl(writeback_spr_en && writeback_spr_reg == `DE_spr_TBL),
		      .write_tbu(writeback_spr_en && writeback_spr_reg == `DE_spr_TBU),
		      .write_dec(writeback_spr_en && writeback_spr_reg == `DE_spr_DEC),
		      .write_val(writeback_spr_value),

		      .tb(as_TB),
		      .dec(as_DEC),
		      .dec_trigger(DEC_msb)
		      );


   /////////////////////////////////////////////////////////////////////////////
   // Perf counters
   assign pctr_de_stall_operands = stall_for_operands && !execute_stall;  // % DE waiting for GPR values %

   /////////////////////////////////////////////////////////////////////////////
   // Assign outputs:
   assign decode_ibundle_out = decode_ibundle_out_r;

   assign decode_out_a = decode_out_a_r;
   assign decode_out_b = decode_out_b_r;
   assign decode_out_c = decode_out_c_r;
   assign decode_out_d = decode_out_d_r;
   assign decode_fault = decode_fault_r;
   assign decode_pc    = decode_pc_r;
   assign decode_msr   = decode_msr_r;
   assign decode_instr = decode_instr_r;

   /* stall_for_fsm asks previous stages to hold tight: */
   assign decode_stall = plc_stall || stall_for_fsm;


   /////////////////////////////////////////////////////////////////////////////
   // Debug info
`ifdef DEBUG
   always @(posedge clk) begin
      if (writeback_gpr_port0_en) begin
	 $display("DE: writing %08x to r%d via port0",
		  writeback_gpr_port0_value, writeback_gpr_port0_reg);
      end
      if (writeback_gpr_port1_en) begin
	 $display("DE: writing %08x to r%d via port1",
		  writeback_gpr_port1_value, writeback_gpr_port1_reg);
      end
      if (writeback_unlock_generic) begin
         $display("DE: unlock generic");
      end
   end
`endif


   /////////////////////////////////////////////////////////////////////////////
   // Debug tasks
`ifdef SIM
   task debug_written;
      input [31:0] val;
      begin
         if (val[15:8] == 8'h00) begin
            // Dump registers, then exit
            $display("GPR0 %016x", GPRF.registers[0]);
            $display("GPR1 %016x", GPRF.registers[1]);
            $display("GPR2 %016x", GPRF.registers[2]);
            $display("GPR3 %016x", GPRF.registers[3]);
            $display("GPR4 %016x", GPRF.registers[4]);
            $display("GPR5 %016x", GPRF.registers[5]);
            $display("GPR6 %016x", GPRF.registers[6]);
            $display("GPR7 %016x", GPRF.registers[7]);
            $display("GPR8 %016x", GPRF.registers[8]);
            $display("GPR9 %016x", GPRF.registers[9]);
            $display("GPR10 %016x", GPRF.registers[10]);
            $display("GPR11 %016x", GPRF.registers[11]);
            $display("GPR12 %016x", GPRF.registers[12]);
            $display("GPR13 %016x", GPRF.registers[13]);
            $display("GPR14 %016x", GPRF.registers[14]);
            $display("GPR15 %016x", GPRF.registers[15]);
            $display("GPR16 %016x", GPRF.registers[16]);
            $display("GPR17 %016x", GPRF.registers[17]);
            $display("GPR18 %016x", GPRF.registers[18]);
            $display("GPR19 %016x", GPRF.registers[19]);
            $display("GPR20 %016x", GPRF.registers[20]);
            $display("GPR21 %016x", GPRF.registers[21]);
            $display("GPR22 %016x", GPRF.registers[22]);
            $display("GPR23 %016x", GPRF.registers[23]);
            $display("GPR24 %016x", GPRF.registers[24]);
            $display("GPR25 %016x", GPRF.registers[25]);
            $display("GPR26 %016x", GPRF.registers[26]);
            $display("GPR27 %016x", GPRF.registers[27]);
            $display("GPR28 %016x", GPRF.registers[28]);
            $display("GPR29 %016x", GPRF.registers[29]);
            $display("GPR30 %016x", GPRF.registers[30]);
            $display("GPR31 %016x", GPRF.registers[31]);
            $display("CR %016x", as_XERCR[31:0]);
            $display("LR %016x", SPRF.as_LR);
            $display("CTR %016x", SPRF.as_CTR);
            $display("XER %016x", {24'h0, as_XERCR[`XERCR_SO], as_XERCR[`XERCR_OV],
				   as_XERCR[`XERCR_CA], 22'h000000, as_XERCR[`XERCR_BC]});
            // Additional state:
            $display("SPRG0 %08x", SPRF.as_SPRG0);
            $display("SPRG1 %08x", SPRF.as_SPRG1);
            $display("SPRG2 %08x", SPRF.as_SPRG2);
            $display("SPRG3 %08x", SPRF.as_SPRG3);
            $display("SRR0 %08x", SPRF.as_SRR0);
            $display("SRR1 %08x", SPRF.as_SRR1);
            $display("SDR1 %08x", SPRF.as_SDR1);
            $display("DAR %08x", SPRF.as_DAR);
            $display("DSISR %08x", SPRF.as_DSISR);
            $display("DABR %08x", SPRF.as_DABR);
            $display("Decode PC %08x", decode_pc);
            $display("EXIT = %d", val[7:0]);
            $finish();
         end else if (val[15:8] == 8'h01) begin
            // Putch
            $write("%c", val[7:0]);
         end else if (val[15:8] == 8'h02) begin
	    // Set debug bits
	    debug_bits <= val[7:0];
	 end
      end
   endtask //
`endif

endmodule // decode
