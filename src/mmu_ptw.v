/* mmu_ptw
 *
 * Page table walker for MMU:  this component receives requests from
 * two channels (from IMMU/DMMU) and performs page table accesses given
 * via a simple read channel to D$.
 *
 * The segment registers are fed in, and the response is an end-to-end
 * EA-to-PA TLB entry (i.e. containing SR info).  The ITLB/DTLBs are
 * therefore invalidated when SRs change.  This is done to keep munging
 * of SR information out of the critical lookup path.
 *
 * It would be good to have a central large TLB in here too, though
 * since the PTEs are cacheable it may be easier to rely on D$ for this.
 *
 * Matt Evans, 14 Dec 2020
 *
 * FIXME:
 * This does not currently RmW PTEs to set C/D bits!  (The channel to
 * D$ would need to support locking, writes, etc.)
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

module mmu_ptw(input wire                      clk,
               input wire                      reset,

               input wire [(32*16)-1:0]        SRs,
               /* Not all bits of SDR1 are used, but 32b for clarity: */
               input wire [31:0]               SDR1,

               /* Inputs from MMU/PTW unit which needs read access to DC: */
               output reg                      walk_req,
               output wire [`REGSZ-1:0]        walk_addr,
               /* NOTE: ack means walk_data will be valid next cycle, not
                * *is currently valid*.
                */
               input wire                      walk_ack,
               input wire [63:0]               walk_data,

               /* PTW interfaces from MMUs: */
               input wire [`REGSZ-1:0]         i_ptw_addr,
               input wire                      i_ptw_req,
               output wire [`PTW_PTE_SIZE-1:0] i_ptw_tlbe,
               output wire [1:0]               i_ptw_fault,
               output wire                     i_ptw_ack,

               input wire [`REGSZ-1:0]         d_ptw_addr,
               input wire                      d_ptw_req,
               output wire [`PTW_PTE_SIZE-1:0] d_ptw_tlbe,
               output wire [1:0]               d_ptw_fault,
               output wire                     d_ptw_ack
               );


   // Base address of Page Table:
   wire [8:0]                                  htabmask = SDR1[8:0];
   wire [31:0]                                 htab_base = { SDR1[31:16], 16'h0 };

   // FIXME latch the request!
   reg [31:0]                                  req_addr;

   reg [31:0]                                  segment_reg;

   wire                                        sr_T = segment_reg[31];
   wire                                        sr_Ks = segment_reg[30];
   wire                                        sr_Kp = segment_reg[29];
   wire                                        sr_N = segment_reg[28];
   wire [23:0]                                 vsid = segment_reg[23:0];

   wire [15:0]                                 page_index = req_addr[27:12];
   wire [5:0]                                  api = page_index[15:10];

   wire [18:0]                                 hash_fn_p = vsid[18:0] ^ {3'h0, page_index};
   wire [18:0]                                 hash_fn_s = ~hash_fn_p;
   wire [31:0]                                 pteg_addr_p = htab_base |
                                               { 7'h0, htabmask & hash_fn_p[18:10], hash_fn_p[9:0], 6'h0 };
   wire [31:0]                                 pteg_addr_s = htab_base |
                                               { 7'h0, htabmask & hash_fn_p[18:10], hash_fn_s[9:0], 6'h0 };

   // Resulting pte details
   wire [`PTW_PTE_PPN_SZ-1:0]                  pte_ppn;
   wire [`PTW_PTE_PP_SZ-1:0]                   pte_pp;
   wire                                        pte_ks;
   wire                                        pte_kp;
   wire                                        pte_cacheable;


   reg [2:0]                                   state;
`define PTW_STATE_IDLE          0
`define PTW_STATE_RD            1
`define PTW_STATE_DATA          2
`define PTW_STATE_CMP           3
`define PTW_STATE_WAIT_CONSUME  4

   reg                                         requester; // 0 = I, 1 = D
   reg [3:0]                                   pte_idx; // >8 = secondary
   reg                                         h_bit;
   reg [63:0]                                  pte;
   reg [1:0]                                   fault;

   // Perf FIXME: set up each time an access is set up (from idx)
   assign       walk_addr = (pte_idx[3] == 0) ? (pteg_addr_p | {26'h0, pte_idx[2:0], 3'h0}) :
                            (pteg_addr_s | {26'h0, pte_idx[2:0], 3'h0});

   always @(posedge clk) begin
      case (state)
        `PTW_STATE_IDLE: begin
           if (i_ptw_req || d_ptw_req) begin
              requester       <= i_ptw_req ? 0 : 1;
              req_addr        <= i_ptw_req ? i_ptw_addr : d_ptw_addr;
              pte_idx         <= 0;

              walk_req        <= 1;
              state           <= `PTW_STATE_RD;

              // FIXME debug add request

              // FIXME check for SR.N && instruction PTW -> NX fault
              // FIXME TF if T=1

              case (i_ptw_req ? i_ptw_addr[31:28] : d_ptw_addr[31:28])
                0:
                  segment_reg <= SRs[(32*0)+31:(32*0)];
                1:
                  segment_reg <= SRs[(32*1)+31:(32*1)];
                2:
                  segment_reg <= SRs[(32*2)+31:(32*2)];
                3:
                  segment_reg <= SRs[(32*3)+31:(32*3)];
                4:
                  segment_reg <= SRs[(32*4)+31:(32*4)];
                5:
                  segment_reg <= SRs[(32*5)+31:(32*5)];
                6:
                  segment_reg <= SRs[(32*6)+31:(32*6)];
                7:
                  segment_reg <= SRs[(32*7)+31:(32*7)];
                8:
                  segment_reg <= SRs[(32*8)+31:(32*8)];
                9:
                  segment_reg <= SRs[(32*9)+31:(32*9)];
                10:
                  segment_reg <= SRs[(32*10)+31:(32*10)];
                11:
                  segment_reg <= SRs[(32*11)+31:(32*11)];
                12:
                  segment_reg <= SRs[(32*12)+31:(32*12)];
                13:
                  segment_reg <= SRs[(32*13)+31:(32*13)];
                14:
                  segment_reg <= SRs[(32*14)+31:(32*14)];
                15:
                  segment_reg <= SRs[(32*15)+31:(32*15)];
              endcase
           end
        end

        `PTW_STATE_RD: begin
           // raise walk_req; wait for walk_resp which means next cycle has data (which we must capture)
           if (walk_ack) begin
              walk_req        <= 0;
              state           <= `PTW_STATE_DATA;
           end
        end

        `PTW_STATE_DATA: begin
           // Compare value here?  Have 1 CLK between D$ RAM and this FF, could use it to
           // compare & latch the PTE if matching.

	   // Endian-reverse as two 32b words:
           pte        <= { walk_data[39:32], walk_data[47:40], walk_data[55:48], walk_data[63:56],
			   walk_data[7:0], walk_data[15:8], walk_data[23:16], walk_data[31:24] };
           h_bit      <= pte_idx[3]; // 0=Primary search, 1=Secondary search
           state      <= `PTW_STATE_CMP;
           pte_idx    <= pte_idx + 1; // Could do this in RD
        end

        `PTW_STATE_CMP: begin
           if (pte[31] /* Valid */ &&
               pte[6] == h_bit /* H == pri/sec? */ &&
               pte[30:7] == vsid &&
               pte[5:0] == api) begin
              // This PTE matches!

              // FIXME R,C update
              // FIXME: PTW_STATE_PF! I.e. valid entry but inaccessible
              // Munge permissions?

              fault   <= `PTW_FAULT_NONE;
              state   <= `PTW_STATE_WAIT_CONSUME;

           end else begin // if (pte[31]...
              // Nup, look for another one, unless pte_idx has wrapped.
              if (pte_idx == 0) begin
                 state        <= `PTW_STATE_WAIT_CONSUME;
                 fault        <= `PTW_FAULT_TF;

              end else begin
                 walk_req     <= 1;
                 state        <= `PTW_STATE_RD;
              end
           end

           // FIXME debug
        end

        `PTW_STATE_WAIT_CONSUME: begin
           // Could wait for Req to go low, but PTW protocol dictates acceptance same cycle!
           // The relevant ack is asserted in this state.
           state   <= `PTW_STATE_IDLE;
        end

      endcase

      if (reset) begin
         walk_req        <= 0;
         state           <= `PTW_STATE_IDLE;
      end
   end


   assign pte_ppn = pte[63:44];
   assign pte_pp = pte[33:32];
   assign pte_ks = sr_Ks;
   assign pte_kp = sr_Kp;
   // R is 40, C is 39

   // Cacheable if not writethrough, not inhibited and not guarded; coherent is ignored:
   assign pte_cacheable = (pte[38:37] == 2'b00) &&
			  (pte[35] == 1'b0);

   assign d_ptw_tlbe = {pte_cacheable, pte_kp, pte_ks, pte_pp, pte_ppn};
   assign i_ptw_tlbe = d_ptw_tlbe;
   assign d_ptw_fault = fault;
   assign i_ptw_fault = fault;

   assign d_ptw_ack =  requester && (state == `PTW_STATE_WAIT_CONSUME);
   assign i_ptw_ack = !requester && (state == `PTW_STATE_WAIT_CONSUME);

endmodule // mmu_ptw
