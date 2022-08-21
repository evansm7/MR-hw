/* mmu_bat_match
 *
 * For an incoming address, match a BAT value.
 *
 * ME 180820
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

module mmu_bat_match(input wire [31:0]  ea,
		     input wire 	privileged,
		     input wire [63:0] 	bat_val,

		     output wire 	match,
		     output wire [10:0] bl,
		     output wire [14:0] brpn,
		     output wire [3:0] 	wimg,
		     output wire [1:0] 	pp
		     );

   parameter INSTRUCTION = 0;

   // BATU fields
   wire [14:0] 				bepi = bat_val[63:49];
   assign 				bl = bat_val[44:34];
   wire 				Vs = bat_val[33];
   wire 				Vp = bat_val[32];

   // While we're decoding, unpack this entry:
   assign brpn = bat_val[31:17];
   assign wimg = bat_val[6:3];
   assign pp = bat_val[1:0];

   reg 				       match_r; // Wire
   always @(*) begin
      match_r = (ea[31:28] == bepi[14:11]) &&
		((ea[27:17] & ~bl[10:0]) == bepi[10:0]) &&
		((Vs && privileged) || (Vp && !privileged));
   end

   assign match = match_r;

endmodule // mmu_bat_match
