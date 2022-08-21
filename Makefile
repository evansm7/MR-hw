# Makefile for MR-hw
#
# Copyright 2020-2022 Matt Evans
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# Licensed under the Solderpad Hardware License v 2.1 (the “License”); you may
# not use this file except in compliance with the License, or, at your option,
# the Apache License version 2.0. You may obtain a copy of the License at
#
#  https://solderpad.org/licenses/SHL-2.1/
#
# Unless required by applicable law or agreed to in writing, any work
# distributed under the License is distributed on an “AS IS” BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.
#

SRC_PATH = src
INC_PATH = include
IVERILOG = iverilog
IVFLAGS = -g2009

# -y$(XILINX_SIMPATH)
PATHS=-y include -y src -y tb -I include -I tb
DEFS=-DSIM

VERILOG_SOURCES = ifetch.v decode.v execute.v memory.v writeback.v
VERILOG_SOURCES += decode_inst.v
VERILOG_SOURCES += cache.v
VERILOG_SOURCES += mr_cpu_mic.v mr_cpu_top.v

VERIDEFS =

EXIT_B_SELF ?= 1
ifeq ($(EXIT_B_SELF), 1)
	VERIDEFS += -DEXIT_B_SELF=1
endif


all:	build_deps run_tb_top

unit:	build_deps tb_decode_inst.vcd tb_ifetch.vcd tb_ifetch2.vcd tb_itlb_icache.vcd

.PHONY: build_deps
build_deps:	include/auto_decoder.vh include/auto_decoder_signals.vh testprog.hex

# Keep *.vcd around:
# .SECONDARY:	tb_top.vcd

%.wave: %.vcd
	gtkwave $<

%.vcd:	%.vvp
	vvp $<

################################################################################

include/auto_decoder.vh:	tools/PPC.csv
	./tools/mk_decode.py -d $@ $<

include/auto_decoder_signals.vh:	tools/PPC.csv
	./tools/mk_decode.py -s $@ $<

testprog.hex: testprog.bin
	./tools/mk_hex.py $< $@

################################################################################
# Tests

# Main integrated CPU test:
tb_top.vvp:	tb/tb_top.v tb/tb_mr_cpu_top.v src/decode_inst.v build_deps
	$(IVERILOG) $(IVFLAGS) $(DEFS) $(PATHS) -o $@ $<

verilate_tb_top: build_deps tb/wrapper_top.v verilator/testbench.h verilator/main.cpp
	verilator -Mdir verilator/obj_dir -Wall -Wno-fatal --trace --timescale 1ns/1ns -j 4 -cc tb/wrapper_top.v -Iinclude/ -Isrc/ -Itb/ -CFLAGS "-O3 -flto" -CFLAGS "$(VERIDEFS)" --exe ../main.cpp
	(cd verilator/obj_dir ; make -f Vwrapper_top.mk -j 4)
	@echo "\nEXE is:  ./verilator/obj_dir/Vwrapper_top"

run_tb_top: verilate_tb_top
	@echo "\nRunning verilated build:\n"
	time ./verilator/obj_dir/Vwrapper_top

# Unit tests, in varying stages of completeness:
tb_decode_inst.vvp:	tb/tb_decode_inst.v src/decode_inst.v
	$(IVERILOG) $(IVFLAGS) $(DEFS) $(PATHS) -o $@ $^

tb_ifetch.vvp:	tb/tb_ifetch.v src/ifetch.v src/itlb_icache.v
	$(IVERILOG) $(IVFLAGS) $(DEFS) $(PATHS) -o $@ $^

tb_ifetch2.vvp:	tb/tb_ifetch2.v src/ifetch.v src/itlb_icache.v
	$(IVERILOG) $(IVFLAGS) $(DEFS) $(PATHS) -o $@ $^

tb_itlb_icache.vvp:	tb/tb_itlb_icache.v src/itlb_icache.v
	$(IVERILOG) $(IVFLAGS) $(DEFS) $(PATHS) -o $@ $^

tb_execute_clz.vvp:	tb/tb_execute_clz.v src/execute_clz.v
	$(IVERILOG) $(IVFLAGS) $(DEFS) $(PATHS) -o $@ $^

tb_rotatemask.vvp:	tb/tb_rotatemask.v src/execute_rotatemask.v
	$(IVERILOG) $(IVFLAGS) $(DEFS) $(PATHS) -o $@ $^

tb_dp_ram.vvp:	tb/tb_dp_ram.v src/dp_ram.v
	$(IVERILOG) $(IVFLAGS) $(DEFS) $(PATHS) -o $@ $^

tb_cache.vvp:  tb/tb_cache.v src/cache.v
	$(IVERILOG) $(IVFLAGS) $(DEFS) $(PATHS) -o $@ $^

tb_execute_divide.vvp:	tb/tb_execute_divide.v src/execute_divide.v
	$(IVERILOG) $(IVFLAGS) $(DEFS) $(PATHS) -o $@ $^

tb_plc.vvp:	tb/tb_plc.v src/plc.v
	$(IVERILOG) $(IVFLAGS) $(DEFS) $(PATHS) -o $@ $^

################################################################################

clean:
	rm -rf include/auto_*.vh *.vvp *.vcd verilator/obj_dir
