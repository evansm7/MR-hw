/* EX stage
 *
 * ME, 9 March 2020
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


module execute(input wire                       clk,
               input wire                       reset,

               input wire                       decode_valid,
               input wire [3:0]                 decode_fault,
               input wire [`REGSZ-1:0]          decode_pc,
               input wire [31:0]                decode_msr,
               input wire [31:0]                decode_instr,
               input wire [`DEC_SIGS_SIZE-1:0]  decode_ibundle_in,

               input wire [`REGSZ-1:0]          decode_op_a,
               input wire [`REGSZ-1:0]          decode_op_b,
               input wire [`REGSZ-1:0]          decode_op_c,
               input wire [`XERCRSZ-1:0]        decode_op_d,

               input wire                       memory_stall,
               input wire                       writeback_annul,

               output wire [`REGSZ-1:0]         execute_out_R0,
               output wire [`REGSZ-1:0]         execute_out_R1,
               output wire [`REGSZ-1:0]         execute_out_R2,
               output wire [`XERCRSZ-1:0]       execute_out_RC,
               output wire [5:0]                execute_out_miscflags,

	       output wire [`REGSZ-1:0]         execute_out_bypass,
	       output wire [4:0]                execute_out_bypass_reg,
	       output wire                      execute_out_bypass_valid,
               output wire [`XERCRSZ-1:0]       execute_out_bypass_xercr,
               output wire                      execute_out_bypass_xercr_valid,
               output wire                      execute_out_writes_gpr0,
               output wire [4:0]                execute_out_writes_gpr0_reg,
               output wire                      execute_out_writes_gpr1,
               output wire [4:0]                execute_out_writes_gpr1_reg,
               output wire                      execute_out_writes_xercr,
               output wire                      execute2_out_writes_gpr0,
               output wire [4:0]                execute2_out_writes_gpr0_reg,
               output wire                      execute2_out_writes_gpr1,
               output wire [4:0]                execute2_out_writes_gpr1_reg,

               output wire                      execute_valid,
               output wire [3:0]                execute_fault,
               output wire [31:0]               execute_instr,
               output wire [31:0]               execute_pc,
               output wire [31:0]               execute_msr,
               output wire [`DEC_SIGS_SIZE-1:0] execute_ibundle_out,
               output wire                      execute_brtaken,

               output wire                      execute_annul,
               output wire [`REGSZ-1:0]         execute2_newpc,
	       output wire [31:0]               execute2_newmsr,
	       output wire                      execute2_newpc_valid,
	       output wire                      execute2_newmsr_valid,

               output wire                      execute_stall
               );


   reg [`DEC_SIGS_SIZE-1:0]                     execute_ibundle_out_r;
   `DEC_SIGS_DECLARE;

   always @(*) begin
      /* Gives access to the zillion sub-components in the decode bundle in
       * this module's scope: */
      {`DEC_SIGS_BUNDLE} = decode_ibundle_in;
   end

   reg [3:0]                                    execute_fault_r;
   reg [31:0] 					execute_instr_r;
   reg [`REGSZ-1:0]                             execute_pc_r;
   reg [31:0]                                   execute_msr_r;

   reg [`REGSZ-1:0]                             execute_out_R0_r;
   reg [`REGSZ-1:0]                             execute_out_R1_r;
   reg [`REGSZ-1:0]                             execute_out_R2_r;
   reg [`XERCRSZ-1:0]                           execute_out_RC_r;
   reg [5:0]                                    execute_out_miscflags_r;

   reg                                          execute_brtaken_r;
   wire                                         exe_annul;
   wire                                         br_taken;
   reg [`REGSZ-1:0]                             res_int; // Wire
   wire [`REGSZ-1:0]                            res_special;
   wire [`REGSZ-1:0]                            res_brdest;
   wire [`XERCRSZ-1:0]                          res_rc;

   reg [1:0]                                    exe_state_r;
   reg [1:0]                                    multicycle_op_newstate; // Wire
