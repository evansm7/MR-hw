#!/usr/bin/python
#
# Derived from MR-ISS/tools/mk_decode.py
#
# This script does similar things to that script, but is largely divergent
# (doesn't need to share same code).  It generates decode (with
# pipeline/function control signals) for MR sim and RTL.
#
# Here's the plan:
#
# Output a decode switch in C
# Or, output a verilog case statement
#
# In aggregate, gather a total set of enables, which default to 0 unless a given instruction enables something.  (2-pass?)
#
# For each instruction, output DE/EXE/MEM/WB control signals (which are latched & carried forward w/ instruction).
#
# Copyright 2017-2022 Matt Evans
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

import csv
import re
import getopt
import sys
import pprint

################################################################################

# Parameter types
param_types     = { 'SI':'s16', 'D':'s16', 'UI':'u16', 'LI':'u32', 'LEV':'u8' }

#needs_accessor = ['RA', 'RA0', 'RB', 'RS', 'RT', 'CR', 'CA']
#regval_types = { 'RA':'REG', 'RA0':'REG', 'RB':'REG', 'RS':'REG', 'RT':'REG', 'CR':'uint32_t' }

immediate_fields        = {'SI', 'SI_HI', 'UI', 'UI_HI',
                           'BD', 'BF', 'BA', 'BB', 'BT',
                           'D', 'BFA', 'FXM', 'SH', 'SR',
                           'LI', 'SH_MB_ME', 'MB_ME', 'TO', '0'}
gpr_dest_names          = {'RA', 'RT'}
gpr_src_names           = {'RA', 'RA0', 'RB', 'RS'}

condition_input_names   = {("Rc", "INST_Rc"),
                           ("LK", "INST_LK"),
                           ("SO", "INST_SO")}

# SPRs valid from port A:
sprs_port_a = {'spr_LR', 'spr_SRR1'}
sprs_port_b = { }
sprs_port_c = {'spr_XER', 'spr_LR', 'spr_CTR', 'spr_DSISR',
               'spr_DAR', 'spr_DEC', 'spr_SDR1', 'spr_SRR0',
               'spr_SRR1', 'spr_SPRG0', 'spr_SPRG1', 'spr_SPRG2', 'spr_SPRG3',
               'spr_PVR', 'spr_IBAT(bat_idx)', 'spr_DBAT(bat_idx)',
               'spr_DABR', 'spr_TBL', 'spr_TBU',
               'spr_DEBUG', 'spr_HID0',
               'spr_SR[SR]'} # fixme spr offsets SR/BAT

srs_port_c = {'SReg(SR)', 'SReg_indirect_gpr'}

de_fsm_triggers = {'state_lmw', 'state_stmw', 'state_dcbz', 'state_mfsrin'}

subdecode_uses_spr = {'mfspr', 'mtspr', 'mftb'}
subdecode_uses_bo = {'bc', 'bclr', 'bcctr'}

signal_sizes = { "enable":1, "gpr_name":5, "sr_name":4, "spr_name":6,
                 "de_port._type":3, "de_depends_generic":1,
                 "de_gen_fault_type":4, "de_port.*checkz":1,
                 "de_port._imm_name":4, "de_fsm_op":3, "exe_int_op":6,
                 "exe_special$":6,
                 "exe_brcond":4, "exe_brdest_op":2, "exe_rc_op":5,
                 "exe_R.$":3,
                 "mem_op$":4, "mem_newpc":1, "mem_newmsr":1,
                 "mem_pass_R.":1, "mem_op_fault_inhibit":1,
                 "mem_op_addr_set_reservation":1, "mem_op_addr_test_reservation":1,
                 "mem_op_size":2, "mem_op_store_bswap":1, "mem_sr_op":2,
                 "wb_write_gpr_port.$":1, "wb_write_gpr_port._reg":5,
                 "wb_write_gpr_port._from":3, "wb_write_spr(_special){0,1}$":1,
                 "wb_write_spr_.*num":6, "wb_write_spr(_special){0,1}_from":3,
                 "wb_write_sr$":1, "wb_write_sr_from":3,
                 "wb_write_xercr":1 }

# Default values for certain signals should reflect their "general case", not zero.
# In some cases, this (currently) makes the signal a constant!
signal_defaults = { "de_porta_read_gpr_name":"INST_RA",
                    "de_portb_read_gpr_name":"INST_RB",
                    "de_portc_read_gpr_name":"INST_RS",
                    "wb_write_gpr_port0_reg":"INST_RT",
                    "wb_write_gpr_port1_reg":"INST_RA",
                    "mem_pass_R0":"1'b0", # This must only be 1 when there's valid bypass data!
                    "mem_pass_R1":"1'b1", # But, harmless to always do this
                    "wb_write_gpr_port0_from":"`WB_PORT_R0",
                    "wb_write_gpr_port1_from":"`WB_PORT_R0",
                    "wb_write_spr_from":"`WB_PORT_R0",
                    "wb_write_spr_special_from":"`WB_PORT_R1",
                    }

# Bodge out some instructions to trap/emulate, for development:
bodge_out = {};

################################################################################

de_sigs = set()
exe_sigs = set()
mem_sigs = set()
wb_sigs = set()
total_sigs = set()

wb_ports = dict()

TAG_INST = 'InstDesc'
TAG_SUB = 'SubdecodeDesc'
TAG_XOPC = 'XopcDesc'


################################################################################
# Misc utilities

def fatal(error_string):
    print "ERROR: " + error_string
    exit(1)


# Read given filename, return list of lines without newlines, and without blank lines:
def read_file_chomp(path):
    with open(path, 'rU') as data:
        d = []
        for line in data:
	    line = line.rstrip()
            if line != '':
                d.append(line)
        return d


def read_csv(path):
        data = read_file_chomp(path)
        reader = csv.DictReader(data)
        for row in reader:
            yield row


def get_wb_port_from_name(name):
    if name not in wb_ports:
        wb_ports[name] = "`WB_PORT_%s" % (name.upper())
    return wb_ports[name]


