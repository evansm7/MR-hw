/* writeback stage
 * Deals with register writeback to GPRF/SPRF (in decode), and exception
 * generation from incoming faults.
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


module writeback(input wire                         clk,
                 input wire 			    reset,

                 input wire 			    memory_valid,
                 input wire [3:0] 		    memory_fault,
                 input wire [31:0] 		    memory_instr,
                 input wire [`REGSZ-1:0] 	    memory_pc,
                 input wire [31:0] 		    memory_msr,
                 input wire [`DEC_SIGS_SIZE-1:0]    memory_ibundle_in,

                 input wire [`REGSZ-1:0] 	    memory_R0,
                 input wire [`REGSZ-1:0] 	    memory_R1,
                 input wire [`XERCRSZ-1:0] 	    memory_RC,
                 input wire [`REGSZ-1:0] 	    memory_res,
                 input wire [`REGSZ-1:0] 	    memory_addr,

                 output wire [`REGSZ-1:0] 	    writeback_newpc,
                 output wire [31:0] 		    writeback_newmsr,
                 output wire 			    writeback_newpcmsr_valid,

                 output wire 			    writeback_gpr_port0_en,
                 output wire [4:0] 		    writeback_gpr_port0_reg,
                 output wire [`REGSZ-1:0] 	    writeback_gpr_port0_value,
                 output wire 			    writeback_gpr_port1_en,
                 output wire [4:0] 		    writeback_gpr_port1_reg,
                 output wire [`REGSZ-1:0] 	    writeback_gpr_port1_value,
                 output wire 			    writeback_xercr_en,
                 output wire [`XERCRSZ-1:0] 	    writeback_xercr_value,
                 output wire 			    writeback_spr_en,
                 output wire [`DE_NR_SPRS_LOG2-1:0] writeback_spr_reg,
                 output wire [`REGSZ-1:0] 	    writeback_spr_value,
                 output wire 			    writeback_sspr_en,
                 output wire [`DE_NR_SPRS_LOG2-1:0] writeback_sspr_reg,
                 output wire [`REGSZ-1:0] 	    writeback_sspr_value,
                 output wire 			    writeback_unlock_generic,

                 output wire 			    writeback_annul
              );

   `DEC_SIGS_DECLARE;

   always @(*) begin
      {`DEC_SIGS_BUNDLE} = memory_ibundle_in;
   end

   reg [1:0]                                     state;
`define WB_STATE_NORMAL    0
`define WB_STATE_2ND_CYCLE 1

   /* Regs, but combinatorial outputs -- not registered */
   reg [`REGSZ-1:0]                              writeback_newpc_int;
   reg [31:0]                                    writeback_newmsr_int;
   reg                                           writeback_newpcmsr_valid_int;
   reg                                           writeback_gpr_port0_en_int /*verilator public*/;
   reg [4:0]                                     writeback_gpr_port0_reg_int /*verilator public*/;
   reg [`REGSZ-1:0]                              writeback_gpr_port0_value_int /*verilator public*/;
   reg                                           writeback_gpr_port1_en_int /*verilator public*/;
   reg [4:0]                                     writeback_gpr_port1_reg_int /*verilator public*/;
   reg [`REGSZ-1:0]                              writeback_gpr_port1_value_int /*verilator public*/;
   reg                                           writeback_xercr_en_int /*verilator public*/;
   reg [`XERCRSZ-1:0]                            writeback_xercr_value_int /*verilator public*/;
   reg                                           writeback_spr_en_int;
   reg [`DE_NR_SPRS_LOG2-1:0] 			 writeback_spr_reg_int;
   reg [`REGSZ-1:0]                              writeback_spr_value_int;
   reg                                           writeback_sspr_en_int;
   reg [`DE_NR_SPRS_LOG2-1:0] 			 writeback_sspr_reg_int;
   reg [`REGSZ-1:0]                              writeback_sspr_value_int;
   reg                                           writeback_unlock_generic_int;

   reg                                           wb_annul_back_int;
   reg                                           wb_twocycle_exception_int;

   /* Counters, for "performance" measurement */
   reg [31:0]                                    counter_instr_commit /* verilator public */;
   reg [31:0]                                    counter_stall_cycle /* verilator public */;

   /////////////////////////////////////////////////////////////////////////////
   // Complicated exception-calcs stuff in a submodule:

   wire [`REGSZ-1:0]                             saved_pc;
   wire [31:0]                                   saved_msr;
   wire [`REGSZ-1:0]                             new_pc;
   wire [31:0]                                   new_msr;
   wire [31:0]                                   new_dsisr;
   wire                                          two_cycle;

   writeback_calc_exc WCE(.fault(memory_fault),
			  .instr(memory_instr),
                          .pc(memory_pc),
                          .msr(memory_msr),

                          .saved_pc(saved_pc),
                          .saved_msr(saved_msr),
                          .new_pc(new_pc),
                          .new_msr(new_msr),
                          .new_dsisr(new_dsisr),

                          .two_cycle(two_cycle)
                          );

   /////////////////////////////////////////////////////////////////////////////
   // Combinatorial stuff -- assert write enables

   always @(*) begin
      writeback_newpc_int = `REG_ZERO;
      writeback_newmsr_int = 32'b0;
      writeback_newpcmsr_valid_int = 0;
      writeback_gpr_port0_en_int = 0;
      writeback_gpr_port0_reg_int = 0;
      writeback_gpr_port0_value_int = `REG_ZERO;
      writeback_gpr_port1_en_int = 0;
      writeback_gpr_port1_reg_int = 0;
      writeback_gpr_port1_value_int = `REG_ZERO;
      writeback_xercr_en_int = 0;
      writeback_xercr_value_int = {`XERCRSZ{1'b0}};
      writeback_spr_en_int = 0;
      writeback_spr_reg_int = 0;
      writeback_spr_value_int = `REG_ZERO;
      writeback_sspr_en_int = 0;
      writeback_sspr_reg_int = 0;
      writeback_sspr_value_int = `REG_ZERO;
      writeback_unlock_generic_int = 0;

      wb_annul_back_int = 0;
      wb_twocycle_exception_int = 0;

      if (memory_valid) begin
         if (memory_fault != 0) begin

            /* WB's been provided with an exception to take.
             *
             * Exception asserts annul to entire pipeline, providing a new_pc to IF.
             *
             * Some exceptions are two-cycle (well, DSI).  The first cycle annuls and
             * the second annuls + writes PC/MSR.  (One cycle faults do just the latter.)
             */
            wb_annul_back_int = 1;

            // check state, 1st cycle (all exceptions) or 2nd cycle (DSI only)

            if (state == `WB_STATE_NORMAL && two_cycle) begin

               /* First cycle of a two-cycle exception */
               wb_twocycle_exception_int = 1;

               writeback_spr_en_int = 1;
               writeback_spr_reg_int = `DE_spr_DAR;
               writeback_spr_value_int = memory_addr;

               /* Special SPR port is LR/SRR1/DSISR only */
               writeback_sspr_en_int = 1;
               writeback_sspr_reg_int = `DE_spr_DSISR;
               writeback_sspr_value_int = new_dsisr;
            end else begin

               /* This case deals with **one-cycle exceptions ONLY**.
                * The second cycle of a two-cycle exception occurs in the
                * !memory_valid clause below, because by definition the first
                * cycle would have annulled/made MEM invalid.
                */
               writeback_spr_en_int = 1;
               writeback_spr_reg_int = `DE_spr_SRR0;
               writeback_spr_value_int = saved_pc;

               /* Special SPR port is LR/SRR1/DSISR only */
               writeback_sspr_en_int = 1;
               writeback_sspr_reg_int = `DE_spr_SRR1;
               writeback_sspr_value_int = saved_msr;

               /* And finally, change control flow: */
               writeback_newpcmsr_valid_int = 1;
               writeback_newpc_int = new_pc;
               writeback_newmsr_int = new_msr;
            end
         end else begin

            if (wb_write_gpr_port0) begin
               writeback_gpr_port0_en_int = 1;
               writeback_gpr_port0_reg_int = wb_write_gpr_port0_reg;

               case (wb_write_gpr_port0_from)
                 `WB_PORT_R0:
                   writeback_gpr_port0_value_int = memory_R0;

                 `WB_PORT_R1:
                   writeback_gpr_port0_value_int = memory_R1;

                 `WB_PORT_MEM_RES:
                   writeback_gpr_port0_value_int = memory_res;

                 // FIXME: Move these into the D$ next to the *other*
                 // masking/transformation that has to happen there anyway!
                 `WB_PORT_SXT16_MEM_RES:
                   writeback_gpr_port0_value_int = {{(`REGSZ-16){memory_res[15]}}, memory_res[15:0]};

                 `WB_PORT_BSWAP16_MEM_RES:
                   writeback_gpr_port0_value_int = {{(`REGSZ-16){1'b0}}, memory_res[7:0], memory_res[15:8]};

                 `WB_PORT_BSWAP32_MEM_RES:
                   writeback_gpr_port0_value_int = {{(`REGSZ-32){1'b0}},
                                                  memory_res[7:0], memory_res[15:8],
                                                  memory_res[23:16], memory_res[31:24]};
                 default: begin
                    /* Value stays 0 as above */