`define EXE_STATE_IDLE    2'h0
`define EXE_STATE_DIV     2'h2
`define EXE_STATE_CONSUME 2'h3
   wire                                         exe_divide_complete;
   reg                                          exe_want_stall; // Wire

   wire                                         valid_instr_presented;
   wire						enable_change;

   wire [31:0]                                  cond_reg = decode_op_d[31:0];
   wire                                         xer_so   = decode_op_d[`XERCR_SO];
   wire                                         xer_ov   = decode_op_d[`XERCR_OV];
   wire                                         xer_ca   = decode_op_d[`XERCR_CA];
   wire [6:0]                                   xer_bc   = decode_op_d[`XERCR_BC];

   wire                                         res_alu_co;
   wire                                         res_alu_ov;
   wire [`REGSZ-1:0] 				res_alu;
   wire [`REGSZ-1:0] 				res_div;
   wire                                         res_div_ov;
   wire [5:0] 					res_cntlz;
   wire [`REGSZ-1:0] 				res_mul;
   wire                                         res_mul_ov;
   wire [`REGSZ-1:0] 				res_shift;
   wire                                         res_shift_co;
   /* There are three (related) results for flags that are broken out for clarity:
    * - res_int_crf -- General record result
    * - res_int_crf_signed -- signed comparison result
    * - res_int_crf_unsigned -- unsigned comparison result
    */
   wire [3:0]                                   res_int_crf;
   wire [3:0]                                   res_int_crf_signed;
   wire [3:0]                                   res_int_crf_unsigned;

   /////////////////////////////////////////////////////////////////////////////

   assign valid_instr_presented = decode_valid && decode_fault == 0 && !writeback_annul;

   wire                                         doing_branch;

   /* When we've a valid instruction that's a branch, and it's taken,
    * and MEM (actually, the skid buffer _i) isn't stalled, then we annul:
    * - We wait because annul will empty _this_ instruction from DE,
    *   which would be bad if this instruction also needs to write
    * 	a result (e.g. CTR or LR!), so only make the branch vanish if
    * 	 not-stalled...
    * - The EXE2 stage below guarantees to emit the newPC next cycle,
    * 	regardless of whether the CTR/LR-writing portion of the instruction
    * 	is stalled (in SB or MEM).
    * - Any other actions, such as writing back CTR or LR, will drop
    *   eventually into MEM via the skid buffer, after the branch itself
    *   has occurred with respect to IF.
    *
    * It is VERY important to base the decision to progress on enable_change,
    * rather than a stall input (such as memory_stall_i), because PLC
    * bubble-squashing will allow an instruction to be consumed from DE even
    * if a stall is flagged downstream.  But, we don't want a branch to be
    * consumed from DE's FFs if EXE2 can't emit its newPC.  If a branch follows
    * a stalling mem operation, we have to ignore the stall; by inhibiting on
    * that stall, the BR would be consumed (because enable_change is actually
    * asserted) but then have no effect.
    *
    * Note: br_taken is dependent on decode_valid.
    * Note: the EXE2 newpc_valid is independent of whether EXE itself is stalled
    * in the same cycle.
    */

   assign doing_branch = (exe_brcond != 0) && br_taken && enable_change;
   assign exe_annul = doing_branch;

   reg                                         e2_newpc_valid /*verilator public*/;
   reg                                         e2_newmsr_valid;
   reg [`REGSZ-1:0]                            e2_newpc /*verilator public*/;
   reg [31:0]                                  e2_newmsr;

   always @(posedge clk) begin
      /* If this instruction "emits newPC in mem" (AKA EXE2) and
       * it's taken, log that for next cycle
       */
      e2_newpc_valid  <= mem_newpc_valid && doing_branch && !writeback_annul;
      e2_newmsr_valid <= mem_newmsr_valid && doing_branch && !writeback_annul;
      e2_newpc        <= (exe_R2 == `EXUNIT_PORT_C) ? decode_op_c :
                         (exe_R2 == `EXUNIT_PCINC) ? {decode_pc[31:2], 2'b00} + 4 :
                         res_brdest;
      e2_newmsr       <= decode_op_a;

      /* Assert assumptions about current decoding methods... */
      if (mem_newpc_valid && mem_newpc != `MEM_R2) begin
`ifdef SIM  $fatal(1, "EXE: newpc valid, but not from MEM_R2!");
`endif
      end

      if (mem_newpc_valid && exe_R2 != `EXUNIT_PORT_C && exe_R2 != `EXUNIT_PCINC &&
          exe_R2 != `EXUNIT_BRDEST) begin
`ifdef SIM  $fatal(1, "EXE: newpc source not PORTC/PCINC/BRDEST");
`endif
      end

      if (mem_newmsr_valid && (mem_newmsr != `MEM_R0 || exe_R0 != `EXUNIT_PORT_A)) begin
         /* Only mtmsr and rfi assert newmsr valid - check if this changes... */
`ifdef SIM  $fatal(1, "EXE: newmsr valid, but not from R0/port A!");
`endif
      end

      if (reset) begin
         e2_newpc_valid  <= 0;
         e2_newmsr_valid <= 0;
         e2_newpc        <= 0;
         e2_newmsr       <= 0;
      end
   end

   assign execute2_newpc_valid = e2_newpc_valid && !writeback_annul; // FIXME shoudln't be important
   assign execute2_newpc = e2_newpc;
   assign execute2_newmsr_valid = e2_newmsr_valid && !writeback_annul;
   assign execute2_newmsr = e2_newmsr;


   /////////////////////////////////////////////////////////////////////////////
   // Multi-cycle ops

   /* The following integer ops are multi-cycle, and flag a subsequent state
    * via multicycle_op_newstate.
    */
   always @(*) begin
      if (valid_instr_presented) begin
	 /* The qualification on valid/notfault isn't really required
	  * as the consumer of multicycle_op_newstate qualifies on those,
	  * but it'll stop the signal flapping around in the wind and
	  * make traces easier to read.
	  */
	 case (exe_int_op)
           /* Multiplies always take exactly two cycles, meaning we can go
            * straight to EXE_STATE_CONSUME (1 cycle plus this one).
            */
	   `EXOP_MUL_AB:
	     multicycle_op_newstate = `EXE_STATE_CONSUME;
	   `EXOP_MUL_HW_AB:
	     multicycle_op_newstate = `EXE_STATE_CONSUME;
	   `EXOP_MUL_HWU_AB:
	     multicycle_op_newstate = `EXE_STATE_CONSUME;

           `EXOP_DIV_AB:
             multicycle_op_newstate = `EXE_STATE_DIV;
           `EXOP_DIV_U_AB:
             multicycle_op_newstate = `EXE_STATE_DIV;

	   default:
	     multicycle_op_newstate = `EXE_STATE_IDLE;
	 endcase
      end else begin
	 multicycle_op_newstate = `EXE_STATE_IDLE;
      end
   end

   /* This stage stalls if we're in (or about to enter) a multicycle state.
    *
    * If EX is in idle but the current op indicates a newstate, stall.
    * If EX is not idle, stall -- except in the CONSUME state, which explicitly drops stall
    *  so that the instruction is consumed.
    */
   always @(*) begin
      exe_want_stall = valid_instr_presented &&
                       (((exe_state_r == `EXE_STATE_IDLE) && (multicycle_op_newstate != `EXE_STATE_IDLE)) ||
                        ((exe_state_r != `EXE_STATE_IDLE) && (exe_state_r != `EXE_STATE_CONSUME)));
   end


   /////////////////////////////////////////////////////////////////////////////
   // Pipeline control
   wire execute_valid_o;
   wire memory_stall_i;

   plc PLC(.clk(clk),
	   .reset(reset),
	   /* To/from previous stage */
	   .valid_in(decode_valid),
	   .stall_out(execute_stall),

	   /* Note: exe_want_stall affects both output/forward progress and
	    * DE to stall/hold inputs.
	    */
	   .self_stall(exe_want_stall),

	   .valid_out(execute_valid_o),
	   .stall_in(memory_stall_i),
	   .annul_in(writeback_annul),

           /* enable_change is for the outputs.  FSM can
            * still change/work on intermediate results if 0.
            */
	   .enable_change(enable_change)
	   );


   /////////////////////////////////////////////////////////////////////////////
   // Sub-units:

   // ALU
   execute_alu ALU(.alu_op(exe_int_op),
		   .in_a(decode_op_a),
		   .in_b(decode_op_b),
		   .in_c(decode_op_c),
		   .carry_in(xer_ca),
		   .carry_out(res_alu_co),
		   .overflow(res_alu_ov),
		   .out(res_alu)
		   );

   // MUL:
   // Synchronous and multi-state/pipelined:
   execute_mul MUL(.clk(clk),
		   .reset(reset),

		   .enable(valid_instr_presented),
		   .mul_op(exe_int_op),
		   .in_a(decode_op_a),
		   .in_b(decode_op_b),
		   .out(res_mul),
                   .ov(res_mul_ov)
		   );

   // CNTLZW
   execute_clz CLZ(.in(decode_op_a),
                   .count(res_cntlz)
                   );

   // SHIFT
   execute_rotatemask ROTMASK(.op(exe_int_op),
                              .in_val(decode_op_a),
                              .insertee_sh(decode_op_b),
                              .SH_MB_ME(decode_op_c[14:0]),

                              .out(res_shift),
                              .co(res_shift_co)
                              );

   // DIV

   wire		divide_instr = valid_instr_presented &&
                ((exe_int_op == `EXOP_DIV_U_AB) ||
                 (exe_int_op == `EXOP_DIV_AB));
   /* Divide is enabled when exe_int_op indicates
    * EXOP_DIV_AB or EXOP_DIV_U_AB.  The condition
    * on EXE_STATE_CONSUME means that for back-to-
    * back divide ops there is at least one cycle
    * not-enabled in which the unit can reset itself.
    */
   wire		divider_enabled = divide_instr &&
                (exe_state_r != `EXE_STATE_CONSUME);

   execute_divide DIV(.clk(clk),
                      .reset(reset),

                      .enable(divider_enabled),
                      .unsigned_div(exe_int_op == `EXOP_DIV_U_AB),
                      .done(exe_divide_complete),

                      .in_a(decode_op_a),
		      .in_b(decode_op_b),
		      .out(res_div),
                      .ov(res_div_ov)
                      );


   // Integer results
   always @(*) begin
      case (exe_int_op)
	`EXOP_ALU_ADC_AB_D:     res_int = res_alu;
	`EXOP_ALU_ADC_A_0_D:    res_int = res_alu;
	`EXOP_ALU_ADC_A_M1_D:   res_int = res_alu;
	`EXOP_ALU_ADD_AB:       res_int = res_alu;
	`EXOP_ALU_ANDC_AB:      res_int = res_alu;
	`EXOP_ALU_AND_AB:       res_int = res_alu;
	`EXOP_ALU_DEC_C:        res_int = res_alu;
	`EXOP_ALU_NAND_AB:      res_int = res_alu;
	`EXOP_ALU_NEG_A:        res_int = res_alu;
	`EXOP_ALU_NOR_AB:       res_int = res_alu;
	`EXOP_ALU_NXOR_AB:      res_int = res_alu;
	`EXOP_ALU_ORC_AB:       res_int = res_alu;
	`EXOP_ALU_OR_AB:        res_int = res_alu;
	`EXOP_ALU_SUB_A_0_D:    res_int = res_alu;
	`EXOP_ALU_SUB_A_M1_D:   res_int = res_alu;
	`EXOP_ALU_SUB_BA:       res_int = res_alu;
	`EXOP_ALU_SUB_BA_D:     res_int = res_alu;
	`EXOP_ALU_XOR_AB:       res_int = res_alu;

	`EXOP_ALU_ADD_R0_4:     res_int = execute_out_R0_r + 4;

	`EXOP_DIV_AB:           res_int = res_div;
	`EXOP_DIV_U_AB:         res_int = res_div;

	`EXOP_MISC_CNTLZW_A:    res_int = {26'h0000000, res_cntlz};

	`EXOP_D_TO_CR:          res_int = decode_op_d[31:0];
	`EXOP_D_TO_XER:         res_int = {xer_so, xer_ov, xer_ca, 22'h000000, xer_bc};
	`EXOP_MSR:              res_int = decode_msr;
	`EXOP_SXT_16_A:         res_int = {{(`REGSZ-16){decode_op_a[15]}}, decode_op_a[15:0]};
	`EXOP_SXT_8_A:          res_int = {{(`REGSZ-8){decode_op_a[7]}}, decode_op_a[7:0]};

	`EXOP_MUL_AB:           res_int = res_mul; // Outputs result in 2nd cycle
	`EXOP_MUL_HWU_AB:       res_int = res_mul;
	`EXOP_MUL_HW_AB:        res_int = res_mul;

	`EXOP_SH_RLWIMI_ABC:    res_int = res_shift;
	`EXOP_SH_RLWNM_ABC:     res_int = res_shift;
	`EXOP_SH_SLW_AB:        res_int = res_shift;
	`EXOP_SH_SRAW_AB:       res_int = res_shift;
	`EXOP_SH_SRW_AB:        res_int = res_shift;

        default: begin
           res_int = 0;
           if (decode_valid && exe_int_op != 0) begin
`ifdef SIM
              $fatal(1, "EXE: Unknown int op %d", exe_int_op);
`endif
           end
        end
      endcase
   end


   // SPECIAL (exunit_special = debug instr.)
   assign res_special = `REG_ZERO;


   /////////////////////////////////////////////////////////////////////////////
   // Branches

   execute_br_cond BRCOND(.instr_cr_field(decode_instr[20:16]), // FIXME: Pass CR field instead of full decode_instr
                          .input_valid(decode_valid),
                          .input_fault(decode_fault),

                          .exe_brcond(exe_brcond),
                          .cond_reg(cond_reg),
                          /* Instead of using the logically equivalent res_int_crf[1] (EQ),
                           * compare to zero here so as not to depend on the entire res_int.
                           * (Actually, it's just the tools not being able to see that
                           * when a branch happens, res_int does not depend on ROL etc.)
                           */
                          .br_ctr_z(res_alu == `REG_ZERO),
                          .branch_taken(br_taken)
                          );


   execute_br_dest BRDEST(.brdest_op(exe_brdest_op),
                          .input_valid(decode_valid),
                          .op_a(decode_op_a),
                          .op_c(decode_op_c),
                          .pc(decode_pc),
                          .inst_aa(decode_instr[1]), // FIXME: Decode AA properly!  Remove the need for decode_instr!

                          .br_dest(res_brdest)
                          );


   /////////////////////////////////////////////////////////////////////////////
   // Condition codes

   // Condition codes on result/RC op:
   execute_crf ecrf(.in(res_int),
                    .co(res_alu_co),	// From ALU, used in unsigned compare
                    .ov(res_alu_ov),	// From ALU, used in signed compare
                    .SO(xer_so),	// Mixed into CRx
                    .crf(res_int_crf),
                    .crf_compare_signed(res_int_crf_signed),
                    .crf_compare_unsigned(res_int_crf_unsigned)
                    );
   /* NOTE: ecrf calculates a CR value for all integer operations.
    * That value is dependent on res_alu_ov, but note that the ALU ensures
    * ov=0 for anything that isn't an arithmetic operation, ensuring
    * CR is calculated correctly for things that *aren't*.
    */

   // The 'D register' is combined XER/CR.  This module splices new
   // values into it:
   execute_rc ERC(.rc_op(exe_rc_op),
                  .input_valid(decode_valid),
                  /* Some fields decoded from immediates: */
                  .BAFXM(decode_op_a[7:0]), // A: BA, FXM
                  .BBBFA(decode_op_b[31:0]), // B: BB, BFA, full 32-bit B
                  .BFBT(decode_op_c[4:0]), // C: BF, BT
                  // These signals are 0 unless respective units are active:
                  .ca(res_alu_co | res_shift_co),
                  .ov(res_alu_ov | res_mul_ov | (res_div_ov && divide_instr)),
                  .crf(res_int_crf),
                  .crf_signed(res_int_crf_signed),
                  .crf_unsigned(res_int_crf_unsigned),
                  .rc_in(decode_op_d),

                  .rc_out(res_rc)
                  );


   /////////////////////////////////////////////////////////////////////////////
   // State changes:

   always @(posedge clk) begin
      if (enable_change) begin // Can we change output data?
         if (decode_fault == 0) begin
`ifdef DEBUG   $display("EXE: '%s', PC %08x:  R0 %08x, R1 %08x, R2 %08x, RC %016x, v%d, brT %d (isf %d)",
                        name, decode_pc, execute_out_R0_r, execute_out_R1_r, execute_out_R2_r, execute_out_RC_r,
                        execute_valid_o, br_taken, execute_fault_r);
`endif
	    /* All cycles latch EXE outputs.  They're only really
	     * required when stall=0, but it's not harmful to
	     * do this during stall cycles.
	     *
	     * It also makes the last cycle of a multi-cycle op a
	     * little simpler because that outputs a value (which gets
	     * captured) in the same cycle as going back to EXE_STATE_IDLE.
	     */

            // Output R0:  MUX, FF
            case (exe_R0)
              `EXUNIT_NONE: begin end
              `EXUNIT_INT:
                execute_out_R0_r <= res_int;
              `EXUNIT_PORT_A:
                execute_out_R0_r <= decode_op_a;
              `EXUNIT_PORT_C:
                execute_out_R0_r <= decode_op_c;
              `EXUNIT_SPECIAL:
                execute_out_R0_r <= res_special;

              default: begin
`ifdef SIM	    $fatal(1, "EX: Unknown exe_R0 unit %d", exe_R0);
`endif
              end
            endcase

            // Output R1:  MUX, FF
            case (exe_R1)
              `EXUNIT_NONE: begin end
              `EXUNIT_INT:
                execute_out_R1_r <= res_int;
              `EXUNIT_PORT_B:
                execute_out_R1_r <= decode_op_b;
              `EXUNIT_PORT_C:
                execute_out_R1_r <= decode_op_c;
              `EXUNIT_PCINC:
                execute_out_R1_r <= {decode_pc[31:2], 2'b00} + 4;

              default: begin
`ifdef SIM	    $fatal(1, "EX: Unknown exe_R1 unit %d", exe_R1);
`endif
              end
            endcase

            // Output R2:  MUX, FF
            case (exe_R2)
              `EXUNIT_NONE: begin end
              `EXUNIT_INT:
                execute_out_R2_r <= res_int;
              `EXUNIT_BRDEST:
                execute_out_R2_r <= res_brdest;
              `EXUNIT_PORT_C:
                execute_out_R2_r <= decode_op_c;
              `EXUNIT_PCINC: // FIXME reduce?  (FIXME2: possibly can remove this b/c bl etc. use PCINC from R1 -- is this only for mtmsr?)
                execute_out_R2_r <= {decode_pc[31:2], 2'b00} + 4;

              default: begin
`ifdef SIM	    $fatal(1, "EX: Unknown exe_R2 unit %d", exe_R2);
`endif
              end
            endcase

            // Conditions
            if (exe_rc_op != 0) begin
               execute_out_RC_r <= res_rc;
            end

            if (exe_brcond != 0) begin
               execute_brtaken_r <= br_taken;
            end

            // Misc/debug:
            if (exe_special == `EXOP_DEBUG) begin
            end

            /* This 'misc flags' register is used for TW(I)
             * instructions, which evaluate flags (to generate a fault)
             * in MEM.  This is a bit of a hack, and done because
             * the standard CR0 doesn't include both signed/unsigned
             * comparison responses.  TW(I) uses ALU_SUB_BA.
             */
            if (exe_int_op == `EXOP_ALU_SUB_BA) begin
               /* LTu, GTu, LT, GT, EQ, SO */
               execute_out_miscflags_r <= {res_int_crf_unsigned[3:2],
                                           res_int_crf};
            end

         end else begin
`ifdef DEBUG   $display("EXE: Passing fault %d through", decode_fault);  `endif
         end

         /* Pipelined state: */
         execute_instr_r <= decode_instr;
         execute_pc_r <= decode_pc;
         execute_msr_r <= decode_msr;
         execute_fault_r <= decode_fault;

         // FIXME: But override mem_newpc_valid and wb_write_spr_special!
         // May be easier/clearer to pass an explicit 'take branch' signal rather
         // than try to rewrite the decode signals in place.
         // (FIXME: umm but remember LR is written even if condition fails!)
         execute_ibundle_out_r <= decode_ibundle_in;
      end // if (enable_change)


      ///////////////////////////////////////////////////////////////////////
      // Execute FSM

      if (writeback_annul) begin
`ifdef DEBUG $display("EXE: Annulled");	`endif
         /* If annulled, instruction vanishes. */
         exe_state_r <= `EXE_STATE_IDLE;

      end else if (valid_instr_presented) begin
         /* The FSM here acts somewhat independently of plc/enable_change,
          * because states can change when this stage asserts exe_want_stall.
          *
          * That's the point here: we stall while doing, say, a DIV, but
          * the FSM can move on (into CONSUME, i.e. done) even so.
          */
         if (exe_state_r == `EXE_STATE_IDLE) begin
	    if (multicycle_op_newstate != `EXE_STATE_IDLE) begin
	       /* If this cycle was the first cycle of a multicycle
		* instruction, move into a new state to complete it:
		*/
	       exe_state_r <= multicycle_op_newstate;
`ifdef DEBUG      $display("EXE: Multi-cycle op %d begins", multicycle_op_newstate);  `endif
	    end

	 end else if (exe_state_r == `EXE_STATE_DIV) begin
	    /* The comb logic selects divider output into res_int, which
	     * is then captured into execute_out_R0_r above.
             *
             * We stay in this state for a variable number of cycles
             * until the divider unit flags completion.
	     */
            if (exe_divide_complete) begin
	       exe_state_r <= `EXE_STATE_CONSUME;
`ifdef DEBUG	     $display("EXE: Multi-cycle DIV complete");  `endif
            end

         end else if (enable_change && (exe_state_r == `EXE_STATE_CONSUME)) begin
            /* The thing that was taking multiple cycles is done;
             * this state is un-stalled (consumes the instr presented from DE)
             * and (as the output is captured), we go valid.
             *
             * res_int (or wherever the op produces to) should be complete/
             * stable in this cycle, for capture into execute_out_RX.
             *
             * (E.g. consider two stalling instructions back to back; if
             * the first instr does its thing then returns to IDLE, the
             * instr hasn't been consumed yet and it's harder to
             * differentiate "I've done this one".  Consume state consumes
             * the instr that's just been executed.  Done.)
             */
	    exe_state_r <= `EXE_STATE_IDLE;
`ifdef DEBUG   $display("EXE: Multi-cycle op complete");  `endif
	 end
      end


      ///////////////////////////////////////////////////////////////////////
      // Debug stuff
`ifdef DEBUG
      if (decode_valid && memory_stall_i) begin
         $display("EXE: Stalled (valid=%d, MEM stall %d)",
                  execute_valid_o, memory_stall_i);
      end
`endif

      if (reset) begin
         exe_state_r             <= `EXE_STATE_IDLE;

	 /* Must reset outputs because subsequent stages calculate stalls from
	  * them, and we get beaucoup de X otherwise:
	  */
	 execute_out_R0_r        <= `REG_ZERO;
	 execute_out_R1_r        <= `REG_ZERO;
	 execute_out_R2_r        <= `REG_ZERO;
	 execute_out_RC_r        <= {`XERCRSZ{1'b0}};
      end
   end // always @ (posedge clk)


   ////////////////////////////////////////////////////////////////////////////////
   // Bypass

   /* This stage might generate the final GPR result for the instruction, so provides
    * a value for a forwarding/bypass path.  The conditions are:
    * - Generating execute_out_R0 from integer (i,e. exe_R0 = EXUNIT_INT), or PORT_C (for mfspr)
    * - Memory passes R0 (mem_pass_R0)
    * - WB writes R0 (wb_write_gpr_port0 and wb_write_gpr_port0_from = WB_PORT_R0, or the same on port1)
    * The value that this instruction carries down to WB, in wb_write_gpr_port0_reg, is the GPR number.
    *
    * The value is valid when:
    * - Decode input is valid, and non-fault
    * - Not annulled by WB (meh probably OK as decode will deal)
    * - Not stalled by mem
    * - i.e. EX is about to go valid in this cycle: EXE_STATE_IDLE and not about to do a multicycle op,
    *   or EXE_STATE_CONSUME.
    *
    * There are few and uncommon instrs whose GPR value comes from R1/R2, so don't bother with them.
    */

   wire instr_generates_result_now = (valid_instr_presented && // A valid instr execution cycle
				      ((exe_state_r == `EXE_STATE_IDLE &&
					multicycle_op_newstate == `EXE_STATE_IDLE) ||
				       (exe_state_r == `EXE_STATE_CONSUME))); // The instr generates a result right now
   assign execute_out_bypass_valid = instr_generates_result_now &&
				     ((exe_R0 == `EXUNIT_INT) || // The result is an int/GPR result in R0
                                      (exe_R0 == `EXUNIT_PORT_C)) && // The result is passed from C in R0
				     mem_pass_R0 && // ...which won't be modified by MEM
				     ((wb_write_gpr_port0 &&
				       wb_write_gpr_port0_from == `WB_PORT_R0) ||
				      (wb_write_gpr_port1 &&
				       wb_write_gpr_port1_from == `WB_PORT_R0)); // ...and _will_ be written to GPR

   assign execute_out_bypass_reg = (wb_write_gpr_port0 &&
				    wb_write_gpr_port0_from == `WB_PORT_R0) ?
				   wb_write_gpr_port0_reg : wb_write_gpr_port1_reg;

   assign execute_out_bypass = (exe_R0 == `EXUNIT_INT) ? res_int : decode_op_c;

   /* XERCR is produced if its value will be written back.  (Assumes an RC op.)
    * Note:  Some instructions, for example twi, evaluate an RC op but don't
    * change XERCR.
    * Note:  This stage *always* forwards XERCR for all instructions that have
    * generated an XERCR value.
    * (Hack: There's also an exception for stwcx, which does change XERCR but is
    * the only instr to produce a new value in MEM rather than EX!)
    */
   assign execute_out_bypass_xercr_valid = instr_generates_result_now &&
                                           !mem_op_addr_test_reservation &&
                                           wb_write_xercr;
   assign execute_out_bypass_xercr = res_rc;

   // If we *can't* forward a value, dep tracking still needs to know which reg we'll eventually write:
   assign execute_out_writes_gpr0 	= valid_instr_presented && wb_write_gpr_port0;
   assign execute_out_writes_gpr0_reg 	= wb_write_gpr_port0_reg;
   assign execute_out_writes_gpr1 	= valid_instr_presented && wb_write_gpr_port1;
   assign execute_out_writes_gpr1_reg   = wb_write_gpr_port1_reg;
   assign execute_out_writes_xercr 	= valid_instr_presented && wb_write_xercr;

   ////////////////////////////////////////////////////////////////////////////////
   // Outputs

`define SB_BUNDLE_SIZE (`DEC_SIGS_SIZE + 32*2 + 4 + 1 + (`REGSZ*4) + `XERCRSZ + 6)
`define EX_USE_SBUFF yes
`ifdef EX_USE_SBUFF
   wire		ds_ready;
   assign 	memory_stall_i = !ds_ready;

   sbuff #(.WIDTH(`SB_BUNDLE_SIZE))
         EXSB(.clk(clk),
              .reset(reset),
	      // Input port:
	      .i_valid(execute_valid_o),
	      .i_ready(ds_ready),
	      .i_data({execute_ibundle_out_r,
                       execute_instr_r,
                       execute_pc_r,
                       execute_msr_r,
                       execute_fault_r,
                       execute_brtaken_r, // don't need this
                       execute_out_R0_r,
                       execute_out_R1_r,
                       execute_out_R2_r,
                       execute_out_RC_r,
                       execute_out_miscflags_r
                       }),
	      // Output port:
	      .o_valid(execute_valid),
	      .o_ready(!memory_stall),
	      .o_data({execute_ibundle_out,
                       execute_instr,
                       execute_pc,
                       execute_msr,
                       execute_fault,
                       execute_brtaken,
                       execute_out_R0,
                       execute_out_R1,
                       execute_out_R2,
                       execute_out_RC,
                       execute_out_miscflags
                       }),
              // Annul this too!
              .empty_all(writeback_annul)
              );

   /* Bypass:  The instruction in the sbuff does not provide a value to bypass, BUT
    * it must participate in identifying which value lives where (AKA which stage
    * owns the newest version of a value).
    */
   wire         sbuff_has_instr    = !ds_ready; // == full
   /* If sbuff_has_instr, then o_data reflects the storage, so unpack to
    * get at the instruction's innards:
    */
   wire         e2_fwd             = sbuff_has_instr && (execute_fault_r == 0 /* ?? */) && !writeback_annul;
   assign execute2_out_writes_gpr0 = e2_fwd && execute_ibundle_out_r[`DEC_RANGE_WB_WRITE_GPR_PORT0];
   assign execute2_out_writes_gpr0_reg = execute_ibundle_out_r[`DEC_RANGE_WB_WRITE_GPR_PORT0_REG];
   assign execute2_out_writes_gpr1 = e2_fwd && execute_ibundle_out_r[`DEC_RANGE_WB_WRITE_GPR_PORT1];
   assign execute2_out_writes_gpr1_reg = execute_ibundle_out_r[`DEC_RANGE_WB_WRITE_GPR_PORT1_REG];

`else // !`ifdef IF_USE_SBUFF
   assign execute_ibundle_out = execute_ibundle_out_r;
   assign execute_instr = execute_instr_r;
   assign execute_pc = execute_pc_r;
   assign execute_msr = execute_msr_r;
   assign execute_fault = execute_fault_r;
   assign execute_brtaken = execute_brtaken_r;
   assign execute_out_R0 = execute_out_R0_r;
   assign execute_out_R1 = execute_out_R1_r;
   assign execute_out_R2 = execute_out_R2_r;
   assign execute_out_RC = execute_out_RC_r;
   assign execute_out_miscflags = execute_out_miscflags_r;

   assign execute_valid = execute_valid_o;
   assign memory_stall_i = memory_stall;

   assign execute2_out_writes_gpr0 = 0;
   assign execute2_out_writes_gpr0_reg = 0;
   assign execute2_out_writes_gpr1 = 0;
   assign execute2_out_writes_gpr1_reg = 0;

`endif // !`ifdef IF_USE_SBUFF
   assign execute_annul = exe_annul;

endmodule // execute
