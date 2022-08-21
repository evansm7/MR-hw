/* decode_regdeps
 *
 * This module tracks register dependencies:
 * - Usage tracking/scoreboarding when an instruction issues
 * 	(Takes note of the resources it will change/write)
 * - Stall calculation in order to stop an issue
 * 	(Given scoreboard state, calculates whether an instr has resources it needs)
 *
 * Refactored from decode.v 130122 ME
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


module decode_regdeps(input wire       		      clk,
		      input wire                      reset,
                      input wire [`DEC_SIGS_SIZE-1:0] db,
                      input wire                      instr_valid,
                      input wire [2:0]                decode_state,
                      input wire [4:0]                de_RX,
                      input wire [4:0]                lsm_reg,
                      input wire                      gpr_a_bypassed,
                      input wire                      gpr_b_bypassed,
                      input wire                      gpr_c_bypassed,
                      input wire                      xercr_bypassed,

                      // XERCR get/put
                      input wire                      get_xercr,
                      input wire                      put_xercr,
                      // Two "ports" for GPR get/put (corresponding to two 2R2W)
                      input wire                      get_gpr_a,
                      input wire [4:0]                get_gpr_a_name,
                      input wire                      get_gpr_b,
                      input wire [4:0]                get_gpr_b_name,
                      input wire                      put_gpr_a,
                      input wire [4:0]                put_gpr_a_name,
                      input wire                      put_gpr_b,
                      input wire [4:0]                put_gpr_b_name,
                      // Two "ports" for SPR (and SpecialSPR) get/put
                      input wire                      get_spr,
                      input wire [5:0]                get_spr_name,
                      input wire                      get_sspr,
                      input wire [5:0]                get_sspr_name,
                      input wire                      put_spr,
                      input wire [5:0]                put_spr_name,
                      input wire                      put_sspr,
                      input wire [5:0]                put_sspr_name,
                      // Generic/coarse-grained SPR locking
                      input wire                      get_spr_generic,
                      input wire                      put_spr_generic,
                      input wire                      reset_scoreboard,

                      output reg                      stall_for_operands, // Wire
                      output reg                      stall_for_fsm // Wire
                      );

   /* For debug it can be interesting to fall back to old behaviour.
    * Disable multiple outstanding writes for GPRs/XERCR here.
    * FIXME: if disabled, no need to keep 2-bit scoreboard values
    * (1 is the max number of uses, so shrink FFs).
    */
   parameter ENABLE_GPR_WAW 	= 1;
   parameter ENABLE_COND_WAW 	= 1;

   `DEC_SIGS_DECLARE;
   always @(*) begin
      {`DEC_SIGS_BUNDLE} = db;
   end

   // Scoreboard/tracking state
   reg [1:0]                           rlock[31:0];
   reg [(`DE_NR_SPRS_RLOCK-1):0]       rlock_spreg;
   reg [1:0]                           rlock_xercr;
   reg                                 rlock_generic;

   // Calculate stalls/register dependencies:
   reg                                 gpr_read_stall; // Wire
   reg                                 spr_read_stall; // Wire
   reg                                 cond_read_stall; // Wire
   reg                                 gpr_write_stall; // Wire
   reg                                 spr_write_stall; // Wire
   reg                                 cond_write_stall; // Wire

   always @(*) begin
      gpr_read_stall     = 0;
      spr_read_stall     = 0;
      cond_read_stall    = 0;
      gpr_write_stall    = 0;
      spr_write_stall    = 0;
      cond_write_stall   = 0;
      stall_for_operands = 0;
      stall_for_fsm      = 0;

      if (instr_valid) begin
         /* In current simple reg locking scheme, DE stalls if any required read operands
          * are still locked for write by an earlier instruction (RAW).
	  * Note if a GPR value can be bypassed, we don't need to stall for it.
          */
         gpr_read_stall = ((de_porta_type == `DE_GPR) &&
                           (!de_porta_checkz_gpr && !gpr_a_bypassed &&
                            rlock[de_porta_read_gpr_name] != 2'h0)) ||
                          ((de_portb_type == `DE_GPR) && !gpr_b_bypassed &&
                           rlock[de_portb_read_gpr_name] != 2'h0) ||
                          ((de_portc_type == `DE_GPR) && !gpr_c_bypassed &&
                           rlock[de_portc_read_gpr_name] != 2'h0);

	 /* Note: Some SPRs are locked via rlock_spreg, but most via rlock_generic.
	  * I don't want rlock_spreg to be larger than the subset that needs it; so,
	  * guard against sometimes out-of-range indices by comparison
	  * to the DE_NR_SPRS_RLOCK range:
	  */
         spr_read_stall = ((de_porta_type == `DE_SPR) &&
			   (de_porta_read_spr_name < `DE_NR_SPRS_RLOCK ?
			    rlock_spreg[de_porta_read_spr_name[`DE_L2_SPRS_RLOCK-1:0]] : 0 /* Avoid Z prop */)) ||
                          /* port B never reads SPRs! */
                          ((de_portc_type == `DE_SPR) &&
			   (de_portc_read_spr_name < `DE_NR_SPRS_RLOCK ?
			    rlock_spreg[de_portc_read_spr_name[`DE_L2_SPRS_RLOCK-1:0]] : 0));

         cond_read_stall = de_portd_xercr_enable_cond && !xercr_bypassed && (rlock_xercr != 2'h0);

         /* Similarly, if this instruction wants to write something that's already being written,
          * we currently resolve non-GPR WAW hazards by stalling too.
	  *
          * The 2-bit scoreboard (rlock) is maintained to allow common WAW hazards for GPRs.
          *
          * That is, we don't stall if the instr to be issued is writing a register already
          * "out for write".  The old logic (detecting this case) is still here for
          * posterity, in gpr_write_stall, but isn't used.
          */

         /* Note, general-case gpr_write_stall is ignored! */
         gpr_write_stall = (wb_write_gpr_port0 && rlock[wb_write_gpr_port0_reg]) ||
                           (wb_write_gpr_port1 && rlock[wb_write_gpr_port1_reg]);

         spr_write_stall = (wb_write_spr &&
			    (wb_write_spr_num < `DE_NR_SPRS_RLOCK ?
			     rlock_spreg[wb_write_spr_num[`DE_L2_SPRS_RLOCK-1:0]] : 0 /* Avoid Z prop */)) ||
                           (wb_write_spr_special &&
			    (wb_write_spr_special_num < `DE_NR_SPRS_RLOCK ?
			     rlock_spreg[wb_write_spr_special_num[`DE_L2_SPRS_RLOCK-1:0]] : 0));

         /* Note, general case cond_write_stall is ignored! */
         cond_write_stall = wb_write_xercr && (rlock_xercr != 2'h0);

         if (decode_state == `DE_STATE_IDLE) begin
            stall_for_operands = gpr_read_stall || spr_read_stall || cond_read_stall ||
                                 (!ENABLE_GPR_WAW && gpr_write_stall) ||
                                 spr_write_stall ||
                                 (!ENABLE_COND_WAW && cond_write_stall) ||
                                 rlock_generic;
         end else begin
            // Stall for operands, based on current 'rx' for LMW/STMW
	    if (decode_state == `DE_STATE_LMW) begin
	       /* Only the first cycle has read dependencies on RA (dealt with
		* above) but write dependencies may exist for RX:
		*/
	       stall_for_operands = !ENABLE_GPR_WAW && (rlock[de_RX] != 2'h0);
	    end else if (decode_state == `DE_STATE_STMW) begin
	       /* Read dependencies on RX: */
	       stall_for_operands = rlock[de_RX] != 2'h0;
	    end else begin
`ifdef SIM
	       $fatal(1, "State %d unimplemented", decode_state);
`endif
	    end
         end

         // Multi-cycle instructions:
         if (decode_state == `DE_STATE_IDLE && de_fsm_op != 0) begin
	    /* This cycle, we're changing into a non-idle state. */
	    if (de_fsm_op == `DE_STATE_LMW) begin
               /* We always stall for LMW, except in the strange case of having
		* only one register to load!
	        */
	       stall_for_fsm = (lsm_reg != 5'h1f);
	    end else if (de_fsm_op == `DE_STATE_STMW) begin
	       /* Ditto */
	       stall_for_fsm = (lsm_reg != 5'h1f);
	    end

         end else if (decode_state != `DE_STATE_IDLE) begin
	    /* If DE is in the last cycle of a multi-cycle instruction, then
	     * we don't stall anymore.
	     *
	     * If it's mid-way, we stall.
	     */
            stall_for_fsm = 1;

	    if (((de_fsm_op == `DE_STATE_LMW) && (de_RX == 5'h1f)) ||
		((de_fsm_op == `DE_STATE_STMW) && (de_RX == 5'h1f))) begin
	       stall_for_fsm = 0;
	    end
         end
      end
   end


   /////////////////////////////////////////////////////////////////////////////
   // Register state tracking/scoreboarding

   always @(posedge clk) begin
      // XERCR
      if (put_xercr && get_xercr) begin
         // Stays the same
      end else if (put_xercr) begin
         if (rlock_xercr == 0) begin
`ifdef SIM     $fatal(1, "DE: XERCR ref saturated on dec!");
`endif
         end else begin
            rlock_xercr <= rlock_xercr - 1;
         end
      end else if (get_xercr) begin
         if (rlock_xercr == 2'b11) begin
`ifdef SIM     $fatal(1, "DE: XERCR ref saturated on inc!");
`endif
         end else begin
            rlock_xercr <= rlock_xercr + 1;
         end
      end

      // SPR generic
      if (put_spr_generic)
        rlock_generic <= 0;
      else if (get_spr_generic)
        rlock_generic <= 1;

      // Debug
`ifdef SIM
      if (get_gpr_a && get_gpr_b && get_gpr_a_name == get_gpr_b_name)
        $fatal(1, "DE: Writing GPR %d twice??", get_gpr_a_name);
      if (put_gpr_a && put_gpr_b && put_gpr_a_name == put_gpr_b_name)
        $fatal(1, "DE: Writeback of GPR %d twice??", put_gpr_a_name);

      if (get_spr && get_sspr && get_spr_name == get_sspr_name)
        $fatal(1, "DE: Writing SPR %d twice??", get_spr_name);
      if (put_spr && put_sspr && put_spr_name == put_sspr_name)
        $fatal(1, "DE: Writeback of SPR %d twice??", put_spr_name);
`endif

      if (reset || reset_scoreboard) begin
         rlock_xercr    <= 2'b00;
         rlock_generic  <= 1'b0;
      end
   end

   genvar     r;
   generate
      // GPRs
      /* We (now) allow multiple outstanding writers of a given register, using
       * a 2-bit refcount for a GPR.
       *
       * In a given cycle, the refcount is adjusted as follows:
       * - Issuing an instr writing a GPR without concurrent writeback of that GPR:  	+1
       * - Issuing an instr writing a GPR with concurrent writeback of that GPR:  	no change
       * - Writeback of that GPR:							-1
       */
      for (r = 0; r < 32; r = r + 1) begin
         wire rln_up = (get_gpr_a && get_gpr_a_name == r) || (get_gpr_b && get_gpr_b_name == r);
         wire rln_down = (put_gpr_a && put_gpr_a_name == r) || (put_gpr_b && put_gpr_b_name == r);
         always @(posedge clk) begin
            if (rln_up && rln_down) begin
`ifdef DEBUG   	  $display("DE: GPR%d ref inc-dec same cycle", r);
`endif
            end else if (rln_up) begin
`ifdef DEBUG   	  $display("DE: GPR%d ref inc", r);
`endif
`ifdef SIM        if (rlock[r] == 2'b11)
               $fatal(1, "DE: GPR%d ref saturated on inc!", r);
`endif
               rlock[r] 	<= rlock[r] + 1;
            end else if (rln_down) begin
`ifdef DEBUG   	  $display("DE: GPR%d ref dec", r);
`endif
`ifdef SIM        if (rlock[r] == 2'b00)
               $fatal(1, "DE: GPR%d ref saturated on dec!", r);
`endif
               rlock[r] 	<= rlock[r] - 1;
            end

            if (reset || reset_scoreboard) begin
               rlock[r]		<= 2'b00;
            end
         end
      end

      // SPRs
      for (r = 0; r < `DE_NR_SPRS_RLOCK; r = r + 1) begin
         always @(posedge clk) begin
            if ((get_spr && get_spr_name == r) || (get_sspr && get_sspr_name == r))
              rlock_spreg[r] <= 1'b1;
            else if ((put_spr && put_spr_name == r) || (put_sspr && put_sspr_name == r))
              rlock_spreg[r] <= 1'b0;

            if (reset || reset_scoreboard)
               rlock_spreg[r]	<= 1'b0;
         end
      end
   endgenerate

endmodule
