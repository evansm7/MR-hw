/* datafmt3264
 *
 * Format 32bit write data into a 64-bit value (for cache access).
 * Given data, address and size, generate big-endian data and write strobes.
 *
 * ME 12/4/20
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


module datafmt3264(input wire [31:0]  in_data,
		   input wire [1:0]   size, // 00=8b, 01=16b, 10=32b
		   input wire [2:0]   address,
		   output wire [7:0]  out_bwe,
		   output wire [63:0] out_data
		   );

   /* Format read/write data:
    *
    * Generate byte write strobes
    * Generate BIG ENDIAN ordering given the size
    */
   reg [63:0] data; // Wire
   reg [7:0]  bws; // Wire

   // Format write data:
   always @(*) begin
      case (size)
        2'b00: begin // 8
           case (address[2:0])
             3'b000: begin
                data = {56'h00000000000000, in_data[7:0]};
                bws = 8'b00000001;
             end
             3'b001: begin
                data = {48'h000000000000, in_data[7:0], 8'h00};
                bws = 8'b00000010;
             end
             3'b010: begin
                data = {40'h0000000000, in_data[7:0], 16'h0000};
                bws = 8'b00000100;
             end
             3'b011: begin
                data = {32'h00000000, in_data[7:0], 24'h000000};
                bws = 8'b00001000;
             end
             3'b100: begin
                data = {24'h000000, in_data[7:0], 32'h00000000};
                bws = 8'b00010000;
             end
             3'b101: begin
                data = {16'h0000, in_data[7:0], 40'h0000000000};
                bws = 8'b00100000;
             end
             3'b110: begin
                data = {8'h00, in_data[7:0], 48'h000000000000};
                bws = 8'b01000000;
             end
             3'b111: begin
                data = {in_data[7:0], 56'h00000000000000};
                bws = 8'b10000000;
             end
             default: begin
                data = 64'h0;
                bws = 8'h00;
             end
           endcase
        end

        2'b01: begin // 16
           case (address[2:0])
             3'b000: begin
                data = {48'h000000000000, in_data[7:0], in_data[15:8]};
                bws = 8'b00000011;
             end
             3'b001: begin
                data = {40'h0000000000, in_data[7:0], in_data[15:8], 8'h00};
                bws = 8'b00000110;
             end
             3'b010: begin
                data = {32'h00000000, in_data[7:0], in_data[15:8], 16'h0000};
                bws = 8'b00001100;
             end
             3'b011: begin
                data = {24'h000000, in_data[7:0], in_data[15:8], 24'h000000};
                bws = 8'b00011000;
             end
             3'b100: begin
                data = {16'h0000, in_data[7:0], in_data[15:8], 32'h00000000};
                bws = 8'b00110000;
             end
             3'b101: begin
                data = {8'h00, in_data[7:0], in_data[15:8], 40'h0000000000};
                bws = 8'b01100000;
             end
             3'b110: begin
                data = {in_data[7:0], in_data[15:8], 48'h000000000000};
                bws = 8'b11000000;
             end
             default: begin
                data = 64'h0;
                bws = 8'h00;
             end
           endcase
        end

        2'b10: begin // 32
           case (address[2:0])
             3'b000: begin
                data = {32'h00000000, in_data[7:0], in_data[15:8], in_data[23:16], in_data[31:24]};
                bws = 8'b00001111;
             end
             3'b001: begin
                data = {24'h000000, in_data[7:0], in_data[15:8], in_data[23:16], in_data[31:24], 8'h00};
                bws = 8'b00011110;
             end
             3'b010: begin
                data = {16'h0000, in_data[7:0], in_data[15:8], in_data[23:16], in_data[31:24], 16'h0000};
                bws = 8'b00111100;
             end
             3'b011: begin
                data = {8'h00, in_data[7:0], in_data[15:8], in_data[23:16], in_data[31:24], 24'h000000};
                bws = 8'b01111000;
             end
             3'b100: begin
                data = {in_data[7:0], in_data[15:8], in_data[23:16], in_data[31:24], 32'h00000000};
                bws = 8'b11110000;
             end
             default: begin
                data = 64'h0;
                bws = 8'h00;
             end
           endcase
        end

        default: begin
           data = 64'h0;
           bws = 8'h00;
	end
      endcase
   end

   assign out_data = data;
   assign out_bwe = bws;

endmodule
