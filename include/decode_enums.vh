/* Definitions/enums used by decoder
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

`ifndef DECODE_ENUMS_VH
`define DECODE_ENUMS_VH

`include "decode_macros.vh"

`define FC_NONE		0
`define FC_IRQ		1
`define FC_DEC		2
`define FC_PROG_ILL	3	// May need sub-types for different causes, e.g. priv vs ill
`define FC_PROG_TRAP	6
`define FC_PROG_PRIV	11
`define FC_SC		4
`define FC_FP		5
`define FC_ILL_HYP  	`FC_PROG_ILL // FIXME: Extend for true HYP traps
`define FC_MEM_ALIGN    7
`define FC_ISI_TF	8
`define FC_ISI_PF	9
`define FC_ISI_NX	10

`define FC_DSI_MASK     4'b11??
`define FC_DSI_WBIT     0
`define FC_DSI_PBIT     1
`define FC_DSI_TF_R	12
`define FC_DSI_TF_W	13
`define FC_DSI_PF_R	14
`define FC_DSI_PF_W	15

	// de_port{a,b}_type
	/* FIXME: could decode GPRs/SPRs/SRs into one "reg ID" value instead of two separate fields */
`define DE_NONE			0
`define DE_GPR			1
`define DE_SPR			2
`define DE_IMM			3
`define DE_SEGREG		4
	// de_port*_imm_name
`define DE_IMM_D		0	// Default
`define DE_IMM_SI		`DE_IMM_D
`define DE_IMM_SI_HI		1
`define DE_IMM_UI		2
`define DE_IMM_UI_HI		3
`define DE_IMM_TO		4
`define DE_IMM_LI		5
`define DE_IMM_SH		6
`define DE_IMM_SH_MB_ME		7
`define DE_IMM_MB_ME		`DE_IMM_SH_MB_ME
`define DE_IMM_FXM		8
`define DE_IMM_SR		9
`define DE_IMM_BA		10
`define DE_IMM_BB		`DE_IMM_SH
`define DE_IMM_BT		`DE_IMM_TO
`define DE_IMM_BF		11
`define DE_IMM_BD		12
`define DE_IMM_BFA		13

	// de_fsm_op
`define DE_STATE_IDLE		0
`define DE_STATE_LMW		1
`define DE_STATE_STMW		2
`define DE_STATE_DCBZ		3
`define DE_STATE_MFSRIN		4
	// exe_int_op
`define EXOP_ALU_ADC_AB_D	1
`define EXOP_ALU_ADC_A_0_D	2
`define EXOP_ALU_ADC_A_M1_D	3
`define EXOP_ALU_ADD_AB		4
`define EXOP_ALU_ANDC_AB	5
`define EXOP_ALU_AND_AB		6
`define EXOP_ALU_DEC_C		7
`define EXOP_ALU_NAND_AB	8
`define EXOP_ALU_NEG_A		9
`define EXOP_ALU_NOR_AB		10
`define EXOP_ALU_NXOR_AB	11
`define EXOP_ALU_ORC_AB		12
`define EXOP_ALU_OR_AB		13
`define EXOP_ALU_SUB_A_0_D	14
`define EXOP_ALU_SUB_A_M1_D	15
`define EXOP_ALU_SUB_BA		16
`define EXOP_ALU_SUB_BA_D	17
`define EXOP_ALU_XOR_AB		18
`define EXOP_ALU_ADD_R0_4	19
`define EXOP_DIV_AB		20
`define EXOP_DIV_U_AB		21
`define EXOP_D_TO_CR		22
`define EXOP_D_TO_XER		23
`define EXOP_MISC_CNTLZW_A	24
`define EXOP_MSR		25
`define EXOP_SXT_16_A		26
`define EXOP_SXT_8_A		27
`define EXOP_MUL_AB		28
`define EXOP_MUL_HWU_AB		29
`define EXOP_MUL_HW_AB		30
`define EXOP_SH_RLWIMI_ABC	31
`define EXOP_SH_RLWNM_ABC	32
`define EXOP_SH_SLW_AB		33
`define EXOP_SH_SRAW_AB		34
`define EXOP_SH_SRW_AB		35

	// exe_brcond
`define EXOP_BRCOND_AL		1
`define EXOP_BRCOND_C_NZ	2
`define EXOP_BRCOND_C_ONE	3
`define EXOP_BRCOND_C_Z		4
`define EXOP_BRCOND_ONE_NZ	5
`define EXOP_BRCOND_ONE_Z	6
`define EXOP_BRCOND_T_NZ	7
`define EXOP_BRCOND_T_ONE	8
`define EXOP_BRCOND_T_Z		9
	// exe_brdest_op