def get_spr_from_name(name):
    # FIXME: parse the BAT sprs (e.g. "spr_DBAT({spr[5],spr[2:0]})")
    return "`DE_" + name


def get_sr_from_name(name):
    # Source uses the 'SR' field in instruction; this becomes INST_SR.
    # This function is a bit of a hack but this is a special-case for one
    # nasty instruction class...
    assert(name == "SReg(SR)")
    return "`DE_SReg(INST_SR)"


def convert_condition(s):
    # Components of condition expressions (e.g. for "write LR if branch link")
    # are written in shorthand that needs to be expanded for real code.
    for cs in condition_input_names:
        (short, signame) = cs
        if short in s:
            s = s.replace(short, signame)
    return s

################################################################################

# A simple helper to create an assignment string (in future can have variants
# for different languages...), but also update a set of signals ever assigned:
def wb_add_sig_assign(name, val):
    if name not in wb_sigs:
        wb_sigs.add(name)
    return "%s = %s" % (name, val)

def de_add_sig_assign(name, val):
    if name not in de_sigs:
        de_sigs.add(name)
    return "%s = %s" % (name, val)

def exe_add_sig_assign(name, val):
    if name not in exe_sigs:
        exe_sigs.add(name)
    return "%s = %s" % (name, val)

def mem_add_sig_assign(name, val):
    if name not in mem_sigs:
        mem_sigs.add(name)
    return "%s = %s" % (name, val)

def get_signal_size(name):
    # Iterate through templates in signal_sizes and look
    # for matches:
    for k in signal_sizes.keys():
        if re.search(k, name):
            return signal_sizes[k]
    print("WARNING: signal size for %s unknown, assuming 1!" % name)
    return 1

def get_signal_default(name):
    for k in signal_defaults.keys():
        if re.search(k, name):
            return signal_defaults[k]
    return None


################################################################################

# If this writes XERCR, return condition string or "1", else None
def wb_write_xercr_cond(op):
    if "XERCR=RC" in op:
        # Is it conditional?
        if "if" in op:
            c = re.search(r"if *\((.*)\)", op)
            # print "cond %s" % (c.group(1))
            return convert_condition(c.group(1))
        else:
            return "1"
    else:
        if "XERCR=" in op:
            fatal("Assignment to XERCR from non-RC port not supported")
        return None


# If this writes LR, SRR1 or DSISR, return (condition string or "1", port), else None
def wb_write_spr_special_cond(op):
    r = re.search(r"((if) *\((.*)\) *){0,1} *(spr_LR|spr_SRR1|spr_DSISR)=(.*)", op)
    if r == None:
        return None

    if r.group(2):
        cond = convert_condition(r.group(3))
    else:
        cond = "1"

    spr = get_spr_from_name(r.group(4))
    port = get_wb_port_from_name(r.group(5))

    return (spr, port, cond)


# If this writes (a non-special) SPR, return (spr, port), else None
def wb_write_spr(op):
    r = re.search(r"(spr_.*)=(.*)", op)
    if r == None:
        return None

    spr = r.group(1)
    # LR/SRR1/DSISR are dealt with as a special case, in wb_write_spr_special_cond
    # FIXME: Check a list
    if spr == "spr_LR" or spr == "spr_SRR1" or spr == "spr_DSISR":
        return None

    spr = get_spr_from_name(spr)
    port = get_wb_port_from_name(r.group(2))

    return (spr, port)


def wb_write_gpr(op):
    r = re.search(r"(%s)=(.*)" % ('|'.join(gpr_dest_names)), op)
    if r == None:
        return None

    gpr = "INST_%s" % (r.group(1))
    port = get_wb_port_from_name(r.group(2))
    return (gpr, port)


def wb_write_sr(op):
    r = re.search(r"SReg_R1=(.*)", op)
    if r == None:
        return None
    port = get_wb_port_from_name(r.group(1))
    return port


def gen_wb_behaviours(wb_ops, genlock):   #, has_rc, has_oe, has_lk):
    # returns list
    # Should also gather control signals
    # Might write 1 or 2 GPRs (load-update), spr, XERCR
    b = []
    ops_list = [x.strip() for x in wb_ops.split(';')]
    cur_gpr_wr_port = 0

    for op in ops_list:
        # - Might write XERCR; set up control signal:
        xercr_cond = wb_write_xercr_cond(op)
        if xercr_cond:
            b.append(wb_add_sig_assign("wb_write_xercr", xercr_cond))
            b.append("`UNLOCK_XERCR_IF(%s)" % (xercr_cond))
            continue
        # - Special SPRs, LR and SRR1: there are sometimes writes of both CTR+LR
        #   or SRR0+SRR1 in the same cycle.  In all other cases, only one SPR is
        #   written.  There's a 'special SPR' port dealing with these.
        sspr = wb_write_spr_special_cond(op)
        if sspr:
            (sprname, port, cond) = sspr
            b.append(wb_add_sig_assign("wb_write_spr_special", cond))
            b.append(wb_add_sig_assign("wb_write_spr_special_num", sprname))
            b.append(wb_add_sig_assign("wb_write_spr_special_from", port))
            if sprname == "`DE_spr_LR":
                b.append("`UNLOCK_LR_IF(%s)" % (cond))
            else:
                # SRR1 doesn't need locking in this way; but assert the generic lock
                # will get taken!
                assert(genlock)
                b.append("`UNLOCK_GENERIC")
            continue
        # - Might write SPR (LR separate). Not conditional.
        spr = wb_write_spr(op)
        if spr:
            (sprname, port) = spr
            b.append(wb_add_sig_assign("wb_write_spr", "1"))
            b.append(wb_add_sig_assign("wb_write_spr_num", sprname))
            b.append(wb_add_sig_assign("wb_write_spr_from", port))
            if genlock:
                # generic lock regs are some SPRs, never GPRs
                assert(len(ops_list) == 1)
                b.append("`UNLOCK_GENERIC")
            else:
                b.append("`UNLOCK_SPR(%s)" % (sprname))
            continue
        # - Might write GPR(s):
        gpr = wb_write_gpr(op)
        if gpr:
            (gprname, port) = gpr
            b.append(wb_add_sig_assign("wb_write_gpr_port%d" % (cur_gpr_wr_port), "1"))
            b.append(wb_add_sig_assign("wb_write_gpr_port%d_reg" % (cur_gpr_wr_port), gprname))
            b.append(wb_add_sig_assign("wb_write_gpr_port%d_from" % (cur_gpr_wr_port), port))
            b.append("`UNLOCK_GPR_PORT%d(%s)" % (cur_gpr_wr_port, gprname))
            cur_gpr_wr_port += 1
            continue
        # - Misc, might do other stuff...

        # - Might write SR (indexed by value in R1)
        sr = wb_write_sr(op)
        if sr:
            # This is an implicit write-of-reg-indexed-by-R1, from data in given port (currently only R0)
            b.append(wb_add_sig_assign("wb_write_sr", "1"))
            b.append(wb_add_sig_assign("wb_write_sr_from", sr))
            assert(genlock)
            assert(len(ops_list) == 1)
            b.append("`UNLOCK_GENERIC")
            continue

        if op != "":
            fatal("WB: Unhandled op '%s'" % op)

    return b

