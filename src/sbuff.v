/* sbuff
 *
 * Skid buffer for the CPU pipeline.  This is designed to back onto
 * existing output FFs e.g. on a sync RAM read, which means this isn't quite a 2-entry
 * pipeline buffer.
 *
 * Behaviour:
 *
 * - Transparent by default, input ready (S=0) -- flow-through
 * - If output not ready and input valid, capture (S=1); thereafter, input not ready
 * - If output ready and S=1, captured data is consumed and S=0; input ready.
 *
 * The key is for i_ready to not depend combinatorially on o_ready
 *
 * There is also a "make empty" input, which returns to S=0.  (Used for annul!)
 *
 * Examples:
 *
 * c0	 in v=0 d=x r=1	 [   ]	out v=0 d=x r=0
 * c1	 in v=0 d=x r=1	 [   ]	out v=0 d=x r=1 // Note r=1 **
 * c2	 in v=1 d=A r=1	 [   ]	out v=1 d=A r=1 // A consumed
 * c3	 in v=1 d=B r=1	 [   ]	out v=1 d=B r=1 // B consumed
 * c4	 in v=1 d=C r=1	 [   ]	out v=1 d=C r=0	// stalls, C not consumed (note in r=1!)
 * c5	 in v=1 d=D r=0	 [ C ]	out v=1 d=C r=1	// C consumed; upstream r=0 **
 * c6	 in v=1 d=D r=1	 [   ]	out v=1 d=D r=0	// stalls, D not consumed
 * c7	 in v=1 d=E r=0	 [ D ]	out v=1 d=D r=0	// stalls
 * c8	 in v=1 d=E r=0	 [ D ]	out v=1 d=D r=0	// stalls
 * c9	 in v=1 d=E r=0	 [ D ]	out v=1 d=D r=1	// D consumed **
 * c10	 in v=1 d=E r=1	 [   ]	out v=1 d=E r=1	// E consumed
 * c11	 in v=1 d=F r=1	 [   ]	out v=1 d=F r=0	// stalls, F not consumed
 * c12	 in v=0 d=x r=0	 [ F ]	out v=1 d=F r=1	// F consumed
 * c13	 in v=0 d=x r=1	 [   ]	out v=0 d=x r=1
 * c14	 in v=0 d=x r=1	 [   ]	out v=0 d=x r=0 // Stall, but no input
 * c15	 in v=0 d=x r=1	 [   ]	out v=0 d=x r=1 // ** Note r=1, doesn't need to be delayed!
 *
 * **: Note upstream ready depends only on internal state, does not depend on
 *     downstream ready.  The bubble percolates up via internal state.
 * Note that input r=1 when empty, as we can always accept data then.  So, the
 * input readiness depends (only) on Fullness.
 *
 * ME 220221
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

module sbuff(input wire              clk,
	     input wire              reset,
	     // Input port:
	     input wire              i_valid,
	     output wire             i_ready,
	     input wire [WIDTH-1:0]  i_data,
	     // Output port:
	     output wire             o_valid,
	     input wire              o_ready,
	     output wire [WIDTH-1:0] o_data,
             // From annul:
             input                   empty_all
	     );

   parameter WIDTH = 1;

   reg [WIDTH-1:0] 			    storage;
   reg                                      full;

   // Input ready is 0 if our stash is full, 1 if empty:
   assign 	i_ready = !full;

   // Downstream valid if empty & input valid (shortcut), or if full (data captured!)
   assign 	o_valid = full ? 1 : i_valid;
   assign 	o_data = full ? storage : i_data;

   always @(posedge clk) begin
      if (empty_all) begin
         full	<= 0;
      end else begin
         if (!full) begin
            // Out not ready, but input?  Capture something:
	    if (i_valid && !o_ready) begin
	       storage 	<= i_data;
	       full	<= 1;
	    end
	 end else begin
            // Input ready is 0.  If out ready, it's consumed:
	    if (o_ready) begin
	       storage 	<= {WIDTH{1'bx}};
               full 	<= 0;
	    end
         end
      end

      if (reset) begin
         full 		<= 0;
      end
   end

endmodule
