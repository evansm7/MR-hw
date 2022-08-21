#!/usr/bin/env python3
#
# This script takes an input verilog module and creates a wrapper for it
# which drives all inputs from a crappy shift register, and consolidates
# all outputs to a single bit.  This can then be used for a synthesis test
# to get reasonable timing estimates, not encumbered by external pin count.
#
# Inspired by http://fpgacpu.ca/fpga/Synthesis_Harness_Input.html
# but auto-generated, so no bit-counting is required by the human.
#
# Important: Run with already-preprocessed input, e.g. iverilog -E in -o out
#
# ME 23/3/2020
#
# Copyright 2020 Matt Evans
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

import re
import sys


clk_net_name = "clk"  # FIXME, parameter

################################################################################

def read_file_chomp(path):
    with open(path, 'r') as data:
        d = []
        for line in data:
            line = line.rstrip()
            # Remove //-style comments:
            line = re.sub('//.*$', '', line)
            if line != '':
                d.append(line)
        return d


def find_module_decl(input_lines):
    module = None
    inputs = list()
    outputs = list()

    for l in input_lines:
        # print(l)
        r = re.match(r".*module\s([^ (]+)\((.*)\)", l)
        if r:
            module = r.group(1)
            params = r.group(2)

            print("Found module '%s':" % module)
            # print("Module %s, params '%s'" % (module, params))
            # OK, now split out dem inputs/outputs:
            plist = params.split(',')

            # Sanitise the list a little
            plist = [x.strip() for x in plist]

            for param in plist:
                if param.find("input") != -1:
                    inputs.append(param)
                elif param.find("output") != -1 :
                    outputs.append(param)
                else:
                    print("*** Unknown parameter type '%s', ignoring" % param)
            break
    return (module, inputs, outputs)


def count_signals(signal_list):
    total_size = 0
    signal_out_list = list()
    for i in signal_list:
        r = re.match(r"(input|output)\s(wire|reg)\s(\[(.*):(.*)\]){,}\s(.*)", i)
        if r:
            vec = r.group(3)
            vec_hi = r.group(4)
            vec_lo = r.group(5)
            name = r.group(6).strip()

            if vec == None:
                sigsize = 1
            else:
                sigsize = eval(vec_hi) - eval(vec_lo) + 1

            print("Signal %s\t size %d (%s)" % (name, sigsize, vec))
            total_size += sigsize
            signal_out_list.append((name, sigsize))
        else:
            print("Can't split signal '%s'!" % i)
            return (None, None)
    return (total_size, signal_out_list)


################################################################################

if len(sys.argv) == 3:
    input_file = sys.argv[1]
    output_file = sys.argv[2]
else:
    print("Syntax:\n\t %s  <input.v> <output_toplevel.v>" % sys.argv[0])
    sys.exit(1)


f = read_file_chomp(input_file)

# Objective:  Find the module definition and generate a list of inputs and outputs:
# Join into one huge line, then re-split lines at ';'
longline = " ".join(f)
# Remove /* .. */ comments:
longline = re.sub('/\*.*?\*/', '', longline)
a = longline.split(';')

(module, inputs, outputs) = find_module_decl(a)

if not module:
    print("Boohoo, didn't find a module declaration!");
    sys.exit(1)

# OK, now we have a list of inputs/outputs.  Count bits in 'em:
(total_input_size, input_list) = count_signals(inputs)

if total_input_size == None:
    print("*** Gone wrong, damn.")
    sys.exit(1)

got_clk = False
# Look for special nets (clk):
for i in input_list:
    (name, size) = i
    if name == clk_net_name:
        got_clk = True
        break

if got_clk:
    print("Found %s" % clk_net_name)
    total_input_size -= 1

(total_output_size, output_list) = count_signals(outputs)

if total_output_size == None:
    print("*** Gone wrong, damn.")
    sys.exit(1)

print("Total inputs %d bits;  total outputs %d bits" % (total_input_size, total_output_size))


# Let's generate us some verilog.

rtl = "module toplevel(input wire clk, input wire shift_clk, input wire shift_en, input wire shift_in, output wire obit);\n\n"

# The clock does not come from the shift reg, it comes from a dedicated (fast) input:
if total_input_size > 1:
    rtl += "    reg [%s:0] input_sreg_a;\n" % (total_input_size-1)
    rtl += "    reg [%s:0] input_sreg;\n\n" % (total_input_size-1)
    rtl += "    always @(posedge shift_clk) begin\n"
    rtl += "        if (shift_en) input_sreg_a[%s:0] <= {input_sreg_a[%s:0], shift_in};\n" % (total_input_size-1, total_input_size-2)
    rtl += "    end\n\n"
    rtl += "    always @(posedge clk) begin\n"
    rtl += "        input_sreg <= input_sreg_a;\n"
    rtl += "    end\n\n"
elif total_input_size == 1:
    rtl += "    reg input_sreg_a;\n"
    rtl += "    reg input_sreg;\n\n"
    rtl += "    always @(posedge shift_clk) begin\n"
    rtl += "        if (shift_en) input_sreg_a <= shift_in;\n"
    rtl += "    end\n\n"
    rtl += "    always @(posedge clk) begin\n"
    rtl += "        input_sreg <= input_sreg_a;\n"
    rtl += "    end\n\n"
else:
    # No inputs.  Weird but whatever.
    rtl += "    // No inputs!"

if total_output_size > 0:
    rtl += "    wire [%s:0] oval;\n" % (total_output_size-1)
    rtl += "    reg [%s:0] output_reg;\n\n" % (total_output_size-1)
    rtl += "    always @(posedge clk) begin\n" # Note, fast clock
    rtl += "        output_reg[%s:0] <= oval[%s:0];\n" % (total_output_size-1, total_output_size-1)
    rtl += "    end\n\n"

    rtl += "    assign obit = ^output_reg;\n\n"
else:
    # Again, this would be weird...
    rtl += "    // No outputs!"

rtl += "    %s DUT(\n" % (module)

# Wire up inputs:
current_bit = 0
comma = False
if got_clk:
    rtl += "        .%s(%s),\n" % (clk_net_name, clk_net_name)

for i in input_list:
    (name, size) = i

    # Special nets generated above
    if name == clk_net_name:
        continue

    if size == 1:
        rtl += "    %s    .%s(input_sreg[%s])\n" % \
            (',' if comma else '', name, current_bit)
    else:
        rtl += "    %s    .%s(input_sreg[%s:%s])\n" % \
            (',' if comma else '', name, current_bit + size - 1, current_bit)
    comma = True
    current_bit += size

# Wire up outputs:
current_bit = 0
for i in output_list:
    (name, size) = i
    if size == 1:
        rtl += "    %s    .%s(oval[%s])\n" % \
            (',' if comma else '', name, current_bit)
    else:
        rtl += "    %s    .%s(oval[%s:%s])\n" % \
            (',' if comma else '', name, current_bit + size - 1, current_bit)
    comma = True
    current_bit += size

rtl += "        );\n\n"

# Condense outputs
rtl += "endmodule"

with open(output_file, "w") as output:
    output.write(rtl)

print("Success lol -- created %s" % output_file)
