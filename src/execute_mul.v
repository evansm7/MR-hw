/* execute_mul
 *
 * Pipelined, two-cycle multiplier.  Supports 32x32->32 and ->32(high word)
 *
 * ME 18/3/20
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

`include "arch_defs.vh"
`include "decode_enums.vh"

module execute_mul(input wire               clk,
                   input wire               reset,
                   input wire               enable,
                   input wire [5:0]         mul_op,
                   input wire [`REGSZ-1:0]  in_a,
                   input wire [`REGSZ-1:0]  in_b,

                   output wire [`REGSZ-1:0] out,
                   output wire              ov
                   );

   /* Fashion a 32-bit multiply with two steps:
    * Four 16x16->32 multiplies for partial products in cycle 1,
    * summing the products in cycle 2.
    */

   reg [`REGSZ-1:0]                         sum_out; // Wire
   reg                                      res_ov; // Wire
   wire [63:0]                              hwu_sum;
   wire [63:0]                              hw_sum;
   wire [63:0]                              mul_sum;

   wire signed [31:0] 			    in_a_s = in_a;
   wire signed [31:0] 			    in_b_s = in_b;
   wire signed [15:0]                       in_a1_s = in_a[15:0];
   wire signed [15:0]                       in_a2_s = in_a[31:16];
   wire signed [15:0]                       in_b1_s = in_b[15:0];
   wire signed [15:0]                       in_b2_s = in_b[31:16];

   wire [15:0]                              in_a1 = in_a[15:0];
   wire [15:0]                              in_a2 = in_a[31:16];
   wire [15:0]                              in_b1 = in_b[15:0];
   wire [15:0]                              in_b2 = in_b[31:16];

   reg [`REGSZ-1:0]                         res_a1b1_r;
   reg [`REGSZ-1:0]                         res_a1b2_r;
   reg [`REGSZ-1:0]                         res_a2b1_r;
   reg [`REGSZ-1:0]                         res_a2b2_r;

   reg [63:0] 				    temp_hw_out;

   assign hwu_sum = {32'h00000000, res_a1b1_r[31:0]} +
                    {16'h0000, res_a1b2_r[31:0], 16'h0000} +
                    {16'h0000, res_a2b1_r[31:0], 16'h0000} +
                    {res_a2b2_r[31:0], 32'h00000000};

   assign hw_sum = temp_hw_out;

   // As above, but with sign-extended products:
/* -----\/----- EXCLUDED -----\/-----
   assign hw_sum = {{32{res_a1b1_r[31]}}, res_a1b1_r[31:0]} +
                   {{16{res_a1b2_r[31]}}, res_a1b2_r[31:0], 16'h0000} +
                   {{16{res_a2b1_r[31]}}, res_a2b1_r[31:0], 16'h0000} +
                   {res_a2b2_r[31:0], 32'h00000000};

   assign mul_sum = res_a1b1_r[31:0] +
                    {res_a1b2_r[15:0], 16'h0000} +
                    {res_a2b1_r[15:0], 16'h0000} +
                    {res_a2b2_r[31:0], 32'h00000000};
 -----/\----- EXCLUDED -----/\----- */

   always @(*) begin
      res_ov = 0;
      if (mul_op == `EXOP_MUL_AB) begin
         sum_out = hw_sum[31:0];
         /* Overflow if:
          * - Top word isn't just sign-extension of bottom word
          * - Sign of result is inconsistent with sign of operands
          */
         res_ov                           = ( hw_sum[31] && &hw_sum[63:32] == 0 ) ||
                                            ( !hw_sum[31] && |hw_sum[63:32] == 1 ) ||
                                            (((in_a[31] ^ in_b[31]) != sum_out[31])
                                             && (sum_out != 0));
         /* 123 * 0 = 0, and does *not* overflow. */
      end else if (mul_op == `EXOP_MUL_HWU_AB) begin
         sum_out = hwu_sum[63:32];
      end else begin
         //  EXOP_MUL_HW_AB:
	 sum_out = hw_sum[63:32];
      end
   end

   always @(posedge clk) begin
      if (enable) begin
         temp_hw_out <= in_a_s * in_b_s;
         if (/*(mul_op == `EXOP_MUL_AB) ||*/
             (mul_op == `EXOP_MUL_HW_AB)) begin
            // Signed multiplies
            //               res_a1b1_r <= in_a1 * in_b1;
            // This is wrong; it does a fully-unsigned multiply b/c one operand is unsigned.
            // What I want is for b2_s to be treated as sign-extended, but in_a1 to not be.
            // Maybe I can fake this by turning this into a 17-bit mul...!

	    // Actually what I want just looks like:
	    // res <= a*b;
	    // output <= res;
	    // *but* current shape of EXE needs the result combinatorially
	    // so it can capture it itself in output FFs.
	    // When I pipeline this, do dedicated MUL_RESULT in MEM and we're good.
	    //

            //               res_a1b2_r <= in_a1 * in_b2_s;
            //               res_a2b1_r <= in_a2_s * in_b1;
            //               res_a2b2_r <= in_a2_s * in_b2_s;

	    // FIXME:  Temp hack to get things moving: see temp_hw_out
	    // Figure out how well this synthesises...!
         end else if ((mul_op == `EXOP_MUL_AB) || (mul_op == `EXOP_MUL_HWU_AB)) begin
            // Currently only used by MUL_HWU_AB; MUL_AB uses temp_hw_out
            res_a1b1_r <= in_a1 * in_b1;
            res_a1b2_r <= in_a1 * in_b2;
            res_a2b1_r <= in_a2 * in_b1;
            res_a2b2_r <= in_a2 * in_b2;
         end
      end
   end // always @ (posedge clk)

   // Assign outputs:
   assign out = sum_out;
   assign ov = res_ov;

endmodule // execute_mul
