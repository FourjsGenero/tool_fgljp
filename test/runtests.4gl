IMPORT os
IMPORT FGL testutils

MAIN
  DEFINE fgljp STRING
  LET fgljp="..",os.Path.separator(),"fgljp"
  --test GAS mode
  CALL testutils.checkRUN(fgljp || " test")
  --test fgljp gives back the exit code of the program it launched
  CALL testutils.checkRUNExitCode(fgljp || " exitcode fail", 3)
  CALL testutils.checkRUNExitCode(fgljp || " exitcode ok", 0)
  --test remote mode
  CALL os.Path.delete("test.start") RETURNING status 
  RUN fgljp ||" -v -l test.log -o test.start -X" WITHOUT WAITING
  CALL testutils.readStartFile("test.start")
  --CALL fgl_setenv("FGLGUIDEBUG","1")
  CALL testutils.checkRUN("fglrun test")
  CALL testutils.testPatternInFile("fgljp FINISH", "test.log", 5)
  CALL testutils.checkRUN(fgljp || " fttest")
  --the resource URLs the VM publishes must survive a proxy or a forwarded
  --port between the browser and fgljp
  CALL testutils.checkRUN(fgljp || " urlprefix")
END MAIN
