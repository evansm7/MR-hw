/* Calculate integer result CR flags
 *
 * ME 10/3/20
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


module execute_crf(input wire [`REGSZ-1:0] in,
                   input wire              co,
                   input wire              ov,
                   input wire              SO,
                   output wire [3:0]       crf,
                   output wire [3:0]       crf_compare_signed,
                   output wire [3:0]       crf_compare_unsigned
                   );

   reg                                     EQ;
   reg                                     LT;
   reg                                     GT;
   reg                                     LTu;
   reg                                     GTu;
   reg                                     LTs;
   reg                                     GTs;

   wire                                    N = in[`REGSZ-1];

   always @(*) begin
      EQ  = 0;
      LT  = 0;
      GT  = 0;
      LTu = 0;
      GTu = 0;
      LTs = 0;
      GTs = 0;

      if (in == `REG_ZERO) begin
	 EQ = 1;
      end else begin
         /* Regular record shows sign: */
         if (N) begin
	    LT = 1;
         end else begin
	    GT = 1;
         end

         /* Signed comparison */
         if (N ^ ov) begin
	    LTs = 1;
         end else begin
	    GTs = 1;
         end

         /* Unsigned comparison: */
         if (!co) begin
            LTu = 1;
         end else begin
            GTu = 1;
         end
      end

   end

   assign crf = {LT, GT, EQ, SO};
   assign crf_compare_signed = {LTs, GTs, EQ, SO};
   assign crf_compare_unsigned = {LTu, GTu, EQ, SO};

endmodule // execute_crf
