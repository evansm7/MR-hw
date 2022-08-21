/* writeback_calc_exc
 *
 * Calculate the PC, MSR and DSISR contents for an exception presented to WB.
 *
 * ME 13/3/20
 *
 * Copyright 2020, 2022 Matt Evans
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

`include "decode_enums.vh"
`include "arch_defs.vh"

module writeback_calc_exc(input wire [3:0]         fault,
                          input wire [31:0]        instr,
                          input wire [`REGSZ-1:0]  pc,
                          input wire [31:0]        msr,

                          output wire [`REGSZ-1:0] saved_pc,
                          output wire [31:0]       saved_msr,
                          output wire [`REGSZ-1:0] new_pc,
                          output wire [31:0]       new_msr,
                          output wire [31:0]       new_dsisr,

                          output wire              two_cycle
                          );

   reg [`REGSZ-1:0]                                saved_pc_r;
   reg [31:0]                                      saved_msr_r;
   reg [`REGSZ-1:0]                                new_pc_r;
   reg [31:0]                                      new_msr_r;
   reg [31:0]                                      new_dsisr_r;
   reg                                             two_cycle_r;

   /* Vectors are at 00...00000000, or ff...fff00000: */
   wire [`REGSZ-16-1:0] 			   vectors = ((msr & `MSR_IP) != 0) ?
						   {{(`REGSZ-16-4){1'b1}}, 4'h0} :
						   {(`REGSZ-16){1'b0}};

   always @(*) begin
      saved_pc_r = pc;
      saved_msr_r = msr;
      new_pc_r = `REG_ZERO;
      new_msr_r = 32'h0;
      new_dsisr_r = 32'h0;
      two_cycle_r = 0;

      casez (fault)
        `FC_IRQ:
          new_pc_r = {vectors, 16'h0500};

        `FC_DEC:
          new_pc_r = {vectors, 16'h0900};

        `FC_PROG_ILL: begin
           new_pc_r = {vectors, 16'h0700};
           saved_msr_r = (msr & 32'h8000ffff) | 32'h00080000;
        end

        `FC_PROG_TRAP: begin
           new_pc_r = {vectors, 16'h0700};
           saved_msr_r = (msr & 32'h8000ffff) | 32'h00020000;
        end

        `FC_PROG_PRIV: begin
           new_pc_r = {vectors, 16'h0700};
           saved_msr_r = (msr & 32'h8000ffff) | 32'h00040000;
        end

        `FC_SC: begin
           new_pc_r = {vectors, 16'h0c00};
           saved_msr_r = msr & 32'h0000ffff;
           saved_pc_r = pc + 4;
        end

        `FC_FP:
          new_pc_r = {vectors, 16'h0800};

        `FC_ISI_TF: begin
           new_pc_r = {vectors, 16'h0400};
           saved_msr_r = (msr & 32'h07ffffff) | 32'h40000000;
        end

        `FC_ISI_PF: begin
           new_pc_r = {vectors, 16'h0400};
           saved_msr_r = (msr & 32'h07ffffff) | 32'h08000000;
        end

        `FC_ISI_NX: begin
           new_pc_r = {vectors, 16'h0400};
           saved_msr_r = (msr & 32'h07ffffff) | 32'h10000000;
        end

        `FC_DSI_MASK: begin
           two_cycle_r = 1;

           new_pc_r = {vectors, 16'h0300};
           saved_msr_r = msr & 32'h0000ffff;

           new_dsisr_r = (fault[`FC_DSI_WBIT] ? 32'h02000000 : 32'h0) |
                         (fault[`FC_DSI_PBIT] ? 32'h08000000 : 32'h40000000);
        end

	`FC_MEM_ALIGN: begin
	   two_cycle_r = 1;

           new_pc_r = {vectors, 16'h0600};
           saved_msr_r = msr & 32'h0000ffff;

	   // For X-form (instr[31]=0), it is {instr[2:1], instr[6], instr[10:7]}.
	   // For D-form loads/stores (instr[31]=1) the 7-bit field is {2'b00, instr[26], instr[30:27]}.
           new_dsisr_r = {15'h0,
			  (instr[31] ? {2'b00, instr[26], instr[30:27]} : {instr[2:1], instr[6], instr[10:7]}),
			  instr[25:21],
			  instr[20:16]
			  };

	end

        default: begin /* Includes FC_NONE, ILL_HYP... */
           /* Nothing */
           new_pc_r = 32'h0;
        end
      endcase
   end

   // Clearing PR, IR, DR, EE.
   assign new_msr = msr & `MSR_IP;

   assign saved_pc = saved_pc_r;
   assign saved_msr = saved_msr_r;
   assign new_pc = new_pc_r;
   assign new_dsisr = new_dsisr_r;
   assign two_cycle = two_cycle_r;

endmodule