################################################################################

# Look for an A= style string, classifying the access type and transforming
# the RHS to an accessor macro name
def de_port_read_template(op, port, sprs, srs = None):
    r = re.match(r"%s=(.*)" % port, op)
    if not r:
        return None
    optype = None
    rval = r.group(1)
    if rval in immediate_fields:
        optype = "imm"
        rval = "`DE_IMM_%s" % rval
    elif rval in gpr_src_names:
        if rval == "RA0":
            rval = "RA"
            optype = "GPRZ"
        else:
            optype = "GPR"
        rval = "INST_%s" % rval
    elif rval in sprs:
        optype = "SPR"
        rval = get_spr_from_name(rval)
    elif srs and rval in srs:
        optype = "SR"
        rval = get_sr_from_name(rval)
    return (optype, rval)

def de_porta_read(op):
    return de_port_read_template(op, 'A', sprs_port_a)

def de_portb_read(op):
    return de_port_read_template(op, 'B', sprs_port_b)

def de_portc_read(op):
    return de_port_read_template(op, 'C', sprs_port_c, srs_port_c)

def de_portd_read(op):
    # Port D is a little different: only reads XERCR, might be conditional.
    r = re.match(r"(if\s*\((.*)\)){0,1}\s*D\s*=\s*(.*)", op)
    if not r:
        return None
    # Condition, or None
    cond = r.group(2)
    if cond:
        cond = convert_condition(cond)
    value = r.group(3)
    if value != "XERCR":
        fatal("de_portd_read: Unknown value in op %s" % op)
    return (cond, value)


def gen_de_behaviours(de_ops, genlock, wb_behaviours):
    b = []
    ops_list = [x.strip() for x in de_ops.split(';')]
    # First, make sure that anything written in WB gets locked appropriately.
    # Could do this properly but a quick hack is to trust UNLOCK* and simply
    # LOCK things that are UNLOCKed in WB.
    #
    # NOTE: the implementation of that must cope with reading a reg in DE that's
    # written in WB!
    #
    for w in wb_behaviours:
        r = re.match(r"`(UNLOCK_GENERIC|UNLOCK_LR_IF\(.*\)|UNLOCK_XERCR_IF\(.*\)|UNLOCK_SPR\(.*\))", w)
        if r:
            b.append("`" + r.group(1).replace("UNLOCK", "LOCK"))
        r = re.match(r"`UNLOCK_GPR_PORT[0-9]\((.*)\)", w)
        if r:
            b.append("`LOCK_GPR(%s)" % r.group(1))

    if genlock:
        b.append(de_add_sig_assign("de_depends_generic", 1))

    for op in ops_list:
        pfns = [(de_porta_read, "a"),
                (de_portb_read, "b"),
                (de_portc_read, "c")]
        foundport = False
        for fn, portname in pfns:
            # Port might read a reg, or an immediate value:
            port = fn(op)
            if port:
                (optype, opname) = port
                if optype == "GPR":
                    b.append(de_add_sig_assign("de_port%s_type" % portname, "`DE_GPR"))
                    b.append(de_add_sig_assign("de_port%s_read_gpr_name" % portname, opname))
                elif optype == "GPRZ":
                    b.append(de_add_sig_assign("de_port%s_type" % portname, "`DE_GPR"))
                    b.append(de_add_sig_assign("de_port%s_read_gpr_name" % portname, opname))
                    b.append(de_add_sig_assign("de_port%s_checkz_gpr" % portname, "`CHECK_" + opname))
                elif optype == "imm":
                    # This selects an immediate by name (presumably to drive a mux).
                    b.append(de_add_sig_assign("de_port%s_type" % portname, "`DE_IMM"))
                    b.append(de_add_sig_assign("de_port%s_imm_name" % portname, opname))
                elif optype == "SPR":
                    b.append(de_add_sig_assign("de_port%s_type" % portname, "`DE_SPR"))
                    b.append(de_add_sig_assign("de_port%s_read_spr_name" % portname, opname))
                else:
                    fatal("Port %s read optype %s (op %s) unhandled" % (portname.upper(), optype, op))
                foundport = True
                break
        if foundport:
            continue

        portd = de_portd_read(op)
        if portd:
            (cond, opname) = portd
            if not cond:
                cond = '1'
            if opname == "XERCR":  # Always true
                b.append(de_add_sig_assign("de_portd_xercr_enable_cond", cond))
            else:
                fatal("Port D read opname %s (op %s) unhandled" % (opname, op))
            continue

        # Or, might trigger DE FSM for multi-cycle ops:
        if op in de_fsm_triggers:
            b.append(de_add_sig_assign("de_fsm_op", "`DE_" + op.upper()))
            continue

        # Or, is flagged as an illegal op/generates fault FC_*:
        if op.startswith("FC_"):
            b.append(de_add_sig_assign("de_gen_fault_type", "`" + op))
            continue

        if op != "":
            fatal("DE: Unhandled op '%s'" % op)

    return b

