#!/usr/bin/env python
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

import sys
import struct


if len(sys.argv) != 3:
    print("thing <in> <out>")
    sys.exit(1)

infile = sys.argv[1]
outfile = sys.argv[2]

with open(infile, mode='rb') as file:
    filebin = file.read()


#Interpret as BE uints:

m = list()
outdata = ""

while len(filebin) > 3:
    (i, ) = struct.unpack("<I", filebin[:4])
    m.append(i)
    filebin = filebin[4:]

while len(m) > 1:
    outdata += "%08x%08x\n" % (m[1], m[0])
    m = m[2:]

if len(m) != 0:
    outdata += "00000000%08x\n" % (m[0])


with open(outfile, mode='w') as file:
    file.write(outdata)
