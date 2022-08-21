/* plc
 *
 * Pipeline stage control logic
 *
 * Produces an enable governing whether a pipeline stage holds its outputs
 * or changes state, given valid indication from the previous stage and
 * a stall from the next stage.
 *
 * Supports a stage being able to stall itself (and those previous),
 * meaning the stage flags it cannot produce valid data in a given cycle.
 *
 * Also supports bubble-squashing, where an empty stage can become full/valid
 * even if downstream stages are stalled.
 *
 * ME 12 Jan 2022
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

/* Operation:
 *             <------ stage N ---------------------> <--- stage N+1 --...
 *
 *    +-----+		                      +-----+
 *  ->| PLC |--valid--------------------in--->| PLC |---valid-out------>
 *    |     |				      |     |
 *  <-|     |<---stall------------------out---|     |<---stall-in------
 *    |     |				      |  V  |
 *    |     |		    +--self_stall---->|     |
 *    +-----+		    |		      +-----+
 *       |                  |                    | (enable_change)
 *    +-----+		    |		      +-----+
 *    |     |           +---+---+             |     |
 *  ->| FFs |--Data---->| Logic |---Data----->| FFs |------------------>
 *    |     |		|       |             |     |
 *    |     |		+-------+	      |     |
 *    +-----+				      +-----+
 *
 * Rational statements about a pipeline stage:
 *
 * Stage has a validity, reflected to next consumer by valid_out. 'V' for short.
 *
 * If V=0 and valid_in=1 and self_stall=0, change to V=1 and enable_change=1
 * (of datapath outputs).
 * Note stall_in is ignored, meaning a pipeline bubble (invalid) before
 * a stalled stage can be squashed by valid data "catching up" with it.
 * stall_out=0 when this happens.
 *
 * A parameter option is given to disable bubble-squashing, meaning a stall_in
 * will propagate to a stall_out even if the current stage is invalid.
 *
 * stall_in=1 means the consumer is requesting we hold valid outputs.  It doesn't
 * apply to invalid outputs (meaning bubbles can be squashed, as above.)
 *
 * Logic flags self_stall=1 if the current valid_in=1 data needs more thinking time.
 * self_stall is only valid when valid_in=1.
 *
 * This leads to:  If V=1, don't change anything if stall_in=1 (including
 * enable_change=0).
 *
 * Otherwise (if V=1 and stall_in=0): if valid_in=1 and self_stall=0 then new
 * V=1 and enable_change=1.
 * If valid_in=1 and self_stall=1, OR valid_in=0 then new valid=0 and enable_change=0.
 *
 * If annul_in=1, enable_change=0 and this stage goes invalid, no matter other inputs.
 *
 * Trooftable:
 * 
 * V  valid_in  stall_in  self_stall  en_chg  new V : Notes
 * 0  0         x         x           0       0       Stay invalid
 * 0  1         x         0           1       1       Go valid/full (squash bubble)
 * 0  1         1         x           0       0       Stay invalid (do not squash bubble)
 * 0  1         x         1           0       0       Stalling self (not yet valid)
 * 1  0         0         x           0       0       Go invalid (consumed)
 * 1  0         1         x           0       1       Hold existing data
 * 1  1         0         0           1       1       Stay valid, new data
 * 1  1         1         0           0       1       Hold existing data
 * 1  1         x         1           0       1       Stalling self, hold existing data
 *
 */

module plc(input wire  clk,
	   input wire  reset,

	   /* To/from previous stage */
	   input wire  valid_in,
	   output wire stall_out,

	   input wire  self_stall,

	   /* To/from next stage */
	   output wire valid_out,
	   input wire  stall_in,
	   input wire  annul_in,

	   /* The final gubbins: enable this stage's outputs to change! */
	   output wire enable_change
	   );

   parameter ENABLE_BUBBLE_SQUASH = 1;

   reg 		       valid;

   wire 	       new_state_valid;
   wire 	       new_state_invalid;

   assign new_state_valid = ((valid == 0) &&
                             (ENABLE_BUBBLE_SQUASH || (stall_in == 0)) &&
			     (valid_in == 1) && (self_stall == 0)) ||
			    ((valid == 1) &&
			     (stall_in == 0) &&
			     (valid_in == 1) && (self_stall == 0));

   assign new_state_invalid = annul_in ||
			      ( (valid == 1) && (stall_in == 0) &&
				/* Either stalling self, result not ready yet... */
				( ((valid_in == 1) && (self_stall == 1)) ||
				  /* ...or we've a result that's consumed AND
				   * the next token isn't valid: */
				  (valid_in == 0) ) );

   assign enable_change = !new_state_invalid && new_state_valid;
   /* Might flag stall upstream for two reasons:
    * 1. This stage holds data that downstream wants held/stall in.
    *    We can't accept new data.
    * 2. Or, we're presented with valid data and this stage is self-stalled
    *    (can't produce valid data yet).  We need to hold our input data.
    */
   assign stall_out = ((valid || ENABLE_BUBBLE_SQUASH == 0) && stall_in) || (valid_in && self_stall);
   assign valid_out = valid;

   always @(posedge clk) begin
      if (new_state_invalid)
	valid <= 0;
      else if (new_state_valid)
	valid <= 1;

      if (reset) begin
	 valid <= 0;
      end
   end


endmodule // plc