################################################################################

def exe_int_op(op):
    r = re.match(r"(R[012])\s*=\s*(misc_cntlzw_a|sxt_8_a|sxt_16_a|D_TO_CR|D_TO_XER|MSR|sh_.*|div_.*|mul_.*|alu_.*)", op)
    return None if not r else (r.group(1), "`EXOP_" + r.group(2).upper())


def exe_brdest_op(op):
    r = re.match(r"(R[012])\s*=\s*(br_dest.*)", op)
    return None if not r else (r.group(1), "`EXOP_" + r.group(2).upper())


def exe_brcond_op(op):
    r = re.match(r"(br_.*annul(\((T|C|1),\s*(Z|NZ|1)\)){0,1})", op)
    if not r:
        return None
    cond = r.group(2)
    if cond:
        crc = r.group(3)
        cdc = r.group(4)
        # transform input syntax, like (T|C|1), (Z|NZ|1), to an enum:
        crc = crc.replace("1", "ONE").replace("0", "ZERO")
        cdc = cdc.replace("1", "ONE").replace("0", "ZERO")
        cond = "BRCOND_%s_%s" % (crc, cdc)
    else:
        cond = 'BRCOND_AL'
    return (r.group(1), "`EXOP_" + cond)


def exe_cr_op(op):
    # Syntax here:
    # Examples:  Rc_SO, Rc_SO_CA, cr_or_abc
    # Rc        Conditional on Rc field
    # SO        Conditional on SO field
    # RcA       Always record
    # CA        Always update carry
    # cr_       condreg op
    r = re.match(r"RC\s*=\s*(.*)", op)
    if not r:
        return None
    opts = r.group(1)
    # There are a small number of combinations that use a macro to decode
    # instruction fields into the minimal required operation.
    if (opts == "Rc" or opts == "Rc_CA" or opts == "Rc_SO" or opts == "Rc_SO_CA"):
        return "`EVAL_EXOP_%s" % opts.upper()
    else:
        # The 'always' operation leads to an 'Rc' op
        opts = opts.replace("RcA", "Rc")
        return "`EXOP_" + opts.upper()


def exe_pthru_op(op):
    r = re.match(r"(R[012])\s*=\s*(A|B|B\[7:4\]|C)", op)
    # These are passthru ops; the final mux treats them as a unit, similar
    # to e.g. output of ALU:
    return None if not r else (r.group(1), "`EXUNIT_PORT_" + r.group(2))


def exe_special_op(op):
    r = re.match(r"(R0)\s*=\s*(debug)", op)
    return None if not r else "`EXOP_DEBUG"


def exe_pcinc_op(op):
    r = re.match(r"(R[12])\s*=\s*(PC4)", op)
    return None if not r else (r.group(1), "`EXUNIT_PCINC")


def gen_check_dup_output(s, o):
    assert(o not in s)
    s.add(o)


def gen_exe_behaviours(exe_ops):
    b = []
    ops_list = [x.strip() for x in exe_ops.split(';')]

    # Simple assert/duplicate detection:
    output_ops = dict()
    outputs = set()
    brcond_ops = False

    for op in ops_list:
        # Many of the operations have a lot in common (output a value):
        unit_operations = { (exe_int_op, "exe_int_op", "INT"),
                            (exe_brdest_op, "exe_brdest_op", "BRDEST"),
        }

        found_op = False
        for unit in unit_operations:
            (fn, sig, uname) = unit
            op_match = fn(op)
            if op_match:
                (dest, unit_op) = op_match
                assert(unit_op not in output_ops)
                output_ops[unit_op] = True
                gen_check_dup_output(outputs, dest)
                # Signals
                b.append(exe_add_sig_assign(sig, unit_op))
                b.append(exe_add_sig_assign("exe_%s" % dest, "`EXUNIT_" + uname))
                found_op = True
                break
        if found_op:
            continue

        # Condition reg logicals, condition generation:
        cr = exe_cr_op(op)
        if cr:
            gen_check_dup_output(outputs, "RC")
            b.append(exe_add_sig_assign("exe_rc_op", cr))
            continue

        # Branch condition evaluation
        brcond = exe_brcond_op(op)
        if brcond:
            assert(not brcond_ops)
            (dest, brcond_op) = brcond
            b.append(exe_add_sig_assign("exe_brcond", brcond_op))
            brcond_ops = True
            continue

        # Passthrus
        pthru = exe_pthru_op(op)
        if pthru:
            (dest, src) = pthru
            gen_check_dup_output(outputs, dest)
            b.append(exe_add_sig_assign("exe_%s" % dest, src))
            continue

        # Special/debug
        special = exe_special_op(op)
        if special:
            # Hard-wided, don't support anything other than R0
            b.append(exe_add_sig_assign("exe_special", special))
            b.append(exe_add_sig_assign("exe_R0" , "`EXUNIT_SPECIAL"))
            continue

        # PC increment
        pcinc = exe_pcinc_op(op)
        if pcinc:
            (dest, src) = pcinc
            b.append(exe_add_sig_assign("exe_%s" % dest, src))
            continue

        if op != "":
            fatal("EXE: Unhandled op '%s'" % op)

    return b

################################################################################

def mem_pthru_op(op):
    r = re.match(r"(R[01])", op)
    return None if not r else r.group(1)


def mem_newpc_op(op):
    r = re.match(r"newpc\s*=\s*(.*)", op)
    return None if not r else "`MEM_" + r.group(1)


def mem_newmsr_op(op):
    r = re.match(r"newmsr\s*=\s*(.*)", op)
    return None if not r else "`MEM_" + r.group(1)

# Mem, TLBI, DC, IC all generate types of mem_op:
def mem_mem_op(op):
    r = re.match(r"(L|S)(8|16|32)((_BS|_RSV){0,1})", op)
    return None if not r else (r.group(1).replace("L", "`MEM_LOAD").replace("S", "`MEM_STORE"),
                               "`MEM_OP_SIZE_" + r.group(2), r.group(3))

