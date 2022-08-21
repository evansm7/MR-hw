#!/usr/bin/env python3
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


if len(sys.argv) == 3:
    input_file = sys.argv[1]
    patch_value = sys.argv[2]
else:
    print("Syntax:\n\t %s  <mos.bin> <start address>" % sys.argv[0])
    sys.exit(1)

address = int(patch_value, 0)

abin = struct.pack(">I", address)

with open(input_file, 'r+b') as f:
    f.seek(0xfff8)
    f.write(abin)

print("Patched start address to %x" % (address))


