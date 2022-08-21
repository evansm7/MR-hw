/* mmu_bat
 *
 * Check BATs, calculate output addresses.  Used by MMU.
 *
 * ME 08/09/20
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


module mmu_bat(/* BAT regs: */
	       input wire [(64*`NR_BATs)-1:0] bats,

	       /* Input request */
	       input wire [`REGSZ-1:0] 	      vaddress,
	       input wire 		      privileged,
	       input wire 		      RnW,

	       /* Output translation */
	       output wire [`REGSZ-1:0]       paddress,
	       output wire 		      cacheable_access,
	       output wire [2:0] 	      fault_type, // MMU_FAULT_xxx, or 0
	       output wire 		      valid
	       );

   parameter                        INSTRUCTION = 0;


   ////////////////////////////////////////////////////////////////////////////////

   wire [`NR_BATs-1:0] 		    bat_n_hit;
   wire 			    bat_hit;

   reg [10:0] 			    bl_n_cond[`NR_BATs-1:0]; // Wire
   reg [14:0] 			    brpn_n_cond[`NR_BATs-1:0]; // Wire
   reg [3:0] 			    wimg_n_cond[`NR_BATs-1:0]; // Wire
   reg [1:0] 			    pp_n_cond[`NR_BATs-1:0]; // Wire

   genvar 			    i;
   generate
      for (i = 0; i < `NR_BATs; i = i + 1) begin: foo
	 wire [14:0] 		    brpn_n;
	 wire [10:0] 		    bl_n;
	 wire [3:0] 		    wimg_n;
	 wire [1:0] 		    pp_n;

	 mmu_bat_match MBM(.ea(vaddress),
			   .privileged(privileged),
			   .bat_val({bats[(i*64)+63:(i*64)+32] /* U */, bats[(i*64)+31:(i*64)+0] /* L */}),
			   .match(bat_n_hit[i]),

			   .bl(bl_n),
			   .brpn(brpn_n),
			   .wimg(wimg_n),
			   .pp(pp_n)
			   );

	 always @(*) begin
	    bl_n_cond[i] = bat_n_hit[i] ? bl_n : 11'h0;
	    brpn_n_cond[i] = bat_n_hit[i] ? brpn_n : 15'h0;
	    wimg_n_cond[i] = bat_n_hit[i] ? wimg_n : 4'h0;
	    pp_n_cond[i] = bat_n_hit[i] ? pp_n : 2'h0;
	 end
      end
   endgenerate

   assign bat_hit = |bat_n_hit;

   /* Attempt at 'wired OR' style reduction to combine
    * BAT outputs when necessary, without using a priority (e.g. flatter
    * logic).  This is OK because multiple BAT hits is UNPRED.
    */

   reg [10:0]                       bl_r[`NR_BATs-1:0]; // Wire
   reg [14:0] 			    brpn_r[`NR_BATs-1:0]; // Wire
   reg [3:0] 			    wimg_r[`NR_BATs-1:0]; // Wire
   reg [1:0] 			    pp_r[`NR_BATs-1:0]; // Wire

   reg [7:0] 			    l; // Loop counter

   /* This does synthesise ;-)  A for in an always block works
    * more consistently than a generate-for across icarus/ISE/Verilator.
    *
    * OR-reduce the array elements:
    */
   always @(*) begin
      for (l = 0; l < `NR_BATs; l = l + 1) begin
	 if (l == 0) begin
	    bl_r[l] = bl_n_cond[l];
	    brpn_r[l] = brpn_n_cond[l];
	    wimg_r[l] = wimg_n_cond[l];
	    pp_r[l] = pp_n_cond[l];
	 end else begin
	    bl_r[l] = bl_r[l-1] | bl_n_cond[l];
	    brpn_r[l] = brpn_r[l-1] | brpn_n_cond[l];
	    wimg_r[l] = wimg_r[l-1] | wimg_n_cond[l];
	    pp_r[l] = pp_r[l-1] | pp_n_cond[l];
	 end
      end
   end

   wire [10:0] 			    bl;
   wire [14:0] 			    brpn;
   wire [3:0] 			    wimg;
   wire [1:0] 			    pp;

   assign bl = bl_r[`NR_BATs-1];
   assign brpn = brpn_r[`NR_BATs-1];
   assign wimg = wimg_r[`NR_BATs-1];
   assign pp = pp_r[`NR_BATs-1];

   // Generate PADDRESS_R from VA (masked down using BL) and BRPN (masked using BL)
   assign paddress = {(vaddress[`REGSZ-1:17] & {4'h0, bl[10:0]}) | brpn[14:0], vaddress[16:0]};
   assign cacheable_access = (wimg[3:2] == 2'b00);
   assign fault_type = ((pp[1:0] == 2'b00) ||
			(!INSTRUCTION && !RnW && pp[0])) ? `MMU_FAULT_PF : `MMU_FAULT_NONE;
   assign valid = bat_hit;

endmodule // mmu_bat