def mem_tlbi_op(op):
    r = re.match(r"(TLBI.*)", op)
    return None if not r else "`MEM_" + r.group(1)


def mem_dc_op(op):
    r = re.match(r"(DC_INV.*|DC_CINV|DC_CLEAN|DC_BZ)", op)
    return None if not r else "`MEM_" + r.group(1)


def mem_ic_op(op):
    r = re.match(r"(IC_INV.*)", op)
    return None if not r else "`MEM_" + r.group(1)


def mem_sr_op(op):
    r = re.match(r"(SR_READ|SR_WRITE)", op)
    return None if not r else "`MEM_" + r.group(1)


def gen_mem_behaviours(mem_ops):
    b = []
    ops_list = [x.strip() for x in mem_ops.split(';')]
    for op in ops_list:
        # Enables for regs passed through stage:
        pthru = mem_pthru_op(op)
        if pthru:
            b.append(mem_add_sig_assign("mem_pass_%s" % pthru, 1))
            continue

        # Mem ops:
        mop = mem_mem_op(op)
        if mop:
            (mtype, size, options) = mop
            b.append(mem_add_sig_assign("mem_op", mtype))
            b.append(mem_add_sig_assign("mem_op_size", size))
            if options == "_RSV":
                assert(mtype == "`MEM_STORE")
                b.append(mem_add_sig_assign("mem_op_addr_test_reservation", 1))
            elif options == "_BS":
                b.append(mem_add_sig_assign("mem_op_store_bswap", 1))
            elif options:
                fatal("MEM: Option unhandled in %s" % op)
            continue

        # Data cache op
        dc = mem_dc_op(op)
        if dc:
            b.append(mem_add_sig_assign("mem_op", dc))
            continue

        # Instruction cache op
        ic = mem_ic_op(op)
        if ic:
            b.append(mem_add_sig_assign("mem_op", ic))
            continue

        # TLBI
        tlbi = mem_tlbi_op(op)
        if tlbi:
            b.append(mem_add_sig_assign("mem_op", tlbi))
            continue

        # Branch address output:
        npc = mem_newpc_op(op)
        if npc:
            b.append(mem_add_sig_assign("mem_newpc", npc))
            b.append(mem_add_sig_assign("mem_newpc_valid", 1))
            continue

        # New MSR output:
        nmsr = mem_newmsr_op(op)
        if nmsr:
            b.append(mem_add_sig_assign("mem_newmsr", nmsr))
            b.append(mem_add_sig_assign("mem_newmsr_valid", 1))
            continue

        # TW(T) trap generation:
        if op == "test_trap_R1_RC":
            b.append(mem_add_sig_assign("mem_test_trap_enable", 1))
            continue

        # Inhibit fault
        if op == "nofault":
            b.append(mem_add_sig_assign("mem_op_fault_inhibit", 1))
            continue

        # Reservation set:
        if op == "RZV":
            b.append(mem_add_sig_assign("mem_op_addr_set_reservation", 1))
            continue

        # SegReg access:
        sr = mem_sr_op(op)
        if sr:
            b.append(mem_add_sig_assign("mem_sr_op", sr))
            continue

        if op != "":
            fatal("MEM: Unhandled op '%s'" % op)

    return b

################################################################################

# Special cases for sub-decoded instructions
# Return (fieldname, val), where fieldname is spr or BO depending on name/class and val is of the format 0b[01x]+
def determine_subdecode(subdec, name, spr, BO):
    if subdec != "1":
        return (None, None)
    field_name = None
    valstring = None
    compare = None
    if name in subdecode_uses_bo:
        field_name = "BO"
        valstring = BO
    elif name in subdecode_uses_spr:
        field_name = "spr"
        valstring = spr
    else:
        fatal("Unsupported subdecode case for instr %s" % (name))

    # Output one of two things;
    # (number, 0)    ->  simply compare field_name with the number.
    # (number, mask) ->  compare number with (field & ~mask)
    #
    # val could be a decimal int, hex or a binary bitmask with 0b prefix.  Normalise all to the latter:
    mask = 0
    val = 0

    try:
        val = int(valstring, 0)
    except ValueError:
        # OK, it's (probably) binary with x bits; parse that and make a mask where 1=dontcare:
        if not re.match(r"0b[01x]*", valstring):
            fatal("Bad number/val %s" % (valstring))
        val = int(valstring.replace("x", "0"), 0)
        mask = int(valstring.replace("1", "0").replace("x", "1"), 0)

    # SPR field is, in the instruction, composed of two swapped 5-bit fields:
    if field_name == "spr":
        val = ((val >> 5) & 0x1f) | ((val << 5) & 0x3e0)
        mask = ((mask >> 5) & 0x1f) | ((mask << 5) & 0x3e0)

    return (field_name, (val, mask))


################################################################################

# Largely used as a struct
class Instruction:
    def __init__(self, name, fmt, comment, de_behaviours, exe_behaviours, \
                 mem_behaviours, wb_behaviours, form):
        self.name = name
        self.fmt = fmt
        self.comment = comment
        self.de_behaviours = de_behaviours
        self.exe_behaviours = exe_behaviours
        self.mem_behaviours = mem_behaviours
        self.wb_behaviours = wb_behaviours
        self.form = form

    def gen_verilog(self, indent, verbose = False):
        if verbose:
            print indent + " Instruction '%s':" % self.name
        s = indent + "/* " + self.fmt + " " + self.comment + " */\n"
        s += indent + "name = \"%s\";\n" % self.name
        s += indent + "/* DE:  */  "
        for sig in self.de_behaviours:
            s += "  %s;" % (sig)
        s += "\n"
        s += indent + "/* EXE: */  "
        for sig in self.exe_behaviours:
            s += "  %s;" % (sig)
        s += "\n"
        s += indent + "/* MEM: */  "
        for sig in self.mem_behaviours:
            s += "  %s;" % (sig)
        s += "\n"
        s += indent + "/* WB:  */  "
        for sig in self.wb_behaviours:
            s += "  %s;" % (sig)
        s += "\n"
        return s


