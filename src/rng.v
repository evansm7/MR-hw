/* rng
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
module rng(input wire clk,
	   input wire reset,
	   output reg [15:0] rng_o
	   );

   parameter S = 16'ha5a5;

   reg [15:0] 	     lfsr;
   reg [15:0] 	     r;
   wire		     lfsr_in;
   assign	     lfsr_in = lfsr[3] ^ ~lfsr[5] ^ lfsr[13] ^ ~lfsr[15];

   always @(posedge clk)
     begin
	if (reset) begin
	   lfsr <= 16'hffff;
	   r <= S;
	   rng_o <= S;
	end else begin
	   r <= {r[0],r[15:1]};
	   lfsr[15:0] <= {lfsr[14:0],lfsr_in};
	   rng_o[15:0] <= r[15:0] ^ lfsr[15:0];
	end
     end

endmodule // rng
