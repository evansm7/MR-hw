/* Decode bypass
 * Calculate whether register values can be consumed via bypass paths.
 *
 * Copyright 2021-2022 Matt Evans
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

`include "arch_defs.vh"
`include "decode_signals.vh"


module decode_bypass(input wire [`DEC_SIGS_SIZE-1:0] db,
                     input wire                enable,

                     input wire                writeback_gpr_port0_en,
                     input wire [4:0]          writeback_gpr_port0_reg,
                     input wire [`REGSZ-1:0]   writeback_gpr_port0_value,
                     input wire                writeback_gpr_port1_en,
                     input wire [4:0]          writeback_gpr_port1_reg,
                     input wire [`REGSZ-1:0]   writeback_gpr_port1_value,
                     input wire                writeback_xercr_en,
                     input wire [`XERCRSZ-1:0] writeback_xercr_value,

                     /* Whether EX/MEM emit a value, and which reg it's for: */
                     input wire [`REGSZ-1:0]   execute_bypass,
	             input wire [4:0]          execute_bypass_reg,
	             input wire                execute_bypass_valid,
                     input wire [`XERCRSZ-1:0] execute_bypass_xercr,
                     input wire                execute_bypass_xercr_valid,
	             input wire [`REGSZ-1:0]   memory_bypass,
	             input wire [4:0]          memory_bypass_reg,
	             input wire                memory_bypass_valid,
                     input wire [`XERCRSZ-1:0] memory_bypass_xercr,
                     input wire                memory_bypass_xercr_valid,

                     /* Whether EX/MEM "own" a given reg value (even if they
                      * might not be emitting a forwarded version of it):
                      */
                     input wire                execute_writes_gpr0,
                     input wire [4:0]          execute_writes_gpr0_reg,
                     input wire                execute_writes_gpr1,
                     input wire [4:0]          execute_writes_gpr1_reg,
                     input wire                execute_writes_xercr,
                     input wire                execute2_writes_gpr0,
                     input wire [4:0]          execute2_writes_gpr0_reg,
                     input wire                execute2_writes_gpr1,
                     input wire [4:0]          execute2_writes_gpr1_reg,
                     input wire                memory_writes_gpr0,
                     input wire [4:0]          memory_writes_gpr0_reg,
                     input wire                memory_writes_gpr1,
                     input wire [4:0]          memory_writes_gpr1_reg,
                     input wire                memory_writes_xercr,

                     /* Final bypass result: */
                     output reg                xercr_bypassed, // Wire
                     output reg [`XERCRSZ-1:0] xercr_bypass_val, // Wire
                     output reg                gpr_a_bypassed, // Wire
                     output reg                gpr_b_bypassed, // Wire
                     output reg                gpr_c_bypassed, // Wire
                     output reg [`REGSZ-1:0]   gpr_a_bypass_val, // Wire
                     output reg [`REGSZ-1:0]   gpr_b_bypass_val, // Wire
                     output reg [`REGSZ-1:0]   gpr_c_bypass_val // Wire
                     );

   `DEC_SIGS_DECLARE;

   always @(*) begin
      {`DEC_SIGS_BUNDLE} = db;
   end

   /* Paths from WB (GPR writeback) flow-through: */
   reg 					     gpr_a_bypass_wb; // Wire
   reg 					     gpr_b_bypass_wb; // Wire
   reg 					     gpr_c_bypass_wb; // Wire
   reg [`REGSZ-1:0] 			     gpr_a_bypass_wb_val; // Wire
   reg [`REGSZ-1:0] 			     gpr_b_bypass_wb_val; // Wire
   reg [`REGSZ-1:0] 			     gpr_c_bypass_wb_val; // Wire

   reg 					     gpr_a_bypass_ex; // Wire
   reg 					     gpr_b_bypass_ex; // Wire
   reg 					     gpr_c_bypass_ex; // Wire
   reg 					     gpr_a_bypass_mem; // Wire
   reg 					     gpr_b_bypass_mem; // Wire
   reg 					     gpr_c_bypass_mem; // Wire

   always @(*) begin
      gpr_a_bypassed = 0;
      gpr_b_bypassed = 0;
      gpr_c_bypassed = 0;
      gpr_a_bypass_val = `REG_ZERO;
      gpr_b_bypass_val = `REG_ZERO;
      gpr_c_bypass_val = `REG_ZERO;

      gpr_a_bypass_wb = 0;
      gpr_b_bypass_wb = 0;
      gpr_c_bypass_wb = 0;
      gpr_a_bypass_wb_val = `REG_ZERO;
      gpr_b_bypass_wb_val = `REG_ZERO;
      gpr_c_bypass_wb_val = `REG_ZERO;

      gpr_a_bypass_ex = 0;
      gpr_b_bypass_ex = 0;
      gpr_c_bypass_ex = 0;

      gpr_a_bypass_mem = 0;
      gpr_b_bypass_mem = 0;
      gpr_c_bypass_mem = 0;

      xercr_bypassed = 0;
      xercr_bypass_val = {`XERCRSZ{1'b0}};

      if (enable) begin
	 /* If one of the write ports from WB is supplying the reg value being read,
	  * take that.
          *
          * HOWEVER:
          *
          * Just because we can bypass a value, doesn't mean we should.  With
          * great bypass comes great responsibility.  Not all register versions
          * are alike.  You can't judge a value by its name.  Um.
          *
          * That is...  Up to 3 pipelined instructions might produce a value
          * for, say, R7:  one in EX, one in MEM, and one in WB.
          * An issuing instruction is only interested in the most recent value.
          * If the most recent (e.g. in EX) happens not to be forwarded, then the
          * other values (which other stages might happily forward) MUST be
          * ignored.
	  */

         // Note order of oldest to newest priority (WB, MEM, EX):
	 if (writeback_gpr_port0_en) begin
	    if (de_porta_read_gpr_name == writeback_gpr_port0_reg) begin
	       gpr_a_bypass_wb = 1;
	       gpr_a_bypass_wb_val = writeback_gpr_port0_value;
	    end
	    if (de_portb_read_gpr_name == writeback_gpr_port0_reg) begin
	       gpr_b_bypass_wb = 1;
	       gpr_b_bypass_wb_val = writeback_gpr_port0_value;
	    end
	    if (de_portc_read_gpr_name == writeback_gpr_port0_reg) begin
	       gpr_c_bypass_wb = 1;
	       gpr_c_bypass_wb_val = writeback_gpr_port0_value;
	    end
	 end

	 if (writeback_gpr_port1_en) begin
	    if (de_porta_read_gpr_name == writeback_gpr_port1_reg) begin
	       gpr_a_bypass_wb = 1;
	       gpr_a_bypass_wb_val = writeback_gpr_port1_value;
	    end
	    if (de_portb_read_gpr_name == writeback_gpr_port1_reg) begin
	       gpr_b_bypass_wb = 1;
	       gpr_b_bypass_wb_val = writeback_gpr_port1_value;
	    end
	    if (de_portc_read_gpr_name == writeback_gpr_port1_reg) begin
	       gpr_c_bypass_wb = 1;
	       gpr_c_bypass_wb_val = writeback_gpr_port1_value;
	    end
	 end

         if (memory_bypass_valid && (de_porta_read_gpr_name == memory_bypass_reg)) begin
	    gpr_a_bypass_mem = 1;
	 end else if ((memory_writes_gpr0 && (de_porta_read_gpr_name == memory_writes_gpr0_reg)) ||
                      (memory_writes_gpr1 && (de_porta_read_gpr_name == memory_writes_gpr1_reg))) begin
            /* If this stage does NOT produce a valid bypass value, but DOES own
             * writing the register value we want, stop!  We can't bypass from
             * MEM or WB.  If we did, we'd get a stale value breaking program
             * order of reg writes.
             */
            gpr_a_bypass_mem = 0;
            gpr_a_bypass_wb  = 0;
         end
	 if (memory_bypass_valid && (de_portb_read_gpr_name == memory_bypass_reg)) begin
	    gpr_b_bypass_mem = 1;
	 end else if ((memory_writes_gpr0 && (de_portb_read_gpr_name == memory_writes_gpr0_reg)) ||
                      (memory_writes_gpr1 && (de_portb_read_gpr_name == memory_writes_gpr1_reg))) begin
            gpr_b_bypass_mem = 0;
            gpr_b_bypass_wb  = 0;
         end
	 if (memory_bypass_valid && (de_portc_read_gpr_name == memory_bypass_reg)) begin
	    gpr_c_bypass_mem = 1;
	 end else if ((memory_writes_gpr0 && (de_portc_read_gpr_name == memory_writes_gpr0_reg)) ||
                      (memory_writes_gpr1 && (de_portc_read_gpr_name == memory_writes_gpr1_reg))) begin
            gpr_c_bypass_mem = 0;
            gpr_c_bypass_wb  = 0;
         end

         /* EXE2 can't bypass, but must spoil everyone else's day if it owns a value (i.e.
          * can't BP from MEM if EXE2 owns it).  EXE2 never produces XERCR.
          */
	 if ((execute2_writes_gpr0 && (de_porta_read_gpr_name == execute2_writes_gpr0_reg)) ||
             (execute2_writes_gpr1 && (de_porta_read_gpr_name == execute2_writes_gpr1_reg))) begin
            /* As above, inhibit bypass (from all previous stages) if EX owns the reg we want
             * but can't bypass it.  It's the only version of the reg that could've been used.
             */
            gpr_a_bypass_ex  = 0;
            gpr_a_bypass_mem = 0;
            gpr_a_bypass_wb  = 0;
         end
         if ((execute2_writes_gpr0 && (de_portb_read_gpr_name == execute2_writes_gpr0_reg)) ||
             (execute2_writes_gpr1 && (de_portb_read_gpr_name == execute2_writes_gpr1_reg))) begin
            gpr_b_bypass_ex  = 0;
            gpr_b_bypass_mem = 0;
            gpr_b_bypass_wb  = 0;
         end
         if ((execute2_writes_gpr0 && (de_portc_read_gpr_name == execute2_writes_gpr0_reg)) ||
             (execute2_writes_gpr1 && (de_portc_read_gpr_name == execute2_writes_gpr1_reg))) begin
            gpr_c_bypass_ex  = 0;
            gpr_c_bypass_mem = 0;
            gpr_c_bypass_wb  = 0;
         end

	 if (execute_bypass_valid && (de_porta_read_gpr_name == execute_bypass_reg)) begin
	    gpr_a_bypass_ex = 1;
	 end else if ((execute_writes_gpr0 && (de_porta_read_gpr_name == execute_writes_gpr0_reg)) ||
                      (execute_writes_gpr1 && (de_porta_read_gpr_name == execute_writes_gpr1_reg))) begin
            /* As above, inhibit bypass (from all previous stages) if EX owns the reg we want
             * but can't bypass it.  It's the only version of the reg that could've been used.
             */
            gpr_a_bypass_ex  = 0;
            gpr_a_bypass_mem = 0;
            gpr_a_bypass_wb  = 0;
         end
	 if (execute_bypass_valid && (de_portb_read_gpr_name == execute_bypass_reg)) begin
	    gpr_b_bypass_ex = 1;
	 end else if ((execute_writes_gpr0 && (de_portb_read_gpr_name == execute_writes_gpr0_reg)) ||
                      (execute_writes_gpr1 && (de_portb_read_gpr_name == execute_writes_gpr1_reg))) begin
            gpr_b_bypass_ex  = 0;
            gpr_b_bypass_mem = 0;
            gpr_b_bypass_wb  = 0;
         end
	 if (execute_bypass_valid && (de_portc_read_gpr_name == execute_bypass_reg)) begin
	    gpr_c_bypass_ex = 1;
	 end else if ((execute_writes_gpr0 && (de_portc_read_gpr_name == execute_writes_gpr0_reg)) ||
                      (execute_writes_gpr1 && (de_portc_read_gpr_name == execute_writes_gpr1_reg))) begin
            gpr_c_bypass_ex  = 0;
            gpr_c_bypass_mem = 0;
            gpr_c_bypass_wb  = 0;
         end

	 /* Final values: Prioritise most recent values, e.g.
	  * if WB and EX both provide r6, take EX as it's more recent.
          */
	 if (gpr_a_bypass_ex) begin
	    gpr_a_bypassed = 1;
	    gpr_a_bypass_val = execute_bypass;
	 end else if (gpr_a_bypass_mem) begin
	    gpr_a_bypassed = 1;
	    gpr_a_bypass_val = memory_bypass;
	 end else if (gpr_a_bypass_wb) begin
	    gpr_a_bypassed = 1;
	    gpr_a_bypass_val = gpr_a_bypass_wb_val;
	 end

	 if (gpr_b_bypass_ex) begin
	    gpr_b_bypassed = 1;
	    gpr_b_bypass_val = execute_bypass;
	 end else if (gpr_b_bypass_mem) begin
	    gpr_b_bypassed = 1;
	    gpr_b_bypass_val = memory_bypass;
	 end else if (gpr_b_bypass_wb) begin
	    gpr_b_bypassed = 1;
	    gpr_b_bypass_val = gpr_b_bypass_wb_val;
	 end

	 if (gpr_c_bypass_ex) begin
	    gpr_c_bypassed = 1;
	    gpr_c_bypass_val = execute_bypass;
	 end else if (gpr_c_bypass_mem) begin
	    gpr_c_bypassed = 1;
	    gpr_c_bypass_val = memory_bypass;
	 end else if (gpr_c_bypass_wb) begin
	    gpr_c_bypassed = 1;
	    gpr_c_bypass_val = gpr_c_bypass_wb_val;
	 end


         // if !execute_bypass_xercr_valid but execute_out_writes_xercr then we MUST STALL, like for the GPRs
         // similarly, if !memory_bypass_xercr_valid but memory_out_writes_xercr we MUST STALL.
         if (execute_bypass_xercr_valid) begin
            /* If EX forwards XERCR, that's the most recent version; take it.
             */
            xercr_bypassed = 1;
            xercr_bypass_val = execute_bypass_xercr;
         end else if (memory_bypass_xercr_valid) begin
            /* If EX doesn't forward, MEM might.  Only forward from MEM if
             * EX doesn't own writing the most recent value:
             */
            xercr_bypassed = !execute_writes_xercr;
            xercr_bypass_val = memory_bypass_xercr;
         end else if (writeback_xercr_en) begin
            /* EX and MEM didn't forward, however now MEM might be responsible
             * for the most recent value.  Only forward from WB if MEM & EX
             * don't own writing the most recent value:
             */
            xercr_bypassed = !memory_writes_xercr && !execute_writes_xercr;
            xercr_bypass_val = writeback_xercr_value;
         end
      end
   end
endmodule // decode_bypass
