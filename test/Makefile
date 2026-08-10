#GNU and nmake compatible
.SUFFIXES: .4gl .42m .per .42f

.4gl.42m:
	fglcomp -M -r -W all $<

.per.42f:
	fglform -M $<


all: testutils.42m test.42m test.42f interrupt.42f runtests.42m wait_for_fgljp_start.42m fttest.42m exitcode.42m parsetcl_test.42m quotevmstr_test.42m

wait_for_fgljp_start.42m: testutils.42m

test.42m: testutils.42m test.42f

runtests.42m: test.42m test.42f fttest.42m exitcode.42m

# unit test for the fgljp Tcl AUI scanner (imports fgljp.42m from ..)
parsetcl_test.42m: parsetcl_test.4gl ../fgljp.42m
	FGLLDPATH=.. fglcomp -M -r -W all parsetcl_test.4gl

# unit test for quoteVMStr (imports fgljp.42m from ..)
quotevmstr_test.42m: quotevmstr_test.4gl ../fgljp.42m
	FGLLDPATH=.. fglcomp -M -r -W all quotevmstr_test.4gl

../fgljp.42m: ../fgljp.4gl ../mygetopt.42m ../URI.42m
	cd .. && fglcomp -M -r -W all fgljp.4gl

../mygetopt.42m: ../mygetopt.4gl
	cd .. && fglcomp -M -r -W all mygetopt.4gl

../URI.42m: ../URI.4gl
	cd .. && fglcomp -M -r -W all URI.4gl

test: all
	-killall fglrun
	FGLLDPATH=.. FGL_LENGTH_SEMANTICS=BYTE fglrun parsetcl_test
	FGLLDPATH=.. FGL_LENGTH_SEMANTICS=CHAR fglrun parsetcl_test
	FGLLDPATH=.. FGL_LENGTH_SEMANTICS=BYTE fglrun quotevmstr_test
	FGLLDPATH=.. FGL_LENGTH_SEMANTICS=CHAR fglrun quotevmstr_test
	FGL_LENGTH_SEMANTICS=BYTE fglrun runtests
	FGL_LENGTH_SEMANTICS=CHAR fglrun runtests

clean: 
	rm -f *.42? *.4gl~ *.log 'logo?.png' tt
	rm -rf priv cacheFT FT

