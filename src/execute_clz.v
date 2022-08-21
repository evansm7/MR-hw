/* execute_clz
 *
 * Combinatorially count 32-bit zeroes top-down, outputting a
 * 6-bit value 0-32
 *
 * ME 24/3/20
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


module execute_clz(input wire [31:0] in,
                   output wire [5:0] count
                   );

   // Approach:  cascade 4 8-bit clz8 blocks
   // and generate a priority decode from all of them?

   wire [3:0]                        a;
   wire [3:0]                        b;
   wire [3:0]                        c;
   wire [3:0]                        d;

   reg [5:0]                         num; // Wire

   clz8 CLZA(.in(in[31:24]), .count(a));
   clz8 CLZB(.in(in[23:16]), .count(b));
   clz8 CLZC(.in(in[15:8]), .count(c));
   clz8 CLZD(.in(in[7:0]), .count(d));

   always @(*) begin
      if (a == 8) begin
         // 00xxxxxx
         if (b == 8) begin
            // 0000xxxx
            if (c == 8) begin
               // 000000xx
               if (d == 8) begin
                  num = 6'b10_0000; // 32
               end else begin
                  num = {3'b011, d[2:0]}; // 24..31
               end
            end else begin
               num = {3'b010, c[2:0]}; // 16..23
            end
         end else begin
            num = {3'b001, b[2:0]}; // 8..15
         end
      end else begin
         num = {3'b000, a[2:0]}; // 0..7
      end
   end

   assign count = num;
endmodule

module clz8(input wire [7:0]  in,
            output wire [3:0] count);

   reg [3:0]                  num;

   always @(*) begin
      casez (in)
        8'b1???????: num = 0;
        8'b01??????: num = 1;
        8'b001?????: num = 2;
        8'b0001????: num = 3;
        8'b00001???: num = 4;
        8'b000001??: num = 5;
        8'b0000001?: num = 6;
        8'b00000001: num = 7;
        default:  // 8'b00000000
          num = 8;
      endcase
   end

   assign count = num;
endmodule