def parse_csv_input(csv_file, verbose = False):
    # Return data:
    #
    # Opcode to list-of-sub-opcodes dict:
    opcodes = dict()

    # An entry is indexed by primary opcode (31:26), and consists of a
    # tuple (a, b) where:
    # a = None: b is an Instruction object
    # a = (start, len):  a describes a sub-opcode, b is another dict
    #     whose entries are indexed by sub-opcodes at pos start+len
    # The hierarchy of opcodes/decode is reflected in this tree.
    top_level_instrs = dict()

    for idx, row in enumerate(read_csv(csv_file)):
        name = row['Name']
        form = row['Form']
        classname = row['Class']
        opc = row['Opcode']
        x_opc = row['XO']
        subdec = row['Subdec']
        dec_spr = row['spr']
        dec_bo = row['BO']

        has_rc = row['Rc']
        has_oe = row['SO'] # fixme name
        has_aa = row['AA']
        has_lk = row['LK']

        privilege = row['Priv']
        genlock = True if row['Lock'] == '1' else False
        de = row['DE_OP']
        exe = row['EXE_OP']
        mem = row['MEM_OP']
        wb = row['WB_OP']

        if form != '' and opc != '':
            # The subdec field is blank, 0 or 1.
            # The line is ignored for software/ISS purposes if 1.
            # The line is ignored for hardware/RTL decode purposes if 0.
            if subdec == "0":
                continue

            if opc != '':
                opc = int(opc)
            else:
                continue

            # Optional extended opcode:
            if x_opc != '':
                x_opc = int(x_opc)
            else:
                x_opc = -1

            # Ignore some delicately-specified instructions and just
            # invoke a fault:
            if name in bodge_out:
                de = "FC_ILL_HYP"
                exe = ""
                mem = ""
                wb = ""

            if verbose:
                print "%d: %s %s:%s %s" % (idx, name, opc, x_opc, subdec)
                print "\t\t %s %s %s %s %s %s " % (has_rc, has_oe, has_aa, has_lk, privilege, genlock)
                print "\t\t %s ||| %s ||| %s ||| %s " % (de, exe, mem, wb)

            # FIXME: Check privilege
            # FIXME: class="Synthetic"
            #   Dunno what to do there; must be flagged as "do not decode" in traditional way,
            #   but then DE clearly has some work to do.  Try by hand (small number of)?

            wb_behaviours = gen_wb_behaviours(wb, genlock)
            mem_behaviours = gen_mem_behaviours(mem)
            exe_behaviours = gen_exe_behaviours(exe)
            # This is last, as it observes things other stages need.
            de_behaviours = gen_de_behaviours(de, genlock, wb_behaviours)

            if verbose:
                for b in de_behaviours:
                    print " DE:\t%s" % (b)
                for b in exe_behaviours:
                    print " EXE:\t%s" % (b)
                for b in mem_behaviours:
                    print " MEM:\t%s" % (b)
                for b in wb_behaviours:
                    print " WB:\t%s" % (b)

            # If sd_check_fieldname != None, this instruction shares
            # opc/x_opc with others but is distinguished by the field
            # sd_check_fieldname which must match val.  Val is a binary 0b string
            # with 0,1,x.  The possibility of dontcare values means this should
            # end up as series of if() else blocks.
            (sd_check_fieldname, sd_val) = determine_subdecode(subdec, name, dec_spr, dec_bo)

            if sd_check_fieldname:
                sd_data = (TAG_SUB, sd_check_fieldname, dict())

            # Instruction might have any number of fields that must match, e.g.:
            # Opc, x_opc, {spr, BO}
            # x_opc is common ... it has an over-optimised 'implied' form below; it'd be more orthogonal
            # to use (TAG_XOPC, (fieldname, dict[xopc]))
            #
            # The following decodes are possible:
            #  A opcodes[major_opcode] -> (TAG_INST, inst info)
            #  B opcodes[major_opcode] -> (TAG_SUB, subdecode fieldname, dict_of[field_value] -> (TAG_INST, inst info) )
            #  C opcodes[major_opcode] -> (TAG_XOPC, form, dict_of[x_opcode] -> (TAG_INST, inst info) )
            #  D opcodes[major_opcode] -> (TAG_XOPC, form, dict_of[x_opcode] -> (TAG_SUB, subdecode fieldname, dict_of[field_value] -> (TAG_INST, inst info)))

            # Verilog output:
            inst_primary_opcode = "{0:06b}".format(opc)
            inst_format = inst_primary_opcode + "??????????????????????????"
            inst_comment = name + ": %s-form, Op %d " % (form, opc)
            # A list of tuples containing decode fields for this instr, in
            # most-to-least significant order:
            inst_decode = [((26, 6), inst_primary_opcode)]

            if form == "X" or form == "XL" or form == "XFX":
                inst_format = inst_format[0:21] + "{0:010b}".format(x_opc) + inst_format[31:]
                inst_comment += " XOp %d " %(x_opc)
                inst_secondary_opcode = "{0:010b}".format(x_opc)
                inst_decode.append(((1, 10), inst_secondary_opcode))
            elif form == "XO":
                inst_format = inst_format[0:22] + "{0:09b}".format(x_opc) + inst_format[31:]
                inst_comment += " XOp %d " %(x_opc)
                inst_secondary_opcode = "?{0:09b}".format(x_opc)
                inst_decode.append(((1, 10), inst_secondary_opcode))

            if sd_check_fieldname != None:
                (mval, mmask) = sd_val
                if sd_check_fieldname == "BO":
                    # Assemble BO value/mask arrangement into bits/x:
                    mval = "{0:05b}".format(mval)
                    mmask = "{0:05b}".format(mmask)
                    val_string = ""
                    for (valbit, maskbit) in zip(mval, mmask):
                        val_string += "?" if maskbit == "1" else valbit
                    inst_format = inst_format[0:6] + val_string + inst_format[11:]
                    inst_comment += " BO/mask %s/%s " %(mval, mmask)
                    inst_decode.append(((21, 5), val_string))
                elif sd_check_fieldname == "spr":
                    # Assemble spr value/mask arrangement into bits/x:
                    mval = "{0:010b}".format(mval)
                    mmask = "{0:010b}".format(mmask)
                    val_string = ""
                    for (valbit, maskbit) in zip(mval, mmask):
                        val_string += "?" if maskbit == "1" else valbit
                    inst_format = inst_format[0:11] + val_string + inst_format[21:]
                    inst_comment += " spr/mask %s/%s " %(mval, mmask)
                    inst_decode.append(((11, 10), val_string))
                else:
                    print "WARN:  Unknown subdecode fieldname %s, not decoded!" % (sd_check_fieldname)

            inst_obj = Instruction(name, inst_format, inst_comment, \
                                   de_behaviours, exe_behaviours, mem_behaviours, wb_behaviours, \
                                   form)

            # Rotate the inst_decode list, the instr's ordered decode fields, into a tree of
            # top-down decode values (which is later traversed to build the decoder):
            l = top_level_instrs
            cur_msk_start = 26
            cur_msk_len = 6

            while True:                         # Do
                decd_info = inst_decode.pop(0)
                # The current level of this instruction's decode: opcode value
                # within mask start/len span:
                ((msk_start, msk_len), opc_str) = decd_info

                if msk_start != cur_msk_start or msk_len != cur_msk_len:
                    fatal("Masks don't match for opcode %s (%d+%d), instr %s: start %d, len %d" \
                          % ((opc_str, msk_start, msk_len, name, cur_msk_start, cur_msk_len)))

                # If there's more sub-decoding to do, get the list and loop
                if len(inst_decode) != 0:
                    if opc_str not in l:
                        # We're the first pass to want a sub-decode on this opcode, init an empty
                        # dict associated with the mask range of the sub-decode/next level:
                        ((sub_msk_start, sub_msk_len), _) = inst_decode[0]
                        l[opc_str] = ((sub_msk_start, sub_msk_len), dict())

                    # Get the list of instrs at this level:
                    (sub_mask, sub_list) = l[opc_str]
                    if sub_mask is None:
                        fatal("Expected an existing mask for opcode %s (%d+%d), instr %s!" \
                              % (opc_str, cur_msk_start, cur_msk_len, name))

                    (cur_msk_start, cur_msk_len) = sub_mask
                    l = sub_list
                    continue                    # While more levels

                else:
                    # The instruction is a leaf in the current dict's level of decode
                    if opc_str not in l:
                        l[opc_str] = inst_obj
                        break
                    else:
                        # This might indicate two instructions share decode fields
                        # up to a point, but that one doens't have a sub-decode that
                        # the other has.
                        fatal("Opcode %s (%d+%d) already used for instr %s!" \
                              % (opc_str, cur_msk_start, cur_msk_len, name))

    return (opcodes, top_level_instrs)

