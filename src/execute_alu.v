/* execute_alu
 *
 * Integer arithmetic, logical ops, popcnt, shifts etc.
 *
 * Note that overflow and carry_out are both 0 unless there's an ALU
 * op in progress.  The calculation of CR (and XER.CA for shifts) depends
 * on this property.
 *
 * ME 13/3/20
 *
 * Copyright 2020 Matt Evans
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
`include "decode_enums.vh"


module execute_alu(input wire [5:0]         alu_op,
		   input wire [`REGSZ-1:0]  in_a,
		   input wire [`REGSZ-1:0]  in_b,
		   input wire [`REGSZ-1:0]  in_c,
		   input wire 		    carry_in,
		   output wire 		    carry_out,
		   output wire 		    overflow,
		   output wire [`REGSZ-1:0] out
		   );

   wire [`REGSZ-1:0]                        add_out;
   wire                                     add_ov;
   wire                                     add_co;

   reg [`REGSZ-1:0]                         val; // Wire
   reg [`REGSZ-1:0]                         add_a; // Wire
   reg [`REGSZ-1:0]                         add_b; // Wire
   reg                                      add_ci; // Wire
   reg                                      ov; // Wire
   reg                                      co; // Wire

   execute_alu_adder ADD(.A(add_a),
			 .B(add_b),
			 .OUT(add_out),
			 .CI(add_ci),
			 .CO(add_co),
			 .OV(add_ov));


   always @(*) begin
      add_a = `REG_ZERO;
      add_b = `REG_ZERO;
      add_ci = 1'b0;
      val = `REG_ZERO;
      ov = 0;
      co = 0;

      case (alu_op)
	////////////////////////////////////////////////////////////////////////
	// Arithmetic

	`EXOP_ALU_ADC_AB_D: begin
	   add_a  = in_a;
	   add_b  = in_b;
	   add_ci = carry_in;
           val    = add_out;
           ov     = add_ov;
           co     = add_co;
	end

	`EXOP_ALU_ADC_A_0_D: begin
	   add_a  = in_a;
	   add_b  = `REG_ZERO;
	   add_ci = carry_in;
           val    = add_out;
           ov     = add_ov;
           co     = add_co;
	end

	`EXOP_ALU_ADC_A_M1_D: begin
	   add_a  = in_a;
	   add_b  = `REG_ONES;
	   add_ci = carry_in;
           val    = add_out;
           ov     = add_ov;
           co     = add_co;
	end

        `EXOP_ALU_ADD_AB: begin
	   add_a  = in_a;
	   add_b  = in_b;
	   add_ci = 0;
           val    = add_out;
           ov     = add_ov;
           co     = add_co;
	end

	`EXOP_ALU_SUB_A_0_D: begin
	   add_a  = ~in_a;
	   add_b  = `REG_ZERO;
	   add_ci = carry_in;
           val    = add_out;
           ov     = add_ov;
           co     = add_co;
	end

	`EXOP_ALU_SUB_A_M1_D: begin
	   add_a  = ~in_a;
	   add_b  = `REG_ONES;
	   add_ci = carry_in;
           val    = add_out;
           ov     = add_ov;
           co     = add_co;
	end

	`EXOP_ALU_SUB_BA: begin
	   add_a  = ~in_a;
	   add_b  = in_b;
	   add_ci = 1;
           val    = add_out;
           ov     = add_ov;
           co     = add_co;
	end

	`EXOP_ALU_SUB_BA_D: begin
	   add_a  = ~in_a;
	   add_b  = in_b;
	   add_ci = carry_in;
           val    = add_out;
           ov     = add_ov;
           co     = add_co;
	end

	`EXOP_ALU_DEC_C: begin
	   add_a  = in_c;
	   add_b  = `REG_ONES;
	   add_ci = 0;
           val    = add_out;
           ov     = add_ov;
           co     = add_co;
	end

        `EXOP_ALU_NEG_A: begin
           add_a  = ~in_a;
	   add_b  = `REG_ZERO;
	   add_ci = 1;
           if (in_a == 32'h80000000) begin
              val = 32'h80000000;
              ov  = 1;
              co  = 0; // Check?  Not doc'd
           end else begin
              val    = add_out;
              ov     = add_ov;
              co     = add_co;
           end
        end

	////////////////////////////////////////////////////////////////////////
	// Logical
	`EXOP_ALU_AND_AB:
	  val = in_a & in_b;

	`EXOP_ALU_ANDC_AB:
	  val = in_a & ~in_b;

	`EXOP_ALU_NAND_AB:
	  val = ~(in_a & in_b);

	`EXOP_ALU_NOR_AB:
	  val = ~(in_a | in_b);

	`EXOP_ALU_NXOR_AB:
	  val = ~(in_a ^ in_b);

	`EXOP_ALU_ORC_AB:
	  val = in_a | ~in_b;

	`EXOP_ALU_OR_AB:
	  val = in_a | in_b;

	`EXOP_ALU_XOR_AB:
	  val = in_a ^ in_b;

        default: begin /* Including zero */
	end

      endcase
   end

   assign out = val;
   assign overflow = ov;
   assign carry_out = co;

endmodule


module execute_alu_adder(input wire [`REGSZ-1:0]  A,
			 input wire [`REGSZ-1:0]  B,
			 output wire [`REGSZ-1:0] OUT,
			 input wire 		  CI,
			 output wire 		  CO,
			 output wire 		  OV);

   reg [`REGSZ:0] 				  res; /* Note 1 bit larger */

   always @(*) begin
      res = A + B + CI;
   end

   assign CO = res[`REGSZ];
   assign OUT = res[`REGSZ-1:0];

   /* The op overflows if two -ves make a +ve, or two +ves make a -ve: */
   assign OV = ( !A[`REGSZ-1] && !B[`REGSZ-1] &&  res[`REGSZ-1] ) ||
	       (  A[`REGSZ-1] &&  B[`REGSZ-1] && !res[`REGSZ-1] );

endmodule
