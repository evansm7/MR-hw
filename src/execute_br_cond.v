/* execute_br_cond
 *
 * Calculate condition for branch
 *
 * Refactored 24/3/20
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

`include "decode_enums.vh"


module execute_br_cond(input wire [4:0]  instr_cr_field,
                       input wire        input_valid,
                       input wire [3:0]  input_fault,

                       input wire [3:0]  exe_brcond,
                       input wire [31:0] cond_reg,
                       input wire        br_ctr_z,

                       output wire       branch_taken
                       );


   reg                                   br_taken; // Wire
   reg                                   br_cr_bit; // Wire

   // Decode branch action
   always @(*) begin
      br_cr_bit = cond_reg[31-instr_cr_field];
   end

   always @(*) begin
      if (!input_valid || (input_fault != 0)) begin
         br_taken = 0;
      end else begin
         case (exe_brcond)
           0:
             br_taken = 0;

           `EXOP_BRCOND_AL:
             br_taken = 1;

           `EXOP_BRCOND_C_NZ:
             br_taken = !br_cr_bit && !br_ctr_z;

           `EXOP_BRCOND_C_ONE:
             br_taken = !br_cr_bit;

           `EXOP_BRCOND_C_Z:
             br_taken = !br_cr_bit &&  br_ctr_z;

           `EXOP_BRCOND_ONE_NZ:
             br_taken =               !br_ctr_z;

           `EXOP_BRCOND_ONE_Z:
             br_taken = br_ctr_z;

           `EXOP_BRCOND_T_NZ:
             br_taken =  br_cr_bit && !br_ctr_z;

           `EXOP_BRCOND_T_ONE:
             br_taken =  br_cr_bit;

           `EXOP_BRCOND_T_Z:
             br_taken =  br_cr_bit &&  br_ctr_z;

           default: begin
              br_taken = 0;
              if (input_valid) begin
`ifdef SIM
                 $fatal(1, "EXE: Unknown exe_brcond %d", exe_brcond);
`endif
              end
           end
         endcase
      end
   end

   assign branch_taken = br_taken;

endmodule // execute_br_cond