`ifdef SIM
                    $fatal(1, "WB: Unknown P0 source %d", wb_write_gpr_port0_from);
`endif
                 end
               endcase // case (wb_write_gpr_port0_from)
            end // if (wb_write_gpr_port0)

            if (wb_write_gpr_port1) begin
               writeback_gpr_port1_en_int = 1;
               writeback_gpr_port1_reg_int = wb_write_gpr_port1_reg;

               if (wb_write_gpr_port1_from == `WB_PORT_R0) begin
                  writeback_gpr_port1_value_int = memory_R0;
               end else begin
`ifdef SIM
                  $fatal(1, "WB: Unknown P1 source %d", wb_write_gpr_port1_from);
`endif
               end
            end

            if (wb_write_spr) begin
               writeback_spr_en_int = 1;
               writeback_spr_reg_int = wb_write_spr_num;
               if (wb_write_spr_from == `WB_PORT_R0) begin
                  writeback_spr_value_int = memory_R0;
               end else begin
`ifdef SIM
                  $fatal(1, "WB: Unknown SPR source %d", wb_write_spr_from);
`endif
               end
            end
            /* Note:  Might write SPR and SSPR at the same time */

            if (wb_write_spr_special) begin
               writeback_sspr_en_int = 1;
               writeback_sspr_reg_int = wb_write_spr_special_num;

               case (wb_write_spr_special_from)
                 `WB_PORT_R0:
                   writeback_sspr_value_int = memory_R0;

                 `WB_PORT_R1:
                   writeback_sspr_value_int = memory_R1;

                 default: begin
                    /* Value stays 0 as above */
