#ifndef TESTBENCH_H
#define TESTBENCH_H

/* Based on TB class from https://zipcpu.com/blog/2017/06/21/looking-at-verilator.html
 *
 * Alterations for MR-hw verilator build are (c) 2020 Matt Evans
 */

#include <stdlib.h>
#include <inttypes.h>
#include "Vwrapper_top.h"
#include "verilated.h"
#include "verilated_vcd_c.h"
#include "Vwrapper_top__Syms.h"


template<class MODULE>	class TESTBENCH {
	uint64_t	m_tickcount;
	MODULE	*m_core;
        VerilatedVcdC	*m_trace;
public:
	TESTBENCH(void) {
		m_trace = 0;
		m_core = new Vwrapper_top;
		m_tickcount = 0l;
                Verilated::traceEverOn(true);
	}

        MODULE *getTop() { return m_core; }

	virtual	void	opentrace(const char *vcdname) {
		if (!m_trace) {
			m_trace = new VerilatedVcdC;
			m_core->trace(m_trace, 99);
			m_trace->open(vcdname);
		}
	}

	// Close a trace file
	virtual void	close(void) {
		if (m_trace) {
			m_trace->close();
			m_trace = NULL;
		}
	}

	virtual ~TESTBENCH(void) {
		delete m_core;
		m_core = NULL;
	}

	virtual void	reset(void) {
		m_core->reset = 1;
		// Make sure any inheritance gets applied
		this->tick();
		this->tick();
		this->tick();
		this->tick();
		m_core->reset = 0;
	}

	virtual void	tick(void) {
		// Increment our own internal time reference
		m_tickcount++;

		// Make sure any combinatorial logic depending upon
		// inputs that may have changed before we called tick()
		// has settled before the rising edge of the clock.
                //		m_core->clk = 0;
                //		m_core->eval();
		// if(m_trace) m_trace->dump(10*m_tickcount-2);
                // ME: No comb inputs (for now!)

		// Toggle the clock

		// Rising edge
		m_core->clk = 1;
		m_core->eval();

		if(m_trace) m_trace->dump((vluint64_t)(10*m_tickcount));

		// Falling edge
		m_core->clk = 0;
		m_core->eval();

                if (m_trace) {
			// This portion, though, is a touch different.
			// After dumping our values as they exist on the
			// negative clock edge ...
			m_trace->dump((vluint64_t)(10*m_tickcount+5));
			//
			// We'll also need to make sure we flush any I/O to
			// the trace file, so that we can use the assert()
			// function between now and the next tick if we want to.
			m_trace->flush();
		}
	}

	virtual bool	done(void) { return (Verilated::gotFinish()); }

        uint64_t get_tickcount() { return m_tickcount; }
};

#endif
