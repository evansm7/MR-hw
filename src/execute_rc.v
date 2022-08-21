/* execute_rc
 *
 * Given carry-out, overflow, an rc_op and current (combined) XERCR, calculate
 * a new XERCR value.
 *
 * Refactored/extended 24/3/20
 *
 * Copyright 2020-2021 Matt Evans
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


module execute_rc(input wire [4:0]           rc_op,
                  input wire                 input_valid,

                  /* BA is 5 bits, FXM is 8 */
                  input wire [7:0]           BAFXM,
                  /* BB is 5 bits, BFA is 3 bits, 32b of B used too: */
                  input wire [31:0]          BBBFA,
                  /* BF is 3 bits, BT is 5 */
                  input wire [4:0]           BFBT,
                  input wire                 ca,
                  input wire                 ov,
                  input wire [3:0]           crf,
                  input wire [3:0]           crf_signed,
                  input wire [3:0]           crf_unsigned,
                  input wire [`XERCRSZ-1:0]  rc_in,

                  output wire [`XERCRSZ-1:0] rc_out
                  );

   reg [`XERCRSZ-1:0]                        res_rc; // Wire
   reg [3:0]                                 source_field; // Wire
   reg                                       crA, crB; // Wire
   reg [31:0]                                crr; // Wire
   reg                                       crbit; // Wire

   wire                                      new_so = rc_in[`XERCR_SO] | ov;

   always @(*) begin
      /* For mcrf */
      case (BBBFA[2:0])
        0:              source_field = rc_in[31:28];
        1:              source_field = rc_in[27:24];
        2:              source_field = rc_in[23:20];
        3:              source_field = rc_in[19:16];
        4:              source_field = rc_in[15:12];
        5:              source_field = rc_in[11:8];
        6:              source_field = rc_in[7:4];
        default:        source_field = rc_in[3:0];
      endcase
   end

   always @(*) begin
      /* Input A for condition register logicals: */
      case (BAFXM[4:0])
        0:		crA = rc_in[31];
        1:		crA = rc_in[30];
        2:		crA = rc_in[29];
        3:		crA = rc_in[28];
        4:		crA = rc_in[27];
        5:		crA = rc_in[26];
        6:		crA = rc_in[25];
        7:		crA = rc_in[24];
        8:		crA = rc_in[23];
        9:		crA = rc_in[22];
        10:		crA = rc_in[21];
        11:		crA = rc_in[20];
        12:		crA = rc_in[19];
        13:		crA = rc_in[18];
        14:		crA = rc_in[17];
        15:		crA = rc_in[16];
        16:		crA = rc_in[15];
        17:		crA = rc_in[14];
        18:		crA = rc_in[13];
        19:		crA = rc_in[12];
        20:		crA = rc_in[11];
        21:		crA = rc_in[10];
        22:		crA = rc_in[9];
        23:		crA = rc_in[8];
        24:		crA = rc_in[7];
        25:		crA = rc_in[6];
        26:		crA = rc_in[5];
        27:		crA = rc_in[4];
        28:		crA = rc_in[3];
        29:		crA = rc_in[2];
        30:		crA = rc_in[1];
        default:	crA = rc_in[0];
      endcase

      /* Input B for condition register logicals: */
      case (BBBFA[4:0])
        0:		crB = rc_in[31];
        1:		crB = rc_in[30];
        2:		crB = rc_in[29];
        3:		crB = rc_in[28];
        4:		crB = rc_in[27];
        5:		crB = rc_in[26];
        6:		crB = rc_in[25];
        7:		crB = rc_in[24];
        8:		crB = rc_in[23];
        9:		crB = rc_in[22];
        10:		crB = rc_in[21];
        11:		crB = rc_in[20];
        12:		crB = rc_in[19];
        13:		crB = rc_in[18];
        14:		crB = rc_in[17];
        15:		crB = rc_in[16];
        16:		crB = rc_in[15];
        17:		crB = rc_in[14];
        18:		crB = rc_in[13];
        19:		crB = rc_in[12];
        20:		crB = rc_in[11];
        21:		crB = rc_in[10];
        22:		crB = rc_in[9];
        23:		crB = rc_in[8];
        24:		crB = rc_in[7];
        25:		crB = rc_in[6];
        26:		crB = rc_in[5];
        27:		crB = rc_in[4];
        28:		crB = rc_in[3];
        29:		crB = rc_in[2];
        30:		crB = rc_in[1];
        default:	crB = rc_in[0];
      endcase
   end

   always @(*) begin
      /* Calculate condition register logical ops */
      crbit = 0;

      case (rc_op)
        `EXOP_CR_ANDC_ABC:           crbit = crA & ~crB;
        `EXOP_CR_AND_ABC:            crbit = crA & crB;
        `EXOP_CR_EQV_ABC:            crbit = ~(crA ^ crB);
        `EXOP_CR_NAND_ABC:           crbit = ~(crA & crB);
        `EXOP_CR_NOR_ABC:            crbit = ~(crA | crB);
        `EXOP_CR_ORC_ABC:            crbit = crA | ~crB;
        `EXOP_CR_OR_ABC:             crbit = crA | crB;
        `EXOP_CR_XOR_ABC:            crbit = crA ^ crB;
        default:                     crbit = 0;
      endcase

      /* Pseudo-output for condition reg logicals: */
      crr[31:0] = rc_in[31:0];
      case (BFBT[4:0])
        0:		crr[31] = crbit;
        1:		crr[30] = crbit;
        2:		crr[29]   = crbit;
        3:		crr[28] = crbit;
        4:		crr[27]   = crbit;
        5:		crr[26] = crbit;
        6:		crr[25]   = crbit;
        7:		crr[24] = crbit;
        8:		crr[23]   = crbit;
        9:		crr[22] = crbit;
        10:		crr[21]   = crbit;
        11:		crr[20] = crbit;
        12:		crr[19]   = crbit;
        13:		crr[18] = crbit;
        14:		crr[17]   = crbit;
        15:		crr[16] = crbit;
        16:		crr[15]   = crbit;
        17:		crr[14] = crbit;
        18:		crr[13]   = crbit;
        19:		crr[12] = crbit;
        20:		crr[11]   = crbit;
        21:		crr[10] = crbit;
        22:		crr[9]   = crbit;
        23:		crr[8] = crbit;
        24:		crr[7]   = crbit;
        25:		crr[6] = crbit;
        26:		crr[5]   = crbit;
        27:		crr[4] = crbit;
        28:		crr[3]   = crbit;
        29:		crr[2] = crbit;
        30:		crr[1]   = crbit;
        default:	crr[0] = crbit;
      endcase
   end

   //////////////////////////////////////////////////////////////////////

   always @(*) begin
      /* The base state is that OUT is the same as IN, then
       * specific fields might get overridden below.
       * (This makes the case statement MUCH clearer!)
       */
      res_rc = rc_in;

      case (rc_op)
        0: begin
        end

        `EXOP_D: begin
           // Pass through XERCR
        end

        `EXOP_CR_COPY_CR4_BCD: begin
           /* For mcrf, copy 4-bit field BFA into BF: */
           if (BFBT[2:0] == 0)         res_rc[31:28] = source_field;
           else if (BFBT[2:0] == 1)    res_rc[27:24] = source_field;
           else if (BFBT[2:0] == 2)    res_rc[23:20] = source_field;
           else if (BFBT[2:0] == 3)    res_rc[19:16] = source_field;
           else if (BFBT[2:0] == 4)    res_rc[15:12] = source_field;
           else if (BFBT[2:0] == 5)    res_rc[11:8] = source_field;
           else if (BFBT[2:0] == 6)    res_rc[7:4] = source_field;
           else /* (BFBT[2:0] == 7) */ res_rc[3:0] = source_field;

        end

        `EXOP_CR_INSERT_ABD: begin
           // mtcrf: insert bits from B as given by FXM fields
           if (BAFXM[7])
             res_rc[31:28] = BBBFA[31:28];
           if (BAFXM[6])
             res_rc[27:24] = BBBFA[27:24];
           if (BAFXM[5])
             res_rc[23:20] = BBBFA[23:20];
           if (BAFXM[4])
             res_rc[19:16] = BBBFA[19:16];
           if (BAFXM[3])
             res_rc[15:12] = BBBFA[15:12];
           if (BAFXM[2])
             res_rc[11:8] = BBBFA[11:8];
           if (BAFXM[1])
             res_rc[7:4] = BBBFA[7:4];
           if (BAFXM[0])
             res_rc[3:0] = BBBFA[3:0];
        end

        `EXOP_CR_INSERT_B: begin
           // mtxer: insert bits from B
           res_rc[`XERCR_SO] = BBBFA[31];
           res_rc[`XERCR_OV] = BBBFA[30];
           res_rc[`XERCR_CA] = BBBFA[29];
           res_rc[`XERCR_BC] = BBBFA[6:0];
        end

        `EXOP_CMP_AB_C: begin
           // BF[2:0] field comes into EXE via port C
           // The XERCR is passed through, except for one CRx field:
           if (BFBT[2:0] == 0)         res_rc[31:28] = crf_signed;
           else if (BFBT[2:0] == 1)    res_rc[27:24] = crf_signed;
           else if (BFBT[2:0] == 2)    res_rc[23:20] = crf_signed;
           else if (BFBT[2:0] == 3)    res_rc[19:16] = crf_signed;
           else if (BFBT[2:0] == 4)    res_rc[15:12] = crf_signed;
           else if (BFBT[2:0] == 5)    res_rc[11:8] = crf_signed;
           else if (BFBT[2:0] == 6)    res_rc[7:4] = crf_signed;
           else /* (BFBT[2:0] == 7) */ res_rc[3:0] = crf_signed;
        end

        `EXOP_CMPU_AB_C: begin
           if (BFBT[2:0] == 0)         res_rc[31:28] = crf_unsigned;
           else if (BFBT[2:0] == 1)    res_rc[27:24] = crf_unsigned;
           else if (BFBT[2:0] == 2)    res_rc[23:20] = crf_unsigned;
           else if (BFBT[2:0] == 3)    res_rc[19:16] = crf_unsigned;
           else if (BFBT[2:0] == 4)    res_rc[15:12] = crf_unsigned;
           else if (BFBT[2:0] == 5)    res_rc[11:8] = crf_unsigned;
           else if (BFBT[2:0] == 6)    res_rc[7:4] = crf_unsigned;
           else /* (BFBT[2:0] == 7) */ res_rc[3:0] = crf_unsigned;
        end

        `EXOP_RC: begin
           // Record CR0:
           res_rc[31:28] = crf;
        end

        `EXOP_SO: begin
           // Set XER SO+OV
           res_rc[`XERCR_SO] = new_so;
           res_rc[`XERCR_OV] = ov;
        end

        `EXOP_CA: begin
           // Set CA
           res_rc[`XERCR_CA] = ca;
        end

        `EXOP_RC_SO: begin
           // Record CR0, XER SO+OV:
           // Note CR0 contains *new* SO value
           res_rc[31:28] = {crf[3:1], new_so};
           res_rc[`XERCR_SO] = new_so;
           res_rc[`XERCR_OV] = ov;
        end

        `EXOP_SO_CA: begin
           // Set XER SO+OV, and CA
           res_rc[`XERCR_SO] = new_so;
           res_rc[`XERCR_OV] = ov;
           res_rc[`XERCR_CA] = ca;
        end

        `EXOP_RC_CA: begin
           // Record CR0, and CA
           // Note CR0 contains current SO value already,
           // which isn't changed by this instruction.
           res_rc[31:28] = crf;
           res_rc[`XERCR_CA] = ca;
        end

        `EXOP_RC_SO_CA: begin
           // Full Monty:  Record CR0, set XER SO+OV, and CA:
           res_rc[31:28] = {crf[3:1], new_so};
           res_rc[`XERCR_SO] = new_so;
           res_rc[`XERCR_OV] = ov;
           res_rc[`XERCR_CA] = ca;
        end

        /* CR conditionals:  See the massive case statements
         * above; these generate crbit, which is spliced into crr
         * above, which is then spliced into res_rc here...
         */
        `EXOP_CR_ANDC_ABC: begin
           res_rc[31:0] = crr[31:0];
        end
        `EXOP_CR_AND_ABC: begin
           res_rc[31:0] = crr[31:0];
        end
        `EXOP_CR_EQV_ABC: begin
           res_rc[31:0] = crr[31:0];
        end
        `EXOP_CR_NAND_ABC: begin
           res_rc[31:0] = crr[31:0];
        end
        `EXOP_CR_NOR_ABC: begin
           res_rc[31:0] = crr[31:0];
        end
        `EXOP_CR_ORC_ABC: begin
           res_rc[31:0] = crr[31:0];
        end
        `EXOP_CR_OR_ABC: begin
           res_rc[31:0] = crr[31:0];
        end
        `EXOP_CR_XOR_ABC: begin
           res_rc[31:0] = crr[31:0];
        end

        default: begin
           if (input_valid) begin
`ifdef SIM
              $fatal(1, "EXE: Unknown exe_rc_op %d", rc_op);
`endif
           end
        end
      endcase
   end

   assign rc_out = res_rc;

endmodule
