/* execute_rotatemask
 *
 * This module implements my nemeses, rlwimi and friends.
 *
 * These, and other shifts, are implemented using the following components in here:
 * - A left-rotator
 * - A mask generator
 * - An inserterizer (using the mask, insert another value)
 *
 * Shift right is (31-n) shift left plus a mask of upper bit (or sxt)
 *
 * These instructions are dealt with by this unit:
 *  rlwimi	Rotate RS by imm and insert into RA where mask bits 1
 *  rlwnm	Rotate RS by RB and AND with mask
 *  rlwinm      Rotate RS by imm and AND with mask
 *  slw		RS shifted left by RB
 *  srw		RS logically shifted right by RB
 *  srawi	RS arithmetically (SXT!) shifted right by immediate
 *  sraw	RS arithmetically shifted right by RB
 *
 * ME 24/3/20
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

/* Notes:
 * Make sxt by generating a mask of 0/1 depending on in[31],
 * with mask boundaries given by [31] to 31-shift_right_amount
 *
 * Need to do the limit cases, e.g. reg shift > 31 (zero? clamped?)
 */

`include "arch_defs.vh"
`include "decode_enums.vh"


module execute_rotatemask(input wire [5:0]         op,
                          input wire [`REGSZ-1:0]  in_val,
                          /* Second operand: either a value into which rlwimi
                           * inserts bits, or a register-based shift value: */
                          input wire [`REGSZ-1:0]  insertee_sh,
                          /* Third operand:  a combined MB/ME and SH amount for
                           * rlwimi, or MB/ME for rlm[i]nm (having shift in
                           * insertee_sh */
                          input wire [14:0]        SH_MB_ME,

                          output wire [`REGSZ-1:0] out,
                          output wire              co
                          );

   reg [4:0]                                       rol_amount; // Wire
   reg [4:0]                                       mask_start; // Wire
   reg [4:0]                                       mask_stop; // Wire
   reg [`REGSZ-1:0]                                res; // Wire
   reg                                             res_co; // Wire

   wire [31:0]                                     rotate_out;
   wire [31:0]                                     mask_out;

   /* Calculate shift amount */
   always @(*) begin
      case (op)
        `EXOP_SH_RLWIMI_ABC:    rol_amount = SH_MB_ME[14:10];
        `EXOP_SH_RLWNM_ABC:     rol_amount = insertee_sh[4:0];
        `EXOP_SH_SLW_AB:        rol_amount = insertee_sh[4:0];
        // I want a 5-bit result, and 32-0 truncating to 0 is desired:
        `EXOP_SH_SRAW_AB:       rol_amount = (32-insertee_sh[4:0]);
        `EXOP_SH_SRW_AB:        rol_amount = (32-insertee_sh[4:0]);
        default:
          rol_amount = 5'h0;
      endcase
   end

   /* Calculate mask positions: NOTE these are in normal-numbering
    * rather than stupid IBM order, so converted here.
    */
   always @(*) begin
      case (op)
        `EXOP_SH_RLWIMI_ABC: begin
           mask_start = (31-SH_MB_ME[10:5]); // MB
           mask_stop = (31-SH_MB_ME[4:0]); // ME
        end

        `EXOP_SH_RLWNM_ABC: begin
           mask_start = (31-SH_MB_ME[10:5]); // MB
           mask_stop = (31-SH_MB_ME[4:0]); // ME
        end

        `EXOP_SH_SLW_AB: begin
           // Mask from lowest valid bit-1 down to 0.
           // Zero-sized shift would break, but this is dealt with below.
           mask_start = rol_amount-1;
           mask_stop = 5'h0;
        end

        `EXOP_SH_SRAW_AB: begin
           // Mask from 31 down to the highest valid bit+1.
           // Again, zero-sized shift will break but dealt with separately.
           mask_start = 5'd31;
           mask_stop = rol_amount;
        end

        `EXOP_SH_SRW_AB: begin
           mask_start = 5'd31;
           mask_stop = rol_amount;
        end

        default: begin
           mask_start = 5'h0;
           mask_stop = 5'h0;
        end
      endcase
   end


   /* Rotator/mask generator instances */
   rotate ROT(.val(in_val),
              .rol(rol_amount),
              .out(rotate_out)
              );

   mask MASK(.start_bit(mask_start),
             .stop_bit(mask_stop),
             .out(mask_out)
             );


   /* Create final result: */
   always @(*) begin
      res_co = 1'b0; /* Some cases override this value */

      case (op)
        `EXOP_SH_RLWIMI_ABC: begin
           res = (rotate_out & mask_out) | (insertee_sh & ~mask_out);
        end

        `EXOP_SH_RLWNM_ABC: begin
           res = (rotate_out & mask_out);
        end

        `EXOP_SH_SLW_AB: begin
           if (insertee_sh[5]) begin
              res = `REG_ZERO;
           end else if (insertee_sh[4:0] == 5'h0) begin
              // A zero-sized shift is not masked (because mask contains at least 1 bit...)
              res = in_val;
           end else begin
              res = (rotate_out & ~mask_out); // Mask is n to 0, zeroes bottom
           end
           // SLW doesn't affect CO, value isn't important.
        end

        `EXOP_SH_SRW_AB: begin
           if (insertee_sh[5]) begin
              res = `REG_ZERO;
           end else if (insertee_sh[4:0] == 5'h0) begin
              // No mask for zero-sized shift.
              res = in_val;
           end else begin
              res = (rotate_out & ~mask_out); // Mask is 31 to n, zeroes top
           end
           // SRW doesn't affect CO, value isn't important.
        end

        `EXOP_SH_SRAW_AB: begin
           if (insertee_sh[5]) begin
              // For shifts > 31, output is filled with sign bit
              res = in_val[31] ? `REG_ONES : `REG_ZERO;
              res_co = in_val[31];
           end else if (insertee_sh[4:0] == 5'h0) begin
              res = in_val;
           end else begin
              // Mask has 1 bits where top bits are shifted right.
              // These are 0 if +ve and 1 if -ve:
              if (in_val[`REGSZ-1]) begin
                 res = (rotate_out | mask_out); // SXT
              end else begin
                 res = (rotate_out & ~mask_out); // ZXT
              end
              /* If a shift occurs, and if in_val[31], and if
               * any 1 bits are shifted out of the BOTTOM, then
               * set res_co.
               * Note bits shifted out bottom are bits shifted into top,
               * so they're captured by a simple reduction-or.
               */
              res_co = in_val[31] && |(rotate_out & mask_out);
           end
        end

        default: begin
           res    = `REG_ZERO;
        end
      endcase
   end

   assign    out = res;
   assign    co = res_co;

endmodule // rotate


////////////////////////////////////////////////////////////////////////////////

/* Make a mask with 1s from start_bit down to stop_bit (inclusive)
 * Where start_bit < stop_bit, the mask wraps.
 *
 * Examples:
 *
 *              3322222222221111111111
 *              10987654321098765432109876543210
 *              --------------------------------
 * S=31,E=7     11111111111111111111111110000000
 * S=12,E=3     00000000000000000001111111111000
 * S=31,E=31    10000000000000000000000000000000
 * S=0,E=0      00000000000000000000000000000001
 * S=31,E=0     11111111111111111111111111111111
 * S=0,E=31     10000000000000000000000000000001
 * S=0,E=1      11111111111111111111111111111111
 * S=7,E=24     11111111000000000000000011111111
 * S=10,E=0     00000000000000000000011111111111
 *
 * The approach taken is to split the 32-bit span into
 * two 16-bit spans each made of two 8-bit spans each made
 * of two 4-bit spans.  At each hierarchy level, the
 * start/stop bit positions are classified into region 0/1
 * and the output bits combined upwards.
 */
module mask(input wire [4:0] start_bit,
            input wire [4:0] stop_bit,
            output wire [31:0] out
            );


   reg [31:0]                  res; // Wire

   reg [3:0]                   s1, e1; // Wire
   reg [3:0]                   s0, e0; // Wire
   wire [15:0]                 m0, m1;
   wire                        w0, w1;

   mask16 masker1(.start_bit(s1), .stop_bit(e1), .out(m1), .wrapped(w1));
   mask16 masker0(.start_bit(s0), .stop_bit(e0), .out(m0), .wrapped(w0));

   always @(*) begin
      /* See which mask chunks overlap the spans: */
      casez({start_bit[4], stop_bit[4]})
        2'b00: begin // Both start and end bits are in the m0 region
           res[31:16] = w0 ? 16'hffff : 16'h0000;
           res[15:0]  = m0;

           s1         = 4'b0000; // unused
           e1         = 4'b0000; // unused
           s0         = start_bit[3:0];
           e0         = stop_bit[3:0];
        end

        2'b01: begin // WRAPS:  Starts in m0, ends in m1 region
           res[31:16] = m1;
           res[15:0]  = m0;

           s1         = 4'b1111;
           e1         = stop_bit[3:0];
           s0         = start_bit[3:0];
           e0         = 4'b0000;
        end

        2'b10: begin // Starts in m1, ends in m0
           res[31:16] = m1;
           res[15:0]  = m0;

           s1         = start_bit[3:0];
           e1         = 4'b0000;
           s0         = 4'b1111;
           e0         = stop_bit[3:0];
        end
        default: begin // 2'b11: Both start and end bits are in the m1 region
           res[31:16] = m1;
           res[15:0]  = w1 ? 16'hffff : 16'h0000;

           s1         = start_bit[3:0];
           e1         = stop_bit[3:0];
           s0         = 4'b0000; // unused
           e0         = 4'b0000; // unused
        end
      endcase
   end

   assign out = res;
endmodule // mask

module mask16(input wire [3:0]  start_bit,
             input wire [3:0]   stop_bit,
             output wire [15:0] out,
             output wire        wrapped);

   reg [15:0]                  res; // Wire
   reg                         w; // Wire

   reg [2:0]                   s1, e1; // Wire
   reg [2:0]                   s0, e0; // Wire
   wire [7:0]                  m0, m1;
   wire                        w0, w1;

   mask8 masker1(.start_bit(s1), .stop_bit(e1), .out(m1), .wrapped(w1));
   mask8 masker0(.start_bit(s0), .stop_bit(e0), .out(m0), .wrapped(w0));

   always @(*) begin
      /* See which mask chunks overlap the spans: */
      casez({start_bit[3], stop_bit[3]})
        2'b00: begin // Both start and end bits are in the m0 region
           res[15:8] = w0 ? 8'hff : 8'h00;
           res[7:0]  = m0;
           w         = w0;

           s1        = 3'b000; // unused
           e1        = 3'b000; // unused
           s0        = start_bit[2:0];
           e0        = stop_bit[2:0];
        end

        2'b01: begin // WRAPS:  Starts in m0, ends in m1 region
           res[15:8] = m1;
           res[7:0]  = m0;
           w         = 1'b1;

           s1        = 3'b111;
           e1        = stop_bit[2:0];
           s0        = start_bit[2:0];
           e0        = 3'b000;
        end

        2'b10: begin // Starts in m1, ends in m0
           res[15:8] = m1;
           res[7:0]  = m0;
           w         = 1'b0;

           s1        = start_bit[2:0];
           e1        = 3'b000;
           s0        = 3'b111;
           e0        = stop_bit[2:0];
        end
        default: begin // 2'b11: Both start and end bits are in the m1 region
           res[15:8] = m1;
           res[7:0]  = w1 ? 8'hff : 8'h00;
           w         = w1;

           s1        = start_bit[2:0];
           e1        = stop_bit[2:0];
           s0        = 3'b000; // unused
           e0        = 3'b000; // unused
        end
      endcase
   end

   assign out = res;
   assign wrapped = w;
endmodule

module mask8(input wire [2:0]  start_bit,
             input wire [2:0]  stop_bit,
             output wire [7:0] out,
             output wire       wrapped);

   reg [7:0]                   r; // Wire
   reg                         w; // Wire

   reg [1:0]                   s1, e1; // Wire
   reg [1:0]                   s0, e0; // Wire
   wire [3:0]                  m0, m1;
   wire                        w0, w1;

   mask4 masker1(.start_bit(s1), .stop_bit(e1), .out(m1), .wrapped(w1));
   mask4 masker0(.start_bit(s0), .stop_bit(e0), .out(m0), .wrapped(w0));

   always @(*) begin
      /* See which mask chunks overlap the spans: */
      casez({start_bit[2], stop_bit[2]})
        2'b00: begin // Both start and end bits are in the m0 region
           r[7:4]   = w0 ? 4'hf : 4'h0;
           r[3:0]   = m0;
           w        = w0; // Wrapped if lower level flags it

           s1       = 2'b00; // unused
           e1       = 2'b00; // unused
           s0       = start_bit[1:0];
           e0       = stop_bit[1:0];
        end

        2'b01: begin // WRAPS:  Starts in m0, ends in m1 region
           r[7:4]   = m1;
           r[3:0]   = m0;
           w        = 1'b1;

           s1       = 2'b11;
           e1       = stop_bit[1:0];
           s0       = start_bit[1:0];
           e0       = 2'b00;
        end

        2'b10: begin // Starts in m1, ends in m0
           r[7:4]   = m1;
           r[3:0]   = m0;
           w        = 1'b0;

           s1       = start_bit[1:0];
           e1       = 2'b00;
           s0       = 2'b11;
           e0       = stop_bit[1:0];
        end

        default: begin // 2'b11: Both start and end bits are in the m1 region
           r[7:4]   = m1;
           r[3:0]   = w1 ? 4'hf : 4'h0;
           w        = w1;

           s1       = start_bit[1:0];
           e1       = stop_bit[1:0];
           s0       = 2'b00; // unused
           e0       = 2'b00; // unused
        end
      endcase
   end

   assign out = r;
   assign wrapped = w;
endmodule

module mask4(input wire [1:0]  start_bit,
             input wire [1:0]  stop_bit,
             output wire [3:0] out,
             output wire       wrapped);

   reg [3:0]                   r; // Wire
   reg                         w; // Wire

   always @(*) begin
      casez ({start_bit, stop_bit})
        4'b0000: begin  r = 4'b0001; w = 1'b0; end
        4'b0100: begin  r = 4'b0011; w = 1'b0; end
        4'b1000: begin  r = 4'b0111; w = 1'b0; end
        4'b1100: begin  r = 4'b1111; w = 1'b0; end

        // start-0 end=1, check
        4'b0001: begin  r = 4'b1111; w = 1'b1; end
        4'b0101: begin  r = 4'b0010; w = 1'b0; end
        4'b1001: begin  r = 4'b0110; w = 1'b0; end
        4'b1101: begin  r = 4'b1110; w = 1'b0; end

        4'b0010: begin  r = 4'b1101; w = 1'b1; end
        4'b0110: begin  r = 4'b1111; w = 1'b1; end
        4'b1010: begin  r = 4'b0100; w = 1'b0; end
        4'b1110: begin  r = 4'b1100; w = 1'b0; end

        4'b0011: begin  r = 4'b1001; w = 1'b1; end
        4'b0111: begin  r = 4'b1011; w = 1'b1; end
        4'b1011: begin  r = 4'b1111; w = 1'b1; end
        /*4'b1111:*/
        default: begin  r = 4'b1000; w = 1'b0; end
      endcase
   end

   assign out = r;
   assign wrapped = w;
endmodule


////////////////////////////////////////////////////////////////////////////////

module rotate(input wire [31:0] val,
              input wire [4:0] rol,
              output wire [31:0] out
              );

   reg [31:0]                    res[4:0]; // Wire

   always @(*) begin
      res[4] = rol[4] ? {val[15:0], val[31:16]} : val[31:0];
      res[3] = rol[3] ? {res[4][23:0], res[4][31:24]} : res[4][31:0];
      res[2] = rol[2] ? {res[3][27:0], res[3][31:28]} : res[3][31:0];
      res[1] = rol[1] ? {res[2][29:0], res[2][31:30]} : res[2][31:0];
      res[0] = rol[0] ? {res[1][30:0], res[1][31]} : res[1][31:0];
   end

   assign out = res[0];
endmodule
