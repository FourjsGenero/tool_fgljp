IMPORT util
IMPORT os

PUBLIC TYPE TStartEntries RECORD
  port INT,
  FGLSERVER STRING,
  pid INT,
  url STRING
END RECORD

DEFINE _pid INT

FUNCTION isWin()
  RETURN os.Path.separator()=="\\"
END FUNCTION

FUNCTION checkRUN(cmd STRING)
  DEFINE code INT
  RUN cmd RETURNING code
  IF code THEN
    CALL myErr(SFMT("RUN '%1' did fail", cmd))
  END IF
END FUNCTION

#+ like checkRUN(), but checks for a specific exit code instead of just
#+ "zero means success" (used to check that fgljp gives back the exit code
#+ of the program it launched, not just whether it failed).
#+ On UNIX, RETURNING gives back the raw wait() status (exit code * 256 +
#+ signal), not the plain exit code - decode it the same way the RUN
#+ instruction's own doc example (runBatch()) does.
FUNCTION checkRUNExitCode(cmd STRING, expected INT)
  DEFINE code INT
  RUN cmd RETURNING code
  IF NOT isWin() THEN
    LET code = code / 256
  END IF
  IF code <> expected THEN
    CALL myErr(SFMT("RUN '%1' returned %2, expected %3", cmd, code, expected))
  END IF
END FUNCTION

FUNCTION myErr(errstr STRING)
  DEFINE ch base.Channel
  DEFINE cmd STRING
  LET ch = base.Channel.create()
  CALL ch.openFile("<stderr>", "w")
  CALL ch.writeLine(
      SFMT("ERROR:%1 stack:\n%2", errstr, base.Application.getStackTrace()))
  CALL ch.close()
  IF _pid IS NOT NULL AND _pid>0 THEN
    LET cmd = SFMT("kill %1", _pid)
    DISPLAY "kill fgljp:", cmd
    RUN cmd
  END IF
  EXIT PROGRAM 1
END FUNCTION

FUNCTION readFile(fname STRING)
  DEFINE t TEXT
  DEFINE s STRING
  LOCATE t IN FILE fname
  LET s = t
  RETURN s
END FUNCTION

FUNCTION readStartFile(fname STRING)
  DEFINE s STRING
  DEFINE entries TStartEntries
  DEFINE i INT
  FOR i = 1 TO 5
    LET s = readFile(fname)
    LET s = s.trim()
    DISPLAY "s:",s
    TRY
      CALL util.JSON.parse(s, entries)
      LET _pid = entries.pid
      DISPLAY "_pid:",_pid 
      RETURN 
    CATCH
      DISPLAY "wait for _pid ..." --,err_get(status)
      SLEEP 1
    END TRY
  END FOR
  CALL myErr(SFMT("fgljp didn't create the start file '%1'", fname))
END FUNCTION

FUNCTION testPatternInFile(pat STRING, fname STRING, numtries INT)
  DEFINE s STRING
  DEFINE i INT
  FOR i = 1 TO numtries
    LET s = readFile(fname)
    IF s.getIndexOf(pat, 1) > 0 THEN
      RETURN
    END IF
    SLEEP 1
  END FOR
  CALL myErr(SFMT("did not find pattern '%1' in '%2'", pat, fname))
END FUNCTION
