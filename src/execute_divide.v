/* execute_divide
 *
 * Very simple iterative integer divider; signed and unsigned.  It is not
 * designed to be optimal for space or time, but correctness and rapid
 * implementation! ;-)
 *
 * Interface:
 * - Present operands and div_op, and enable=1
 * - done goes high once out/ov are valid
 * - drop enable, then done drops.
 *
 * 28/12/2020
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

`include "arch_defs.vh"
`include "decode_enums.vh"


module execute_divide(input wire              clk,
                      input wire              reset,

                      input wire              enable,
                      input wire 	      unsigned_div,
                      output wire             done,

                      input wire [`REGSZ-1:0] in_a,
                      input wire [`REGSZ-1:0] in_b,
                      output reg [`REGSZ-1:0] out,
                      output reg              ov
                      );

   reg [1:0]                                   state;
`define ST_DIV_IDLE	0
`define ST_DIV_BUSY	1
`define ST_DIV_DONE	2

   reg [5:0]                                   count;
   reg [31:0]                                  R;
   reg [31:0]                                  Q;

   reg [31:0]                                  N; // Numerator
   reg [31:0]                                  D; // Denominator

   reg                                         negate;

   always @(posedge clk) begin
      if (state == `ST_DIV_IDLE) begin
         // New request
         if (enable) begin

            // Handle special cases (such as /0) immediately:
            if (in_b == 32'h0) begin
               if (unsigned_div) begin
                  out	<= 32'hffffffff;
               end else if (in_a[31]) begin
                  // A is -ve
                  out <= 32'h80000000;
               end else begin
                  // A is +ve
                  out <= 32'h7fffffff;
               end

               ov 	<= 1;
               state 	<= `ST_DIV_DONE;

            end else if (!unsigned_div &&
                         in_a == 32'h80000000 && in_b == 32'hffffffff) begin
               ov 	<= 1;
               out 	<= 32'h7fffffff;
               state 	<= `ST_DIV_DONE;

            end else begin
               // Normal division
               ov 	<= 0;
               state  <= `ST_DIV_BUSY;
               count  <= 32;
               Q 	<= 0;

               if (unsigned_div) begin
                  R 	<= {31'h0, in_a[31]}; // Init R from numerator
                  N   <= {in_a[30:0], 1'b0};
                  D   <= in_b;

               end else begin
                  negate	<= in_a[31] ^ in_b[31];

                  if (in_a[31]) begin // A negative
                     N	<= {-in_a[30:0], 1'b0};
                     /* Another corner case: where numerator is 0x80000000,
                      * it is treated as "+0x80000000" with this one wierd
                      * trick(TM):
                      */
                     R 	<= (in_a == 32'h80000000) ?
                           32'h00000001 :
                           32'h00000000;
                  end else begin
                     N   	<= {in_a[30:0], 1'b0};
                     R 	<= 32'h0;
                  end

                  if (in_b[31]) begin // B negative
                     D   	<= -in_b;
                  end else begin
                     D   	<= in_b;
                  end
               end
            end
         end

      end else if (state == `ST_DIV_BUSY) begin
         if (!enable) begin
            // Can always cancel
            state 	<= `ST_DIV_IDLE;
         end else begin

            /* Algorithm based on https://en.wikipedia.org/wiki/Division_algorithm#Integer_division_(unsigned)_with_remainder
             *
             * (Yes, a classy reference to WP!)  Algorithm re-arranged for non-imperative format.
             */
            if (R >= D) begin
               Q 	<= {Q[30:0], 1'b1};
               R 	<= {(R-D), N[31]};
            end else begin
               Q    	<= {Q[30:0], 1'b0};
               R    	<= {R[30:0], N[31]};
            end
            N <= {N[30:0], 1'b0};

            // Do that 32 times.
            if (count != 0) begin
               count 	<= count - 1;
            end else begin

               state 	<= `ST_DIV_DONE;

               if (unsigned_div) begin
                  // FIXME: can probably remove this FF, but need to inhibit last Q write
                  out <= Q;
               end else begin
                  if (negate)
                    out <= -Q;
                  else
                    out <= Q;
               end
            end
         end

      end else begin // Implies ST_DIV_DONE
         // Hold until enable drops.
         if (!enable) begin
            state 	<= `ST_DIV_IDLE;
            /* Note: we keep the results (out and ov) stable
             * until the next request.  The execute stage
             * might have other problems (e.g. being stalled by MEM)
             * and will pick up the result when it's ready.
             */
         end
      end

      if (reset) begin
         state  	<= `ST_DIV_IDLE;
      end
   end

   assign done = (state == `ST_DIV_DONE);

endmodule // execute_divide

