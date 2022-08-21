/*
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

`timescale 1ns/1ns

`include "decode_signals.vh"
`include "decode_enums.vh"

`define MEMSIZEL2       20 // 1MB

module tb_mr_cpu_top(input wire clk,
		     input wire reset);

   wire [15:0]          random;

   // Memory storage & simple IO for external memory interface.
   // Make this much bigger than the cache, to demonstrate it properly.
   // Also, implements random stalls!

   reg [63:0]           memory [(1 << (`MEMSIZEL2 - 3))-1:0];

   /* There are two EMI interfaces accessing the same memory.
    * The first, for D, is full read-write.
    */
   wire [63:0]          emi_d_read_data;
   reg [63:0]           emi_d_mem_read_data;
   wire [63:0]          emi_d_write_data;
   wire                 emi_d_req; // Valid request or write data
   wire                 emi_d_valid;
   reg                  emi_d_valid_r;
   wire                 emi_d_rnw;
   wire [7:0]           emi_d_bws;
   wire [1:0]           emi_d_size; // Only interesting if it's 2'b11, i.e. CL (and bws ignored)
   wire [31:0]          emi_d_address;
   reg                  emi_d_first;
   reg [`MEMSIZEL2-1:3] emi_d_addr_r;
   wire [`MEMSIZEL2-1:3] ram_daddr = emi_d_first ? emi_d_address[`MEMSIZEL2-1:3] : emi_d_addr_r;
   wire                  memoryi_stall = random[7];
   wire                  memoryd_stall = random[3];

   assign emi_d_read_data = emi_d_mem_read_data;

   // The requester just gives the initial address and the beat count is
   // ignored thereafter.  This enables a pipelined read to stream data
   // in.  Otherwise the requester is waiting for the ack on data and
   // can't change address until that arrives, costing a cycle round trip.
   //
   always @(posedge clk) begin
      if (reset) begin
         emi_d_first <= 1;
         emi_d_addr_r <= 0;
         emi_d_valid_r <= 1;
      end else begin
         if (!memoryd_stall) begin
            if (emi_d_req) begin
               if (emi_d_first && emi_d_size == 2'b11) begin
                  // Burst has auto-incremented address
                  emi_d_addr_r <= emi_d_address[`MEMSIZEL2-1:3] + 1;
                  emi_d_first <= 0;

               end else begin
                  // For multiple beats, increment addr for next access.
                  emi_d_addr_r <= emi_d_addr_r + 1;
               end

               if (emi_d_rnw) begin
                  emi_d_mem_read_data <= memory[ram_daddr];
                  // Data valid is delayed 1 cycle, just like the data
                  // itself:
                  emi_d_valid_r <= 1;

               end else begin // Write
                  // Data write, with byte strobes:
                  if (emi_d_bws[0])
                    memory[ram_daddr][7:0] <= emi_d_write_data[7:0];
                  if (emi_d_bws[1])
                    memory[ram_daddr][15:8] <= emi_d_write_data[15:8];
                  if (emi_d_bws[2])
                    memory[ram_daddr][23:16] <= emi_d_write_data[23:16];
                  if (emi_d_bws[3])
                    memory[ram_daddr][31:24] <= emi_d_write_data[31:24];
                  if (emi_d_bws[4])
                    memory[ram_daddr][39:32] <= emi_d_write_data[39:32];
                  if (emi_d_bws[5])
                    memory[ram_daddr][47:40] <= emi_d_write_data[47:40];
                  if (emi_d_bws[6])
                    memory[ram_daddr][55:48] <= emi_d_write_data[55:48];
                  if (emi_d_bws[7])
                    memory[ram_daddr][63:56] <= emi_d_write_data[63:56];
                  // For writes, valid means previous edge captured the data
                  // This happens via req && !RnW && !stall below
               end
            end
         end else begin
            emi_d_valid_r <= 0;
         end

         if (!emi_d_req) begin
            // A cycle between requests is required
            // FIXME
            emi_d_first <= 1;
            emi_d_valid_r <= 0;
         end
      end // else: !if(reset)
   end
   assign emi_d_valid = emi_d_req && ((emi_d_rnw && emi_d_valid_r) ||
                                  (!emi_d_rnw && !memoryd_stall)) ;

   /* The second EMI interface, for I, is read-only. */
   wire [63:0]          emi_i_read_data;
   reg [63:0]           emi_i_mem_read_data;
   wire                 emi_i_req; // Valid request or write data
   wire                 emi_i_valid;
   reg                  emi_i_valid_r;
   wire [1:0]           emi_i_size; // Only interesting if it's 2'b11, i.e. CL (and bws ignored)
   wire [31:0]          emi_i_address;
   reg                  emi_i_first;
   reg [`MEMSIZEL2-1:3] emi_i_addr_r;
   wire [`MEMSIZEL2-1:3] ram_iaddr = emi_i_first ? emi_i_address[`MEMSIZEL2-1:3] : emi_i_addr_r;

   assign emi_i_read_data = emi_i_mem_read_data;

   // The requester just gives the initial address and the beat count is
   // ignored thereafter.  This enables a pipelined read to stream data
   // in.  Otherwise the requester is waiting for the ack on data and
   // can't change address until that arrives, costing a cycle round trip.
   //
   always @(posedge clk) begin
      if (reset) begin
         emi_i_first <= 1;
         emi_i_addr_r <= 0;
         emi_i_valid_r <= 1;
      end else begin
         if (!memoryi_stall) begin
            if (emi_i_req) begin
               if (emi_i_first && emi_i_size == 2'b11) begin
                  // A burst has an auto-incremented address
                  emi_i_addr_r <= emi_i_address[`MEMSIZEL2-1:3] + 1;
                  emi_i_first <= 0;

               end else begin
                  // For multiple beats, increment addr for next access.
                  emi_i_addr_r <= emi_i_addr_r + 1;
               end

               emi_i_mem_read_data <= memory[ram_iaddr];
               // Data valid is delayed 1 cycle, just like the data
               // itself:
               emi_i_valid_r <= 1;
            end
         end else begin
            emi_i_valid_r <= 0;
         end

         if (!emi_i_req) begin
            // A cycle between burst requests is required
            // FIXME: Should just count 4 :P
            emi_i_first <= 1;
            emi_i_valid_r <= 0;
         end
      end
   end
   assign emi_i_valid = emi_i_req && emi_i_valid_r;


   rng #(.S(16'hcafe)) RNG(.clk(clk),
                           .reset(reset),
                           .rng_o(random)
                           );


   ////////////////////////////////////////////////////////////////////////////////
   // DUT
   mr_cpu_top CPU(.clk(clk),
		  .reset(reset),

		  .IRQ(1'b0),

		  .i_emi_addr(emi_i_address),
		  .i_emi_size(emi_i_size),
		  .i_emi_req(emi_i_req),
		  .i_emi_rdata(emi_i_read_data),
		  .i_emi_valid(emi_i_valid),

                  .d_emi_addr(emi_d_address),
                  .d_emi_rdata(emi_d_read_data),
                  .d_emi_wdata(emi_d_write_data),
                  .d_emi_size(emi_d_size), // 1/2/4/CL
                  .d_emi_RnW(emi_d_rnw),
                  .d_emi_bws(emi_d_bws),
                  .d_emi_req(emi_d_req),
                  .d_emi_valid(emi_d_valid)
		  );

endmodule