################################################################################

def gen_verilog_condition_term(msb, lsb, string):
    sl = len(string)
    if sl == 1:
        return "instruction[%d] == 1'b%s" % (msb, string)
    else:
        return "instruction[%d:%d] == %d'b%s" % (msb, lsb, sl, string)

# Return a string suitable for an if() condition, given a bit range (opc_start
# for opc_len bits) and a casez-style 0/1/? match string in opc.
# Where wildcards are used, multiple AND terms are generated with direct
# sub-field comparisons.
def gen_verilog_condition(opc_start, opc_len, opc):
    # In the simplest case, the opcode doesn't use any wildcards:
    if opc.find('?') < 0:
        return "instruction[%d:%d] == %d'b%s" % \
            (opc_start + opc_len-1, opc_start, opc_len, opc)

    # Otherwise, we have work to do.  Split the opcode string into a list of
    # tuples of (bitnumber, len, value) where value is a string of 0, 1s:
    l = []
    cur_str = ""
    out_terms = []
    opcs = list(opc)
    msb = opc_start + opc_len - 1

    print("+++ Starting scan of cond %s %d:%d" % (opc, opc_start+opc_len-1, opc_start))
    while len(opcs) > 0:
        ch = opcs.pop(0)
        if ch == '?':
            sl = len(cur_str)
            if sl > 0:
                # Save the previous term, as its span has finished:
                term = gen_verilog_condition_term(msb, msb - sl + 1, cur_str)
                out_terms.append(term)
                print("Finished field, " + term)
                cur_str = ""
            msb -= sl + 1
            print("Finished field, msb now %d" % (msb))
        else:
            # Increase the current term:
            cur_str += ch
    sl = len(cur_str)
    if sl > 0:
        term = gen_verilog_condition_term(msb, msb - sl + 1, cur_str)
        out_terms.append(term)
        print("Final field " + term)

    # Using that list of bitfield & match values, we can generate
    # "if (a[10:9] == 10 && a[7:5] == 010 ..."-style condition terms:
    s = ""
    for t in out_terms:
        if s != "":
            s += " && "
        s += "(" + t + ")"
    return ("/* [%d:%d] = %s */ " % (opc_start + opc_len - 1, opc_start, opc)) + s


# Recursive function to depth-first traverse the opcode tree:
def gen_verilog_iterate_ilist(itree, opc_st, opc_len, level):
    s = ""
    idt = '\t'*level
    ft = "de_gen_fault_type = `FC_PROG_ILL;"
    first = True
    # Experiment: Chain of ifs at top level any better than nested casezs?
    # What about no cases (only ifs)?