`ifdef SIM
                    $fatal(1, "WB: Unknown SSPR source %d", wb_write_spr_special_from);
`endif
                 end
               endcase // case (wb_write_spr_special_from)
            end

            // FIXME: Write SR

            if (wb_write_xercr) begin
               writeback_xercr_en_int = 1;
               writeback_xercr_value_int = memory_RC;
            end

            /* Register locking/tracking is sorted out by the act of writing
             * back values, by DE.  But the generic full-lock is separate.
             * This could be optimised (DE could check wb_unlocks_generic)
             * but separate signals are a bit clearer.
             */
            writeback_unlock_generic_int = wb_unlocks_generic;
         end
      end else begin // if (memory_valid)

         if (state == `WB_STATE_2ND_CYCLE) begin
            /* This case deals with the second cycle of a two-cycle exception.
             * The first cycle has annulled/made MEM invalid.
             */
            writeback_spr_en_int = 1;
            writeback_spr_reg_int = `DE_spr_SRR0;
            writeback_spr_value_int = saved_pc;

            /* Special SPR port is LR/SRR1/DSISR only */
            writeback_sspr_en_int = 1;
            writeback_sspr_reg_int = `DE_spr_SRR1;
            writeback_sspr_value_int = saved_msr;

            /* And finally, change control flow: */
            writeback_newpcmsr_valid_int = 1;
            writeback_newpc_int = new_pc;
            writeback_newmsr_int = new_msr;
         end
      end // else: !if(memory_valid)
   end

   ////////////////////////////////////////////////////////////////////////////////
   // State

   always @(posedge clk) begin
      /* Debug */
      if (memory_valid) begin
         if (memory_fault == 0) begin
            counter_instr_commit <= counter_instr_commit + 1;
	 end

`ifdef DEBUG
         if (memory_fault != 0) begin
            $display("WB: Fault presented (%d), PC %08x",
                     memory_fault, memory_pc);
         end

         if (writeback_gpr_port0_en_int) begin
            $display("WB: '%s': writing %08x to r%d via port0, PC %08x\n",
                     name, writeback_gpr_port0_value_int, wb_write_gpr_port0_reg, memory_pc);
         end
         if (writeback_gpr_port1_en_int) begin
            $display("WB: '%s': writing %08x to r%d via port1, PC %08x\n",
                     name, writeback_gpr_port1_value_int, wb_write_gpr_port1_reg, memory_pc);
         end
         if (writeback_spr_en_int) begin
            $display("WB: '%s': writing %08x to SPR%d, PC %08x\n",
                     name, writeback_spr_value_int, writeback_spr_reg_int, memory_pc);
         end
         if (writeback_sspr_en_int) begin
            $display("WB: '%s': writing %08x to special SPR%d, PC %08x\n",
                     name, writeback_sspr_value_int, writeback_sspr_reg_int, memory_pc);
         end
         if (wb_write_xercr) begin
            $display("WB: '%s': writing %016x to XER/CR, PC %08x\n",
                     name, writeback_xercr_value_int, memory_pc);
         end

         /* -----\/----- EXCLUDED -----\/-----
          if (wb_write_sr_reg != -1)
          $display("WB: '%s': writing %08x to SR idx %d, PC %08x\n",
          name,
          wb_write_sr_value, wb_write_sr_reg, memory_pc);
          -----/\----- EXCLUDED -----/\----- */

         if (wb_annul_back_int || writeback_newpcmsr_valid_int) begin
            $display("WB: '%s': annul %d, new_pc_msr_valid %d, new_pc %08x, PC %08x\n",
                     name, wb_annul_back_int, writeback_newpcmsr_valid_int,
                     writeback_newpc_int, memory_pc);
         end
         if (writeback_unlock_generic_int) begin
            $display("WB: '%s': Generic-unlock, PC %08x\n", name, memory_pc);
         end
`endif
      end else begin
         counter_stall_cycle <= counter_stall_cycle + 1;
`ifdef DEBUG
         $display("WB: Nothing, MEM not valid (ctrs: icomm %d, cstall %d",
                  counter_instr_commit, counter_stall_cycle);
`endif
      end

      /* Actual work */
      if (state == `WB_STATE_NORMAL && wb_twocycle_exception_int) begin
         state <= `WB_STATE_2ND_CYCLE;
`ifdef DEBUG
         $display("WB: Exception 1st cycle (%d), PC %08x, DAR %08x, DSISR %08x\n",
                  memory_fault, memory_pc,
                  writeback_spr_value_int,  writeback_sspr_value_int);
