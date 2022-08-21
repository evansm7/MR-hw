/* execute_br_dest
 *
 * Calculates branch destination (relative, absolute)
 *
 * Refactored 24/3/20
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


module execute_br_dest(input wire [1:0]         brdest_op,
                       input wire               input_valid,
                       input wire [`REGSZ-1:0]  op_a,
                       input wire [`REGSZ-1:0]  op_c,
                       input wire [`REGSZ-1:0]  pc,
                       input wire               inst_aa,
                       output wire [`REGSZ-1:0] br_dest
                       );

   reg [`REGSZ-1:0]                             res_brdest;

   always @(*) begin
      case (brdest_op)
        0:
          res_brdest = 0;

        `EXOP_BR_DEST_A:
          res_brdest = {op_a[`REGSZ-1:2], 2'h0};

        `EXOP_BR_DEST_C:
          res_brdest = {op_c[`REGSZ-1:2], 2'h0};

        `EXOP_BR_DEST_PC_A_AA: begin

           if (inst_aa) begin // if AA
              res_brdest = {op_a[`REGSZ-1:2], 2'h0};
           end else begin
              res_brdest = {(op_a[`REGSZ-1:2] + pc[`REGSZ-1:2]), 2'h0};
           end
        end

        default: begin
           res_brdest = 0;
           if (input_valid) begin
`ifdef SIM
              $fatal(1, "EXE: Unknown exe_brdest_op %d", brdest_op);
`endif
           end
        end

      endcase
   end

   assign br_dest = res_brdest;

endmodule
