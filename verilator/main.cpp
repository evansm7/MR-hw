/*
 * Copyright 2020-2022 Matt Evans
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <stdlib.h>
#include <unistd.h>
#include "testbench.h"

TESTBENCH<Vwrapper_top> *tb;

double sc_time_stamp ()
{
        return tb->get_tickcount();
}

static void print_help(char *nom)
{
	fprintf(stderr, "Syntax:\n\t%s [-t <VCD filename>]\n",
		nom);
}

/* Tracing:
 * Since I'm using --trace on the command-line, can use $dumpfile/$dumpvars.
 *
 * Or, starting tracing in C, as below.
 */

int main(int argc, char **argv)
{
	char *exe_name = argv[0];
	char ch;

	Verilated::commandArgs(argc, argv);
        tb = new TESTBENCH<Vwrapper_top>();

	while ((ch = getopt(argc, argv, "t:h")) != -1) {
                switch (ch) {
                        case 't':
				printf("Writing VCD trace to %s\n", optarg);
				// The docs claim using $dumpfile works; I get
				// an unsupp PLI error.  This enables VCD
				// output:
				tb->opentrace(optarg);
                                break;

			case 'h':
			default:
				print_help(exe_name);
				return 1;
		}
	}

	//////////////////////////////////////////////////////////////////////

        tb->reset();

	while(!tb->done()) {
		tb->tick();
#ifdef EXIT_B_SELF
		// If a valid instruction with IRQs off
		if (tb->getTop()->tb_top->TMCT->CPU->decode_valid &&
		    !(tb->getTop()->tb_top->TMCT->CPU->DE->decode_msr_r & 0x00008000) &&
		    (tb->getTop()->tb_top->TMCT->CPU->DE->decode_instr_r == 0x48000000)) {
			printf("*** Branch to self: Exiting\n");
			break;
		}
#endif
	}

        printf("Complete:  Committed %d instructions, %d stall cycles, %lld cycles total\n",
               tb->getTop()->tb_top->TMCT->CPU->WB->counter_instr_commit,
               tb->getTop()->tb_top->TMCT->CPU->WB->counter_stall_cycle,
               tb->get_tickcount());

        exit(EXIT_SUCCESS);
}