`define EXOP_BR_DEST_A		1
`define EXOP_BR_DEST_C		2
`define EXOP_BR_DEST_PC_A_AA	3
	// exe_rc_op
`define EXOP_CA			1
`define EXOP_CMPU_AB_C		2
`define EXOP_CMP_AB_C		4
`define EXOP_CR_ANDC_ABC	5
`define EXOP_CR_AND_ABC		6
`define EXOP_CR_COPY_CR4_BCD	7
`define EXOP_CR_EQV_ABC		8
`define EXOP_CR_INSERT_ABD	9
`define EXOP_CR_INSERT_B	10
`define EXOP_CR_NAND_ABC	11
`define EXOP_CR_NOR_ABC		12
`define EXOP_CR_ORC_ABC		13
`define EXOP_CR_OR_ABC		14
`define EXOP_CR_XOR_ABC		15
`define EXOP_D			16
`define EXOP_RC			17
`define EXOP_SO			18
`define EXOP_SO_CA		19
`define EXOP_RC_CA		20 // mk_decode transforms RcA_CA to this
`define EXOP_RC_SO		21 // mk_decode transforms RcA_SO to this
`define EXOP_RC_SO_CA		22 // mk_decode transforms RcA_SO_CA to this
`define EVAL_EXOP_RC	        (INST_Rc ? `EXOP_RC : 0)
`define EVAL_EXOP_RC_CA	        (INST_Rc ? `EXOP_RC_CA : `EXOP_CA)
`define EVAL_EXOP_RC_SO	        (INST_Rc ?			\
				 (INST_SO ? `EXOP_RC_SO : `EXOP_RC) :	\
				 (INST_SO ? `EXOP_SO : 0))
`define EVAL_EXOP_RC_SO_CA      (INST_Rc ?			\
				 (INST_SO ? `EXOP_RC_SO_CA : `EXOP_RC_CA) :	\
				 (INST_SO ? `EXOP_SO_CA : `EXOP_CA))

        // exe_special
`define EXOP_DEBUG              1

	// exe_R{0,1,2}
`define EXUNIT_NONE		0
`define EXUNIT_INT		1
`define EXUNIT_BRDEST		2
`define EXUNIT_PORT_A		3
`define EXUNIT_PORT_B		4
`define EXUNIT_PORT_C		5
`define EXUNIT_SPECIAL		6
`define EXUNIT_PCINC		7

	// mem_op
`define MEM_LOAD		1
`define MEM_STORE		2
`define MEM_DC_CLEAN		3
`define MEM_DC_CINV		4
`define MEM_DC_INV		5
`define MEM_DC_INV_SET          6
`define MEM_DC_BZ		7
`define MEM_IC_INV		8
`define MEM_IC_INV_SET          9
`define MEM_TLBI_R0		10
`define MEM_TLBIA		11

        // mem_sr_op
`define MEM_SR_READ             1
`define MEM_SR_WRITE            2

        // size
`define MEM_OP_SIZE_8           2'b00
`define MEM_OP_SIZE_16          2'b01
`define MEM_OP_SIZE_32          2'b10

	// mem_newpc/mem_newmsr
`define MEM_R0			0
`define MEM_R2 			1
	// wb_write_gpr_port{0,1}_from
	/* FIXME: Also don't really need wb_write_gpr_port{0,1} as 'from' can
	 * encode a 'none' value as 0. */
`define WB_PORT_R0 		1
`define WB_PORT_R1 		2
`define WB_PORT_MEM_RES 	3
`define WB_PORT_SXT16_MEM_RES	4
`define WB_PORT_BSWAP16_MEM_RES	5
`define WB_PORT_BSWAP32_MEM_RES 6


/* SPRs: */
`define DE_spr_LR	        0 /* SSPR */
`define DE_spr_CTR	        1
`define DE_spr_SPRG0	        2
`define DE_spr_SPRG1	        3
`define DE_spr_SPRG2	        4
`define DE_spr_SPRG3	        5
`define DE_NR_SPRS_RLOCK        6 /* SPRs below this point are individually locked */
`define DE_L2_SPRS_RLOCK	3
`define DE_spr_SRR0	        6 /* Remainder of SPRs use generic lock */
`define DE_spr_SRR1	        7 /* SSPR */
`define DE_spr_PVR	        8
`define DE_spr_SDR1	        9
`define DE_spr_DAR	        10
`define DE_spr_DSISR	        11 /* SSPR */
`define DE_spr_DABR	        12
`define DE_spr_TBL	        13
`define DE_spr_TBU	        14
`define DE_spr_DEC	        15
`define DE_spr_DEBUG            16
`define DE_spr_HID0             17
/* Note: SSPRs only written via 2nd port */

/* BATs */
`define NR_BATs                 4 /* 4 pairs of upper/lower per I and D */

`define DE_spr_IBAT0	        32
`define DE_spr_IBATU_msk	6'b100??0
`define DE_spr_IBATL_msk	6'b100??1
`define DE_spr_DBAT0	        40
`define DE_spr_DBATU_msk	6'b101??0
`define DE_spr_DBATL_msk	6'b101??1
`define DE_spr_BAT_idxb         2:1
`define DE_spr_IBAT(x)	        (`DE_spr_IBAT0 | ``x``) // FIXME, OR into low bits
`define DE_spr_DBAT(x)	        (`DE_spr_DBAT0 | ``x``)

`define DE_NR_SPRS_LOG2         6

// SRs are something else entirely, TBD...
`define DE_spr_SR0	64
`define DE_spr_SR15	80

`define DE_SReg(x)      (``x``)


// TLB/cache internal stuff
`define MMU_FAULT_NONE  3'b000
`define MMU_FAULT_TF    3'b001
`define MMU_FAULT_PF    3'b010
`define MMU_FAULT_NX    3'b011
`define MMU_FAULT_ALIGN 3'b100

`define PTW_FAULT_NONE  2'b00
`define PTW_FAULT_TF    2'b10 /* Requested PTE is not present */
`define PTW_FAULT_PF    2'b11 /* PTE is no-access (or NX) */

`define PTW_PTE_PPN_ST  0
`define PTW_PTE_PPN_SZ  20
`define PTW_PTE_PP_ST   (`PTW_PTE_PPN_ST+`PTW_PTE_PPN_SZ)
`define PTW_PTE_PP_SZ   2
`define PTW_PTE_KS_ST   (`PTW_PTE_PP_ST+`PTW_PTE_PP_SZ)
`define PTW_PTE_KP_ST   (`PTW_PTE_KS_ST+1)
`define PTW_PTE_CACH_ST (`PTW_PTE_KP_ST+1)

/* The request to the PTW returns a subset of the TLB entry info,
 * as the source is already aware of the VPN.
 */
`define PTW_PTE_SIZE    (`PTW_PTE_CACH_ST+1)

`endif