#    makeCase = True if level != 0 else False
#    makeCase = True # Case always
#    makeCase = False # If-then-else always
    # FIXME: Configure this from commandline, as may want to be different
    # for different tool flows!
    makeCase = False if level != 0 else True

    if makeCase:
        s += idt + "casez(instruction[%d:%d])\n" % (opc_st+opc_len-1, opc_st)

    iidt = idt + '\t'

    for opc in itree:
        if makeCase:
            s += "\n" + idt + "%d'b%s: begin\n" % (opc_len, opc)
        else:
            cond = gen_verilog_condition(opc_st, opc_len, opc)
            s += (idt if first else "else ") + "if (" + cond + ") begin\n"

        opc_entry = itree[opc]

        # Each entry in the dict (indexed by opcode) is either a leaf
        # Instruction, or a tuple describing a new span of bits to decode,
        # and a list of sub-opcode values of these bits (with corresponding
        # instructions, or further spans to decode).
        if isinstance(opc_entry, Instruction):
            s += opc_entry.gen_verilog(idt + "\t")
        else:
            # It's a tuple describing a new sub-range to decode!
            ((new_opc_st, new_opc_len), new_l) = opc_entry
            # Iterate through the sub-list
            s += gen_verilog_iterate_ilist(new_l, new_opc_st, new_opc_len, level + 1)
        s += "\n" + idt + "end "
        if makeCase:
            s += "\n"
        if first:
            first = False

    if makeCase:
        s += "\n" + idt + "default:\n" + iidt + ft + "\n\n"
        s += idt + "endcase\n"
    else:
        s += "else begin\n" + iidt + ft + "\n" + idt + "end\n"

    return s

def gen_verilog_decode_switch(itree, verbose = False):
    switch_stmt = ""

    # Initial values of all signals:
    for sig in sorted(total_sigs):
        sigsize = get_signal_size(sig)
        sigval = get_signal_default(sig)
        if not sigval:
            switch_stmt += "\t%s = %d'b%s;\n" % (sig, sigsize, "0" * sigsize)
        else:
            switch_stmt += "\t%s = %s;\n" % (sig, sigval)
    switch_stmt += "\n"

    # Start traversing the opcode tree from the primary opcode [31:26]
    switch_stmt += gen_verilog_iterate_ilist(itree, 26, 6, 0)

    return switch_stmt

################################################################################

def help():
    print "Syntax: this.py [options] <defs.csv>"
    print "\t-h\t\t- Help"
    print "\t-v\t\t- Verbose"
    print "\t-i \"string\"\t- Includes added to generated files"
    print "\t-d <file>\t- Output Verilog decoder to file"
    print "\t-s <file>\t- Output Verilog signal definitions to file"


################################################################################
################################################################################
################################################################################
################################################################################


# Parse command-line args:

verbose = False
include_string = ""
verilog_decoder_file = ""
verilog_sigdefs_file = ""

try:
    opts, args = getopt.getopt(sys.argv[1:], "hvi:d:s:")
except getopt.GetoptError as err:
    help()
    fatal("Invocation error: " + str(err))

for o, a in opts:
    if o == "-h":
        help()
        sys.exit()
    elif o == "-v":
        verbose = True
    elif o == "-i":
        include_string = a
    elif o == "-d":
        verilog_decoder_file = a
    elif o == "-s":
        verilog_sigdefs_file = a
    else:
        help()
        fatal("Unknown option?")

if len(args) > 0:
    input_file = args[0]
else:
    help()
    fatal("Input file required");


################################################################################

# Do the work:

(opcodes, instr_tree) = parse_csv_input(input_file, verbose)

# After crunching all of the input, we can make a list of all of the state that decode will set up:
total_sigs = de_sigs | exe_sigs | mem_sigs | wb_sigs

if verbose:
    pp = pprint.PrettyPrinter(indent=4)
    pp.pprint(opcodes)

verilog_sw = gen_verilog_decode_switch(instr_tree, verbose)

print "\nDE assigns signals:"
for w in de_sigs:
    print "  %s" % (w)

print "\nEXE assigns signals:"
for w in exe_sigs:
    print "  %s" % (w)

print "\nMEM assigns signals:"
for w in mem_sigs:
    print "  %s" % (w)

print "\nWB assigns signals:"
for w in wb_sigs:
    print "  %s" % (w)

print "WB stage inputs (from which a write might occur):"
for w in wb_ports.keys():
    print "  %s" % (wb_ports[w])

################################################################################

# TODO include_string
if verilog_decoder_file:
    with open(verilog_decoder_file, "w") as output:
        output.write(verilog_sw)

if verilog_sigdefs_file:
    siglist = "`ifndef AUTOSIGDEFS_VH\n"
    siglist += "`define AUTOSIGDEFS_VH\n\n"
    siglist += "`define DEC_AUTO_SIGS_DECLARE \\\n"
    siglist += "/* verilator lint_off UNUSED */\\\n"
    total_size = 0
    for x in sorted(total_sigs):
        sigsize = get_signal_size(x)
        siglist += "reg %s\t%s;  \\\n" % ("\t" if sigsize == 1 else "[%d:0] " % (sigsize-1), x)
        total_size += sigsize

    siglist += "/* verilator lint_on UNUSED */\\\n"
    siglist += "if (0)\n\n"       # Permits ; after statement
    siglist += "`define DEC_AUTO_SIGS_SIZE %d\n\n" % (total_size)

    bundle_list = ""
    for x in sorted(total_sigs):
        bundle_list += x + ", "
    # HACK: remove final ", "
    bundle_list = bundle_list[:-2]

    # Generate defines for spans for the sigs within the bundle:
    bitpos = 0
    reversedsigs = sorted(total_sigs)
    reversedsigs.reverse()
    for x in reversedsigs:
        sigsize = get_signal_size(x)
        if sigsize == 1:
            siglist += "`define DEC_RANGE_%s  %d\n" % (x.upper(), bitpos)
        else:
            siglist += "`define DEC_RANGE_%s  %d:%d\n" % (x.upper(), bitpos+sigsize-1, bitpos)
        bitpos += sigsize

    siglist += "\n"

    siglist += "`define DEC_AUTO_SIGS_BUNDLE %s\n" % (bundle_list)

    siglist += "\n`endif\n"
    with open(verilog_sigdefs_file, "w") as output:
        output.write(siglist)

################################################################################