`endif
      end else begin
         /* Either NORMAL and not a two-cycle exception, or in 2nd cycle. */
         if (state == `WB_STATE_2ND_CYCLE) begin
            state <= `WB_STATE_NORMAL;
`ifdef DEBUG
            $display("WB: Exception 2nd cycle (%d), PC %08x, newPC %08x, newMSR %08x, SRR0 %08x, SRR1 %08x\n",
                     memory_fault, memory_pc, new_pc, new_msr,
                     writeback_spr_value_int,  writeback_sspr_value_int);
`endif
         end else begin
            if (memory_valid && memory_fault != 0) begin
`ifdef DEBUG
               $display("WB: Exception (%d), PC %08x, newPC %08x, newMSR %08x, SRR0 %08x, SRR1 %08x\n",
                        memory_fault, memory_pc, new_pc, new_msr,
                        writeback_spr_value_int,  writeback_sspr_value_int);
`endif
            end
         end
      end

      if (reset) begin
         state                <= `WB_STATE_NORMAL;
         counter_instr_commit <= 32'h0;
         counter_stall_cycle  <= 32'h0;
      end
   end

   /////////////////////////////////////////////////////////////////////////////
   // Assign outputs

   assign writeback_newpc = writeback_newpc_int;
   assign writeback_newmsr = writeback_newmsr_int;
   assign writeback_newpcmsr_valid = writeback_newpcmsr_valid_int;
   assign writeback_gpr_port0_en = writeback_gpr_port0_en_int;
   assign writeback_gpr_port0_reg = writeback_gpr_port0_reg_int;
   assign writeback_gpr_port0_value = writeback_gpr_port0_value_int;
   assign writeback_gpr_port1_en = writeback_gpr_port1_en_int;
   assign writeback_gpr_port1_reg = writeback_gpr_port1_reg_int;
   assign writeback_gpr_port1_value = writeback_gpr_port1_value_int;
   assign writeback_xercr_en = writeback_xercr_en_int;
   assign writeback_xercr_value = writeback_xercr_value_int;
   assign writeback_spr_en = writeback_spr_en_int;
   assign writeback_spr_reg = writeback_spr_reg_int;
   assign writeback_spr_value = writeback_spr_value_int;
   assign writeback_sspr_en = writeback_sspr_en_int;
   assign writeback_sspr_reg = writeback_sspr_reg_int;
   assign writeback_sspr_value = writeback_sspr_value_int;
   assign writeback_unlock_generic = writeback_unlock_generic_int;
   assign writeback_annul = wb_annul_back_int;
endmodule
