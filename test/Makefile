#GNU and nmake compatible
.SUFFIXES: .4gl .42m .per .42f

.4gl.42m:
	fglcomp -M -r -W all $<

.per.42f:
	fglform -M $<


all: testutils.42m test.42m test.42f interrupt.42f runtests.42m wait_for_fgljp_start.42m fttest.42m exitcode.42m

wait_for_fgljp_start.42m: testutils.42m

test.42m: testutils.42m test.42f

runtests.42m: test.42m test.42f fttest.42m exitcode.42m

test: all
	-killall fglrun
	fglrun runtests

clean: 
	rm -f *.42? *.4gl~ *.log 'logo?.png' tt
	rm -rf priv cacheFT FT

