#GNU make
.SUFFIXES: .4gl .42m .per .42f

.4gl.42m:
	fglcomp -M -r -W all $<

.per.42f:
	fglform -M $<

ifdef windir
WINDIR=$(windir)
endif
ifdef WINDIR
SLEEP=timeout
FGLJP=fgljp
define _path
$(subst /,\,$(1))
endef

else

SLEEP=sleep
FGLJP=./fgljp
define _path
$(1)
endef

endif
ifdef VERBOSE
  VERBOSEARG=-v
endif

all: fgljp.42m mygetopt.42m runonserver.42m getgdcpath.42m fglssh.42m URI.42m

demo: fgljp.42m interrupt.42f demo.42m demo.42f simple.42m
	$(FGLJP) $(VERBOSEARG) demo.42m a b

test/wait_for_fgljp_start.42m:
	make -C test

#starts the demo in file transfer mode in one rush
demoft: fgljp.42m demo.42m demo.42f test/wait_for_fgljp_start.42m
	rm -f demoft.txt
ifdef WINDIR
	cmd /c start $(FGLJP) --startfile demoft.txt -X
else
	$(FGLJP) --startfile demoft.txt -X &
endif
	cd test&&fglrun wait_for_fgljp_start ../demoft.txt&&cd ..
	fglrun demo.42m a b

fgldeb_demo: fgljp.42m fgldeb demo.42m demo.42f test/wait_for_fgljp_start.42m
	rm -f demoft.txt
ifdef WINDIR
	cmd /c start $(FGLJP) --startfile demoft.txt -X
else
	$(FGLJP) --startfile demoft.txt -X &
endif
	cd test&&fglrun wait_for_fgljp_start ../demoft.txt&&cd ..
	$(call _path,fgldeb/fgldeb) demo a b

fgldeb:
	git clone https://github.com/FourjsGenero/tool_fgldeb fgldeb
	make -C fgldeb

rundemo: demo.42m demo.42f
	fglrun demo.42m a b

demogmi: fgljp.42m demo.42m demo.42f
	$(FGLJP) -r demo.42m a b

demogdc: fgljp.42m demo.42m demo.42f
	GDC=1 ./fgljp -v -g demo.42m a b

tests:
	make -C test test

format:
	rm -f *.4gl~
	fglcomp -M --format --fo-inplace mygetopt.4gl
	fglcomp -M --format --fo-inplace fgljp.4gl
	fglcomp -M --format --fo-inplace fglssh.4gl
	fglcomp -M --format --fo-inplace demo.4gl
	fglcomp -M --format --fo-inplace URI.4gl

clean_prog:
	rm -f fgljp.42m mygetopt.42m

clean: clean_prog
	rm -f *.42? *.4gl~
	rm -rf priv cacheFT
	rm -f upload*.png
	$(MAKE) -C test clean

distclean: clean
	rm -rf fgldeb

echo:
	echo "fgljp:$(FGLJP)"

dist: all 
