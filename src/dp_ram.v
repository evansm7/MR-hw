/* dp_ram
 *
 * Dual-ported RAM (synch reads and writes), compatible with being inferred to BRAM
 *
 * BRAM is desired to be in "no-change" mode:  addr conflicts are not expected
 * so this shouldn't matter, and it appears this will be faster than read-first.
 * But, see below...
 *
 * ME 12/4/20
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


module dp_ram(input wire                          clk,
	      input wire 			  reset,

	      input wire [L2SIZE-L2WIDTH-1:0] 	  a_addr,
	      input wire [(1 << (L2WIDTH+3))-1:0] a_wr_data,
	      output reg [(1 << (L2WIDTH+3))-1:0] a_rd_data,
	      input wire 			  a_enable,
	      input wire 			  a_WE,
	      input wire [(1 << L2WIDTH)-1:0] 	  a_BWE,

	      input wire [L2SIZE-L2WIDTH-1:0] 	  b_addr,
	      input wire [(1 << (L2WIDTH+3))-1:0] b_wr_data,
	      output reg [(1 << (L2WIDTH+3))-1:0] b_rd_data,
	      input wire 			  b_enable,
	      input wire 			  b_WE,
	      input wire [(1 << L2WIDTH)-1:0] 	  b_BWE
	      );

   parameter L2WIDTH = 2; // Log2 of width in bytes
   parameter L2SIZE = 12; // Log2 of size in in bytes

   reg [(1 << (L2WIDTH+3))-1:0]				  memory[(1 << (L2SIZE-L2WIDTH))-1:0];

`ifndef BUILD_ECP5
   genvar 						  i;

   // NO-CHANGE mode idiom as recommended by Vivado guide ug901 is:
   // generate per-byte if(enable) and if(BWE[i]) mem[addr][byte] <= wr[byte]
   // if (~|BWE) rd <= mem[addr]
   //
   // However, I've spent AGES looking for an idiom that synthesises in both old
   // and new tools.  (Muchos silent failures, e.g. unwritable RAM, in XST!)
   //
   // The following appears to generate read_first RAMs, but at least works in
   // both (which is more valuable).

   generate // Port A
      for (i = 0; i < (1 << L2WIDTH); i = i+1) begin : porta
         always @ (posedge clk) begin
            if(a_enable) begin
               if (a_WE && a_BWE[i]) begin
                  // [i*8 +: 8] syntax not supported by Verilator?
                  memory[a_addr][(i*8)+7:(i*8)] <= a_wr_data[(i*8)+7:(i*8)];
               end
               a_rd_data[(i*8)+7:(i*8)] <= memory[a_addr][(i*8)+7:(i*8)];
            end
         end
      end
   endgenerate

   generate // Port B
      for (i = 0; i < (1 << L2WIDTH); i = i+1) begin : portb
         always @ (posedge clk) begin
            if(b_enable) begin
               if(b_WE && b_BWE[i]) begin
                  memory[b_addr][(i*8)+7:(i*8)] <= b_wr_data[(i*8)+7:(i*8)];
               end
               b_rd_data[(i*8)+7:(i*8)] <= memory[b_addr][(i*8)+7:(i*8)];
            end
         end
      end
   endgenerate

`else
   /* ECP5:
    *
    * Yosys doesn't pick up on that DP RAM idiom.  Wasted a bunch of time trying
    * different variants: for now, just explicitly instantiate DP16KDs.
    */

   /* GAHHHH yosys evaluates these parameters upon reading the file, not in the
    * context of an instantiation! ;(
    */
   if (L2WIDTH != 3 || L2SIZE != 14) begin
      // FIXME: $error($sformatf("Unknown dimensions %d x %d", L2WIDTH, L2SIZE));
   end

   wire [63:0] doa[1:0];
   wire [63:0] dob[1:0];

   /* Generate a matrix of 8 2KB RAMs, i.e. 64 bits by 2KB.
    * Specifically for 16KB could also use 8x 8b-wide 2KB RAMs ...
    * But evaluate this generate stuff for use in BRAMs elsewhere.
    */
   genvar      hw, bank;
   generate

      for (bank = 0; bank < 2; bank = bank+1) begin : bank
         wire [63:0] doa_bank;
         wire [63:0] dob_bank;

         wire        a_bank_selected = (a_addr[10] == bank);
         wire        b_bank_selected = (b_addr[10] == bank);

         for (hw = 0; hw < 4; hw = hw+1) begin : halfword

            wire [15:0] awd;
            wire [15:0] bwd;

            assign awd = a_wr_data[(hw*16)+15:(hw*16)];
            assign bwd = b_wr_data[(hw*16)+15:(hw*16)];

            wire [17:0] ard;
            wire [17:0] brd;

            DP16KD #(
                     .INIT_DATA("STATIC"),
                     .ASYNC_RESET_RELEASE("SYNC"),
                     .GSR("ENABLED"),
                     .CSDECODE_A("0b001"), // active low, 1 means active-high
                     .CSDECODE_B("0b001"),
                     .WRITEMODE_A("NORMAL"),
                     .WRITEMODE_B("NORMAL"),
                     .RESETMODE("ASYNC"),
                     .REGMODE_A("NOREG"),
                     .REGMODE_B("NOREG"),
                     .DATA_WIDTH_A(18),
                     .DATA_WIDTH_B(18)
                     ) BRAM (
                             /* Port A */
                             .CLKA(clk),
                             .CEA(a_enable),
                             .OCEA(1'b1),
                             .RSTA(reset),
                             .WEA(a_WE),
                             .CSA2(1'b0), .CSA1(1'b0), .CSA0(a_bank_selected),
                             /* Address */
                             .ADA13(a_addr[9]), .ADA12(a_addr[8]), .ADA11(a_addr[7]), .ADA10(a_addr[6]), .ADA9(a_addr[5]),
                             .ADA8(a_addr[4]), .ADA7(a_addr[3]), .ADA6(a_addr[2]), .ADA5(a_addr[1]), .ADA4(a_addr[0]),
                             /* Byte write strobes */
                             .ADA3(1'b0), .ADA2(1'b0), .ADA1(a_BWE[1]), .ADA0(a_BWE[0]),

                             /* Data in */
                             .DIA17(1'b0), .DIA16(awd[15]), .DIA15(awd[14]), .DIA14(awd[13]), .DIA13(awd[12]), .DIA12(awd[11]), .DIA11(awd[10]), .DIA10(awd[9]), .DIA9(awd[8]),
                             .DIA8(1'b0), .DIA7(awd[7]), .DIA6(awd[6]), .DIA5(awd[5]), .DIA4(awd[4]),.DIA3(awd[3]), .DIA2(awd[2]), .DIA1(awd[1]), .DIA0(awd[0]),

                             /* Data out */
                             .DOA17(ard[17]), .DOA16(ard[16]), .DOA15(ard[15]), .DOA14(ard[14]), .DOA13(ard[13]), .DOA12(ard[12]), .DOA11(ard[11]), .DOA10(ard[10]), .DOA9(ard[9]),
                             .DOA8(ard[8]), .DOA7(ard[7]), .DOA6(ard[6]), .DOA5(ard[5]), .DOA4(ard[4]), .DOA3(ard[3]), .DOA2(ard[2]), .DOA1(ard[1]), .DOA0(ard[0]),

                             /* Port B */
                             .CLKB(clk),
                             .CEB(b_enable),
                             .OCEB(1'b1),
                             .RSTB(reset),
                             .WEB(b_WE),
                             .CSA2(1'b0), .CSA1(1'b0), .CSA0(b_bank_selected),
                             /* Address */
                             .ADA13(b_addr[9]), .ADA12(b_addr[8]), .ADA11(b_addr[7]), .ADA10(b_addr[6]), .ADA9(b_addr[5]),
                             .ADA8(b_addr[4]), .ADA7(b_addr[3]), .ADA6(b_addr[2]), .ADA5(b_addr[1]), .ADA4(b_addr[0]),
                             /* Byte write strobes */
                             .ADA3(1'b0), .ADA2(1'b0), .ADA1(b_BWE[1]), .ADA0(b_BWE[0]),

                             /* Data in */
                             .DIA17(1'b0), .DIA16(bwd[15]), .DIA15(bwd[14]), .DIA14(bwd[13]), .DIA13(bwd[12]), .DIA12(bwd[11]), .DIA11(bwd[10]), .DIA10(bwd[9]), .DIA9(bwd[8]),
                             .DIA8(1'b0), .DIA7(bwd[7]), .DIA6(bwd[6]), .DIA5(bwd[5]), .DIA4(bwd[4]),.DIA3(bwd[3]), .DIA2(bwd[2]), .DIA1(bwd[1]), .DIA0(bwd[0]),

                             /* Data out */
                             .DOA17(brd[17]), .DOA16(brd[16]), .DOA15(brd[15]), .DOA14(brd[14]), .DOA13(brd[13]), .DOA12(brd[12]), .DOA11(brd[11]), .DOA10(brd[10]), .DOA9(brd[9]),
                             .DOA8(brd[8]), .DOA7(brd[7]), .DOA6(brd[6]), .DOA5(brd[5]), .DOA4(brd[4]), .DOA3(brd[3]), .DOA2(brd[2]), .DOA1(brd[1]), .DOA0(brd[0])
                             );

            assign doa_bank[(hw*16)+15:(hw*16)] = ard[15:0];
            assign dob_bank[(hw*16)+15:(hw*16)] = brd[15:0];
         end // block: halfword

         assign doa[bank] = doa_bank;
         assign dob[bank] = dob_bank;
      end
   endgenerate

   reg                  last_bank_a;
   reg                  last_bank_b;
   /* Mux between bank read data */
   always @(posedge clk) begin
      if (a_enable)
        last_bank_a 	<= a_addr[10];
      if (b_enable)
        last_bank_b 	<= b_addr[10];
   end

   always @(*) begin
      a_rd_data = doa[last_bank_a];
      b_rd_data = dob[last_bank_b];
   end

`endif // !`ifndef BUILD_ECP5

endmodule
