/* datafmt6432
 *
 * Format 32-bit data from a 64-bit word, given address/size, for cache
 * read access.
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


module datafmt6432(input wire [63:0]  in_data,
		   input wire [1:0]   size,
		   input wire [2:0]   address,
		   output wire [31:0] out_data
		   );


   reg [31:0] data /*verilator public*/; // Wire

   // Format read data:
   always @(*) begin
      case (size)
        2'b00: begin // 8
           case (address[2:0])
             3'b000:
               data = {24'h000000, in_data[7:0]};
             3'b001:
               data = {24'h000000, in_data[15:8]};
             3'b010:
               data = {24'h000000, in_data[23:16]};
             3'b011:
               data = {24'h000000, in_data[31:24]};
             3'b100:
               data = {24'h000000, in_data[39:32]};
             3'b101:
               data = {24'h000000, in_data[47:40]};
             3'b110:
               data = {24'h000000, in_data[55:48]};
             3'b111:
               data = {24'h000000, in_data[63:56]};
             default:
               data = 32'h0;
           endcase
        end

        2'b01: begin // 16
           case (address[2:0])
             3'b000:
               data = {16'h0000, in_data[7:0], in_data[15:8]};
             3'b001:
               data = {16'h0000, in_data[15:8], in_data[23:16]};
             3'b010:
               data = {16'h0000, in_data[23:16], in_data[31:24]};
             3'b011:
               data = {16'h0000, in_data[31:24], in_data[39:32]};
             3'b100:
               data = {16'h0000, in_data[39:32], in_data[47:40]};
             3'b101:
               data = {16'h0000, in_data[47:40], in_data[55:48]};
             3'b110:
               data = {16'h0000, in_data[55:48], in_data[63:56]};
             default:
               data = 32'h0;
           endcase
        end

        2'b10: begin // 32
           case (address[2:0])
             3'b000:
               data = {in_data[7:0], in_data[15:8], in_data[23:16], in_data[31:24]};
             3'b001:
               data = {in_data[15:8], in_data[23:16], in_data[31:24], in_data[39:32]};
             3'b010:
               data = {in_data[23:16], in_data[31:24], in_data[39:32], in_data[47:40]};
             3'b011:
               data = {in_data[31:24], in_data[39:32], in_data[47:40], in_data[55:48]};
             3'b100:
               data = {in_data[39:32], in_data[47:40], in_data[55:48], in_data[63:56]};
             default:
               data = 32'h0;
           endcase
        end

           default:
             data = 32'h0;
        endcase
   end

   assign out_data = data;

endmodule
