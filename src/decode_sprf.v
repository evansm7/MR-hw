/* decode_sprf
 *
 * This module holds (most of) the SPRs, and decodes reads/writes.
 * Locking/dependencies are done elsewhere.
 *
 * Refactored out of decode.v 130122 ME
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

module decode_sprf(input wire                      clk,
		   input wire 			   reset,

		   /* Exported internal state: */
		   output wire [(64*`NR_BATs)-1:0] i_bats,
		   output wire [(64*`NR_BATs)-1:0] d_bats,
		   output wire [`REGSZ-1:0] 	   sdr1,

		   /* Read ports: */
		   input wire [5:0] 		   read_a_name,
		   output reg [`REGSZ-1:0] 	   spr_a, // Wire
		   input wire [5:0] 		   read_c_name,
		   output reg [`REGSZ-1:0] 	   spr_c, // Wire

		   /* Write ports: */
		   input wire 			   wr_spr_en,
		   input wire [5:0] 		   wr_spr_name,
		   input wire [`REGSZ-1:0] 	   wr_spr_value,

		   input wire 			   wr_sspr_en,
		   input wire [5:0] 		   wr_sspr_name,
		   input wire [`REGSZ-1:0] 	   wr_sspr_value,

		   /* Imported SPRs from elsewhere: */
		   input wire [63:0] 		   as_TB,
		   input wire [31:0] 		   as_DEC,

		   /* Debug reg access decode */
		   output wire 			   debug_written
		   );

   parameter WITH_BATS = 1;
   parameter WITH_MMU = 1;

   /////////////////////////////////////////////////////////////////////////////
   /* Architected state */
   reg [`REGSZ-1:0] 			     as_LR /*verilator public*/;     // SpecialSPR
   reg [`REGSZ-1:0] 			     as_CTR /*verilator public*/;
   reg [`REGSZ-1:0] 			     as_SPRG0 /*verilator public*/;
   reg [`REGSZ-1:0] 			     as_SPRG1 /*verilator public*/;
   reg [`REGSZ-1:0] 			     as_SPRG2 /*verilator public*/;
   reg [`REGSZ-1:0] 			     as_SPRG3 /*verilator public*/;
   reg [`REGSZ-1:0] 			     as_SRR0 /*verilator public*/;
   reg [`REGSZ-1:0] 			     as_SRR1 /*verilator public*/;   // SpecialSPR
   reg [`REGSZ-1:0] 			     as_SDR1 /*verilator public*/;
   reg [`REGSZ-1:0] 			     as_DAR /*verilator public*/;
   reg [31:0]                                as_DSISR /*verilator public*/;  // SpecialSPR
   reg [`REGSZ-1:0] 			     as_DABR /*verilator public*/;

   reg [31:0]                                as_IBAT0U /*verilator public*/;
   reg [31:0]                                as_IBAT0L /*verilator public*/;
   reg [31:0]                                as_IBAT1U /*verilator public*/;
   reg [31:0]                                as_IBAT1L /*verilator public*/;
   reg [31:0]                                as_IBAT2U /*verilator public*/;
   reg [31:0]                                as_IBAT2L /*verilator public*/;
   reg [31:0]                                as_IBAT3U /*verilator public*/;
   reg [31:0]                                as_IBAT3L /*verilator public*/;
   reg [31:0]                                as_DBAT0U /*verilator public*/;
   reg [31:0]                                as_DBAT0L /*verilator public*/;
   reg [31:0]                                as_DBAT1U /*verilator public*/;
   reg [31:0]                                as_DBAT1L /*verilator public*/;
   reg [31:0]                                as_DBAT2U /*verilator public*/;
   reg [31:0]                                as_DBAT2L /*verilator public*/;
   reg [31:0]                                as_DBAT3U /*verilator public*/;
   reg [31:0]                                as_DBAT3L /*verilator public*/;


   /////////////////////////////////////////////////////////////////////////////
   /* Bundle the BATs for export to IMMU/DMMU: */
   assign i_bats = WITH_BATS ? {as_IBAT3U & `BATU_valid_msk, as_IBAT3L & `BATL_valid_msk,
                                as_IBAT2U & `BATU_valid_msk, as_IBAT2L & `BATL_valid_msk,
                                as_IBAT1U & `BATU_valid_msk, as_IBAT1L & `BATL_valid_msk,
                                as_IBAT0U & `BATU_valid_msk, as_IBAT0L & `BATL_valid_msk}
                   : 256'h0;
   assign d_bats = WITH_BATS ? {as_DBAT3U & `BATU_valid_msk, as_DBAT3L & `BATL_valid_msk,
                                as_DBAT2U & `BATU_valid_msk, as_DBAT2L & `BATL_valid_msk,
                                as_DBAT1U & `BATU_valid_msk, as_DBAT1L & `BATL_valid_msk,
                                as_DBAT0U & `BATU_valid_msk, as_DBAT0L & `BATL_valid_msk}
                   : 256'h0;

   assign sdr1 = WITH_MMU ? as_SDR1 & `SDR1_valid_msk : 32'h0;


   /////////////////////////////////////////////////////////////////////////////
   /* Full SPR register file holds all SPRs except LR, DSISR, SRR1.
    * "Special SPR" file is for LR, DSISR, SRR1.
    *
    * This is done as two, because in some circumstances we want to write 2 SPRs
    * in a cycle, and we don't need a 2-write-port RF in the general case.
    */
   always @(*) begin
      /* Port A only ever reads LR & SRR1: */
      case (read_a_name)
	`DE_spr_LR:
	  spr_a = as_LR;

	`DE_spr_SRR1:
	  spr_a = as_SRR1;

	default: begin
	   spr_a = 0;
	end
      endcase

      /* Port C is general SPR-reading port.
       *
       * FIXME: mfspr LR is the *only* case where LR is read through C -- and
       * this could be removed to make this mux a bit smaller.  Same for mfspr SRR1!
       */
      casez (read_c_name)
	`DE_spr_LR:
	  spr_c = as_LR;  /* FIXME: Remove me. */

	`DE_spr_CTR:
	  spr_c = as_CTR;

	`DE_spr_SPRG0:
	  spr_c = as_SPRG0;
	`DE_spr_SPRG1:
	  spr_c = as_SPRG1;
	`DE_spr_SPRG2:
	  spr_c = as_SPRG2;
	`DE_spr_SPRG3:
	  spr_c = as_SPRG3;

	`DE_spr_SRR0:
	  spr_c = as_SRR0;
	`DE_spr_SRR1:
	  spr_c = as_SRR1; /* And me. */

	`DE_spr_PVR:
	  spr_c = `MR_PVR; /* Read-only */

	`DE_spr_SDR1:
	  spr_c = WITH_MMU ? as_SDR1 & `SDR1_valid_msk : 32'h0;
	`DE_spr_DAR:
	  spr_c = as_DAR;
	`DE_spr_DSISR:
	  spr_c = as_DSISR;

	`DE_spr_DABR:
	  spr_c = as_DABR;

	`DE_spr_DEC:
	  spr_c = as_DEC;

	`DE_spr_TBL:
	  spr_c = as_TB[31:0];

	`DE_spr_TBU:
	  spr_c = as_TB[63:32];

        `DE_spr_DEBUG:
          spr_c = `REG_ONES; /* In future, some kind of getchr? */

        `DE_spr_IBAT((0+0)):
          spr_c = WITH_BATS ? as_IBAT0U & `BATU_valid_msk : 32'h0;
        `DE_spr_IBAT((0+1)):
          spr_c = WITH_BATS ? as_IBAT0L & `BATL_valid_msk : 32'h0;
        `DE_spr_IBAT((2+0)):
          spr_c = WITH_BATS ? as_IBAT1U & `BATU_valid_msk : 32'h0;
        `DE_spr_IBAT((2+1)):
          spr_c = WITH_BATS ? as_IBAT1L & `BATL_valid_msk : 32'h0;
        `DE_spr_IBAT((4+0)):
          spr_c = WITH_BATS ? as_IBAT2U & `BATU_valid_msk : 32'h0;
        `DE_spr_IBAT((4+1)):
          spr_c = WITH_BATS ? as_IBAT2L & `BATL_valid_msk : 32'h0;
        `DE_spr_IBAT((6+0)):
          spr_c = WITH_BATS ? as_IBAT3U & `BATU_valid_msk : 32'h0;
        `DE_spr_IBAT((6+1)):
          spr_c = WITH_BATS ? as_IBAT3L & `BATL_valid_msk : 32'h0;

        `DE_spr_DBAT((0+0)):
          spr_c = WITH_BATS ? as_DBAT0U & `BATU_valid_msk : 32'h0;
        `DE_spr_DBAT((0+1)):
          spr_c = WITH_BATS ? as_DBAT0L & `BATL_valid_msk : 32'h0;
        `DE_spr_DBAT((2+0)):
          spr_c = WITH_BATS ? as_DBAT1U & `BATU_valid_msk : 32'h0;
        `DE_spr_DBAT((2+1)):
          spr_c = WITH_BATS ? as_DBAT1L & `BATL_valid_msk : 32'h0;
        `DE_spr_DBAT((4+0)):
          spr_c = WITH_BATS ? as_DBAT2U & `BATU_valid_msk : 32'h0;
        `DE_spr_DBAT((4+1)):
          spr_c = WITH_BATS ? as_DBAT2L & `BATL_valid_msk : 32'h0;
        `DE_spr_DBAT((6+0)):
          spr_c = WITH_BATS ? as_DBAT3U & `BATU_valid_msk : 32'h0;
        `DE_spr_DBAT((6+1)):
          spr_c = WITH_BATS ? as_DBAT3L & `BATL_valid_msk : 32'h0;

	default:
	  spr_c = {`REGSZ{1'b0}};
      endcase
   end


   /////////////////////////////////////////////////////////////////////////////
   // SPR write ports

   always @(posedge clk) begin
      /* Register writeback:
       */
      if (wr_spr_en) begin
	 // Never LR, SRR1 or DSISR.  Assert me.
	 casez (wr_spr_name)
	   /* Writes to DE_spr_TBU, DE_spr_TBL and DE_spr_DEC are dealt with
	    * in the TB/DEC logic below.
	    */

	   /* No DE_spr_LR here */

	   `DE_spr_CTR:
	     as_CTR <= wr_spr_value;

	   `DE_spr_SPRG0:
	     as_SPRG0 <= wr_spr_value;
	   `DE_spr_SPRG1:
	     as_SPRG1 <= wr_spr_value;
	   `DE_spr_SPRG2:
	     as_SPRG2 <= wr_spr_value;
	   `DE_spr_SPRG3:
	     as_SPRG3 <= wr_spr_value;

	   `DE_spr_SRR0:
	     as_SRR0 <= wr_spr_value;
	   /* No DE_spr_SRR1 here */

	   `DE_spr_SDR1:
	     if (WITH_MMU) 		as_SDR1 <= wr_spr_value & `SDR1_valid_msk;
	   `DE_spr_DAR:
	     as_DAR <= wr_spr_value;
	   /* No DE_spr_DSISR here */

	   `DE_spr_DABR:
	     as_DABR <= wr_spr_value;

	   /* Writes to DE_spr_DEC, DE_spr_TBL and DE_spr_TBU are dealt with below. */
	   `DE_spr_DEC: begin end
	   `DE_spr_TBL: begin end
	   `DE_spr_TBU: begin end

           `DE_spr_IBAT((0+0)):
             if (WITH_BATS) 		as_IBAT0U <= wr_spr_value & `BATU_valid_msk;
           `DE_spr_IBAT((0+1)):
             if (WITH_BATS) 		as_IBAT0L <= wr_spr_value & `BATL_valid_msk;
           `DE_spr_IBAT((2+0)):
             if (WITH_BATS) 		as_IBAT1U <= wr_spr_value & `BATU_valid_msk;
           `DE_spr_IBAT((2+1)):
             if (WITH_BATS)  		as_IBAT1L <= wr_spr_value & `BATL_valid_msk;
           `DE_spr_IBAT((4+0)):
             if (WITH_BATS)  		as_IBAT2U <= wr_spr_value & `BATU_valid_msk;
           `DE_spr_IBAT((4+1)):
             if (WITH_BATS)  		as_IBAT2L <= wr_spr_value & `BATL_valid_msk;
           `DE_spr_IBAT((6+0)):
             if (WITH_BATS)		as_IBAT3U <= wr_spr_value & `BATU_valid_msk;
           `DE_spr_IBAT((6+1)):
             if (WITH_BATS)		as_IBAT3L <= wr_spr_value & `BATL_valid_msk;

           `DE_spr_DBAT((0+0)):
             if (WITH_BATS)		as_DBAT0U <= wr_spr_value & `BATU_valid_msk;
           `DE_spr_DBAT((0+1)):
             if (WITH_BATS)		as_DBAT0L <= wr_spr_value & `BATL_valid_msk;
           `DE_spr_DBAT((2+0)):
             if (WITH_BATS)		as_DBAT1U <= wr_spr_value & `BATU_valid_msk;
           `DE_spr_DBAT((2+1)):
             if (WITH_BATS)		as_DBAT1L <= wr_spr_value & `BATL_valid_msk;
           `DE_spr_DBAT((4+0)):
             if (WITH_BATS)		as_DBAT2U <= wr_spr_value & `BATU_valid_msk;
           `DE_spr_DBAT((4+1)):
             if (WITH_BATS)		as_DBAT2L <= wr_spr_value & `BATL_valid_msk;
           `DE_spr_DBAT((6+0)):
             if (WITH_BATS)		as_DBAT3U <= wr_spr_value & `BATU_valid_msk;
           `DE_spr_DBAT((6+1)):
             if (WITH_BATS)		as_DBAT3L <= wr_spr_value & `BATL_valid_msk;

	   `DE_spr_DEBUG: begin end /* Dealt with externally */
`ifdef SIM
	   default:
	     $fatal(1, "DE: Attempt to write spr%d", wr_spr_name);
`endif
	 endcase
      end

      if (wr_sspr_en) begin
	 // Only LR, SRR1 or DSISR.
	 case (wr_sspr_name)
	   `DE_spr_LR:
	     as_LR <= wr_sspr_value;

	   `DE_spr_SRR1:
	     as_SRR1 <= wr_sspr_value;

	   `DE_spr_DSISR:
	     as_DSISR <= wr_sspr_value;
`ifdef SIM
	   default:
	     $fatal(1, "DE: Attempt to write sspr%d", wr_sspr_name);
`endif
	 endcase
      end
   end // always @ (posedge clk)

   assign debug_written = (wr_spr_en && wr_spr_name == `DE_spr_DEBUG);


endmodule // decode_sprf
