/* cache_arb2
 *
 * Arbitrate for the cache, for two requesters A & B.
 *
 * Note, stall is common to all requesters, doesn't need muxing.
 * Similarly, read data does not need muxing (both requesters consume
 * same wires).
 *
 * Refactored out of itlb_icache 170820 ME
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


module cache_arb2(input wire clk,
		  input wire 	     reset,

		  /* Requester A */
		  input wire [31:0]  cache_a_address,
		  input wire 	     cache_a_strobe,
		  input wire [3:0]   cache_a_request,
		  input wire [1:0]   cache_a_size,
		  input wire [31:0]  cache_a_wdata,
		  output wire 	     cache_a_valid,

		  /* Requester B */
		  input wire [31:0]  cache_b_address,
		  input wire 	     cache_b_strobe,
		  input wire [3:0]   cache_b_request,
		  input wire [1:0]   cache_b_size,
		  input wire [31:0]  cache_b_wdata,
		  output wire 	     cache_b_valid,

		  /* Cache interface */
		  output wire [31:0] cache_address,
		  output wire 	     cache_strobe,
		  output wire [3:0]  cache_request,
		  output wire [1:0]  cache_size,
		  output wire [31:0] cache_wdata,
		  input wire 	     cache_valid
		  );

   parameter PASS_A = 0;

   reg [31:0] 	int_address; // Wire
   reg 		int_strobe; // Wire
   reg [3:0]	int_request; // Wire
   reg [1:0] 	int_size; // Wire
   reg [31:0] 	int_rdata; // Wire
   reg [63:0] 	int_raw_rdata; // Wire
   reg [31:0] 	int_wdata; // Wire
   reg 		int_a_valid; // Wire
   reg 		int_b_valid; // Wire

   reg [1:0] 	cache_chosen_requestor;

   always @(posedge clk) begin
      // There are two input requests: cache_a_strobe and cache_b_strobe.

      // Choose a requester and set cache_chosen_requestor
      if (cache_chosen_requestor == 0) begin
	 // A request is being made via comb logic below.
	 // If valid, a result is returned same-cycle.
	 // However, if not valid then we're going into a
	 // multi-cycle op if we carry on with same inputs.

	 // if valid = 0 and at least one requester = 1, then stall will occur
	 // in next cycle; so go into 'chosen' state:

	 if (cache_a_strobe && !cache_valid) begin
	    cache_chosen_requestor <= 1;
	 end else if (cache_b_strobe && !cache_valid) begin
	    cache_chosen_requestor <= 2;
	 end
      end else begin
	 // Inputs/outputs are muxed over to chosen requester in comb logic below.
	 // It stays chosen until a Valid=1 cycle, whereupon the access
	 // is complete.  Or, until the request goes away; this can happen if
	 // fetch stops due to a pipeline stall (most likely because MEM is waiting
	 // on us!).  The MEM "other" request will never just go away, though.
	 if (cache_valid || !cache_strobe) begin
	    cache_chosen_requestor <= 0;
	 end
      end

      if (reset) begin
	 cache_chosen_requestor <= 2'b00;
      end
   end

   always @(*) begin
      // If a requester is not the "chosen one", it gets valid=0:
      if (cache_chosen_requestor == 1 ||
	  (cache_chosen_requestor == 0 && cache_a_strobe)) begin
	 int_a_valid = cache_a_strobe && cache_valid;
	 int_b_valid = 0;

	 int_address = cache_a_address;
	 int_strobe = cache_a_strobe;
	 int_request = cache_a_request;
	 int_size = cache_a_size;
	 int_wdata = cache_a_wdata;
      end else if (cache_chosen_requestor == 2 ||
		   (cache_chosen_requestor == 0 || cache_b_strobe)) begin
	 int_a_valid = 0;
	 int_b_valid = cache_b_strobe && cache_valid;

	 int_address = cache_b_address;
	 int_strobe = cache_b_strobe;
	 int_request = cache_b_request;
	 int_size = cache_b_size;
	 int_wdata = cache_b_wdata;
      end else begin
	 // No requests, so we get default values.
	 int_a_valid = 0;
	 int_b_valid = 0;

	 int_address = PASS_A ?
                       cache_a_address :
                       cache_b_address;
	 int_strobe = 0;
	 int_request = 4'h0;
	 int_size = 2'h0;
	 int_wdata = 32'h0;
      end
   end // always @ (*)

   assign cache_a_valid = int_a_valid;
   assign cache_b_valid = int_b_valid;

   assign cache_address = int_address;
   assign cache_strobe = int_strobe;
   assign cache_request = int_request;
   assign cache_size = int_size;
   assign cache_wdata = int_wdata;

endmodule // cache_arb2
