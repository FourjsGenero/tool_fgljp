#+ fgljp fgl GAS/remote proxy using the new Genero binary channel API
OPTIONS
SHORT CIRCUIT
&define MYASSERT(x) IF NOT NVL(x,0) THEN CALL myErr("ASSERTION failed in line:"||__LINE__||":"||#x) END IF
&define MYASSERT_MSG(x,msg) IF NOT NVL(x,0) THEN CALL myErr("ASSERTION failed in line:"||__LINE__||":"||#x||","||msg) END IF
&define UNUSED_VAR(variable) IF (variable) IS NULL THEN END IF
&define NO_JAVA
IMPORT os
IMPORT util
IMPORT FGL mygetopt
IMPORT FGL URI
CONSTANT _keepalive =
    FALSE --if set to TRUE http socket connections are kept alive, needed for safari browser close
--TODO sometimes Safari blocks after fgl_putfile() if keepalive is true
DEFINE _useJSWrapper BOOLEAN --whether we use the 'native' embed mode in GBC
--set after the first GBC is loaded
--note: mixing GBC's in remote mode gives undefined behavior for now
DEFINE _localhost STRING --is either 'localhost' or '127.0.0.1'

PUBLIC TYPE TStartEntries RECORD
  port INT,
  FGLSERVER STRING,
  pid INT,
  url STRING
END RECORD

TYPE TStringDict DICTIONARY OF STRING
TYPE TStringArr DYNAMIC ARRAY OF STRING

CONSTANT S_INIT = "Init"
CONSTANT S_HEADERS = "Headers"
CONSTANT S_WAITCONTENT = "WaitContent"
CONSTANT S_WAITFORFT = "WaitForFT"
CONSTANT S_ACTIVE = "Active"
CONSTANT S_WAITFORVM = "WaitForVM"
CONSTANT S_HTTPHANDLER = "HttpHandler"
CONSTANT S_FINISH = "Finish"
CONSTANT PUTFILE_DELIVERED = "!!!!__putfile_delivered__!!!"

CONSTANT CLIENT_CLOSE = "close\n"
CONSTANT CLIENT_INTERRUPT = "interrupt\n"

CONSTANT APP_COOKIE = "GENERO_APP"
CONSTANT SID_COOKIE = "GENERO_SID"

CONSTANT GO_OUT = TRUE
CONSTANT CLOSED = TRUE

PUBLIC TYPE F_customHeaderFunc FUNCTION(hdrs DYNAMIC ARRAY OF STRING)

TYPE FTGetImage RECORD
  name STRING,
  num INT,
  cache BOOLEAN,
  node om.DomNode,
  fileSize INT,
  mtime INT,
  ft2 BOOLEAN,
  httpIdx INT
END RECORD

TYPE FTList DYNAMIC ARRAY OF FTGetImage

--record holding the state of an initial
--or HTTP connection
--isHTTP is set: its a HTTP connection
TYPE TConn RECORD
  id INT,
  active BOOLEAN,
  chan base.Channel,
  state STRING,
  starttime DATETIME HOUR TO FRACTION(1),
  isHTTP BOOLEAN, --followed by http specific members
  procId STRING, --VM procId
  sessId STRING, --session Id
  path STRING,
  query STRING,
  queryDict TStringDict,
  method STRING,
  body STRING,
  appCookie STRING,
  sidCookie STRING,
  cdattachment BOOLEAN,
  headers TStringDict,
  customHeaderFunc F_customHeaderFunc,
  contentLen INT,
  contentType STRING,
  clitag STRING,
  newtask BOOLEAN,
  isSSE BOOLEAN,
  isMeta BOOLEAN,
  keepalive BOOLEAN,
  idx INT,
  ftLockFile BOOLEAN,
  retry BOOLEAN
END RECORD

--record holding the state of a VM connection
TYPE TVMRec RECORD
  id INT,
  active BOOLEAN,
  chan base.Channel,
  state STRING,
  starttime DATETIME HOUR TO FRACTION(1),
  vmVersion FLOAT, --vm reported version
  RUNchildren TStringArr, --program RUN children procId's
  RUNchildIdx INT, --current RUN child index
  httpIdx INT, --http connection waiting
  VmCmd STRING, --last VM cmd
  wait BOOLEAN, --token for socket communication
  toVMCmd STRING, --cmd buffer if VM socket is waiting
  FTV2 BOOLEAN, --VM has filetransfer V2
  FTFC BOOLEAN, --VM has filetransfer FrontCall
  useSSE BOOLEAN, --we communicate using the SSE protocol
  ftNum INT, --current FT num
  writeNum INT, --FT id1
  writeNum2 INT, --FT id2
  writeCPut base.Channel,
  writeC base.Channel,
  procId STRING, --VM procId
  procIdParent STRING, --VM procIdParent
  procIdParentWaiting STRING, --VM procIdParentWaiting
  procIdWaiting STRING, --VM procIdWaiting
  programName STRING,
  frontEndID STRING,
  sessId STRING, --session Id
  didSendVMClose BOOLEAN,
  closeSeen BOOLEAN, --client did send close
  FTs FTList, --list of running file transfers
  --meta STRING,
  clientMetaSent BOOLEAN,
  isMeta BOOLEAN,
  vmputfile STRING,
  cliputfile STRING,
  ftEndCmd STRING,
  vmgetfile STRING,
  vmgetfilenum INT,
  doc om.DomDocument, --aui tree
  aui DYNAMIC ARRAY OF om.DomNode, --node storage
  rnFTNodeId INT, --pending FT node id
  vmidx INT --index in the array
END RECORD

PUBLIC TYPE I_HttpHandler INTERFACE
  httpHandler(x TConn INOUT) RETURNS BOOLEAN,
  log(msg STRING),
  exit()
END INTERFACE

--Parser token types
CONSTANT TOK_None = 0
CONSTANT TOK_Number = 1
CONSTANT TOK_Value = 2
CONSTANT TOK_Ident = 3

--encapsulation command types
CONSTANT TAuiData = 1
--CONSTANT TPing=2
CONSTANT TInterrupt = 3
CONSTANT TCloseApp = 4
CONSTANT TFileTransfer = 5

--FT command sub numbers
CONSTANT FTPutFile = 1
CONSTANT FTGetFile = 2
CONSTANT FTBody = 3
CONSTANT FTEof = 4
CONSTANT FTStatus = 5
CONSTANT FTAck = 6
CONSTANT FTOk = 0 --// Success
DEFINE FT2Str DYNAMIC ARRAY OF STRING

--FT Status codes
CONSTANT FStErrSource = 4 --, // Error with source file (read)
CONSTANT FStErrDestination = 5 --, // Error with destination file (write)
--               FStErrInterrupt = 1, // Interrupted (DVM)
--               FStErrSock =2, // Socket Error (Can't happen...)
--               FStErrAborted = 3, // Aborted
--               FStErrInvState= 6, // Invalide State (DVM)
--               FStErrNotAvail= 7

DEFINE _htdelegate I_HttpHandler
DEFINE _s DYNAMIC ARRAY OF TConn --virgin and HTTP connections
DEFINE _v DYNAMIC ARRAY OF TVMRec --VM connections
-- keep track of RUN WITHOUT WAITING children
DEFINE _RWWchildren DICTIONARY OF TStringArr
DEFINE _stdoutNONL STRING

DEFINE _opt_port STRING
DEFINE _opt_startfile STRING
DEFINE _opt_logfile STRING
DEFINE _opt_autoclose BOOLEAN
DEFINE _opt_any BOOLEAN
DEFINE _opt_gdc BOOLEAN
DEFINE _opt_runonserver BOOLEAN
DEFINE _opt_nostart BOOLEAN
DEFINE _opt_clearcache BOOLEAN
DEFINE _opt_kiosk_mode BOOLEAN
DEFINE _logChan base.Channel
DEFINE _opt_program, _opt_program1 STRING
DEFINE _verbose BOOLEAN
DEFINE _selDict DICTIONARY OF INTEGER --maps procId's to vm index
DEFINE _lastVM INT --last VM index active
DEFINE _checkGoOut BOOLEAN
DEFINE _starttime DATETIME HOUR TO FRACTION(1)
DEFINE _stderr base.Channel
DEFINE _newtasks INT
DEFINE _firstPath STRING
DEFINE _sidCookie STRING --protection cookie
DEFINE _sidCookieSent BOOLEAN

CONSTANT size_i = 4 --sizeof(int)

DEFINE _isMac BOOLEAN
DEFINE _askedOnMac BOOLEAN
DEFINE _gbcdir STRING
DEFINE _gbcver FLOAT
DEFINE _owndir STRING
DEFINE _privdir STRING
DEFINE _pubdir STRING
DEFINE _progdir STRING
DEFINE _htpre STRING
DEFINE _port INT
DEFINE _server base.Channel
DEFINE _channels DYNAMIC ARRAY OF base.Channel
DEFINE _didAcceptOnce BOOLEAN
DEFINE _fglserver STRING
DEFINE _fglfeid STRING
DEFINE _numWaitingParent INT
DEFINE _lockMap TStringDict
DEFINE _numId INT
DEFINE _direct_mode BOOLEAN

--Parser state record
TYPE TclP RECORD
  pos INT,
  buf STRING,
  number INT,
  value STRING,
  valueStart INT,
  ident STRING,
  active BOOLEAN
END RECORD

DEFINE _p TclP

MAIN
  DEFINE chan base.Channel
  DEFINE port, idx INT
  DEFINE htpre STRING
  DEFINE priv, pub STRING
  LET _starttime = CURRENT
  IF fgl_getenv("VERBOSE") IS NOT NULL THEN
    LET _verbose = TRUE
  END IF
  CALL parseArgs()
  LET _direct_mode = _opt_program IS NULL
  --'localhost' is sloow with Chrome/Edge on Windows
  --probably due to IPv6 probing
  LET _localhost = IIF(isWin(), "127.0.0.1", "localhost")
  LET _opt_kiosk_mode = fgl_getenv("KIOSK") IS NOT NULL
  LET _sidCookie = genSID(FALSE)
  IF _opt_clearcache THEN
    CALL clearCache()
  END IF
  LET _fglserver = fgl_getenv("FGLSERVER")
  IF _opt_program IS NOT NULL AND _opt_port IS NULL THEN
    LET port = 8787
    LET _opt_autoclose = TRUE
  ELSE
    LET port = IIF(_opt_port IS NOT NULL, parseInt(_opt_port), 6400)
  END IF
  LET port = findFreePortL(IIF(port == 0, 1025, port), NOT _opt_any)
  LET _port = port
  --DISPLAY "port:", port
  LET _server = base.Channel.create()
  CALL _server.openServerSocket("127.0.0.1", port, "u")
  IF _direct_mode THEN
    CALL writeStartFile(port)
  END IF
  IF fgl_getenv("FGLJPSSH_PARENT") == "1" THEN
    DEFER INTERRUPT
  END IF
  CALL log(
      SFMT("listening on real port:%1,FGLSERVER:%2",
          port, fgl_getenv("FGLSERVER")))
  LET htpre = SFMT("http://" || _localhost || ":%1/", port)
  LET _htpre = htpre
  LET priv = htpre, "priv/"
  LET pub = htpre
  LET _owndir = os.Path.fullPath(os.Path.dirName(arg_val(0)))
  IF _opt_program IS NOT NULL THEN
    CALL checkGBCAvailable()
    CALL setup_program(_opt_program1, priv, pub)
  END IF
  LET _channels[1] = _server
  WHILE (idx := util.Channels.select(_channels)) <> 0
    CALL log(SFMT("select() did return idx:%1", idx))
    --DISPLAY "idx:",idx
    IF idx == 1 THEN
      CALL acceptNew()
    ELSE
      LET chan = _channels[idx]
      CALL handleConnection(chan)
    END IF
    IF _didAcceptOnce AND _checkGoOut AND canGoOut() THEN
      EXIT WHILE
    END IF
  END WHILE
  --give a small statistic about global container objects
  CALL log(
      SFMT("fgljp FINISH, _s:%1,_v:%2,_selDict:%3,_RWWchildren:%4",
          util.JSON.stringify(_s),
          util.JSON.stringify(_v),
          util.JSON.stringify(_selDict),
          util.JSON.stringify(_RWWchildren)))
END MAIN

FUNCTION findFreePortL(startport, local)
  DEFINE startport INT
  DEFINE local BOOLEAN
  DEFINE ch base.Channel
  DEFINE port INT
  LET ch = base.Channel.create()
  FOR port = startport TO 65535
    TRY
      CALL ch.openServerSocket(IIF(local, "127.0.0.1", NULL), port, "u")
      --DISPLAY "bound port ok:", port
      CALL ch.close() --chance is high that we get this port
      RETURN port
    CATCH
      --DISPLAY SFMT("findFreePort: can't bind port %1:%2", port, err_get(status))
    END TRY
  END FOR
  CALL myErr(
      SFMT("findFreePort:Can't find free port for start port:%1", startport))
  RETURN NULL
END FUNCTION

FUNCTION printVIdx(vmidx INT) RETURNS STRING
  RETURN printV(_v[vmidx])
END FUNCTION

FUNCTION printV(v TVMRec INOUT) RETURNS STRING
  DEFINE diff INTERVAL MINUTE TO FRACTION(1)
  IF NOT _verbose THEN
    RETURN ""
  END IF
  LET diff = CURRENT - v.starttime
  RETURN SFMT("{VM id:%1 vmidx:%2 s:%3 procId:%4 t:%5 pp:%6 pw:%7 wait:%8 progName:%9}",
      v.id,
      v.vmidx,
      v.state,
      v.procId,
      diff,
      v.procIdParent,
      v.procIdWaiting,
      v.wait,
      v.programName)
END FUNCTION

FUNCTION printSel(x TConn INOUT) RETURNS STRING
  DEFINE diff INTERVAL MINUTE TO FRACTION(1)
  IF NOT _verbose THEN
    RETURN ""
  END IF

  LET diff = CURRENT - x.starttime
  CASE
    WHEN x.isHTTP
      RETURN SFMT("{HTTP id:%1 s:%2 p:%3 q:%4 t:%5 idx:%6, body:%7, ftLockFile:%8 }",
          x.id, x.state, x.path, x.query, diff, x.idx, x.body, x.ftLockFile)
    OTHERWISE
      RETURN SFMT("{_ id:%1 s:%2 t:%3}", x.id, x.state, diff)
  END CASE
END FUNCTION

FUNCTION selDictRemove(procId STRING)
  CALL _selDict.remove(procId)
  CALL log(
      SFMT("selDictRemove after remove procId %1:%2",
          procId, util.JSON.stringify(_selDict.getKeys())))
  LET _checkGoOut = TRUE
END FUNCTION

FUNCTION canGoOut()
  LET _checkGoOut = FALSE
  CALL log(
      SFMT("canGoOut: _selDict.getLength:%1,keys:%2",
          _selDict.getLength(), util.JSON.stringify(_selDict.getKeys())))
  IF _selDict.getLength() == 0 THEN
    CALL log("canGoOut: no VM channels anymore")
    IF _opt_program IS NOT NULL OR _opt_autoclose THEN
      RETURN TRUE
    END IF
  END IF
  RETURN FALSE
END FUNCTION

FUNCTION setup_program_old(priv STRING, pub STRING, port INT)
  DEFINE s, arg1, cmd, fglrun STRING
  DEFINE code INT
  LET _progdir = os.Path.fullPath(os.Path.dirName(_opt_program1))
  LET _pubdir = _progdir
  LET _privdir = os.Path.join(_progdir, "priv")
  CALL os.Path.mkdir(_privdir) RETURNING status
  CALL fgl_setenv("FGLSERVER", SFMT(_localhost || ":%1", port - 6400))
  CALL fgl_setenv("FGL_PRIVATE_DIR", _privdir)
  CALL fgl_setenv("FGL_PUBLIC_DIR", _pubdir)
  CALL fgl_setenv("FGL_PUBLIC_IMAGEPATH", ".")
  CALL fgl_setenv("FGL_PRIVATE_URL_PREFIX", priv)
  CALL fgl_setenv("FGL_PUBLIC_URL_PREFIX", pub)
  IF _fglfeid IS NULL THEN
    LET _fglfeid = genSID(TRUE)
    CALL fgl_setenv("_FGLFEID", _fglfeid)
  END IF
  --CALL fgl_setenv("FGLGUIDEBUG", "1")
  --CALL fgl_setenv("FGLGUIDEBUG", "1")
  --should work on both Win and Unix
  --LET s= "cd ",_progdir,"&&fglrun ",os.Path.baseName(prog)
  LET arg1 = os.Path.fullPath(_opt_program1.trim())
  LET cmd = "fglrun -r ", quote(arg1), IIF(isWin(), ">NUL", " >/dev/null 2>&1")
  --we check if we can deassemble the file, this works for .42m and .42r
  --DISPLAY "cmd:",cmd
  RUN cmd RETURNING code
  --if code is set the 1st arg is not a valid .42m or .42r
  LET fglrun = IIF(code, "", "fglrun ")
  LET s = SFMT("%1%2", fglrun, _opt_program)
  CALL log(SFMT("RUN:'%1' WITHOUT WAITING", s))
  RUN s WITHOUT WAITING
END FUNCTION

FUNCTION setup_program(program1 STRING, priv STRING, pub STRING)
  DEFINE s, arg1, cmd, fglrun STRING
  DEFINE code INT
  VAR progdir = os.Path.fullPath(os.Path.dirName(program1))
  LET _pubdir = os.Path.join(progdir, "pub")
  LET _privdir = os.Path.join(progdir, "priv")
  CALL os.Path.mkdir(_privdir) RETURNING status
  CALL fgl_setenv("FGLSERVER", SFMT(_localhost || ":%1", _port - 6400))
  CALL fgl_setenv("FGL_PRIVATE_DIR", _privdir)
  CALL fgl_setenv("FGL_PUBLIC_DIR", _pubdir)
  CALL fgl_setenv("FGL_PUBLIC_IMAGEPATH", "pub")
  CALL fgl_setenv("FGL_PRIVATE_URL_PREFIX", priv)
  CALL fgl_setenv("FGL_PUBLIC_URL_PREFIX", pub)
  {
  IF _fglfeid IS NULL THEN
    LET _fglfeid = genSID(TRUE)
    CALL fgl_setenv("_FGLFEID", _fglfeid)
  END IF
  }
  --CALL fgl_setenv("FGLGUIDEBUG", "1")
  --CALL fgl_setenv("FGLGUIDEBUG", "1")
  VAR program = program1.trim()
  LET arg1 = os.Path.fullPath(program)
  LET cmd = "fglrun -r ", quote(arg1), IIF(isWin(), ">NUL", " >/dev/null 2>&1")
  --we check if we can deassemble the file, this works for .42m and .42r
  --DISPLAY "cmd:",cmd
  RUN cmd RETURNING code
  --if code is set the 1st arg is not a valid .42m or .42r
  LET fglrun = IIF(code, "", "fglrun ")
  LET s = SFMT("%1%2", fglrun, _opt_program)
  CALL log(SFMT("xRUN:'%1' WITHOUT WAITING", s))
  RUN s WITHOUT WAITING
END FUNCTION

FUNCTION initFT2Str()
  LET FT2Str[FTOk + 1] = "FTOk"
  LET FT2Str[FTPutFile + 1] = "FTPutFile"
  LET FT2Str[FTGetFile + 1] = "FTGetFile"
  LET FT2Str[FTBody + 1] = "FTBody"
  LET FT2Str[FTEof + 1] = "FTEof"
  LET FT2Str[FTStatus + 1] = "FTStatus"
  LET FT2Str[FTAck + 1] = "FTAck"
END FUNCTION

FUNCTION getFT2Str(ftconst INT)
  IF FT2Str.getLength() == 0 THEN
    CALL initFT2Str()
  END IF
  RETURN FT2Str[ftconst + 1]
END FUNCTION

FUNCTION writeStartFile(port INT)
  DEFINE entries TStartEntries
  DEFINE ch base.Channel
  LET entries.port = port
  LET entries.FGLSERVER = SFMT(_localhost || ":%1", port - 6400)
  LET entries.pid = fgl_getpid()
  DISPLAY util.JSON.stringify(entries)
  IF _opt_startfile IS NULL THEN
    RETURN
  END IF
  LET ch = base.Channel.create()
  CALL ch.openFile(_opt_startfile, "w")
  CALL ch.writeLine(util.JSON.stringify(entries))
  CALL ch.close()
END FUNCTION

PRIVATE FUNCTION parseArgs()
  DEFINE gr mygetopt.GetoptR
  DEFINE o mygetopt.GetoptOptions
  DEFINE opt_arg STRING
  DEFINE i, cnt INT

  LET i = o.getLength() + 1
  LET o[i].name = "startfile"
  LET o[i].description =
      "JSON file with start info (port,pid,FGLSERVER) if no program is directly started"
  LET o[i].opt_char = "o"
  LET o[i].arg_type = mygetopt.REQUIRED

  LET i = o.getLength() + 1
  LET o[i].name = "version"
  LET o[i].description = "Version information"
  LET o[i].opt_char = "V"
  LET o[i].arg_type = mygetopt.NONE

  LET i = o.getLength() + 1
  LET o[i].name = "help"
  LET o[i].description = "program help"
  LET o[i].opt_char = "h"
  LET o[i].arg_type = mygetopt.NONE

  LET i = o.getLength() + 1
  LET o[i].name = "verbose"
  LET o[i].description = "detailed log"
  LET o[i].opt_char = "v"
  LET o[i].arg_type = mygetopt.NONE

  LET i = o.getLength() + 1
  LET o[i].name = "port"
  LET o[i].description = "Listening port"
  LET o[i].opt_char = "p"
  LET o[i].arg_type = mygetopt.REQUIRED

  LET i = o.getLength() + 1
  LET o[i].name = "logfile"
  LET o[i].description = "File written for logs and success"
  LET o[i].opt_char = "l"
  LET o[i].arg_type = mygetopt.REQUIRED

  LET i = o.getLength() + 1
  LET o[i].name = "runonserver"
  LET o[i].description =
      "connects GMI/GMA via runonserver to the spawned program (internal dev)"
  LET o[i].opt_char = "r"
  LET o[i].arg_type = mygetopt.NONE

  LET i = o.getLength() + 1
  LET o[i].name = "gdc"
  LET o[i].description = "connects GDC to the spawned program (internal dev)"
  LET o[i].opt_char = "g"
  LET o[i].arg_type = mygetopt.NONE

  LET i = o.getLength() + 1
  LET o[i].name = "nostart"
  LET o[i].description =
      "spawns the program and displays the program URL on stdout"
  LET o[i].opt_char = "n"
  LET o[i].arg_type = mygetopt.NONE

  LET i = o.getLength() + 1
  LET o[i].name = "autoclose"
  LET o[i].description = "If the connecton ends fgljp closes"
  LET o[i].opt_char = "X"
  LET o[i].arg_type = mygetopt.NONE

  LET i = o.getLength() + 1
  LET o[i].name = "clear-cache"
  LET o[i].description = "Clears the file transfer cache"
  LET o[i].opt_char = "x"
  LET o[i].arg_type = mygetopt.NONE

  LET i = o.getLength() + 1
  LET o[i].name = "listen-any"
  LET o[i].description = "fgljp is reachable from outside"
  LET o[i].opt_char = "a"
  LET o[i].arg_type = mygetopt.NONE

  CALL mygetopt.initialize(gr, "fgljp", mygetopt.copyArguments(1), o)
  WHILE mygetopt.getopt(gr) == mygetopt.SUCCESS
    LET opt_arg = mygetopt.opt_arg(gr)
    CASE mygetopt.opt_char(gr)
      WHEN 'V'
        DISPLAY "1.00"
        EXIT PROGRAM 0
      WHEN 'v'
        LET _verbose = TRUE
      WHEN 'h'
        CALL mygetopt.displayUsage(gr, "?program? ?arg? ?arg?")
        EXIT PROGRAM 0
      WHEN 'p'
        LET _opt_port = opt_arg
        CALL parseInt(_opt_port) RETURNING status
      WHEN 'o'
        LET _opt_startfile = opt_arg
      WHEN 'n'
        LET _opt_nostart = TRUE
      WHEN 'l'
        LET _opt_logfile = opt_arg
      WHEN 'g'
        LET _opt_gdc = TRUE
      WHEN 'r'
        LET _opt_runonserver = TRUE
      WHEN 'x'
        LET _opt_clearcache = TRUE
      WHEN 'X'
        LET _opt_autoclose = TRUE
      WHEN 'a'
        LET _opt_any = TRUE
    END CASE
  END WHILE
  IF (cnt := mygetopt.getMoreArgumentCount(gr)) >= 1 THEN
    FOR i = 1 TO cnt
      LET _opt_program = _opt_program, quote(mygetopt.getMoreArgument(gr, i)), " "
      IF i == 1 THEN
        LET _opt_program1 = _opt_program
      END IF
    END FOR
  END IF
END FUNCTION

FUNCTION printStderr(errstr STRING)
  DEFINE ch base.Channel
  LET ch = base.Channel.create()
  CALL ch.openFile("<stderr>", "w")
  CALL ch.writeLine(errstr)
  CALL ch.close()
END FUNCTION

FUNCTION printStdout(str STRING, noNewLine BOOLEAN)
  IF noNewLine THEN
    LET _stdoutNONL = _stdoutNONL, str
  ELSE
    LET str = _stdoutNONL, str
    LET _stdoutNONL = ""
    DISPLAY str
  END IF
END FUNCTION

FUNCTION myErr(errstr STRING)
  CALL printStderr(
      SFMT("ERROR:%1 stack:\n%2", errstr, base.Application.getStackTrace()))
  EXIT PROGRAM 1
END FUNCTION

FUNCTION mkdirp(basedir, path)
  DEFINE basedir, path, part STRING
  DEFINE tok base.StringTokenizer
  LET tok = base.StringTokenizer.create(path, "/")
  LET part = basedir
  WHILE tok.hasMoreTokens()
    LET part = os.Path.join(part, tok.nextToken())
    IF NOT os.Path.exists(part) THEN
      IF NOT os.Path.mkdir(part) THEN
        CALL myErr(SFMT("can't create directory:%1", part))
      ELSE
        --DISPLAY "did mkdir:",part
      END IF
    END IF
    --LET part=part,os.Path.separator()
  END WHILE
END FUNCTION

{
FUNCTION createBufferedReader()
  DEFINE ins InputStream
  DEFINE ir InputStreamReader
  LET ins = _sel.chan.socket().getInputStream()
  --LET ir = InputStreamReader.create(ins,"ISO-8859-1"); --need an 8bit encoding
  LET ir = InputStreamReader.create(ins, "utf-8"); --need an 8bit encoding
  LET _sel.br = BufferedReader.create(ir);
END FUNCTION
}

FUNCTION findFreeSelIdx()
  DEFINE i, len INT
  LET len = _s.getLength()
  FOR i = 1 TO len
    IF NOT _s[i].active THEN
      RETURN i
    END IF
  END FOR
  LET i = len + 1
  RETURN i
END FUNCTION

FUNCTION findFreeVMIdx()
  DEFINE i, len INT
  LET len = _v.getLength()
  FOR i = 1 TO len
    IF NOT _v[i].active THEN
      RETURN i
    END IF
  END FOR
  LET i = len + 1
  RETURN i
END FUNCTION

FUNCTION findIdxForChan(chan base.Channel) RETURNS INT
  RETURN _s.search("chan", chan)
END FUNCTION

FUNCTION findVMIdxForChan(chan base.Channel) RETURNS INT
  RETURN _v.search("chan", chan)
END FUNCTION

FUNCTION acceptNew()
  DEFINE chan base.Channel
  DEFINE c INT
  LET _didAcceptOnce = TRUE
  LET chan = util.Channels.accept(_server)
  IF chan IS NULL THEN
    --CALL log("acceptNew: chan is NULL") --normal in non blocking
    RETURN
  END IF
  LET c = findFreeSelIdx()
  CALL setEmptyConnection(c)
  LET _s[c].state = S_INIT
  LET _s[c].chan = chan
  LET _s[c].starttime = CURRENT
  LET _s[c].active = TRUE
  LET _numId = _numId + 1
  LET _s[c].id = _numId
  LET _channels[_channels.getLength() + 1] = chan
END FUNCTION

FUNCTION removeCR(s STRING)
  IF s.getCharAt(s.getLength()) == '\r' THEN
    LET s = s.subString(1, s.getLength() - 1)
  END IF
  RETURN s
END FUNCTION

FUNCTION splitHTTPLine(s)
  DEFINE a DYNAMIC ARRAY OF STRING
  DEFINE s STRING
  DEFINE t base.StringTokenizer
  LET t = base.StringTokenizer.create(s, ' ')
  LET a[1] = t.nextToken()
  LET a[2] = t.nextToken()
  LET a[3] = t.nextToken()
  RETURN a
END FUNCTION

FUNCTION parseHttpLine(x TConn INOUT, s STRING)
  DEFINE a DYNAMIC ARRAY OF STRING
  DEFINE path STRING
  LET s = removeCR(s)
  LET a = splitHTTPLine(s)
  LET x.method = a[1]
  LET path = a[2]
  IF path.getIndexOf("Disposition=attachment", 1) > 0 THEN
    --DISPLAY "!!!Disposition=attachment for:", s
    LET x.cdattachment = TRUE
    LET x.keepalive = TRUE
  END IF
  VAR qidx = path.getIndexOf("?", 1)
  VAR query = IIF(qidx > 0, path.subString(qidx + 1, path.getLength()), "")
  LET x.query = query
  IF x.query.getIndexOf("%", 1) > 0 THEN
    LET x.query = util.Strings.urlDecode(x.query)
  END IF
  LET path = IIF(qidx > 0, path.subString(1, qidx - 1), path)
  LET x.path = path
  CALL log(SFMT("parseHttpLine:%1 %2", s, printSel(x)))
  IF a[3] <> "HTTP/1.1" THEN
    CALL myErr(SFMT("'%1' must be HTTP/1.1", a[3]))
  END IF
END FUNCTION

FUNCTION setAppCookie(x TConn INOUT, path STRING)
  UNUSED_VAR(path)
  {
  IF _s[x].appCookie IS NOT NULL THEN
    DISPLAY "setAppCookie: IS NOT NULL:",_s[x].appCookie
    RETURN
  END IF
  }
  --DISPLAY "setAppCookie:", printSel(x), ",path:", path
  VAR dict = getQueryDict(x.query)
  --DISPLAY "urlpath:", urlpath
  IF dict.contains("monitor") AND x.path.equals("/gbc/index.html") THEN
    CALL log(SFMT("setAppCookie: monitor seen,appCookie=%1", x.appCookie))
  ELSE
    MYASSERT(dict.contains("app"))
    LET x.appCookie = dict["app"]
  END IF
  --DISPLAY ">>>>set app cookie:", dict["app"]
END FUNCTION

FUNCTION parseCookies(x TConn INOUT, cookies STRING)
  DEFINE tok base.StringTokenizer
  DEFINE c, name, value STRING
  DEFINE idx INT
  LET tok = base.StringTokenizer.create(cookies, ";")
  WHILE tok.hasMoreTokens()
    LET c = tok.nextToken()
    LET c = c.trim()
    IF (idx := c.getIndexOf("=", 1)) != 0 THEN
      LET name = c.subString(1, idx - 1)
      LET value = c.subString(idx + 1, c.getLength())
      CALL log(
          SFMT("parseCookies:name:%1,value:%2,x:%3", name, value, printSel(x)))
      CASE name
        WHEN APP_COOKIE
          LET x.appCookie = value
          CALL log(SFMT("parseCookies: set %1=%2", APP_COOKIE, value))
        WHEN SID_COOKIE
          LET x.sidCookie = value
          CALL log(SFMT("parseCookies: set %1=%2", SID_COOKIE, value))
      END CASE
    END IF
  END WHILE
END FUNCTION

FUNCTION parseHttpHeader(x TConn INOUT, s STRING)
  DEFINE cIdx INT
  DEFINE key, val STRING
  LET s = removeCR(s)
  LET cIdx = s.getIndexOf(":", 1)
  MYASSERT(cIdx > 0)
  LET key = s.subString(1, cIdx - 1)
  LET key = key.toLowerCase()
  LET val = s.subString(cIdx + 2, s.getLength())
  --DISPLAY "key:",key,",val:'",val,"'"
  CASE key
    WHEN "cookie"
      --DISPLAY "cookie:'", val, "'"
      CALL parseCookies(x, val)
    WHEN "content-length"
      LET x.contentLen = val
      --DISPLAY "Content-Length:",_s[x].contentLen
    WHEN "content-type"
      LET x.contentType = val
      --DISPLAY "Content-Type:", _s[x].contentType
    WHEN "if-none-match"
      LET x.clitag = val
      --DISPLAY "If-None-Match", _sel.clitag
    WHEN "x-fourjs-lockfile"
      --DISPLAY ">>>>>>>>>>>>>>x-fourjs-lockfile"
      LET x.ftLockFile = TRUE
    WHEN "x-sw-cache"
      --DISPLAY "  X-SW-Cache:", val
  END CASE
  LET x.headers[key] = val
END FUNCTION

FUNCTION finishHttp(x TConn INOUT)
  MYASSERT(x.state == S_FINISH)
  CALL log(SFMT("finishHttp:%1,keepalive:%2", printSel(x), _keepalive))
  CALL checkReRegister(x)
  IF NOT _keepalive THEN
    CALL closeSel(x)
  END IF
END FUNCTION

FUNCTION isBlocking(chan base.Channel) RETURNS BOOLEAN
  UNUSED_VAR(chan)
  RETURN TRUE
END FUNCTION

FUNCTION checkHTTPForSend(
    x TConn INOUT, procId STRING, vmclose BOOLEAN, line STRING)
  MYASSERT(x.state == S_WAITFORVM)
  CALL log(
      SFMT("checkHTTPForSend procId:%1, vmclose:%2,%3",
          procId, vmclose, printSel(x)))
  IF NOT sendToClient(x, line, procId, vmclose, FALSE) THEN
    CALL log(
        SFMT("checkHTTPForSend: sendToClient of %1 with cmd:%2 failed",
            printSel(x), limitPrintStr(line)))
    CALL closeSel(x)
  ELSE
    CALL finishHttp(x)
  END IF
END FUNCTION

FUNCTION checkNewTasks(v TVMRec INOUT) RETURNS INT
  DEFINE sessId STRING
  DEFINE i, len, cnt INT
  IF _newtasks <= 0
      OR (sessId := v.sessId) IS NULL
      OR NOT _RWWchildren.contains(sessId)
      OR _RWWchildren[sessId].getLength() == 0 THEN
    --DISPLAY SFMT("checkNewTasks:_newtasks:%1 sessId:%2 _RWWchildren:%3",
    --    _newtasks, sessId, util.JSON.stringify(_RWWchildren))
    RETURN 0
  END IF
  {
  DISPLAY "checkNewTasks:",
      printV(v),
      ",_newtasks:",
      _newtasks,
      ",sess:",
      util.JSON.stringify(_RWWchildren),
      ",sessId:",
      v.sessId
  }
  FOR i = 1 TO _s.getLength()
    IF _s[i].newtask THEN
      --DISPLAY "  newtask http:", printSel(_s[i])
    END IF
  END FOR
  LET len = _s.getLength()
  CALL log(
      SFMT("checkNewTasks sessId:%1, children:%2",
          sessId, util.JSON.stringify(_RWWchildren[sessId])))
  FOR i = 1 TO len
    IF _s[i].newtask AND _s[i].procId == sessId THEN
      LET cnt = cnt + 1
      CALL log(SFMT("checkNewTasks->checkHTTPForSend:%1", i))
      CALL checkHTTPForSend(_s[i], sessId, FALSE, "")
    END IF
  END FOR
  RETURN cnt
END FUNCTION

FUNCTION getSSEIdxFor(v TVMRec INOUT) RETURNS INT
  DEFINE sessId STRING
  DEFINE i, len INT
  LET sessId = v.sessId
  IF sessId IS NULL THEN
    RETURN 0
  END IF
  LET len = _s.getLength()
  FOR i = 1 TO len
    --DISPLAY SFMT("getSSEIdxFor:vmidx:%1,sessId:%2,i:%3,isSSE:%4,sessId:%5,state:%6",
    --vmidx, sessId, i, _s[i].isSSE, _s[i].sessId, _s[i].state)
    IF _s[i].state == S_WAITFORVM
        AND _s[i].isSSE
        AND _s[i].active
        AND sessId == _s[i].sessId THEN
      RETURN i
    END IF
  END FOR
  RETURN 0
END FUNCTION

FUNCTION handleVM(v TVMRec INOUT, vmclose BOOLEAN, httpIdx INT)
  DEFINE procId STRING
  DEFINE line STRING
  CALL log(
      SFMT("handleVM:%1,vmclose:%2,httpIdx:%3", printV(v), vmclose, httpIdx))
  IF v.vmidx == 0 THEN
    CALL log(SFMT("handleVM: dead VM:%1", printV(v)))
    RETURN
  END IF
  IF v.closeSeen THEN
    CALL handleVMFinish(v)
    RETURN
  END IF

  IF NOT vmclose THEN
    CALL checkNewTasks(v) RETURNING status
  END IF
  LET procId = v.procId
  LET line = v.VmCmd
  IF httpIdx == 0 THEN
    IF v.useSSE THEN
      LET httpIdx = getSSEIdxFor(v)
    ELSE
      LET httpIdx = v.httpIdx
    END IF
    IF httpIdx = 0 OR httpIdx > _s.getLength() THEN
      CALL log(
          SFMT("handleVM line:'%1' but httpIdx out of bounds:%2",
              limitPrintStr(line), httpIdx))
      VAR i = 1
      FOR i = 1 TO _s.getLength()
        CALL log(SFMT(" i:%1,x:%2", i, printSel(_s[i])))
      END FOR
      RETURN
    END IF
  END IF
  MYASSERT(httpIdx > 0 AND httpIdx <= _s.getLength())
  CALL checkHTTPForSend(_s[httpIdx], procId, vmclose, line)
  LET v.httpIdx = 0
  LET v.VmCmd = NULL
  LET v.didSendVMClose = vmclose
  CALL log(SFMT("handleVM vmclose:%1,%2", vmclose, printV(v)))
END FUNCTION

FUNCTION checkNewTask(v TVMRec INOUT)
  DEFINE pidx, cnt INT
  DEFINE procIdParent STRING
  LET procIdParent = v.procIdParent
  MYASSERT(procIdParent IS NOT NULL)
  LET pidx = _selDict[procIdParent]
  --DISPLAY "checkNewTask:", procIdParent, " for meta:", v.VmCmd
  LET cnt = checkNewTasks(v)
  IF _v[pidx].httpIdx == 0 THEN
    CALL log(SFMT("checkNewTask(): parent httpIdx is NULL,cnt:%1", cnt))
    RETURN IIF(cnt > 0, TRUE, FALSE)
  END IF
  CALL handleVM(_v[pidx], FALSE, 0)
  RETURN TRUE
END FUNCTION

FUNCTION vmidxForSessId(sessId STRING)
  DEFINE i INT
  --DISPLAY sfmt("vmidxForSessId:%1,_lastVM:%2",sessId,_lastVM)
  --first check if one of the VM channels has data to send
  IF _lastVM > 0
      AND _v[_lastVM].sessId == sessId
      AND _v[_lastVM].VmCmd IS NOT NULL THEN
    --DISPLAY "  vmidxForSessId: with data _lastVM:", _lastVM
    RETURN _lastVM
  END IF
  FOR i = 1 TO _v.getLength()
    IF _v[i].sessId == sessId AND _v[i].VmCmd IS NOT NULL THEN
      --DISPLAY "  vmidxForSessId: with data i:", i
      RETURN i
    END IF
  END FOR
  IF _lastVM > 0 AND _v[_lastVM].sessId == sessId THEN
    --DISPLAY "  vmidxForSessId: without data _lastVM:", _lastVM
    RETURN _lastVM
  END IF
  FOR i = 1 TO _v.getLength()
    IF _v[i].sessId == sessId THEN
      --DISPLAY "  vmidxForSessId: without data i:", i
      RETURN i
    END IF
  END FOR
  --DISPLAY "  vmidxForSessId no Vm for session:",sessId
  RETURN 0
END FUNCTION

FUNCTION vmidxFromProcId(procId STRING)
  DEFINE vmidx INT
  IF NOT _selDict.contains(procId) THEN
    CALL log(
        SFMT("vmidxFromProcId: no procId '%1' in _selDict:%2",
            procId, util.JSON.stringify(_selDict.getKeys())))
    RETURN 0
  END IF
  LET vmidx = _selDict[procId]
  MYASSERT(vmidx > 0 AND vmidx <= _v.getLength())
  RETURN vmidx
END FUNCTION

FUNCTION startsWith(s STRING, sub STRING) RETURNS STRING
  RETURN s.getIndexOf(sub, 1) == 1
END FUNCTION

FUNCTION getVMCloseSSECmd(sessId STRING, data STRING)
  RETURN SFMT("event:vmclose\nid:%1\nretry:10\ndata: %2\n\n", sessId, data)
END FUNCTION

FUNCTION sendVMCloseViaSSE(x TConn INOUT, sessId STRING) RETURNS BOOLEAN
  DEFINE hdrs TStringArr
  DEFINE ct, cmd STRING
  MYASSERT(x.isSSE)
  LET ct = "text/event-stream; charset=UTF-8"
  LET cmd = getVMCloseSSECmd(sessId, "http404")
  CALL log(SFMT("sendVMCloseViaSSE:sessId:%1,http:%2", sessId, printSel(x)))
  RETURN writeResponseInt2(x, cmd, ct, hdrs, "200 OK")
END FUNCTION

FUNCTION procIdFromPath(
    x TConn INOUT, path STRING, subPos INT, qidx INT)
    RETURNS STRING
  VAR procId = util.Strings.urlDecode(path.subString(subPos, qidx - 1))
  VAR appId = getQueryParam(x, "appId")
  IF appId <> "0" THEN
    LET procId = appId
    MYASSERT(procId IS NOT NULL)
  END IF
  RETURN procId
END FUNCTION

FUNCTION procIdFromX(x TConn INOUT) RETURNS STRING
  VAR pbase = os.Path.baseName(x.path)
  VAR procId = util.Strings.urlDecode(pbase)
  VAR appId = getQueryParam(x, "appId")
  IF appId <> "0" THEN
    LET procId = appId
    MYASSERT(procId IS NOT NULL)
  END IF
  RETURN procId
END FUNCTION

FUNCTION sendEmptyResponse(x TConn INOUT)
  VAR procId = procIdFromX(x)
  MYASSERT(procId IS NOT NULL)
  CALL log(SFMT("sendEmptyResponse x:%1", printSel(x)))
  IF NOT sendToClient(
      x: x, vmCmd: "", procId: procId, vmclose: FALSE, newtask: FALSE) THEN
    CALL closeSel(x)
  ELSE
    CALL finishHttp(x)
  END IF
END FUNCTION

FUNCTION handleUAProto(x TConn INOUT, path STRING) RETURNS BOOLEAN
  DEFINE body, procId, vmCmd, sessId STRING
  DEFINE qidx, vmidx INT
  DEFINE vmclose, newtask BOOLEAN
  DEFINE hdrs TStringArr
  --DEFINE key SelectionKey
  LET qidx = path.getIndexOf("?", 1)
  LET qidx = IIF(qidx > 0, qidx, path.getLength() + 1)
  CASE
    WHEN path.getIndexOf("/ua/r/", 1) == 1
      LET procId = util.Strings.urlDecode(path.subString(7, qidx - 1))
      LET sessId = procId
      CALL log(SFMT("handleUAProto procId:%1", procId))
      IF _opt_gdc THEN
        CALL setAppCookie(x, path)
      END IF
    WHEN path.getIndexOf("/ua/sse/", 1) == 1
      LET sessId = util.Strings.urlDecode(path.subString(9, qidx - 1))
      MYASSERT(x.method == "GET")
      --DISPLAY "SSE GET for sessId:", sessId
      LET x.sessId = sessId
      LET x.isSSE = TRUE
      --IF NOT _selDict.contains(sessId) THEN
      LET vmidx = vmidxForSessId(sessId)
      IF vmidx == 0 THEN
        CALL selDictRemove(sessId)
        RETURN sendVMCloseViaSSE(x, sessId)
      END IF
      --END IF
    WHEN path.getIndexOf("/ua/fgljp_close/", 1) == 1
      LET sessId = util.Strings.urlDecode(path.subString(17, qidx - 1))
      CALL handleBrowserClose(x, sessId)
      LET x.state = S_FINISH
      CALL finishHttp(x)
      RETURN TRUE
    WHEN path.getIndexOf("/ua/interrupt/", 1) == 1 -- GAS proto interrupt
      LET procId = procIdFromPath(x, path, 15, qidx)
      LET x.body = CLIENT_INTERRUPT
    WHEN path.getIndexOf("/ua/sua/", 1) == 1
      LET procId = procIdFromPath(x, path, 9, qidx)
      CALL log(SFMT("handleUAProto ua/sua procId:%1,x:2", procId, printSel(x)))
    WHEN path.getIndexOf("/ua/newtask/", 1) == 1
      LET procId = util.Strings.urlDecode(path.subString(13, qidx - 1))
      LET sessId = procId
      LET x.sessId = procId
      LET newtask = TRUE
      LET vmidx = vmidxFromAppCookie(x, path)
      MYASSERT(vmidx > 0)
    WHEN (path.getIndexOf("/ua/ping/", 1)) == 1
      CALL log(SFMT("handleUAProto ping:%1", path))
      LET hdrs = getCacheHeaders(FALSE, "")
      RETURN writeResponseCtHdrs(x, "", "text/plain; charset=UTF-8", hdrs)
  END CASE
  IF NOT x.isSSE AND procId IS NULL THEN --hanging GDCs can disturb frequently
    DISPLAY "Warning: no VM found for:", path
    RETURN http404(x, path)
  END IF
  IF NOT newtask THEN
    IF x.method == "POST" THEN
      LET body = x.body
      IF body.getLength() > 0 THEN
        IF NOT writeToVMWithProcId(x, body, procId) THEN
          CALL log(SFMT("writeToVMWithProcId returned false,x:%1", printSel(x)))
          --IF NOT x.state.equals(S_WAITFORVM) THEN
          --  RETURN http404(x, path)
          --END IF
          RETURN TRUE
        END IF
      END IF
    END IF
    IF x.isSSE THEN
      MYASSERT(vmidx > 0)
      LET procId = _v[vmidx].procId
      --DISPLAY "isSSE vmidx:", vmidx, ",procId:", procId
      LET sessId = NULL
    ELSE
      LET vmidx = vmidxFromProcId(procId)
    END IF
    IF vmidx == 0 THEN -- we get re trials of VM's no more existing
      RETURN http404(x, path)
    END IF
    LET vmCmd = _v[vmidx].VmCmd
    IF sessId IS NOT NULL THEN
      --DISPLAY "handleUAProto: set sessId for vmidx:", vmidx, " to:", sessId
      LET _v[vmidx].sessId = sessId
      CALL _RWWchildren[sessId].clear()
      CALL _RWWchildren.remove(sessId)
    ELSE
      LET sessId = _v[vmidx].sessId
      IF sessId IS NOT NULL THEN
        LET x.sessId = sessId
      END IF
    END IF
    IF (_v[vmidx].useSSE OR body == CLIENT_INTERRUPT)
        AND x.method == "POST"
        AND NOT x.isSSE THEN
      --only if SSE is active we answer with an empty result
      --DISPLAY "!!!answer with empty result"
      --IF x.starttime
      IF x.state == S_FINISH OR x.active == FALSE THEN
        RETURN TRUE
      ELSE
        RETURN sendToClient(x, "", procId, FALSE, FALSE)
      END IF
    END IF
  END IF
  CASE
    WHEN (vmCmd IS NOT NULL)
        OR (newtask AND hasChildrenForVMIdx(vmidx, sessId))
        OR (vmidx > 0 AND (vmclose := (_v[vmidx].state == S_FINISH)) == TRUE)
      IF NOT sendToClient(
          x, IIF(newtask, "", vmCmd), procId, vmclose, newtask) THEN
        RETURN FALSE
      END IF
    WHEN vmCmd IS NULL
      LET x.state = S_WAITFORVM
      CALL log(
          SFMT("handleUAProto:vmCmd IS NULL, switch to wait state:%1",
              printSel(x)))
      IF newtask THEN
        LET _newtasks = _newtasks + 1
        LET x.newtask = newtask
        LET x.procId = procId
      ELSE
        LET _v[vmidx].httpIdx = x.idx
      END IF
  END CASE
  RETURN TRUE
END FUNCTION

FUNCTION formatHTTPDate(d DATE) RETURNS STRING
  DEFINE s STRING
  LET s = d USING "DDD, DD MMM YYYY", " ", TIME, " GMT"
  RETURN s
END FUNCTION

FUNCTION oneYearPlus() RETURNS STRING
  DEFINE d DATE
  DEFINE ds STRING
  LET d = TODAY + INTERVAL(1-0) YEAR(1) TO MONTH
  LET ds = formatHTTPDate(d)
  --DISPLAY "ds:",ds
  RETURN ds
END FUNCTION

FUNCTION getCacheHeaders(
    cache BOOLEAN, etag STRING)
    RETURNS DYNAMIC ARRAY OF STRING
  DEFINE hdrs DYNAMIC ARRAY OF STRING
  IF cache THEN
    VAR longCache = IIF(fgl_getenv("LONGCACHE") IS NOT NULL, TRUE, FALSE)
    LET hdrs[hdrs.getLength() + 1] =
        SFMT("Cache-Control: max-age=%1, public", IIF(longCache, 31536000, 1))
    IF longCache THEN
      LET hdrs[hdrs.getLength() + 1] = SFMT("Expires: %1", oneYearPlus())
    END IF
    LET hdrs[hdrs.getLength() + 1] = SFMT("ETag: %1", etag)
  ELSE
    LET hdrs[hdrs.getLength() + 1] = "Cache-Control: no-cache"
    LET hdrs[hdrs.getLength() + 1] = "Pragma: no-cache"
    LET hdrs[hdrs.getLength() + 1] = "Expires: -1"
  END IF
  RETURN hdrs
END FUNCTION

FUNCTION sendNotModified(
    x TConn INOUT, fname STRING, etag STRING)
    RETURNS BOOLEAN
  DEFINE hdrs DYNAMIC ARRAY OF STRING
  LET hdrs[hdrs.getLength() + 1] = "Cache-Control: max-age=1,public"
  LET hdrs[hdrs.getLength() + 1] = SFMT("ETag: %1", etag)
  CALL log(SFMT("sendNotModified:%1", fname))
  RETURN writeResponseInt2(
      x, "", "text/plain; charset=UTF-8", hdrs, "304 Not Modified")
END FUNCTION

FUNCTION hasChildrenForVMIdx(vmidx INT, sessId STRING)
  DEFINE children TStringArr
  LET children = getChildrenForVMIdx(vmidx, sessId)
  RETURN children.getLength() > 0
END FUNCTION

--we lookup the RUN children first,
--then the RUN WITHOUT WAITING children
FUNCTION getChildrenForVMIdx(vmidx INT, sessId STRING)
  DEFINE empty TStringArr
  IF vmidx > 0 AND _v[vmidx].RUNchildren.getLength() > 0 THEN
    RETURN _v[vmidx].RUNchildren
  END IF
  IF sessId IS NOT NULL AND _RWWchildren.contains(sessId) THEN
    IF _RWWchildren[sessId].getLength() > 0 THEN
      RETURN _RWWchildren[sessId]
    END IF
  END IF
  RETURN empty
END FUNCTION

--format the multi line command into a JSON array
FUNCTION splitVMCmd(vmCmd STRING) RETURNS STRING
  DEFINE tok base.StringTokenizer
  DEFINE arr DYNAMIC ARRAY OF STRING
  DEFINE s STRING
  LET tok = base.StringTokenizer.create(vmCmd, "\n")
  WHILE tok.hasMoreTokens()
    LET s = tok.nextToken()
    IF s.getLength() > 0 THEN
      LET arr[arr.getLength() + 1] = s
    END IF
  END WHILE
  RETURN util.JSON.stringify(arr)
END FUNCTION

--adds the necessary id,retry,event and data lines for SSE
FUNCTION buildSSECmd(
    x TConn INOUT, vmCmd STRING, procId STRING, hdrs DYNAMIC ARRAY OF STRING)
    RETURNS STRING
  DEFINE sse base.StringBuffer

  LET sse = base.StringBuffer.create()
  CALL sse.append(SFMT("id:%1\nretry:10\n", procId))
  IF x.isMeta THEN
    CALL sse.append("event:meta\n") --set the special meta event type
  END IF
  IF x.retry THEN
    CALL sse.append("event:retry\n") --set the special retry event type
    LET vmCmd = "__RETRY__"
  END IF
  CALL sse.append("data: ")
  IF vmCmd.getIndexOf("\n", 1) > 0 THEN --multiple lines: this may happen
    LET vmCmd = splitVMCmd(vmCmd) --if we don't use encapsulation
  END IF
  CALL sse.append(vmCmd)
  CALL sse.append("\n\n")
  LET hdrs[hdrs.getLength() + 1] = SFMT("X-FourJs-Id: %1", procId)
  RETURN sse.toString()
END FUNCTION

--sets all headers sent to the HTTP side
--and the VM command, close or new task
FUNCTION sendToClient(
    x TConn INOUT,
    vmCmd STRING,
    procId STRING,
    vmclose BOOLEAN,
    newtask BOOLEAN)
    RETURNS BOOLEAN
  DEFINE hdrs DYNAMIC ARRAY OF STRING
  DEFINE newProcId, path, ct STRING
  DEFINE vmidx INT
  DEFINE children TStringArr
  --DEFINE pp STRING
  CALL log(
      SFMT("sendToClient:(x:%1,vmCmd:%2,procId:%3,vmclose:%4,newtask:%5)",
          x.idx, vmCmd, procId, vmclose, newtask))
  MYASSERT(x.active == TRUE)
  LET hdrs[hdrs.getLength() + 1] = "Pragma: no-cache"
  LET hdrs[hdrs.getLength() + 1] = "Expires: -1"
  LET hdrs[hdrs.getLength() + 1] = "X-XSS-Protection: 1; mode=block"
  LET hdrs[hdrs.getLength() + 1] = "Cache-Control: no-cache, no-store"
  LET hdrs[hdrs.getLength() + 1] = "Transfer-Encoding: Identity"
  LET hdrs[hdrs.getLength() + 1] = "X-Content-Type-Options: nosniff"
  LET hdrs[hdrs.getLength() + 1] = "Vary: Content-Encoding"
  --LET hdrs[hdrs.getLength() + 1] = "X-FourJs-Version: 2.0"
  --LET hdrs[hdrs.getLength() + 1] = "X-FourJs-WebComponent: "|| procId || "/"
  LET hdrs[hdrs.getLength() + 1] = "X-FourJs-Server: GAS/3.20.14-202012101044"
  LET hdrs[hdrs.getLength() + 1] = "X-FourJs-Timeout: 10000"
  LET hdrs[hdrs.getLength() + 1] = "X-FourJs-Request-Result: 10000"
  IF _opt_gdc IS NOT NULL THEN
    LET hdrs[hdrs.getLength() + 1] =
        "X-FourJs-WebComponent: ",
        SFMT("%1gbc/webcomponents/webcomponents", _htpre)
    LET hdrs[hdrs.getLength() + 1] = "X-FourJs-GBC: ", SFMT("%1gbc", _htpre)
  ELSE
    LET hdrs[hdrs.getLength() + 1] = "X-FourJs-WebComponent: webcomponents"
  END IF
  --LET pp=_selDict[procId].procIdParent
  --IF pp IS NULL OR  NOT _selDict.contains(pp) THEN
  LET path = x.path
  IF newtask OR path.getIndexOf("/ua/r/", 1) == 1 THEN
    --send the first or parent procId
    --DISPLAY "send server features for:", printSel(x)
    LET hdrs[hdrs.getLength() + 1] = SFMT("X-FourJs-Id: %1", procId)
    LET hdrs[hdrs.getLength() + 1] = "X-FourJs-Server-Features: ft-lock-file"
    LET hdrs[hdrs.getLength() + 1] = "X-FourJs-Development: true"
  END IF
  --END IF
  --LET hdrs[hdrs.getLength() + 1] = "X-FourJs-PageId: 1"
  --DISPLAY "sendToClient procId:", procId, ", ", printSel(x)
  IF NOT newtask THEN --sessId is also set in the newtask case
    LET vmidx = vmidxFromProcId(procId)
    IF vmidx == 0 THEN
      LET vmclose = TRUE
      LET vmCmd = NULL
    ELSE
      IF vmCmd.getLength() > 0 THEN --clear out VmCmd
        LET _v[vmidx].VmCmd = NULL
        LET x.isMeta = _v[vmidx].isMeta
      END IF
    END IF
  END IF
  LET children = getChildrenForVMIdx(vmidx, x.sessId)
  IF children.getLength() > 0 THEN
    LET newProcId = children[1]
    CALL children.deleteElement(1)
    LET hdrs[hdrs.getLength() + 1] = SFMT("X-FourJs-NewTask: %1", newProcId)
    IF x.newtask THEN
      LET _newtasks = _newtasks - 1
      LET x.newtask = FALSE
    END IF
    CALL log(SFMT("sendToClient:send X-FourJs-NewTask:%1", newProcId))
  END IF
  IF vmclose THEN --must be the last check in _selDict
    LET hdrs[hdrs.getLength() + 1] = "X-FourJs-Closed: true"
    LET vmidx = vmidxFromProcId(procId)
    IF vmidx <> 0 THEN
      CALL setEmptyVMConnection(vmidx)
    END IF
    CALL selDictRemove(procId)
  ELSE
    LET procId = IIF(vmidx > 0, _v[vmidx].procId, procId)
    --in each interaction coming from the VM we set the app id cookie new
    --this ensures after an action being sent that the context of resources
    --fetched by the client sends the right cookie back
    --DISPLAY "write vm side cookie:",SetCookieHdr(procId)," ",x.path
    LET hdrs[hdrs.getLength() + 1] = SetCookieHdr(APP_COOKIE, procId)
    LET x.appCookie = NULL --avoid sending session id later
  END IF
  CALL checkSIDHdr(hdrs)
  IF x.isSSE THEN
    LET vmCmd =
        IIF(vmclose,
            getVMCloseSSECmd(procId, "connectionEnd"),
            buildSSECmd(x, vmCmd, procId, hdrs))
  ELSE
    IF vmCmd.getLength() > 0 THEN
      LET vmCmd = vmCmd, "\n"
    END IF
  END IF
  CALL log(
      SFMT("sendToClient:%1%2",
          limitPrintStr(vmCmd), IIF(vmclose, " vmclose", "")))
  LET ct =
      IIF(x.isSSE,
          "text/event-stream; charset=UTF-8",
          "text/plain; charset=UTF-8")
  RETURN writeResponseInt2(x, vmCmd, ct, hdrs, "200 OK")
END FUNCTION

FUNCTION handleGBCPath(x TConn INOUT, path STRING) RETURNS BOOLEAN
  DEFINE fname, pathCut STRING
  DEFINE cut BOOLEAN
  DEFINE idx1, idx2, idx3 INT
  LET cut = TRUE
  LET pathCut = cut_question(path)
  CASE
    WHEN pathCut == "/gbc/index.html"
      CALL setAppCookie(x, path)
    WHEN pathCut == "/gbc/gbc_fgljp.js"
        AND os.Path.exists((fname := os.Path.join(_owndir, "gbc_fgljp.js")))
      CALL log(SFMT("handleGBCPath: process our gbc_fglp bootstrap:%1", fname))
      RETURN processFile(x: x, fname: fname, cache: TRUE, checkExists: TRUE)
  END CASE
  IF _opt_program IS NOT NULL THEN
    LET fname = path.subString(6, path.getLength())
    LET fname = cut_question(fname)
    LET fname = gbcResourceName(fname)
    --DISPLAY "fname:", fname
    RETURN processFile(x: x, fname: fname, cache: TRUE, checkExists: TRUE)
  ELSE
    CASE
      WHEN path.getIndexOf("/webcomponents/", 1) == 1
        LET path = "/gbc", path
        GOTO webco
      WHEN path.getIndexOf("/gbc/webcomponents/", 1) == 1
        LABEL webco:
        LET fname = path.subString(20, path.getLength())
        LET idx1 = fname.getIndexOf("/", 20)
        CASE
          WHEN idx1 > 0
              AND (idx2 := fname.getIndexOf("/", idx1)) > 0
              AND (idx3 := fname.getIndexOf("/__VM__/", idx1)) == idx2
            LET fname = fname.subString(idx3 + 1, fname.getLength())
            LET cut = FALSE --we pass the whole URL
        END CASE
      WHEN path.getIndexOf("/gbc/__VM__/", 1) == 1
        LET fname = path.subString(6, path.getLength())
        IF getQueryParam(x, "F") == "1" THEN
          --remove the __VM__ prefix made by us
          LET fname = fname.subString(8, fname.getLength())
        ELSE
          LET cut = FALSE --we pass the whole URL
        END IF
      OTHERWISE
        LET fname = "gbc://", path.subString(6, path.getLength())
    END CASE
    LET fname = IIF(cut, fname, SFMT("%1?%2", fname, x.query))
    RETURN processRemoteFile(x, fname)
  END IF
END FUNCTION

FUNCTION handleGDCPutFile(x TConn INOUT, path STRING) RETURNS BOOLEAN
  VAR procId = getQueryParam(x, "procId")
  CALL log(
      SFMT("handleGDCPutFile:%1,procId:%2,x:%3", path, procId, printSel(x)))
  MYASSERT(procId IS NOT NULL)
  LET x.appCookie = procId
  --DISPLAY "  fname:", fname
  VAR vmidx = vmidxFromAppCookie(x, path)
  IF vmidx < 1 THEN
    RETURN http404(x, path)
  END IF
  --LET _v[vmidx].cliputfile = NULL
  RETURN deliverPutFile(x, path, _v[vmidx])
END FUNCTION

#+ all http requests land here
FUNCTION invokeHttpHandler(x TConn INOUT, path STRING)
  LET x.state = S_HTTPHANDLER
  CASE
    WHEN startsWith(s: x.path, sub: "/ua/") --ua protocol
      CALL printRequest(x, "handleUAProto")
      RETURN handleUAProto(x: x, path: path)
    WHEN _direct_mode AND x.cdattachment
      RETURN handleCDAttachment(x)
    WHEN startsWith(s: path, sub: "/gbc/") --gbc asset
      CALL printRequest(x, "handleGBCPath")
      RETURN handleGBCPath(x: x, path: path)
    WHEN path.getIndexOf("/putfile/", 1) == 1 --gdc putfile
      RETURN handleGDCPutFile(x, path.subString(9, path.getLength()))
  END CASE
  MYASSERT(NOT x.state.equals(S_FINISH))
  VAR ret = FALSE
  IF _htdelegate IS NOT NULL THEN
    LET ret = _htdelegate.httpHandler(x)
  ELSE
    CASE
      WHEN path == "/"
        VAR text = "<!DOCTYPE html><html><body>This is fgljp</body></html>"
        LET ret = writeResponse(x, text)
      OTHERWISE
        LET ret = findFile(x, path)
    END CASE
  END IF
  RETURN ret
END FUNCTION

--MYASSERT(_sidCookie IS NOT NULL)
{
IF NOT _sidCookie.equals(_s[x].sidCookie)
    AND NOT startsWith(path, _firstPath) THEN

  DISPLAY "wrong sid cookie:'",
      _s[x].sidCookie,
      "' for path:",
      path,
      ",must be :'",
      _sidCookie,
      "' _firstPath:",
      _firstPath
  CALL http404(x, path)
  RETURN
END IF
}

--fglrun creates a tmp file for the short while of a frontcall
--as GBC doesn't control *when* the download takes place we must
--store the file somewehere else
FUNCTION lockFile(x TConn INOUT, fname STRING)
  VAR tmpName = SFMT("%1.%2", os.Path.makeTempName(), os.Path.extension(fname))
  CALL log(
      SFMT("lockFile fname:%1,tmpName:%2,pathWithQuery:%3",
          fname, tmpName, pathWithQuery(x)))
  MYASSERT(x.method == "GET")
  MYASSERT(os.Path.copy(fname, tmpName) == TRUE)
  LET _lockMap[pathWithQuery(x)] = tmpName
  VAR nocache = getCacheHeaders(cache: FALSE, etag: NULL)
  RETURN writeResponseInt2(
      x: x, content: NULL, ct: "text/plain", headers: nocache, code: "200 OK")
END FUNCTION

FUNCTION handleLockedFile(x TConn INOUT, locked STRING) RETURNS BOOLEAN
  CALL _lockMap.remove(pathWithQuery(x))
  CALL log(
      SFMT("use lockFile:'%1' instead of:'%2', x:%3",
          locked, pathWithQuery(x), printSel(x)))
  VAR ret = processFile(x: x, fname: locked, cache: FALSE, checkExists: TRUE)
  CALL os.Path.delete(locked) RETURNING status
  RETURN ret
END FUNCTION

FUNCTION findFile(x TConn INOUT, path STRING) RETURNS BOOLEAN
  DEFINE qidx INT
  DEFINE relpath STRING
  LET qidx = path.getIndexOf("?", 1)
  IF qidx > 0 THEN
    LET path = path.subString(1, qidx - 1)
  END IF
  VAR locked = ""
  IF NOT x.ftLockFile
      AND (locked := _lockMap[pathWithQuery(x)]) IS NOT NULL THEN
    RETURN handleLockedFile(x, locked)
  END IF
  LET path = util.Strings.urlDecode(path)
  LET relpath = ".", path
  IF NOT os.Path.exists(relpath) THEN
    CALL log(
        SFMT("findFile:relpath '%1' doesn't exist, pwd:%2",
            relpath, os.Path.pwd()))
    IF _direct_mode THEN --ask VM
      RETURN processRemoteFile(x: x, fname: path)
    END IF
    RETURN http404(x, path)
  END IF
  IF x.ftLockFile THEN
    RETURN lockFile(x, relpath)
  END IF
  RETURN processFile(x: x, fname: relpath, cache: TRUE, checkExists: FALSE)
END FUNCTION

FUNCTION gbcResourceName(fname STRING)
  DEFINE trial STRING
  CASE
    WHEN fname.getIndexOf("webcomponents", 1) > 0
      LET fname = fname.subString(15, fname.getLength())
      --first look in <programdir>/webcomponents
      LET trial = os.Path.join(_progdir, fname)
      IF os.Path.exists(trial) THEN
        LET fname = trial
      ELSE
        --lookup the fgl web components
        --DISPLAY "Can't find:",trial
        LET fname = os.Path.join(fgl_getenv("FGLDIR"), fname)
      END IF
      --WHEN fname == "js/gbc.bootstrap.js"
      --  DISPLAY "!!fake bootstrap"
      --  LET fname = os.Path.join(_owndir, "gbc.bootstrap.js")
    OTHERWISE
      LET fname = os.Path.join(_gbcdir, fname)
  END CASE
  RETURN fname
END FUNCTION

FUNCTION readTextFile(fname)
  DEFINE fname, res STRING
  DEFINE t TEXT
  LOCATE t IN FILE fname
  LET res = t
  RETURN res
END FUNCTION

FUNCTION getRUNChildIdx(vmidx INT)
  DEFINE cidx INT
  LET cidx = _v[vmidx].RUNchildIdx
  IF cidx IS NULL OR cidx <= 0 OR cidx > _s.getLength() THEN
    RETURN vmidx
  END IF
  IF _v[cidx].procIdWaiting == _v[vmidx].procId THEN
    RETURN getRUNChildIdx(cidx)
  ELSE
    RETURN vmidx
  END IF
END FUNCTION

FUNCTION vmidxFromAppCookie(x TConn INOUT, fname STRING) RETURNS INT
  DEFINE vmidx INT
  LET vmidx = vmidxFromAppCookieInt(x, fname)
  IF vmidx < 1 THEN
    RETURN 0
  END IF
  MYASSERT(vmidx <= _v.getLength())
  IF vmidx > 0 AND vmidx <= _v.getLength() THEN
    IF _v[vmidx].state == S_FINISH THEN
      CALL log(
          SFMT("vmidxFromAppCookie: caught vmidx for dead VM:%1, fname:%2",
              printVIdx(vmidx), fname))
      RETURN 0
    END IF
  END IF
  RETURN vmidx
END FUNCTION

FUNCTION vmidxFromAppCookieInt(x TConn INOUT, fname STRING)
  DEFINE vmidx, cidx INT
  VAR procId = getQueryParam(x, "app")
  IF procId IS NULL THEN
    LET procId = x.appCookie
    IF procId IS NULL THEN
      --DISPLAY
      --    SFMT("vmidxFromAppCookie:no App Cookie set for:%1,%2",
      --        fname, _s[x].path)
      CALL log(
          SFMT("vmidxFromAppCookie:no App Cookie set for:%1,%2",
              fname, printSel(x)))
      RETURN 0
    END IF
    --ELSE
    --  DISPLAY "  vmidxFromAppCookie:procId:", procId
  END IF
  IF NOT _selDict.contains(procId) THEN
    CALL log(
        SFMT("vmidxFromAppCookie:no app anymore for:%1,procId:%2,%3",
            fname, procId, printSel(x)))
    RETURN 0
  END IF
  LET vmidx = _selDict[procId]
  CALL log(
      SFMT("vmidxFromAppCookie %1,procId:%2,vmidx:%3",
          printSel(x), procId, vmidx))
  --need to lookup the current RUN child
  IF _v[vmidx].useSSE THEN
    RETURN vmidx
  END IF
  LET cidx = getRUNChildIdx(vmidx)
  IF cidx <> vmidx THEN
    CALL log(SFMT("  RUNchild %1", printVIdx(cidx)))
  END IF
  RETURN cidx
END FUNCTION

FUNCTION processRemoteFile(x TConn INOUT, fname STRING) RETURNS BOOLEAN
  DEFINE vmidx INT
  LET vmidx = vmidxFromAppCookie(x, fname)
  IF vmidx < 1 THEN
    RETURN http404(x, fname)
  END IF
  LET x.state = S_WAITFORVM
  CALL log(SFMT("processRemoteFile x:%1, fname:%2", printSel(x), fname))
  RETURN checkRequestFT(x, _v[vmidx], fname)
END FUNCTION

FUNCTION processFile(
    x TConn INOUT, fname STRING, cache BOOLEAN, checkExists BOOLEAN)
    RETURNS BOOLEAN
  DEFINE ext, ct, txt STRING
  DEFINE etag STRING
  DEFINE hdrs TStringArr
  --DISPLAY "processFile:", x, " ", fname,",pathCut:",_s[x].pathCut,",method:",_s[x].method
  IF checkExists AND NOT os.Path.exists(fname) THEN
    RETURN http404(x, fname)
  END IF
  IF x.method == "POST" THEN
    --DISPLAY "!!!!processFile POST:", fname, " return 200 OK"
    LET hdrs = getCacheHeaders(FALSE, "")
    RETURN writeResponseInt2(x, "", "", hdrs, "200 OK")
  END IF
  VAR found_index = FALSE
  VAR ret = FALSE
  CALL process_index_html(x, fname) RETURNING ret, found_index
  IF found_index THEN
    RETURN ret
  END IF
  IF cache THEN
    LET etag = SFMT("%1.%2", os.Path.mtime(fname), os.Path.size(fname))
    IF x.clitag IS NOT NULL AND x.clitag == etag THEN
      RETURN sendNotModified(x, fname, etag)
    END IF
  END IF
  IF x.method == "GET"
      AND (x.path == "/gbc/js/gbc.js" OR x.path == "gbc://js/gbc.js") THEN
    --DISPLAY "!!!!processGBCJS:", x, " ", fname
    RETURN process_gbc_js(x, fname, etag)
  END IF
  LET ext = os.Path.extension(fname)
  LET ct = NULL
  CASE
    WHEN ext == "html"
        OR ext == "css"
        OR ext == "js"
        OR ext == "txt"
        OR ext == "svg"
      CASE
        WHEN ext == "html"
          LET ct = "text/html"
        WHEN ext == "js"
          LET ct = "application/x-javascript"
        WHEN ext == "css"
          LET ct = "text/css"
        WHEN ext == "txt"
          LET ct = "text/plain"
        WHEN ext == "svg"
          LET ct = "image/svg+xml"
      END CASE
      LET txt = readTextFile(fname)
      LET hdrs = getCacheHeaders(cache, etag)
      --DISPLAY "processTextFile:", fname, " ct:", ct, " txt:", limitPrintStr(txt)
      RETURN writeResponseFileHdrs(x, fname, ct, hdrs, ext, checkExists)
    OTHERWISE
      LET ct = "application/octet-stream"
      CASE
        WHEN ext == "gif"
          LET ct = "image/gif"
        WHEN ext == "woff"
          LET ct = "application/font-woff"
        WHEN ext == "ttf"
          LET ct = "application/octet-stream"
        WHEN ext == "svg"
          LET ct = "image/svg+xml"
      END CASE
      LET hdrs = getCacheHeaders(cache, etag)
      --DISPLAY "processFile:", fname, " ct:", ct
      RETURN writeResponseFileHdrs(x, fname, ct, hdrs, ext, checkExists)
  END CASE
  RETURN FALSE
END FUNCTION

FUNCTION formatUrl(fn STRING, d TStringDict)
  DEFINE i INT
  DEFINE keys DYNAMIC ARRAY OF STRING
  DEFINE o, key STRING
  LET o = fn
  LET keys = d.getKeys()
  FOR i = 1 TO keys.getLength()
    LET o = o, IIF(i == 1, "?", "&")
    LET key = keys[i]
    LET o = o, key, "=", d[key]
  END FOR
  RETURN o
END FUNCTION

FUNCTION findScriptOrLink(l STRING)
  DEFINE i1, i2, i3, i4, i5 INT
  DEFINE fn, fnp STRING
  DEFINE d TStringDict
  DEFINE url URI
  IF ((i1 := l.getIndexOf("<script", 1)) > 0
          OR (i1 := l.getIndexOf("<link", 1)))
      AND ((i2 := l.getIndexOf("src", i1)) > 0
          OR (i2 := l.getIndexOf("href", i1)) > 0)
      AND (i3 := l.getIndexOf("=", i2)) > 0
      AND (i4 := l.getIndexOf('"', i3)) > 0
      AND (i5 := l.getIndexOf('"', i4 + 1)) > 0 THEN
    LET fn = l.subString(i4 + 1, i5 - 1)
    --DISPLAY "fn:'", fn, "'"
    CALL getURLQueryDict(fn) RETURNING d, url
    LET fnp = url.getPath();
  END IF
  RETURN l, fnp
END FUNCTION

FUNCTION inject_gbc_fgljp(b base.StringBuffer)
  DEFINE d TStringDict
  DEFINE gbc_fgljp STRING
  LET gbc_fgljp = os.Path.join(_owndir, "gbc_fgljp.js")
  MYASSERT(os.Path.exists(gbc_fgljp))
  LET d["s"] = os.Path.size(gbc_fgljp)
  LET d["t"] = getLastModified(gbc_fgljp)
  CALL b.append(
      SFMT('<script src="%1"></script>\n', formatUrl("gbc_fgljp.js", d)))
END FUNCTION

--injects our js wrapper into the gbc index.html page
--and returns the modified page as html string
FUNCTION patch_index_html(fname STRING) RETURNS STRING
  DEFINE ch base.Channel
  DEFINE line, dir, fn STRING
  DEFINE b base.StringBuffer
  LET b = base.StringBuffer.create()
  LET dir = os.Path.dirName(fname)
  LET ch = base.Channel.create()
  CALL ch.openFile(fname, "r")
  WHILE (line := ch.readLine()) IS NOT NULL
    CALL findScriptOrLink(line) RETURNING line, fn
    CALL b.append(line)
    CALL b.append("\n")
    IF fn == "js/gbc.js" THEN --after gbc.js appeared we inject
      --our js helper to implement a custom GAS protocol for GBC>=4.00
      CALL inject_gbc_fgljp(b)
    END IF
  END WHILE
  CALL ch.close()
  RETURN b.toString()
END FUNCTION

FUNCTION process_index_html(
    x TConn INOUT, fname STRING)
    RETURNS(BOOLEAN, BOOLEAN)
  DEFINE hdrs TStringArr
  DEFINE ct, txt STRING
  IF os.Path.baseName(fname) == "index.html"
          AND (_opt_program IS NOT NULL
              AND fname == gbcResourceName("index.html"))
      OR (_direct_mode AND fname = cacheFileName("gbc://index.html")) THEN
    LET hdrs = getCacheHeaders(FALSE, "") --never cache for now
    LET txt = patch_index_html(fname)
    LET ct = "text/html"
    VAR ret = writeResponseCtHdrs(x, txt, ct, hdrs)
    RETURN ret, TRUE
  ELSE
    RETURN TRUE, FALSE
  END IF
END FUNCTION

--we need to patch the head of gbc.js
--(insert an unload handler)
--GBC's unload handlers otherwise don't let us get a foot into the door
FUNCTION process_gbc_js(
    x TConn INOUT, gbc_js STRING, etag STRING)
    RETURNS BOOLEAN
  DEFINE txt STRING
  DEFINE hdrs TStringArr
  --add our custom unload code as the 1st instruction in gbc.js
  LET txt =
      '"use strict";\nwindow.addEventListener("unload",function(e) {\nconsole.log("process gbc_fgljp_unload gbc");\ntry { window.gbc_fgljp_unload();\n} catch(err) {\nconsole.warn("process gbc_fgljp_unload error:"+err.msg);\n}\n});\n'
  LET txt = txt, readTextFile(gbc_js)
  LET hdrs = getCacheHeaders(TRUE, etag)
  RETURN writeResponseCtHdrs(x, txt, "application/x-javascript", hdrs)
END FUNCTION

FUNCTION addCrossBlaBla(hdrs DYNAMIC ARRAY OF STRING)
  --make SharedArray buffer working
  LET hdrs[hdrs.getLength() + 1] = "Cross-Origin-Opener-Policy: same-origin"
  LET hdrs[hdrs.getLength() + 1] = "Cross-Origin-Embedder-Policy: require-corp"
  LET hdrs[hdrs.getLength() + 1] = "Access-Control-Allow-Headers: *"
END FUNCTION

FUNCTION addOptionHeaders(hdrs DYNAMIC ARRAY OF STRING)
  LET hdrs[hdrs.getLength() + 1] =
      "Access-Control-Allow-Headers: Access-Control-Allow-Headers, Origin,Accept, X-Requested-With, Content-Type, Access-Control-Request-Method, Access-Control-Request-Headers"
  LET hdrs[hdrs.getLength() + 1] =
      "Access-Control-Allow-Methods : GET,HEAD,OPTIONS,POST,PUT"
  LET hdrs[hdrs.getLength() + 1] = "Access-Control-Allow-Credentials: true";
END FUNCTION

FUNCTION cut_question(fname) RETURNS STRING
  DEFINE fname STRING
  DEFINE idx INT
  IF (idx := fname.getIndexOf("?", 1)) <> 0 THEN
    RETURN fname.subString(1, idx - 1)
  END IF
  RETURN fname
END FUNCTION

FUNCTION extract_query(fname) RETURNS STRING
  DEFINE fname STRING
  VAR lastQ = lastIndexOf(fname, "?")
  IF lastQ > 0 THEN
    RETURN fname.subString(lastQ + 1, fname.getLength())
  END IF
  RETURN ""
END FUNCTION

FUNCTION http404(x TConn INOUT, fn STRING) RETURNS BOOLEAN
  DEFINE content STRING
  LET content =
      SFMT("<!DOCTYPE html><html><body>Can't find: '%1'</body></html>", fn)
  CALL log(SFMT("http404:%1", fn))
  LET x.cdattachment = FALSE
  RETURN writeResponseInt(x, content, "text/html", "404 Not Found")
END FUNCTION

FUNCTION writeHTTPLine(x TConn INOUT, s STRING) RETURNS BOOLEAN
  IF fgl_getenv("SHOWALLHTTP") IS NOT NULL THEN
    DISPLAY SFMT("writeHTTPLine:%1=%2", x.id, interpretchars(s))
  END IF
  LET s = s, "\r\n"
  RETURN writeHTTP(x, s)
END FUNCTION

FUNCTION closeOnError(x TConn INOUT, func STRING, err STRING, line STRING)
  --if the channel was closed by the other side we close and go back in the
  --call chain
  DISPLAY SFMT("closeOnError:%1:%2 ,line:%2", func, err, line)
  CALL closeSel(x)
END FUNCTION

FUNCTION writeHTTP(x TConn INOUT, s STRING) RETURNS BOOLEAN
  DEFINE chan base.Channel
  IF s IS NULL THEN
    RETURN TRUE
  END IF
  LET chan = x.chan
  --DISPLAY sfmt("writeHTTP:%1->'%2'",printSel(x),s)
  MYASSERT(_channels.search(NULL, chan) > 0)
  TRY
    CALL chan.writeNoNL(s)
  CATCH
    CALL closeOnError(x, "writeHTTP", err_get(status), __LINE__)
    RETURN FALSE
  END TRY
  RETURN TRUE
END FUNCTION

FUNCTION retrySSE(v TVMRec INOUT)
  VAR sseIdx = getSSEIdxFor(v)
  IF sseIdx
      > 0 THEN --close also /ua/sse/ because we otherwise run into connection closes
    LET _s[sseIdx].retry = TRUE
    CALL sendEmptyResponse(_s[sseIdx])
  END IF
END FUNCTION

FUNCTION checkPutFileGetFile(x TConn INOUT, v TVMRec INOUT, s STRING)
  UNUSED_VAR(s)
  IF v.cliputfile IS NULL AND v.vmputfile IS NULL AND v.vmgetfile IS NULL THEN
    RETURN FALSE
  END IF
  {
  DISPLAY ">>>>hold reply of:'",
      s,
      "' because of cliputfile:'",
      _v[vmidx].cliputfile,
      "',vmputfile:'",
      _v[vmidx].vmputfile
  }
  LET x.state = S_WAITFORVM --still the body contains the information for the VM
  LET x.procId = v.procId
  CALL log(
      SFMT("checkPutFileGetFile x:%1,v:%2,s:%3,cliputfile",
          printSel(x), printV(v), limitPrintStr(s), v.cliputfile))
  IF v.vmgetfile IS NOT NULL THEN
    MYASSERT(os.Path.exists("tmp_getfile.upload"))
    LET v.VmCmd = NULL
    LET v.vmgetfile = NULL
    LET v.httpIdx = x.idx --mark the connection for VM answer
    CALL sendFileToVM(v, v.vmgetfilenum, "tmp_getfile.upload")
  END IF
  IF v.cliputfile == PUTFILE_DELIVERED THEN
    --DISPLAY "v.cliputfile == PUTFILE_DELIVERED body:'", x.body, "'"
    MYASSERT(x.body.getIndexOf('{}{{FunctionCallEvent 0', 1) > 0)
    LET x.body = NULL
    LET v.httpIdx = x.idx
    CALL endPutfileFT(v)
  ELSE
    IF v.useSSE AND v.toVMCmd IS NULL THEN
      MYASSERT(x.isSSE == FALSE AND x.path.getIndexOf("/ua/sua/", 1) == 1)
      LET v.toVMCmd = x.body
      CALL log(
          SFMT("checkPutFileGetFile: v.vmputfile:'%1', v.cliputfile:'%1' not delivered yet,set v.toVMCmd To:%1",
              v.vmputfile, v.cliputfile, x.body))
      LET x.body = NULL
      CALL retrySSE(v)
      CALL sendEmptyResponse(x)
    END IF
  END IF
  RETURN TRUE
END FUNCTION

FUNCTION writeToVMWithProcId(
    x TConn INOUT, s STRING, procId STRING)
    RETURNS BOOLEAN
  DEFINE vmidx INT
  LET x.idx = x.idx
  IF NOT _selDict.contains(procId) THEN
    CALL log(
        SFMT("writeToVMWithProcIdDISPLAY not contained procId:%1, x:%2, _selDict:%3",
            procId, printSel(x), util.JSON.stringify(_selDict)))
    RETURN FALSE
  END IF
  CALL log(SFMT("writeToVMWithProcId procId:%1, x:%2", procId, printSel(x)))
  LET vmidx = _selDict[procId]
  IF checkPutFileGetFile(x, _v[vmidx], s) THEN
    RETURN FALSE
  END IF
  CALL writeToVM(_v[vmidx], s)
  IF _v[vmidx].useSSE AND NOT x.isSSE THEN
    CALL log(SFMT("finish non SSE:%1 after write to VM", printSel(x)))
    CALL writeResponseCt(x: x, content: "", ct: "text/plain") RETURNING status
    CALL finishHttp(x)
  END IF
  RETURN TRUE
END FUNCTION

--we need to correct encapsulation
FUNCTION handleClientMeta(v TVMRec INOUT, meta STRING)
  DEFINE ftreply, ftFC, feid2, mfeid2 STRING
  LET meta = replace(meta, '{encapsulation "0"}', '{encapsulation "1"}')
  --LET ftreply = IIF(_v[vmidx].FTV2, sfmt('{filetransfer "2"} {filetransferAppId "&app=%1"}',
  LET ftreply = IIF(v.FTV2, '{filetransfer "2"}', '{filetransfer "1"}')
  LET ftFC = IIF(v.FTFC, '{filetransferFC "1"}', "")
  LET feid2 = fgl_getenv("_FGLFEID2")
  LET mfeid2 = IIF(feid2 IS NOT NULL, SFMT('{frontEndID2 "%1"}', feid2), "")
  LET meta =
      replace(meta, '{filetransfer "0"}', SFMT('%1%2%3', ftreply, ftFC, mfeid2))
  --DISPLAY "handleClientMeta:", meta
  RETURN meta
END FUNCTION

FUNCTION handleBrowserClose(x TConn INOUT, sessId STRING)
  DEFINE i INT
  CALL log(SFMT("handleBrowserClose:%1 sessId:%2", printSel(x), sessId))
  FOR i = 1 TO _v.getLength()
    IF _v[i].sessId == sessId THEN
      CALL writeToVM(_v[i], CLIENT_CLOSE)
    ELSE
      --CALL dlog(SFMT("vm idx:%1 has sessId:%2", printV(i), _v[i].sessId))
    END IF
  END FOR
END FUNCTION

FUNCTION writeToVM(v TVMRec INOUT, s STRING)
  CALL log(SFMT("writeToVM:%1 s:%2 wait:%3", printV(v), s, v.wait))
  LET v.closeSeen = s.equals(CLIENT_CLOSE)
  IF v.wait THEN
    IF s.equals(CLIENT_INTERRUPT) OR v.closeSeen THEN
      CALL log(SFMT(" writeToVM wait pending, force write for:%1", s))
      --reset wait to avoid assertion
      LET v.wait = FALSE
    ELSE
      CALL log(
          SFMT("  writeToVM wait pending,store:%1, stack:%2",
              s, base.Application.getStackTrace()))
      LET v.toVMCmd = s
      RETURN
    END IF
  END IF
  IF _direct_mode THEN
    IF NOT v.clientMetaSent THEN
      MYASSERT(s.getIndexOf("meta ", 1) == 1)
      LET v.clientMetaSent = TRUE
      LET s = handleClientMeta(v, s)
    END IF
    CALL writeToVMEncaps(v, s)
  ELSE
    CALL writeToVMNoEncaps(v, s)
  END IF
  CALL setWait(v)
END FUNCTION

FUNCTION writeToVMNoEncaps(v TVMRec INOUT, s STRING)
  DEFINE chan base.Channel
  LET chan = v.chan
  MYASSERT(_channels.search(NULL, chan) > 0)
  CALL chan.writeNoNL(s)
  CALL chan.flush()
  --DISPLiY SFMT("writeToVMNoEncaps vmidx:%1 s:'%2'", vmidx, s)
END FUNCTION

FUNCTION writeHTTPFile(x TConn INOUT, fn STRING, ctlen INT) RETURNS BOOLEAN
  DEFINE numBytes INT
  DEFINE c base.Channel
  DEFINE chan base.Channel
  LET chan = x.chan
  MYASSERT(chan IS NOT NULL AND _channels.search(NULL, chan) > 0)
  LET c = base.Channel.create()
  CALL c.openFile(fn, "r")
  LET numBytes = os.Path.size(fn)
  MYASSERT(os.Path.size(fn) == ctlen)
  VAR written = util.Channels.copyN(c, chan, ctlen)
  CALL log(
      SFMT("writeHTTPFile: Did write:%1 of len:%2,fn:%3 x:%4",
          written, ctlen, fn, printSel(x)));
  CALL c.close()
  IF written == ctlen THEN
    CALL chan.flush()
    RETURN TRUE
  ELSE
    IF NOT chan.isEof() THEN
      CALL myErr(
          SFMT("writeHTTPFile:Could only write %1 bytes of %2 to channel",
              written, ctlen))
    END IF
    RETURN FALSE
  END IF
END FUNCTION

FUNCTION writeResponse(x TConn INOUT, content STRING) RETURNS BOOLEAN
  RETURN writeResponseInt(x, content, "text/html; charset=UTF-8", "200 OK")
END FUNCTION

FUNCTION writeResponseCtHdrs(
    x TConn INOUT, content STRING, ct STRING, headers DYNAMIC ARRAY OF STRING)
    RETURNS BOOLEAN
  RETURN writeResponseInt2(x, content, ct, headers, "200 OK")
END FUNCTION

FUNCTION writeResponseCt(
    x TConn INOUT, content STRING, ct STRING)
    RETURNS BOOLEAN
  RETURN writeResponseInt(x, content, ct, "200 OK")
END FUNCTION

FUNCTION writeHTTPCommon(x TConn INOUT) RETURNS BOOLEAN
  DEFINE h STRING
  LET h = "Date: ", TODAY USING "DDD, DD MMM YYY", " ", TIME, " GMT"
  IF NOT writeHTTPLine(x, h) THEN
    RETURN FALSE
  END IF
  VAR conn = IIF(x.keepalive, "Connection: keep-alive", "Connection: close")
  IF x.cdattachment THEN
    LET conn = "Connection: close"
    CALL log("send connection close")
  END IF

  {IF x.keepalive == FALSE THEN
    DISPLAY "write header :", conn
  END IF}
  IF NOT writeHTTPLine(x, conn) THEN
    RETURN FALSE
  END IF
  IF NOT writeHTTPLine(x, "Access-Control-Allow-Origin: *") THEN
    RETURN FALSE
  END IF
  LET x.state = S_FINISH
  RETURN TRUE
END FUNCTION

FUNCTION writeResponseInt(
    x TConn INOUT, content STRING, ct STRING, code STRING)
    RETURNS BOOLEAN
  DEFINE headers DYNAMIC ARRAY OF STRING
  RETURN writeResponseInt2(x, content, ct, headers, code)
END FUNCTION

--SSE: the VM putfile is always fetched with the master sse procId:
--doesn't work for child processes, so we simply compare against vmputfile
--(vmputfile would be better a unique temp name to avoid clashes)
FUNCTION getPutfileVMIdx(x TConn INOUT, path STRING) RETURNS INT
  DEFINE i INT
  CALL log(SFMT("getPutfileVMIdx: path:%1,x:%2", path, printSel(x)))
  MYASSERT(startsWith(path, "/gbc/"))
  VAR effpath = path.subString(6, path.getLength())
  FOR i = 1 TO _v.getLength()
    VAR vmputfile = _v[i].vmputfile
    IF effpath.equals(vmputfile) THEN
      --CALL log(sfmt("  did find VM at idx:%1,v:%1",i,printVIdx(i)))
      RETURN i
    END IF
  END FOR
  CALL log(
      SFMT("getPutfileVMIdx: no match for path:%1,x:%2", path, printSel(x)))
  RETURN 0
END FUNCTION

FUNCTION handleCDAttachment(x TConn INOUT) RETURNS BOOLEAN
  VAR path = x.path
  IF path.getIndexOf("/gbc/FT/", 1) == 1 THEN
    LET path = path.subString(5, path.getLength())
  END IF
  VAR vmidx = getPutfileVMIdx(x, path)
  CALL log(
      SFMT("handleCDAttachment:x:%1 path:%2 vmidx:%3,conn:%4",
          x.id, path, vmidx, printSel(x)))
  IF vmidx < 1 THEN
    RETURN http404(x, x.path)
  END IF
  IF x.ftLockFile THEN
    MYASSERT(_v[vmidx].cliputfile.equals(path) == FALSE)
    LET _v[vmidx].cliputfile = path
    LET x.cdattachment = FALSE
    VAR hdrs = getCacheHeaders(FALSE, "")
    CALL log(
        SFMT("handleCDAttachment:send 204 No Content:%1,lockFile:%2,cliputfile:%3",
            printSel(x), x.ftLockFile, _v[vmidx].cliputfile))
    RETURN writeResponseInt2(x, "", "", hdrs, "204 No Content")
  ELSE
    DISPLAY "handleCDAttachment set cliputfile from:",
        _v[vmidx].cliputfile,
        " to NULL"
    LET _v[vmidx].cliputfile = NULL
    --actually deliver the putfile to the browser
    RETURN deliverPutFile(x, path, _v[vmidx])
  END IF
END FUNCTION

FUNCTION deliverPutFile(
    x TConn INOUT, path STRING, v TVMRec INOUT)
    RETURNS BOOLEAN
  CALL log(
      SFMT("deliverPutFile:%1,%2,%3,v.vmputfile:%4,x.ftLockFile:%5",
          path, printSel(x), printV(v), v.vmputfile, x.ftLockFile))
  IF v.FTFC AND _direct_mode THEN
    MYASSERT(v.vmputfile IS NOT NULL)
    LET path = FTName(v.vmputfile)
    DISPLAY "deliverPutfile processFile:", path
    LET v.vmputfile = NULL
    --need to forbid caching otherwise the ftLock mechanism is disturbed
    IF NOT processFile(x: x, fname: path, cache: FALSE, checkExists: TRUE) THEN
      DISPLAY "deliverPutfile processFile *not* successfule"
      RETURN FALSE
    END IF
  ELSE
    IF NOT findFile(x, path) THEN
      RETURN FALSE
    END IF
  END IF
  LET v.cliputfile = PUTFILE_DELIVERED
  CALL handleVMResultForPutfile(x, v, path)
  RETURN TRUE
END FUNCTION

FUNCTION handleVMResultForPutfile(x TConn INOUT, v TVMRec INOUT, path STRING)
  DEFINE i, len, vmidx2 INT
  DEFINE body, procId STRING
  DEFINE found BOOLEAN
  CALL log(
      SFMT("handleVMResultForPutfile:x:%1,v:%2,path:%3",
          printSel(x), printV(v), path))
  IF checkToVMCmd(v) THEN
    LET v.cliputfile = NULL
    RETURN
  END IF

  LET len = _s.getLength()
  FOR i = 1 TO len
    IF _s[i].state == S_WAITFORVM
        AND NOT _s[i].isSSE
        AND (vmidx2 := vmidxFromAppCookie(_s[i], path)) > 0
        AND vmidx2 == v.vmidx THEN
      LET body = _s[i].body
      LET procId = v.procId
      CALL log(
          SFMT("handleVMResultForPutfile:"
                  || "x:%1 found i:%1 for vmidx:%3 body:%4,sel:%5",
              printSel(x), i, v.vmidx, body, printSel(_s[i])))
      --MYASSERT(procId == _s[i].procId)
      --MYASSERT(_s[i].procId IS NOT NULL)
      MYASSERT(body.getIndexOf('{}{{FunctionCallEvent 0{{result "0"}}{}}}', 1) > 0)
      IF _direct_mode AND (NOT v.FTFC) THEN -- simulated FT mode
        CALL endPutfileFT(v)
      ELSE
        LET v.cliputfile = NULL
        CALL retrySSE(v)
        CALL writeToVM(v, body)
      END IF
      IF (i <> x.idx AND x.state == S_FINISH) THEN
        CALL log(
            SFMT("handleVMResultForPutfile i:%1<>x.idx:%2,_s[i]:%3,x:%4->finishHttp(x)",
                i, x.idx, printSel(_s[i]), printSel(x)))
        CALL finishHttp(x)
      END IF
      IF _v[vmidx2].useSSE THEN
        CALL sendEmptyResponse(_s[i])
      ELSE
        IF x.cdattachment THEN
          CALL finishHttp(x)
        ELSE
          LET v.httpIdx = i --mark the connection for VM answer
        END IF
      END IF
      LET found = TRUE
      EXIT FOR
    END IF
  END FOR
  IF NOT found THEN
    CALL log(
        SFMT("handleVMResultForPutfile:did not find waiting http connection for:%1",
            printSel(x)))
    IF v.FTFC THEN
      LET v.cliputfile = NULL
    END IF
  END IF
END FUNCTION

FUNCTION endPutfileFT(v TVMRec INOUT)
  DEFINE num INT
  MYASSERT(v.cliputfile == PUTFILE_DELIVERED)
  CALL log(SFMT("endPutfileFT:vmputfile:%1,%2", v.vmputfile, printV(v)))
  LET v.cliputfile = NULL
  LET v.vmputfile = NULL
  LET num = getWriteNum(v)
  CALL resetWriteNum(v, num)
  --we end now the file transfer to the VM
  --DISPLAY SFMT("!!!!!!!sendFTStatus %1 and lookupNextImage", num)
  CALL sendFTStatus(v, num, FTOk)
  CALL lookupNextImage(v)
END FUNCTION

FUNCTION checkCDAttachment(x TConn INOUT, hdrs TStringArr)
  DEFINE qidx INT
  DEFINE path, fname STRING
  IF NOT x.cdattachment THEN
    RETURN
  END IF
  LET path = x.path
  LET qidx = path.getIndexOf("?", 1)
  LET path = IIF(qidx > 0, path.subString(1, qidx - 1), path)
  LET path = util.Strings.urlDecode(path)
  LET fname = os.Path.baseName(path)
  --DISPLAY ">>>>>>>>>>>>send attach:", path, ",fname:", fname
  LET qidx = hdrs.getLength() + 1
  LET hdrs[qidx] = SFMT('Content-Disposition: attachment; filename="%1"', fname)
END FUNCTION

FUNCTION SetCookieHdr(cookieName STRING, value STRING)
  --SFMT("Set-Cookie: %1=%2; Path=/; HttpOnly; expires=Thu, 21 Oct 2121 07:28:00 GMT",

  RETURN SFMT("Set-Cookie: %1=%2; Path=/; HttpOnly;", cookieName, value)
END FUNCTION

FUNCTION checkSIDHdr(hdrs TStringArr)
  --IF hdrs.getLength() THEN
  --END IF
  --UNUSED_VAR(hdrs)
  IF NOT _sidCookieSent OR _opt_gdc IS NOT NULL THEN
    LET _sidCookieSent = TRUE
    LET hdrs[hdrs.getLength() + 1] = SetCookieHdr(SID_COOKIE, _sidCookie)
  END IF
END FUNCTION

FUNCTION writeHTTPHeaders(x TConn INOUT, headers TStringArr) RETURNS BOOLEAN
  DEFINE i, len INT
  DEFINE path STRING
  CALL checkCDAttachment(x, headers)
  IF x.customHeaderFunc IS NOT NULL THEN
    CALL x.customHeaderFunc(headers)
  END IF
  CALL checkSIDHdr(headers)
  LET len = headers.getLength()
  FOR i = 1 TO len
    IF NOT writeHTTPLine(x, headers[i]) THEN
      RETURN FALSE
    END IF
  END FOR
  LET path = x.path
  --DISPLAY "writeHTTPHeaders path:",path, ",appCookie:",_s[x].appCookie
  IF x.appCookie IS NOT NULL
      AND (path.getIndexOf("/ua/", 1) == 1
          OR path.getIndexOf("/gbc/index.html", 1) == 1) THEN
    --DISPLAY "  !!!!!!!!!!!!!!!!!!write appCookie:", SetCookieHdr(_s[x].appCookie)," ",_s[x].path
    RETURN writeHTTPLine(x, SetCookieHdr(APP_COOKIE, x.appCookie))
  END IF
  RETURN TRUE
END FUNCTION

FUNCTION writeResponseInt2(
    x TConn INOUT,
    content STRING,
    ct STRING,
    headers DYNAMIC ARRAY OF STRING,
    code STRING)
    RETURNS BOOLEAN
  DEFINE content_length INT
  --DISPLAY "writeResponseInt2:",content
  IF NOT writeHTTPLine(x, SFMT("HTTP/1.1 %1", code)) THEN
    RETURN FALSE
  END IF
  CALL printCode(code)
  IF NOT writeHTTPCommon(x) THEN
    RETURN FALSE
  END IF
  IF content IS NULL THEN
    LET content = " " CLIPPED
  END IF
  LET content_length = content.getLength() -- need content.getByteLength()
  IF NOT writeHTTPHeaders(x, headers) THEN
    RETURN FALSE
  END IF
  IF NOT x.method.equals("OPTIONS") THEN
    IF NOT writeHTTPLine(x, SFMT("Content-Length: %1", content_length)) THEN
      RETURN FALSE
    END IF
    IF ct IS NOT NULL THEN
      IF NOT writeHTTPLine(x, SFMT("Content-Type: %1", ct)) THEN
        RETURN FALSE
      END IF
    END IF
  END IF
  IF NOT writeHTTPLine(x, "") THEN
    RETURN FALSE
  END IF
  VAR chan = x.chan
  IF NOT x.method.equals("OPTIONS") THEN
    --TODO: TRY/CATCH
    TRY
      --CALL util.Channels.writeBinaryString(chan, content)
      CALL chan.writeNoNL(content)
    CATCH
      CALL printStderr(
          SFMT("ERROR,writeResponseInt2 content writing failed:%1",
              err_get(status)))
      RETURN FALSE
    END TRY
  END IF
  TRY
    CALL chan.flush()
  CATCH
    CALL printStderr(
        SFMT("ERROR,writeResponseInt2 flush failed:%1", err_get(status)))
    RETURN FALSE
  END TRY
  RETURN TRUE
END FUNCTION

FUNCTION printCode(code STRING)
  IF fgl_getenv("__GWA_DISPLAY_CODE") IS NOT NULL THEN
    CALL printStdout(SFMT(" -> %1", code), FALSE)
  END IF
END FUNCTION

FUNCTION writeResponseFileHdrs(
    x TConn INOUT,
    fn STRING,
    ct STRING,
    headers TStringArr,
    ext STRING,
    checkExists BOOLEAN)
    RETURNS BOOLEAN
  DEFINE ctlen INT
  --DISPLAY "writeResponseFileHeaders:", fn
  IF checkExists AND NOT os.Path.exists(fn) THEN
    RETURN http404(x, fn)
  END IF
  VAR line
      = IIF(x.method == "OPTIONS", "HTTP/1.1 204 NoContent", "HTTP/1.1 200 OK")
  IF NOT writeHTTPLine(x, line) THEN
    RETURN FALSE
  END IF
  CALL printCode("200 OK")
  IF NOT writeHTTPCommon(x) THEN
    RETURN FALSE
  END IF

  IF x.method == "OPTIONS" THEN
    CALL addOptionHeaders(headers)
  ELSE
    IF ext == "js" THEN
      CALL addCrossBlaBla(headers)
    END IF
  END IF

  IF NOT writeHTTPHeaders(x, headers) THEN
    RETURN FALSE
  END IF
  LET ctlen = os.Path.size(fn);
  IF NOT x.method.equals("OPTIONS") THEN --don't need to send body
    IF NOT writeHTTPLine(x, SFMT("Content-Length: %1", ctlen)) THEN
      RETURN FALSE
    END IF
    IF NOT writeHTTPLine(x, SFMT("Content-Type: %1", ct)) THEN
      RETURN FALSE
    END IF
  END IF
  IF NOT writeHTTPLine(x, "") THEN
    RETURN FALSE
  END IF
  IF x.method.equals("OPTIONS") THEN
    RETURN TRUE
  END IF
  RETURN writeHTTPFile(x, fn, ctlen)
END FUNCTION

FUNCTION extractMetaVar(
    line STRING, varname STRING, forceFind BOOLEAN)
    RETURNS STRING
  DEFINE valueIdx1, valueIdx2 INT
  DEFINE value STRING
  CALL extractMetaVarSub(line, varname, forceFind)
      RETURNING value, valueIdx1, valueIdx2
  RETURN value
END FUNCTION

FUNCTION patchProcId(line STRING, procId STRING)
  DEFINE valueIdx1, valueIdx2 INT
  DEFINE value STRING
  CALL extractMetaVarSub(line, "procId", TRUE)
      RETURNING value, valueIdx1, valueIdx2
  LET line =
      line.subString(1, valueIdx1 - 1),
      procId,
      line.subString(valueIdx2 + 1, line.getLength())
  RETURN line
END FUNCTION

FUNCTION extractMetaVarSub(
    line STRING, varname STRING, forceFind BOOLEAN)
    RETURNS(STRING, INT, INT)
  DEFINE idx1, idx2, len INT
  DEFINE key, value STRING
  LET key = SFMT('{%1 "', varname)
  LET len = key.getLength()
  LET idx1 = line.getIndexOf(key, 1)
  IF (forceFind == FALSE AND idx1 <= 0) THEN
    RETURN "", 0, 0
  END IF
  MYASSERT(idx1 > 0)
  LET idx2 = line.getIndexOf('"}', idx1 + len)
  IF (forceFind == FALSE AND idx2 < idx1 + len) THEN
    RETURN "", 0, 0
  END IF
  MYASSERT(idx2 > idx1 + len)
  LET value = line.subString(idx1 + len, idx2 - 1)
  CALL log(SFMT("extractMetaVar: '%1'='%2'", varname, value))
  RETURN value, idx1 + len, idx2 - 1
END FUNCTION

FUNCTION extractProcId(p STRING)
  RETURN p --we always use the full procId now
END FUNCTION

FUNCTION extractPidFromProcId(p STRING)
  DEFINE pidx1 INT
  LET pidx1 = p.getIndexOf(":", 1)
  MYASSERT(pidx1 > 0)
  RETURN p.subString(pidx1 + 1, p.getLength())
END FUNCTION

FUNCTION handleVMMetaSel(c TConn INOUT, line STRING) RETURNS INT
  DEFINE vmidx INT
  --allocate a new VM index
  LET vmidx = findFreeVMIdx()
  --DISPLAY "new vmidx:", vmidx
  CALL setEmptyVMConnection(vmidx)
  RETURN initVMWithMeta(vmidx, _v[vmidx], c, line)
END FUNCTION

FUNCTION initVMWithMeta(
    vmidx INT, v TVMRec INOUT, c TConn INOUT, line STRING)
    RETURNS INT
  DEFINE pp, procIdWaiting, encaps, compression, rtver STRING
  DEFINE ftV, ftFC, feid, {env_feid,} name STRING
  LET feid = extractMetaVar(line, "frontEndID", FALSE)
  {
  LET env_feid = fgl_getenv("_FGLFEID")
  IF env_feid IS NOT NULL AND NOT env_feid.equals(feid) THEN
    CALL printStderr(
        "Security alert:_FGLFEID doesn't match with the frontEndID of the VM, close connection.")
    CALL closeSel(c)
    RETURN -1
  END IF
  }
  LET v.frontEndID = feid
  --assign matching members from _s to _v
  LET v.active = TRUE
  LET v.chan = c.chan
  LET v.starttime = c.starttime
  LET v.state = c.state
  LET v.id = c.id
  --'free' the _s[c] index
  CALL setEmptyConnection(c.idx)
  --DISPLAY "handleVMMetaSel: vmidx:", vmidx, ":", util.JSON.stringify(_v[vmidx])
  LET v.VmCmd = line
  LET v.state = IIF(_opt_program IS NOT NULL, S_ACTIVE, S_WAITFORFT)
  LET v.isMeta = TRUE
  LET v.vmidx = vmidx
  IF (name := extractMetaVar(line, "programName", FALSE)) IS NOT NULL THEN
    LET v.programName = name
  END IF
  CALL log(SFMT("initVMWithMeta: v:%1, line:%1", printV(v), line))
  LET encaps = extractMetaVar(line, "encapsulation", TRUE)
  LET compression = extractMetaVar(line, "compression", FALSE)
  --DISPLAY "encaps:", encaps, ",compression:", compression
  IF compression IS NOT NULL THEN
    MYASSERT(compression.equals("none")) --avoid that someone enables zlib
  END IF
  LET ftV = extractMetaVar(line, "filetransferVersion", FALSE)
  LET v.FTV2 = IIF(ftV == "2", TRUE, FALSE)
  LET ftFC = extractMetaVar(line, "filetransferFC", FALSE)
  LET v.FTFC = IIF(ftFC == "1", TRUE, FALSE)
  LET rtver = extractMetaVar(line, "runtimeVersion", TRUE)
  LET v.vmVersion = parseVersion(rtver)
  VAR procId = extractMetaVar(line, "procId", TRUE)
  LET procId = extractProcId(procId)
  LET v.procId = procId
  LET _selDict[procId] = vmidx --store the selector index of the procId
  LET procIdWaiting = extractMetaVar(line, "procIdWaiting", FALSE)
  IF procIdWaiting IS NOT NULL THEN
    LET procIdWaiting = extractProcId(procIdWaiting)
    LET v.procIdWaiting = procIdWaiting
  END IF
  LET pp = extractMetaVar(line, "procIdParent", FALSE)
  IF pp IS NOT NULL THEN
    LET pp = extractProcId(pp)
    CALL checkChildren(vmidx, pp)
  END IF
  CALL decideStartOrNewTask(v, vmidx)
  RETURN vmidx
END FUNCTION

FUNCTION checkChildren(vmidx INT, procIdParent STRING)
  DEFINE children TStringArr
  DEFINE ppidx, waitIdx INT
  DEFINE sessId, procIdWaiting, ppid STRING
  IF NOT _selDict.contains(procIdParent) THEN
    LET ppid = extractPidFromProcId(procIdParent)
    IF ppid == fgl_getpid() THEN
      --DISPLAY "we did invoke this program"
    ELSE
      DISPLAY "checkChildren vmidx:", vmidx, ",no procIdParent:", procIdParent
      LET _v[vmidx].procIdParentWaiting = procIdParent
    END IF
    RETURN
  END IF
  LET ppidx = _selDict[procIdParent]
  LET procIdWaiting = _v[vmidx].procIdWaiting
  LET _v[vmidx].procIdParent = procIdParent
  IF (sessId := _v[ppidx].sessId) IS NOT NULL THEN
    --DISPLAY SFMT("checkChildren set _v[%1].sessId=%2", vmidx, sessId)
    LET _v[vmidx].sessId = sessId
    LET _v[vmidx].useSSE = _v[ppidx].useSSE
    IF NOT _v[vmidx].useSSE AND _RWWchildren.contains(sessId) THEN
      LET children = _RWWchildren[sessId] --could be RUN WITHOUT WAITING child
    END IF
  END IF
  IF procIdWaiting IS NOT NULL
      AND NOT _v[vmidx].useSSE
      AND _selDict.contains(procIdWaiting) THEN
    LET waitIdx = _selDict[procIdWaiting];
    LET _v[waitIdx].RUNchildIdx = vmidx;
  END IF
  IF procIdWaiting == procIdParent THEN
    LET children = _v[ppidx].RUNchildren --procIdWaiting forces a RUN child
  END IF
  IF NOT _v[vmidx].useSSE THEN
    LET children[children.getLength() + 1] = _v[vmidx].procId
  END IF
  --DISPLAY "!!!!set children of:",
  --    printSel(ppidx),
  --    " to:",
  --    util.JSON.stringify(children)
END FUNCTION

{
FUNCTION parentActive(procId STRING)
  IF _selDict.contains(procId) THEN
    RETURN TRUE
  END IF

END FUNCTION
}

FUNCTION findAppWithSameFEID(feid STRING)
  DEFINE keys TStringArr
  DEFINE i, vmidx INT
  MYASSERT(feid IS NOT NULL)
  LET keys = _selDict.getKeys()
  FOR i = 1 TO keys.getLength()
    LET vmidx = _selDict[keys[i]]
    IF feid.equals(_v[vmidx].frontEndID) THEN
      RETURN TRUE
    END IF
  END FOR
  RETURN FALSE
END FUNCTION

FUNCTION checkWaitingForParent(procId STRING, sessId STRING, useSSE BOOLEAN)
  DEFINE keys TStringArr
  DEFINE vmidx INT
  CALL log(
      SFMT("checkWaitingForParent:procId:%1,sessId:%2,useSSE:%3",
          procId, sessId, useSSE))
  MYASSERT(procId IS NOT NULL)
  MYASSERT(sessId IS NOT NULL)
  LET keys = _selDict.getKeys()
  FOR vmidx = 1 TO _v.getLength()
    IF NOT S_ACTIVE.equals(_v[vmidx].state) THEN
      CONTINUE FOR
    END IF
    IF procId.equals(_v[vmidx].procIdParentWaiting) THEN
      CALL log(
          SFMT("checkWaitingForParent: found waiting app:%1,procId:%2 for parent:%3",
              _v[vmidx].programName, _v[vmidx].procId, procId))
      LET _numWaitingParent = _numWaitingParent - 1
      LET _v[vmidx].procIdParentWaiting = NULL
      CALL checkChildren(vmidx, procId)
      MYASSERT(_numWaitingParent >= 0)
      CALL handleVM(_v[vmidx], FALSE, 0)
    END IF
  END FOR
END FUNCTION

FUNCTION decideStartOrNewTask(v TVMRec INOUT, vmidx INT)
  DEFINE pp, procId STRING
  DEFINE v_old INT
  --either start client or send newTask
  LET procId = v.procId
  ---MYASSERT(_selDict.contains(procId))
  IF _selDict.contains(procId) THEN
    --happens if fglrun -d restarts a process, new socket but old procId
    LET v_old = _selDict[procId]
    --DISPLAY SFMT("same procId:%1,v_old:%2,vmidx:%3", procId, v_old, vmidx)
    MYASSERT(_v[v_old].procId == procId)
    IF v.sessId IS NULL THEN
      LET v.sessId = procId
    END IF
    IF v_old <> vmidx THEN
      CALL handleVMFinish(_v[v_old])
      CALL setEmptyVMConnection(v_old)
      LET _selDict[procId] = vmidx
      --DISPLAY "  handleVMFinish v_old, let _selDict[", procId, "]=", vmidx
    END IF
  END IF
  IF (pp := v.procIdParent) IS NOT NULL THEN
    CALL log(
        SFMT("decideStartOrNewTask:%1 procId:%2 procIdParent:%3 _selDict[pp] idx:%4",
            vmidx, procId, pp, IIF(_selDict.contains(pp), _selDict[pp], -1)))
    CASE
      WHEN v.useSSE AND _selDict.contains(pp)
        LET _selDict[procId] = vmidx --store the selector index of the procId
        --DISPLAY "  decideStartOrNewTask1 let _selDict[", procId, "]=", vmidx
        CALL handleVM(v, FALSE, 0)
      WHEN NOT v.useSSE AND NOT checkNewTask(v) AND NOT _selDict.contains(pp)
        CALL handleStart(v)
    END CASE
    IF _numWaitingParent > 0 THEN
      IF v.sessId IS NOT NULL THEN
        IF NOT v.useSSE AND _selDict.contains(pp) THEN
          LET _selDict[procId] = vmidx --store the selector index of the procId
          --DISPLAY "  decideStartOrNewTask2 let _selDict[", procId, "]=", vmidx
        END IF
        CALL checkWaitingForParent(procId, v.sessId, v.useSSE)
      END IF
    END IF
  ELSE
    IF _opt_program IS NOT NULL
        AND v.frontEndID IS NOT NULL
        AND v.procIdParentWaiting IS NOT NULL
        AND findAppWithSameFEID(v.frontEndID) THEN
      LET _numWaitingParent = _numWaitingParent + 1
      CALL log(
          SFMT("decideStartOrNewTask incr _numWaitingParent:%1, procIdParentWaiting:%2",
              _numWaitingParent, v.procIdParentWaiting))
      RETURN
    END IF
    CALL handleStart(v)
  END IF
  IF _direct_mode THEN
    CALL log("decideStartOrNewTask: send 'filetransfer\\n'")
    CALL writeToVMNoEncaps(v, "filetransfer\n")
    CALL setWait(v)
  END IF
END FUNCTION

FUNCTION setEmptyConnection(x INT)
  DEFINE empty TConn
  LET _s[x].* = empty.* --resets also active
  LET _s[x].keepalive = _keepalive
END FUNCTION

FUNCTION setEmptyVMConnection(vmidx INT)
  DEFINE empty TVMRec
  CALL log(SFMT("setEmptyVMConnection:%1", printVIdx(vmidx)))
  IF _v[vmidx].chan IS NOT NULL THEN
    --DISPLAY sfmt("  setEmptyVMConnection close_chan:%1",printVIdx(vmidx))
    LET _v[vmidx].chan = close_chan(_v[vmidx].chan)
  END IF
  LET _v[vmidx].* = empty.* --resets also active
  LET _lastVM = IIF(vmidx == _lastVM, 0, _lastVM)
  CALL log(SFMT("  _lastVM=%1", _lastVM))
END FUNCTION

FUNCTION handleConnection(chan base.Channel)
  VAR c = findIdxForChan(chan)
  IF c < 1 THEN
    VAR vmidx = findVMIdxForChan(chan)
    MYASSERT(vmidx <> 0)
    LET _v[vmidx].vmidx = vmidx
    CALL log(SFMT("handleConnection VM:vmidx:%1, %2", vmidx, printV(_v[vmidx])))
    CALL handleVMConnectionInt(_v[vmidx], vmidx)
  ELSE
    LET _s[c].idx = c
    CALL log(SFMT("handleConnection:idx:%1, %2", c, printSel(_s[c])))
    CALL handleConnectionInt(_s[c])
  END IF
END FUNCTION

FUNCTION handleVMLine(v TVMRec INOUT, line STRING)
  IF v.state == S_WAITFORFT THEN
    MYASSERT(line == "filetransfer")
    CALL log("handleLineVMLine: filetransfer\\n received")
    LET v.state = S_ACTIVE
    CALL lookupNextImage(v)
  ELSE
    IF v.FTV2 AND v.FTFC AND NOT _opt_gdc THEN
      --no need to parse the protocol anymore
      LET v.VmCmd = line
    ELSE
      CALL parseTcl(v, line)
      --CALL printOmInt(_s[c].doc.getDocumentElement(),2)
      LET v.VmCmd = _p.buf
    END IF
    LET v.isMeta = FALSE
    CALL handleVM(v, FALSE, 0)
  END IF
END FUNCTION

FUNCTION handleVMConnectionInt(v TVMRec INOUT, vmidx INT)
  DEFINE type TINYINT
  IF v.wait THEN
    --DISPLAY "!!!!reset wait for:", printV(v)
    LET v.wait = FALSE
  END IF
  --LET v.isMeta = FALSE
  VAR line = ""
  IF _direct_mode AND v.state == S_ACTIVE THEN
    CALL readEncaps(v) RETURNING type, line
    IF type != TAuiData THEN
      --DISPLAY "-------go out with type:", type
      RETURN
    END IF
  ELSE
    LET line = readLineFromVM(v, 0)
  END IF
  IF line.getLength() == 0 THEN
    CALL handleVMFinish(v)
  ELSE
    CALL handleVMLine(v, line)
  END IF
  IF v.didSendVMClose OR v.state == S_FINISH THEN
    LET _lastVM = IIF(vmidx == _lastVM, 0, _lastVM)
  ELSE
    --DISPLAY "  handleVMConnectionInt let _selDict[", v.procId, "]=", vmidx
    LET _selDict[v.procId] = vmidx --store the selector index of the procId
    LET _lastVM = vmidx
    CALL checkToVMCmd(v) RETURNING status
  END IF
END FUNCTION

FUNCTION checkToVMCmd(v TVMRec INOUT) RETURNS BOOLEAN
  IF NOT v.wait AND v.toVMCmd IS NOT NULL THEN
    CALL log(SFMT("checkToVM send after wait:%1 for:%2", v.toVMCmd, printV(v)))
    CALL writeToVM(v, v.toVMCmd)
    LET v.toVMCmd = NULL
    RETURN TRUE
  ELSE
    RETURN FALSE
  END IF
END FUNCTION

FUNCTION handleConnectionInt(c TConn INOUT)
  DEFINE go_out, closed BOOLEAN
  DEFINE line STRING
  DEFINE isVM BOOLEAN
  WHILE NOT go_out
    IF c.isHTTP AND c.state == S_WAITCONTENT THEN
      IF NOT handleWaitContent(c) THEN
        CALL closeSel(c)
        LET closed = TRUE
      END IF
      EXIT WHILE
    END IF
    LET line = ReadLine(c)
    IF line.getLength() == 0 THEN
      CALL handleEmptyLine(c) RETURNING go_out, closed
    ELSE
      IF handleLine(c, line) THEN
        LET isVM = TRUE
        EXIT WHILE
      END IF
    END IF
  END WHILE
  CALL log(
      SFMT("handleConnection end of:%1%2",
          printSel(c), IIF(closed, " closed", "")))
  IF NOT isVM AND NOT closed THEN
    IF c.state == S_FINISH {OR _exitLoop} THEN
      CALL finishHttp(c)
    ELSE
      CALL checkReRegister(c)
    END IF
  END IF
END FUNCTION

FUNCTION reRegister(isVM BOOLEAN, v INT, c INT)
  UNUSED_VAR(isVM)
  UNUSED_VAR(v)
  UNUSED_VAR(c)
END FUNCTION

FUNCTION handleStart(v TVMRec INOUT)
  DEFINE fake TConn
  --we ask for the GBC version to decide which protocol we choose
  IF _direct_mode THEN
    --request via FT and a -1 httpIdx trick
    --which will call handleGBCVersion in turn
    LET fake.idx = -1
    CALL checkRequestFT(fake, v, "gbc://VERSION") RETURNING status
  ELSE
    --just look in FGLGBCDIR
    IF _opt_gdc THEN
      CALL handleStart2(v)
    ELSE
      CALL handleGBCVersion(v, gbcResourceName("VERSION"))
    END IF
  END IF
END FUNCTION

FUNCTION handleGBCVersion(v TVMRec INOUT, gbcVerFile STRING)
  DEFINE t TEXT
  DEFINE vstr STRING
  LOCATE t IN FILE gbcVerFile
  LET vstr = t
  LET _gbcver = parseVersion(vstr)
  CALL log(SFMT("handleGBCVersion:%1,float:%2", vstr, _gbcver))
  LET _useJSWrapper = _gbcver >= 4.0
  IF _useJSWrapper THEN
    LET v.useSSE = _gbcver >= 4.0
  END IF
  CALL handleStart2(v)
END FUNCTION

FUNCTION handleStart2(v TVMRec INOUT)
  DEFINE url, procId, startPath,platfName,platfType STRING
  DEFINE no_browser BOOLEAN
  LET procId = v.procId
  LET no_browser = _opt_runonserver OR _opt_gdc
  IF NOT no_browser THEN
    LET startPath = SFMT("gbc/index.html?app=%1&useSSE=%2", procId, v.useSSE)
    IF _useJSWrapper THEN
      --since GBC5 we can announce being a browser thingy
      LET platfType=IIF(_gbcver >= 5.0,"browser","native")
      LET startPath = startPath, "&UR_PLATFORM_TYPE=",platfType
      --since GBC5 the chrome isn't shown for GDC so we masquerade as GWA
      LET platfName=IIF(_gbcver >= 5.0,"GWA","GDC")
      LET startPath = startPath, "&UR_PLATFORM_NAME=",platfName
      LET startPath = startPath, "&UR_PROTOCOL_TYPE=direct"
      IF _gbcver >= 4.0 THEN
        LET startPath = startPath, "&UR_PROTOCOL_VERSION=2"
      END IF
      IF _verbose THEN
        LET startPath = startPath, "&verbose=1"
      END IF
      LET startPath = startPath, "&debugmode=1"
    END IF
    IF _firstPath IS NULL THEN
      LET _firstPath = "/", startPath
    END IF
    LET url = SFMT("%1%2", _htpre, startPath)
  END IF
  CASE
    WHEN no_browser
      LET startPath = SFMT("ua/r/%2?app=%2", procId, procId)
      IF _firstPath IS NULL THEN
        LET _firstPath = "/", startPath
      END IF
      LET url = SFMT("%1%2", _htpre, startPath)
      IF _opt_gdc THEN
        CALL checkGDC(url)
      ELSE
        CALL connectToGMI(url)
      END IF
    WHEN _opt_nostart --we just write the starting URL on stdout
      DISPLAY url
    OTHERWISE
      CALL openBrowser(url)
  END CASE
END FUNCTION

FUNCTION connectToGMI(url STRING) --works only for the emulator
  --DISPLAY "runOnServer:", url
  --need to reset the env
  CALL fgl_setenv("FGLSERVER", _fglserver)
  CALL fgl_setenv("FGL_PRIVATE_DIR", "")
  CALL fgl_setenv("FGL_PUBLIC_DIR", "")
  CALL fgl_setenv("FGL_PUBLIC_IMAGEPATH", "")
  CALL fgl_setenv("FGL_PRIVATE_URL_PREFIX", "")
  CALL fgl_setenv("FGL_PUBLIC_URL_PREFIX", "")
  RUN SFMT("fglrun runonserver %1", url) WITHOUT WAITING
END FUNCTION

FUNCTION connectToGDC(url STRING) --works only for the emulator
  --DISPLAY "runOnServer:", url
  --need to reset the env
  CALL fgl_setenv("FGLSERVER", _fglserver)
  CALL fgl_setenv("FGL_PRIVATE_DIR", "")
  CALL fgl_setenv("FGL_PUBLIC_DIR", "")
  CALL fgl_setenv("FGL_PUBLIC_IMAGEPATH", "")
  CALL fgl_setenv("FGL_PRIVATE_URL_PREFIX", "")
  CALL fgl_setenv("FGL_PUBLIC_URL_PREFIX", "")
  RUN SFMT("fglrun runongdc %1", url) WITHOUT WAITING
END FUNCTION

--we need to read the encapsulated VM data and decice
--upon the type byte what is to do
FUNCTION readEncaps(v TVMRec INOUT)
  DEFINE bodySize, dataSize INT
  DEFINE type TINYINT
  DEFINE line STRING
  DEFINE chan base.Channel
  LET chan = v.chan
  LET bodySize = util.Channels.readNetInt32(chan)
  IF chan.isEof() THEN
    RETURN TAuiData, ""
  END IF
  LET dataSize = util.Channels.readNetInt32(chan)
  LET type = util.Channels.readNetInt8(chan)
  --DISPLAY "readEncaps: bodySize:",bodySize,",type:",type
  MYASSERT(bodySize == dataSize)
  CASE
    WHEN type = TAuiData
      --DISPLAY "read TAuiData"
      LET line = readLineFromVM(v, dataSize)
      CALL lookupNextImage(v)
    WHEN type = TFileTransfer
      --DISPLAY "read TFileTransfer"
      CALL handleFT(v, dataSize)
    OTHERWISE
      CALL myErr(SFMT("unhandled encaps type:%1", type))
  END CASE
  RETURN type, line
END FUNCTION

--unfortunately we can't use neither
--DataInputStream.readLine nor
--BufferedReader.readLine because both stop already at '\r'
--this forces us to read byte chunks until we discover '\n'
--which may give us even more than one line (in the processing case)
FUNCTION readLineFromVM(v TVMRec INOUT, dataSize INT) RETURNS STRING
  DEFINE line STRING
  VAR chan = v.chan
  IF dataSize == 0 THEN
    LET line = chan.readLine() --need to check for '\r'
    --DISPLAY "did read line:'",line,"'"
  ELSE
    --LET line=chan.readBinaryString(dataSize)
    LET line = chan.readOctets(dataSize)
    --DISPLAY sfmt("did read binary line(%1)='%2'",dataSize,line)
  END IF
  RETURN line
END FUNCTION

FUNCTION ReadLine(c TConn INOUT)
  DEFINE line STRING
  TRY
    LET line = c.chan.readLine()
  CATCH
    CALL log(SFMT("Error ReadLine:%1", err_get(status)))
  END TRY
  RETURN line
END FUNCTION

FUNCTION handleEmptyLine(c TConn INOUT)
  --DISPLAY "handleEmpyLine , line '' ,c:", c
  IF NOT c.isHTTP THEN
    CALL log(
        SFMT(">>>>handleEmptyLine: ignore empty line for:%1, close...",
            printSel(c)))
    CALL closeSel(c)
    RETURN GO_OUT, CLOSED
  END IF
  IF c.isHTTP AND c.state = S_WAITFORVM THEN
    CALL log(
        SFMT(">>>>handleEmptyLine S_WAITFORVM: ignore empty line for:%1, close...",
            printSel(c)))
    LET c.state = S_FINISH
    CALL finishHttp(c)
    --CALL closeSel(c)
    RETURN GO_OUT, CLOSED
  END IF
  IF c.isHTTP AND c.state == S_HTTPHANDLER AND c.path == "/ssepoll" THEN
    CALL log(SFMT("close ssepoll,close app, x:%1", printSel(c)))
    CALL closeSel(c)
    --CALL _htdelegate.exit()
  END IF
  IF c.isHTTP AND NOT c.state.equals(S_HEADERS) THEN
    DISPLAY "ASSERT handleEmptyLine:", printSel(c)
  END IF
  MYASSERT(c.isHTTP AND c.state == S_HEADERS)
  IF c.contentLen > 0 THEN
    LET c.state = S_WAITCONTENT
    RETURN FALSE, FALSE
  ELSE
    --DISPLAY "Finish of :", _s[c].path
    VAR closed = FALSE
    IF NOT invokeHttpHandler(c, c.path) THEN --might set state to S_FINISH
      MYASSERT(c.chan IS NULL)
      MYASSERT(c.active == FALSE)
      LET closed = TRUE
    END IF
    RETURN GO_OUT, closed
  END IF
END FUNCTION

FUNCTION pathWithQuery(x TConn INOUT) RETURNS STRING
  VAR path = x.path
  VAR query = x.query
  VAR result = SFMT("%1%2%3", path, IIF(query.getLength() > 0, "?", ""), query)
  RETURN result
END FUNCTION

FUNCTION printRequest(x TConn INOUT, where STRING)
  VAR path = x.path
  --IF fgl_getenv("VERBOSE") IS NULL THEN
  VAR swcache = x.headers["x-sw-cache"]
  LET swcache = IIF(swcache IS NOT NULL, SFMT(" %1", swcache), "")
  CALL printStdout(SFMT("%1 %2%3 ", x.method, pathWithQuery(x), swcache), TRUE)
  CALL log(SFMT("%1 %2 '%3'%4 %5", x.method, where, path, swcache, printSel(x)))
END FUNCTION

--main HTPP/VM connection state machine
FUNCTION handleLine(c TConn INOUT, line STRING) RETURNS BOOLEAN
  IF fgl_getenv("SHOWALLHTTP") IS NOT NULL THEN
    DISPLAY SFMT("handleLine:%1,line:%2 x:%3",
        c.id, interpretchars(line), printSel(c))
  END IF
  CASE
    WHEN NOT c.isHTTP
      CASE
        WHEN line.getIndexOf("meta ", 1) == 1 --no http: a VM did connect
          VAR vmidx = handleVMMetaSel(c, line)
          CALL log(SFMT("handleVMetaSel returns:%1", vmidx))
          RETURN TRUE
        WHEN line.getIndexOf("GET ", 1) == 1
            OR line.getIndexOf("PUT ", 1) == 1
            OR line.getIndexOf("POST ", 1) == 1
            OR line.getIndexOf("HEAD ", 1) == 1
            OR line.getIndexOf("OPTIONS ", 1) == 1
          CALL parseHttpLine(c, line)
          LET c.isHTTP = TRUE
          LET c.state = S_HEADERS
        OTHERWISE
          CALL myErr(SFMT("Unexpected connection handshake:%1", line))
      END CASE
    WHEN c.isHTTP
      MYASSERT(c.state == S_HEADERS)
      CALL parseHttpHeader(c, line)
    OTHERWISE
      CALL myErr("Unhandled case")
  END CASE
  RETURN FALSE
END FUNCTION

FUNCTION createFO(
    path STRING, forceAbsolute BOOLEAN)
    RETURNS(base.Channel, STRING, STRING)
  DEFINE fo base.Channel
  DEFINE err STRING
  IF NOT forceAbsolute AND path.getIndexOf("/", 1) == 1 THEN
    LET path = ".", path
  END IF
  LET fo = base.Channel.create()
  TRY
    CALL fo.openFile(path, "wb")
  CATCH
    LET err =
        SFMT("createFO (POST) outputFile:%1 failed:%2", path, err_get(status))
    CALL printStderr(err)
  END TRY
  RETURN fo, path, err
END FUNCTION

FUNCTION copyBytes(
    src base.Channel, dest base.Channel, numBytes INT)
    RETURNS BOOLEAN
  VAR bytesWritten = util.Channels.copyN(src, dest, numBytes)
  IF bytesWritten <> numBytes THEN
    CALL printStderr(
        SFMT("ERROR copyBytes:bytesWritten(%1)<>numBytes(%2)",
            bytesWritten, numBytes))
    RETURN FALSE
  END IF
  RETURN TRUE
END FUNCTION

#+ writes the POST data to a file
FUNCTION handleSimplePost(x TConn INOUT, path STRING) RETURNS BOOLEAN
  DEFINE chan base.Channel
  DEFINE fo base.Channel
  DEFINE err STRING
  LET chan = x.chan
  CALL createFO(path, FALSE) RETURNING fo, path, err
  IF err IS NOT NULL THEN
    RETURN FALSE
  END IF
  IF NOT copyBytes(chan, fo, x.contentLen) THEN
    RETURN FALSE
  END IF
  CALL fo.close()
  MYASSERT(os.Path.size(path) == x.contentLen)
  RETURN TRUE
END FUNCTION

#+ writes the mp data to a file
FUNCTION handleMultiPartUpload(
    x TConn INOUT, path STRING, ct STRING)
    RETURNS BOOLEAN
  DEFINE fo base.Channel
  DEFINE err STRING
  CONSTANT INITIAL = 1
  CONSTANT STARTBOUNDARY = 1
  CONSTANT STARTCONTENT = 2
  VAR chan = x.chan
  MYASSERT(startsWith(path, "/priv/"))
  VAR tmpFile = os.Path.join(_privdir, path.subString(7, path.getLength()))
  CALL log(
      SFMT("handleMultiPartUpload x:%1, path:%2,ct:%3, pwd:%4,tmpFile:%5",
          printSel(x), path, ct, os.Path.pwd(), tmpFile))
  CALL createFO(tmpFile, TRUE) RETURNING fo, path, err
  IF err IS NOT NULL THEN
    RETURN FALSE
  END IF
  VAR ctlen = x.contentLen
  VAR bidx = ct.getIndexOf("boundary=", 1)
  MYASSERT(bidx > 0)
  VAR boundary = ct.subString(bidx + 9, ct.getLength())
  --strip off unwanted continuations
  VAR tok = base.StringTokenizer.create(boundary, " \t;")
  IF tok.hasMoreTokens() THEN
    LET boundary = tok.nextToken()
  END IF
  --start value has 2 dashes more...
  LET boundary = "--", boundary
  VAR state = INITIAL
  VAR numRead = 0
  WHILE TRUE
    --read the headers until the empty line
    VAR line = chan.readLine()
    LET numRead = numRead + line.getLength() + 2 --\r\n
    --DISPLAY "handleMultiPartUpload line:'", line, "'"
    CASE
      WHEN line.getIndexOf(boundary, 1) == 1
        LET state = STARTBOUNDARY
      WHEN line.getLength() == 0
        CASE
          WHEN state == STARTBOUNDARY
            LET state = STARTCONTENT
            EXIT WHILE
          OTHERWISE
            CALL myErr("invalid state")
        END CASE
    END CASE
  END WHILE
  --set boundary to the end value
  VAR endboundary = SFMT("\r\n%1--\r\n", boundary)
  VAR blen = endboundary.getLength()
  VAR maxToRead = ctlen - numRead
  --special case: as there is only one file we redirect everything
  --except the end boundary into the tmpfile
  VAR written = util.Channels.copyN(chan, fo, maxToRead - blen)
  DISPLAY SFMT("did write:%1 to:%2", written, path)
  VAR boundary2 = chan.readOctets(length: blen)
  {
  DISPLAY "boundary2:'", boundary2, "',boundary:'", boundary, "'"
  DISPLAY "boundary2.len:",
      boundary2.getLength(),
      ",boundary.len:",
      boundary.getLength()
  }
  MYASSERT(endboundary == boundary2)
  CALL fo.close()
  RETURN TRUE
END FUNCTION

FUNCTION readBody(x TConn INOUT) RETURNS BOOLEAN
  VAR chan = x.chan
  TRY
    LET x.body = chan.readOctets(x.contentLen)
  CATCH
    VAR err = err_get(status)
    IF NOT chan.isEof() THEN
      CALL myErr(SFMT("handleWaitContent readBody:%1", err))
    END IF
    RETURN FALSE
  END TRY
  RETURN TRUE
END FUNCTION

FUNCTION handleWaitContent(x TConn INOUT) RETURNS BOOLEAN
  VAR path = x.path
  CALL log(
      SFMT("handleWaitContent %1, read:%2,x:%3",
          path, x.contentLen, printSel(x)))
  --the path check probably needs another delegate call
  IF path == "/newtest"
      OR os.Path.baseName(path) == "FDB_POST"
      OR path == "/post"
      OR path == "/QA_RESULT"
      OR path == "/qamessage"
      OR path == "/GOTO_TEST"
      OR startsWith(path, "/ua/") THEN
    IF NOT readBody(x) THEN
      RETURN FALSE
    END IF
    --DISPLAY "  body=", x.body
  ELSE
    VAR ct = x.contentType
    VAR ok = TRUE
    IF ct.getIndexOf("multipart/form-data", 1) > 0 THEN
      LET ok = handleMultiPartUpload(x, path, ct)
    ELSE
      LET ok = handleSimplePost(x, path)
    END IF
    IF NOT ok THEN
      RETURN http404(x, fn: path)
    END IF
  END IF
  RETURN invokeHttpHandler(x, path)
END FUNCTION

FUNCTION handleVMFinish(v TVMRec INOUT)
  DEFINE procId STRING
  DEFINE vmidx, httpIdx INT
  LET procId = v.procId
  MYASSERT(_selDict.contains(procId))
  LET vmidx = _selDict[procId]
  MYASSERT(vmidx == v.vmidx)
  IF v.useSSE THEN
    LET httpIdx = getSSEIdxFor(v)
  ELSE
    LET httpIdx = _v[vmidx].httpIdx
  END IF
  IF v.closeSeen THEN
    LET httpIdx = 0
    CALL selDictRemove(v.procId)
  END IF
  CALL log(
      SFMT("handleVMFinish:%1, http:%2",
          printV(v), IIF(httpIdx > 0, printSel(_s[httpIdx]), "notfound")))
  IF httpIdx <> 0 THEN
    CALL handleVM(v, TRUE, httpIdx)
    IF v.useSSE THEN
      CALL selDictRemove(v.procId)
    END IF
  END IF
  LET v.state = S_FINISH
  LET v.chan = close_chan(v.chan)
END FUNCTION

FUNCTION close_chan(chan base.Channel)
  DEFINE idx INT
  IF chan IS NOT NULL THEN
    CALL chan.close()
  END IF
  LET idx = _channels.search(NULL, chan)
  IF idx > 0 THEN
    --DISPLAY "close_chan:remove channels idx:",idx
    CALL _channels.deleteElement(idx)
  ELSE
    --DISPLAY "channel already removed"
  END IF
  RETURN NULL
END FUNCTION

FUNCTION closeSel(x TConn INOUT)
  CALL log(SFMT("closeSel:%1", printSel(x)))
  LET x.chan = close_chan(x.chan)
  LET x.active = FALSE
END FUNCTION

FUNCTION checkReRegister(c TConn INOUT)
  DEFINE newChan BOOLEAN
  DEFINE empty TConn
  DEFINE state STRING
  LET state = c.state
  --DISPLAY "checkReRegister:", printSel(c), ",state:", state
  IF (state <> S_FINISH)
      OR (newChan
              := (_keepalive
                  AND state == S_FINISH
                  AND c.isHTTP
                  AND c.chan IS NOT NULL))
          == TRUE THEN
    IF newChan THEN
      {
      CALL log(
          SFMT("re register newchan id:%1,c.chan IS NULL:%2",
              c.id, c.chan IS NULL))
      }
      LET empty.chan = c.chan
      LET empty.id = c.id
      LET c.* = empty.*
      LET c.active = TRUE
      LET c.starttime = CURRENT
      LET c.state = S_INIT
      LET c.keepalive = _keepalive
    END IF
  END IF
END FUNCTION

FUNCTION setWait(v TVMRec INOUT)
  --DISPLAY ">>setWait:", printV(v),base.Application.getStackTrace()
  MYASSERT(v.wait == FALSE)
  LET v.wait = TRUE
END FUNCTION

FUNCTION getNameC(chan base.Channel)
  DEFINE name STRING
  DEFINE namesize, xlen INT
  LET namesize = util.Channels.readNetInt32(chan)
  --namesize includes the terminating 0
  --LET name=chan.readBinaryString(namesize-1)
  LET name = chan.readOctets(namesize - 1)
  LET xlen = util.Channels.readNetInt8(chan) --read over terminating 0
  CALL log(
      SFMT("getNameC name:%1 len:%2 ,namesize:%3, bytes:%4",
          name, name.getLength(), namesize, namesize + 4))
  RETURN name, namesize + 4
END FUNCTION

FUNCTION FTName(name STRING) RETURNS STRING
  RETURN clientSideName(name, "FT") --all getfile/putfile lands in "FT"
END FUNCTION

FUNCTION cacheFileName(name STRING) RETURNS STRING
  RETURN clientSideName(
      name, "cacheFT") --all client side resources are in "cacheFT"
END FUNCTION

FUNCTION replace(src STRING, oldStr STRING, newString STRING)
  DEFINE b base.StringBuffer
  LET b = base.StringBuffer.create()
  CALL b.append(src)
  CALL b.replace(oldStr, newString, 0)
  RETURN b.toString()
END FUNCTION

FUNCTION backslash2slash(src STRING)
  RETURN replace(src, "\\", "/")
END FUNCTION

FUNCTION backslash2slashCnt(src STRING) RETURNS(STRING, INT)
  DEFINE occ INT
  DEFINE repl STRING
  LET occ = countOccur(src, "\\")
  LET repl = replace(src, "\\", "/")
  RETURN repl, occ
END FUNCTION

FUNCTION countOccur(src STRING, sub STRING) RETURNS INT
  DEFINE start, occ, sublen INT
  LET sublen = sub.getLength()
  LET start = 1
  WHILE (start := src.getIndexOf(sub, start)) > 0
    LET occ = occ + 1
    LET start = start + sublen
  END WHILE
  RETURN occ
END FUNCTION

FUNCTION clientSideName(name STRING, subDir STRING) RETURNS STRING
  DEFINE b base.StringBuffer
  LET b = base.StringBuffer.create()
  CALL b.append(name)
  IF NOT os.Path.exists(subDir) THEN
    MYASSERT(os.Path.mkdir(subDir) == 1)
  END IF
  --//first quote our replacement characters
  IF isWin() THEN
    CALL b.replace(",", ",,", 0)
  ELSE
    CALL b.replace("|", "||", 0)
  END IF
  CALL b.replace("_", "__", 0)
  --//make the file name a flat name
  IF isWin() THEN
    CALL b.replace("/", ",", 0)
    CALL b.replace("\\", ",", 0)
  ELSE
    CALL b.replace("/", "|", 0)
    CALL b.replace("\\", "|", 0)
  END IF
  CALL b.replace("..", "_", 0)
  CALL b.replace(" ", "_", 0)
  CALL b.replace(":", "_", 0)
  --CALL log(sfmt("clientSideName %1 returns %2",name,os.Path.join(subDir, b.toString())))
  RETURN os.Path.join(subDir, b.toString())
END FUNCTION

FUNCTION getURL(surl STRING) RETURNS URI
  DEFINE url URI
  LET url = URI.create(surl)
  RETURN url
END FUNCTION

FUNCTION getQueryParam(x TConn INOUT, param STRING) RETURNS STRING
  IF x.query.getLength() == 0 THEN
    RETURN NULL
  END IF
  --build queryDict on the fly
  IF x.queryDict.getLength() == 0 THEN
    LET x.queryDict = getQueryDict(x.query)
  END IF
  RETURN x.queryDict[param]
END FUNCTION

--checks for arg=<value> query params
FUNCTION getArgsFromQuery(query STRING) RETURNS STRING
  DEFINE idx INT
  DEFINE args STRING
  VAR tok = base.StringTokenizer.create(query, "&")
  WHILE tok.hasMoreTokens()
    VAR pstr = tok.nextToken()
    IF (idx := pstr.getIndexOf("=", 1)) != 0 THEN
      VAR name = pstr.subString(1, idx - 1)
      IF name.toLowerCase() == "arg" THEN
        VAR value = pstr.subString(idx + 1, pstr.getLength())
        LET args = args, " ", quote(value)
      END IF
    END IF
  END WHILE
  RETURN args
END FUNCTION

FUNCTION getQueryDict(query STRING) RETURNS TStringDict
  DEFINE idx INT
  DEFINE d TStringDict
  VAR tok = base.StringTokenizer.create(query, "&")
  WHILE tok.hasMoreTokens()
    VAR pstr = tok.nextToken()
    IF (idx := pstr.getIndexOf("=", 1)) != 0 THEN
      VAR name = pstr.subString(1, idx - 1)
      VAR value = pstr.subString(idx + 1, pstr.getLength())
      LET d[name] = value
    END IF
  END WHILE
  RETURN d
END FUNCTION

FUNCTION getURLQueryDict(surl STRING) RETURNS(TStringDict, URI)
  DEFINE url URI
  DEFINE d TStringDict
  LET surl = replace(surl, " ", "+")
  LET surl = backslash2slash(surl)
  IF surl.getIndexOf(":", 1) == 2 THEN --drive letter
    LET surl = "http:", surl.subString(3, surl.getLength())
  END IF
  LET url = URI.create(surl)
  LET d = getQueryDict(url.getQuery())
  --DISPLAY "getURLQueryDict:", surl, ":", util.JSON.stringify(d), ":", url.getPath()
  RETURN d, url
END FUNCTION

FUNCTION scanCacheParameters(
    v TVMRec INOUT, lastQ INT, fileName STRING, ftg FTGetImage)
  VAR query = fileName.subString(lastQ + 1, fileName.getLength())
  VAR d = getQueryDict(query)
  LET ftg.fileSize = d["s"]
  LET ftg.mtime = d["t"]
  CALL updateImg(v, ftg.*)
END FUNCTION

FUNCTION createOutputStream(
    v TVMRec INOUT, num INT, fn STRING, putfile BOOLEAN)
    RETURNS BOOLEAN
  DEFINE fc base.Channel
  IF putfile THEN
    MYASSERT(v.writeCPut IS NULL)
  ELSE
    MYASSERT(v.writeC IS NULL)
  END IF
  --CALL log(sfmt("createOutputStream:'%1'",fn))
  TRY
    LET fc = base.Channel.create()
    CALL fc.openFile(fn, "wb")
    IF putfile THEN
      LET v.writeCPut = fc
    ELSE
      LET v.writeC = fc
    END IF
    CALL log(
        SFMT("createOutputStream:did create file output stream for:%1", fn))
  CATCH
    CALL warning(SFMT("createOutputStream:%1", err_get(status)))
    IF num <> 0 THEN
      CALL sendFTStatus(v, num, FStErrDestination)
    END IF
    RETURN FALSE
  END TRY
  RETURN TRUE
END FUNCTION

FUNCTION hasPrefix(s STRING, prefix STRING)
  RETURN s.getIndexOf(prefix, 1) == 1
END FUNCTION

FUNCTION getLastModified(fn STRING) RETURNS INT
  DEFINE m INT
  DEFINE dt DATETIME YEAR TO SECOND
  LET dt = os.Path.mtime(fn)
  LET m = util.Datetime.toSecondsSinceEpoch(dt)
  MYASSERT(m IS NOT NULL)
  RETURN m
END FUNCTION

FUNCTION setLastModified(fn STRING, t INT)
  VAR dt = util.Datetime.fromSecondsSinceEpoch(t)
  MYASSERT(os.Path.setModificationTime(fn, dt) == TRUE)
END FUNCTION

FUNCTION lookupInCache(name STRING) RETURNS(BOOLEAN, INT, INT)
  DEFINE cachedFile STRING
  DEFINE s, t INT
  LET cachedFile = cacheFileName(name);
  IF NOT os.Path.exists(cachedFile) THEN
    --DISPLAY sfmt("did not find cachedFile:'%1' for name:'%2'",
    --     cachedFile,name)
    RETURN FALSE, 0, 0
  END IF
  LET s = os.Path.size(cachedFile)
  LET t = getLastModified(cachedFile)
  --CALL printStderr(sfmt("lookupInCache:%1,s:%2,t:%3,os.Path.mtime:%4",cachedFile,s,t,os.Path.mtime(cachedFile)))
  RETURN TRUE, s, t
END FUNCTION

FUNCTION getByte(x, pos) --pos may be 0..3
  DEFINE x, pos, b INTEGER
  LET b = util.Integer.shiftRight(x, 8 * pos)
  LET b = util.Integer.and(b, 255)
  RETURN b
END FUNCTION

FUNCTION limitPrintStr(s STRING)
  DEFINE len INT
  IF NOT _verbose THEN
    RETURN ""
  END IF
  LET len = s.getLength()
  IF len > 323 THEN
    RETURN s.subString(1, 160) || "..." || s.subString(len - 160, len)
  ELSE
    RETURN s
  END IF
END FUNCTION

FUNCTION parseVersion(version STRING)
  DEFINE fversion, testversion FLOAT
  DEFINE pointpos, major, idx INTEGER
  LET pointpos = version.getIndexOf(".", 1)
  IF pointpos == 0 OR pointpos = 1 THEN
    --version string did not contain a '.' or no major number
    CALL myErr(SFMT("parseVersion: no valid version (wrong dot):%1", version))
  ELSE
    LET major = version.subString(1, pointpos - 1)
    IF major IS NULL
        OR major
            > 100 THEN --one needs to adjust the 100 hopefully only after 300 years
      CALL myErr(
          SFMT("parseVersion: no valid major number:'%1' in version:%2",
              version.subString(1, pointpos - 1), version))
    END IF
  END IF
  --go a long as possible thru the string after '.' and remember the last
  --valid conversion, so it doesn't matter if a '.' or something else is right hand side of major.minor
  LET idx = 1
  LET fversion = NULL
  WHILE (testversion := version.subString(1, pointpos + idx)) IS NOT NULL
      AND pointpos + idx <= version.getLength()
    LET fversion = testversion
    --DISPLAY "fversion:",fversion," out of:",version.subString(1,pointpos+idx)
    LET idx = idx + 1
  END WHILE
  IF fversion IS NULL OR fversion == 0.0 THEN --we had no valid conversion
    CALL myErr(SFMT("parseVersion: can't convert to float:%1", version))
  END IF
  RETURN fversion
END FUNCTION

&define EQ( s1, s2 ) ((s1) == (s2))
{
FUNCTION EQ(s1 STRING, s2 STRING) RETURNS BOOLEAN
  RETURN s1.equals(s2)
END FUNCTION
}

FUNCTION EQI(s1 STRING, s2 STRING) RETURNS BOOLEAN
  DEFINE s1l, s2l STRING
  LET s1l = s1.toLowerCase()
  LET s2l = s2.toLowerCase()
  RETURN s1l.equals(s2l)
END FUNCTION
--&define NEQ(s1, s2) (NOT (s1).equals(s2))
{
FUNCTION NEQ(s1 STRING, s2 STRING) RETURNS BOOLEAN
  RETURN NOT EQ(s1, s2)
END FUNCTION
}

FUNCTION quoteVMStr(s STRING)
  DEFINE sb base.StringBuffer
  DEFINE len, i INT
  DEFINE c STRING
  LET sb = base.StringBuffer.create()
  LET len = s.getLength()
  FOR i = 1 TO len
    LET c = s.getCharAt(i)
    CASE c
      WHEN '\\'
        CALL sb.append('\\\\')
      WHEN '\n'
        CALL sb.append('\\n')
      WHEN '"'
        CALL sb.append('\\"')
      WHEN '$'
        CALL sb.append('\\$')
      WHEN '{'
        CALL sb.append('\\{')
      WHEN '}'
        CALL sb.append('\\}')
      OTHERWISE
        CALL sb.append(c)
    END CASE
  END FOR
  RETURN sb.toString()
END FUNCTION

FUNCTION parseInt(s STRING)
  DEFINE intVal INT
  LET intVal = s
  MYASSERT(intVal IS NOT NULL)
  RETURN intVal
END FUNCTION

FUNCTION writeToLog(s STRING)
  DEFINE diff INTERVAL MINUTE TO FRACTION(1)
  DEFINE chan base.Channel
  LET diff = CURRENT - _starttime
  IF _logChan IS NULL AND _opt_logfile IS NOT NULL THEN
    LET _logChan = base.Channel.create()
    CALL _logChan.openFile(_opt_logfile, "w")
  END IF
  IF _logChan IS NOT NULL THEN
    LET chan = _logChan
  ELSE
    CALL checkStderr()
    LET chan = _stderr
  END IF
  CALL chan.writeNoNL(diff)
  CALL chan.writeNoNL(" ")
  CALL chan.writeLine(s)
END FUNCTION

FUNCTION checkStderr()
  IF _stderr IS NULL THEN
    LET _stderr = base.Channel.create()
    CALL _stderr.openFile("<stderr>", "w")
  END IF
END FUNCTION

FUNCTION dlog(s STRING)
  DISPLAY s
END FUNCTION

FUNCTION log(s STRING)
  IF NOT _verbose AND _opt_logfile IS NULL THEN
    RETURN
  END IF
  CALL writeToLog(s)
END FUNCTION

FUNCTION warning(s STRING)
  DISPLAY "!!!!!!!!WARNING:", s
END FUNCTION

PRIVATE FUNCTION _findGBCIn(dirname)
  DEFINE dirname STRING
  IF os.Path.exists(os.Path.join(dirname, "index.html"))
      AND os.Path.exists(os.Path.join(dirname, "index.html"))
      AND os.Path.exists(os.Path.join(dirname, "VERSION")) THEN
    LET _gbcdir = dirname
    RETURN TRUE
  END IF
  RETURN FALSE
END FUNCTION

FUNCTION checkGBCAvailable()
  IF NOT _findGBCIn(os.Path.join(os.Path.pwd(), "gbc")) THEN
    IF NOT _findGBCIn(fgl_getenv("FGLGBCDIR")) THEN
      IF NOT _findGBCIn(
          os.Path.join(fgl_getenv("FGLDIR"), "web_utilities/gbc/gbc")) THEN
        CALL myErr(
            "Can't find a GBC in <pwd>/gbc, fgl_getenv('FGLGBCDIR') or $FGLDIR/web_utilities/gbc/gbc")
      END IF
    END IF
  END IF
END FUNCTION

FUNCTION already_quoted(path)
  DEFINE path, first, last STRING
  LET first = NVL(path.getCharAt(1), "NULL")
  LET last = NVL(path.getCharAt(path.getLength()), "NULL")
  IF isWin() THEN
    RETURN (first == '"' AND last == '"')
  END IF
  RETURN (first == "'" AND last == "'") OR (first == '"' AND last == '"')
END FUNCTION

FUNCTION quote(path)
  DEFINE path STRING
  IF path.getIndexOf(" ", 1) > 0 THEN
    IF NOT already_quoted(path) THEN
      LET path = '"', path, '"'
    END IF
  ELSE
    IF already_quoted(path) AND isWin() THEN --remove quotes(Windows)
      LET path = path.subString(2, path.getLength() - 1)
    END IF
  END IF
  RETURN path
END FUNCTION

FUNCTION checkGDC(url STRING)
  DEFINE gdc, cmd STRING
  LET gdc = getGDCPath()
  IF NOT os.Path.exists(gdc) THEN
    CALL myErr(SFMT("Can't find GDC executable at '%1'", gdc))
  END IF
  IF NOT os.Path.executable(gdc) THEN
    CALL warning(SFMT("checkGDC:os.Path not executable:%1", gdc))
  END IF
  LET cmd = SFMT("%1 --listen none -p 8000 -u %2", quote(gdc), url)
  CALL log(SFMT("GDC cmd:%1", cmd))
  RUN cmd WITHOUT WAITING
END FUNCTION

FUNCTION extSlashless(name STRING)
  IF name.getIndexOf("/", name.getLength()) > 0 THEN
    LET name = name.subString(1, name.getLength() - 1)
  END IF
  RETURN os.Path.extension(name)
END FUNCTION

FUNCTION getGDCPath()
  DEFINE cmd, fglserver, fglprofile, executable STRING
  DEFINE native, dbg_unset, redir, orig, gdc STRING
  IF (gdc := fgl_getenv("GDC")) IS NOT NULL THEN
    IF isMac() AND os.Path.isDirectory(gdc) AND extSlashless(gdc) == "app" THEN
      --avoid the need for the full Mac OS lindworm
      LET gdc = os.Path.join(gdc, "Contents/MacOS/gdc")
    END IF
    IF os.Path.exists(gdc) THEN
      RETURN gdc
    END IF
    CALL warning(SFMT("getGDCPath: GDC doesn't exist at:%1", gdc))
  END IF
  LET orig = fgl_getenv("FGLSERVER")
  LET fglserver = fgl_getenv("GDCFGLSERVER")
  IF fglserver IS NULL THEN
    CALL myErr("either GDC or GDCFGLSERVER must be set to connect to GDC")
  END IF
  CALL fgl_setenv("FGLSERVER", fglserver)
  LET fglprofile = fgl_getenv("FGLPROFILE")
  IF fglprofile IS NOT NULL THEN
    LET native = os.Path.join(_owndir, "fglprofile")
    CALL fgl_setenv("FGLPROFILE", native)
  END IF
  LET dbg_unset = IIF(isWin(), "set FGLGUIDEBUG=", "unset FGLGUIDEBUG")
  --LET redir = IIF(isWin(), "2>nul", "2>/dev/null")
  LET cmd =
      SFMT("%1&&fglrun %2 %3",
          dbg_unset, quote(os.Path.join(_owndir, "getgdcpath")), redir)
  LET executable = getProgramOutput(cmd)
  IF fglprofile IS NOT NULL THEN
    CALL fgl_setenv("FGLPROFILE", fglprofile)
  END IF
  CALL log(SFMT("getGDCPath:%1", executable))
  CALL fgl_setenv("FGLSERVER", orig)
  RETURN executable
END FUNCTION

FUNCTION winQuoteUrl(url STRING) RETURNS STRING
  LET url = replace(url, "%", "^%")
  LET url = replace(url, "&", "^&")
  RETURN url
END FUNCTION

FUNCTION getMacChromeCmd(url STRING)
  CONSTANT CHROME = "Google Chrome"
  DEFINE cmd STRING
  IF fgl_getenv("KIOSK") IS NOT NULL THEN
    LET cmd =
        SFMT("open -n -a %1 --args '--app=%2' '--force-devtools-available' '--no-default-browser-check'",
            quote(CHROME), url)
  ELSE
    LET cmd = SFMT("open -a %1  '%2'", quote(CHROME), url)
  END IF
  RETURN cmd
END FUNCTION

FUNCTION getWinEdgeChromeCmd(browser STRING, url STRING)
  LET browser = IIF(browser == "edge", "msedge", browser)
  IF _opt_kiosk_mode THEN
    RETURN SFMT("start %1 --new-window --app=%2", browser, winQuoteUrl(url))
  ELSE
    RETURN SFMT("start %1 %2", browser, winQuoteUrl(url))
  END IF
END FUNCTION

--see https://stackoverflow.com/questions/32458095/how-can-i-get-the-default-browser-name-in-bash-script-on-mac-os-x
FUNCTION getMacDefaultBrowser()
  CONSTANT PBUDDY = "/usr/libexec/PlistBuddy"
  DEFINE plist, cmd, result, err, browser STRING
  DEFINE cnt, lastDot INT
  LET browser = "none"
  LET plist =
      os.Path.join(
          fgl_getenv("HOME"),
          "Library/Preferences/com.apple.LaunchServices/com.apple.launchservices.secure.plist")
  IF NOT os.Path.exists(plist) THEN
    RETURN browser
  END IF
  WHILE TRUE
    LET cmd =
        SFMT('%1 -c "Print LSHandlers:%2:LSHandlerURLScheme" %3',
            PBUDDY, cnt, quote(plist))
    CALL getProgramOutputWithErr(cmd) RETURNING result, err
    IF err IS NOT NULL THEN
      --DISPLAY SFMT("Can't run:%1,err:%2", cmd, err)
      EXIT WHILE
    END IF
    IF result == "http" OR result == "https" THEN
      LET cmd =
          SFMT('%1 -c "Print LSHandlers:%2:LSHandlerRoleAll" %3',
              PBUDDY, cnt, quote(plist))
      CALL getProgramOutputWithErr(cmd) RETURNING result, err
      IF err IS NULL THEN
        --cut last entry from "com.apple.safari" or "com.google.chrome"
        LET lastDot = lastIndexOf(result, ".")
        IF lastDot > 0 THEN
          LET browser = result.subString(lastDot + 1, result.getLength())
        END IF
      END IF
      EXIT WHILE
    END IF
    LET cnt = cnt + 1
  END WHILE
  CALL log(SFMT("default browser:%1", browser))
  RETURN browser
END FUNCTION

FUNCTION trimWhiteSpace(s STRING)
  LET s = s.trim()
  LET s = replace(s, "\n", "")
  LET s = replace(s, "\r", "")
  RETURN s
END FUNCTION

FUNCTION trimWhiteSpaceAndLower(s STRING)
  LET s = trimWhiteSpace(s)
  LET s = s.toLowerCase()
  RETURN s
END FUNCTION

FUNCTION getWinDefaultBrowser() RETURNS STRING
  DEFINE cmd, res, err, ext STRING
  DEFINE sz_idx, q_idx1, q_idx2 INT
  DEFINE success BOOLEAN
  --first try Windows 10
  LET cmd =
      "reg query HKEY_CURRENT_USER\\SOFTWARE\\Microsoft\\Windows\\Shell\\Associations\\URLAssociations\\http\\UserChoice /v ProgID"
  CALL getProgramOutputWithErr(cmd) RETURNING res, err
  IF err IS NULL THEN
    LET sz_idx = res.getIndexOf("REG_SZ", 1)
    IF sz_idx > 0 THEN
      LET res = res.subString(sz_idx + 6, res.getLength())
      LET res = trimWhiteSpaceAndLower(res)
      LET success = TRUE
    END IF
  ELSE --older Windows
    LET cmd = "reg query HKEY_CLASSES_ROOT\\http\\shell\\open\\command /ve"
    CALL getProgramOutputWithErr(cmd) RETURNING res, err
    IF err IS NULL THEN
      LET sz_idx = res.getIndexOf("REG_SZ", 1)
      IF sz_idx > 0 THEN
        LET res = res.subString(sz_idx + 6, res.getLength())
        --remove '"' from the path
        --it's something like '"C:\Program Files\Microsoft\Edge\Application\msedge.exe"' ...
        LET q_idx1 = res.getIndexOf('"', 1)
        IF q_idx1 > 0 THEN
          LET q_idx2 = res.getIndexOf('"', q_idx1 + 1)
          IF q_idx2 > 0 THEN
            LET res = res.subString(q_idx1 + 1, q_idx2 - 1)
            LET res = os.Path.baseName(res)
            LET ext = os.Path.extension(res)
            IF ext IS NOT NULL THEN
              LET res = res.subString(1, res.getLength() - ext.getLength() - 1)
            END IF
            LET res = res.toLowerCase()
            --and the wanted result would be "msedge"
            LET success = TRUE
          END IF
        END IF
      END IF
    END IF
  END IF
  CALL log(SFMT("getWinDefaultBrowser res:'%1',success:%2", res, success))
  CASE
    WHEN NOT success
      RETURN "none"
    WHEN res.getIndexOf("firefox", 1) > 0
      RETURN "firefox"
    WHEN res.getIndexOf("msedge", 1) > 0
      RETURN "edge"
    WHEN res.getIndexOf("chrome", 1) > 0
      RETURN "chrome"
  END CASE
  RETURN res
END FUNCTION

FUNCTION openBrowser(url)
  DEFINE url, cmd, browser, pre, lbrowser, defbrowser STRING
  CALL log(SFMT("openBrowser url:%1", url))
  IF fgl_getenv("SLAVE") IS NOT NULL THEN
    CALL log("gdcm SLAVE set,return")
    RETURN
  END IF
  LET browser = fgl_getenv("BROWSER")
  IF browser=="none" THEN
    DISPLAY "Copy the following URL into your browser:"
    DISPLAY url
    RETURN
  END IF
  CASE
    WHEN browser IS NOT NULL AND browser <> "default" AND browser <> "standard"
      IF browser == "gdcm" THEN --TODO: gdcm
        CASE
          WHEN isMac()
            LET browser = "./gdcm.app/Contents/MacOS/gdcm"
          WHEN isWin()
            LET browser = ".\\gdcm.exe"
          OTHERWISE
            LET browser = "./gdcm"
        END CASE
      END IF
      CASE
        WHEN isMac() AND browser <> "./gdcm.app/Contents/MacOS/gdcm"
          IF browser == "chrome" OR browser == "Google Chrome" THEN
            LET cmd = getMacChromeCmd(url)
          ELSE
            LET cmd = SFMT("open -a %1 '%2'", quote(browser), url)
          END IF
        WHEN isWin()
          LET lbrowser = browser.toLowerCase()
          --no path separator and no .exe given: we use start
          IF browser.getIndexOf("\\", 1) == 0
              AND lbrowser.getIndexOf(".exe", 1) == 0 THEN
            CASE
              WHEN (browser == "edge"
                  OR browser == "msedge"
                  OR browser == "chrome")
                LET cmd = getWinEdgeChromeCmd(browser, url)
              OTHERWISE
                LET pre = "start "
            END CASE
          END IF
          IF cmd IS NULL THEN
            LET cmd = SFMT('%1%2 %3', pre, quote(browser), winQuoteUrl(url))
          END IF
        OTHERWISE --Unix
          LET cmd = SFMT("%1 '%2'", quote(browser), url)
      END CASE
    OTHERWISE --standard browser
      CASE
        WHEN isWin()
          LET defbrowser = getWinDefaultBrowser()
          CASE
            WHEN defbrowser == "edge" OR defbrowser == "chrome"
              LET cmd = getWinEdgeChromeCmd(defbrowser, url)
            OTHERWISE
              LET cmd = SFMT("start %1", winQuoteUrl(url))
          END CASE
        WHEN isMac()
          IF getMacDefaultBrowser() == "chrome" THEN
            LET cmd = getMacChromeCmd(url)
          ELSE
            LET cmd = SFMT("open '%1'", url)
          END IF
        OTHERWISE --assume kinda linux
          LET cmd = SFMT("xdg-open '%1'", url)
      END CASE
  END CASE
  CALL log(SFMT("openBrowser cmd:%1", cmd))
  RUN cmd WITHOUT WAITING
END FUNCTION

FUNCTION isWin()
  RETURN os.Path.separator() == "\\"
END FUNCTION

FUNCTION isMac()
  IF NOT _askedOnMac THEN
    LET _askedOnMac = TRUE
    LET _isMac = isMacInt()
  END IF
  RETURN _isMac
END FUNCTION

FUNCTION isMacInt()
  IF NOT isWin() THEN
    RETURN getProgramOutput("uname") == "Darwin"
  END IF
  RETURN FALSE
END FUNCTION

FUNCTION getProgramOutput(cmd STRING) RETURNS STRING
  DEFINE result, err STRING
  CALL getProgramOutputWithErr(cmd) RETURNING result, err
  IF err IS NOT NULL THEN
    CALL myErr(SFMT("failed to RUN:%1%2", cmd, err))
  END IF
  RETURN result
END FUNCTION

FUNCTION getProgramOutputWithErr(cmd STRING) RETURNS(STRING, STRING)
  DEFINE cmdOrig, tmpName, errStr STRING
  DEFINE txt TEXT
  DEFINE ret STRING
  DEFINE code INT
  LET cmdOrig = cmd
  LET tmpName = makeTempName()
  LET cmd = cmd, ">", tmpName, " 2>&1"
  --DISPLAY "run:", cmd
  RUN cmd RETURNING code
  --DISPLAY "code:", code
  LOCATE txt IN FILE tmpName
  LET ret = txt
  CALL os.Path.delete(tmpName) RETURNING status
  IF code THEN
    LET errStr = ",\n  output:", ret
    CALL os.Path.delete(tmpName) RETURNING code
  ELSE
    --remove \r\n
    IF ret.getCharAt(ret.getLength()) == "\n" THEN
      LET ret = ret.subString(1, ret.getLength() - 1)
    END IF
    IF ret.getCharAt(ret.getLength()) == "\r" THEN
      LET ret = ret.subString(1, ret.getLength() - 1)
    END IF
  END IF
  RETURN ret, errStr
END FUNCTION

#+computes a temporary file name
FUNCTION makeTempName()
  DEFINE tmpDir, tmpName, sbase, curr STRING
  DEFINE sb base.StringBuffer
  DEFINE i INT
  IF isWin() THEN
    LET tmpDir = fgl_getenv("TEMP")
  ELSE
    LET tmpDir = "/tmp"
  END IF
  LET curr = CURRENT
  LET sb = base.StringBuffer.create()
  CALL sb.append(curr)
  CALL sb.replace(" ", "_", 0)
  CALL sb.replace(":", "_", 0)
  CALL sb.replace(".", "_", 0)
  CALL sb.replace("-", "_", 0)
  LET sbase = SFMT("fgl_%1_%2", fgl_getpid(), sb.toString())
  LET sbase = os.Path.join(tmpDir, sbase)
  FOR i = 1 TO 10000
    LET tmpName = SFMT("%1%2.tmp", sbase, i)
    IF NOT os.Path.exists(tmpName) THEN
      RETURN tmpName
    END IF
  END FOR
  CALL myErr("makeTempName:Can't allocate a unique name")
  RETURN NULL
END FUNCTION

FUNCTION sendFileToVM(v TVMRec INOUT, num INT, name STRING)
  DEFINE ch base.Channel
  DEFINE size INT
  LET ch = base.Channel.create()
  TRY
    CALL ch.openFile(name, "r")
  CATCH
    CALL sendFTStatus(v, num, FStErrSource)
    RETURN
  END TRY
  LET size = os.Path.size(name)
  CALL sendAck(v, num, name)
  CALL sendBody(v, num, ch, size)
  CALL ch.close()
  CALL sendEof(v, num)
  CALL setWait(v)
END FUNCTION

FUNCTION getWriteNum(v TVMRec INOUT)
  DEFINE num INT
  LET num = v.writeNum2
  IF num <> 0 THEN
    RETURN num
  END IF
  MYASSERT(v.writeNum <> 0)
  RETURN v.writeNum
END FUNCTION

FUNCTION resetWriteNum(v TVMRec INOUT, num INT)
  IF v.writeNum2 == num THEN
    LET v.writeNum2 = 0
  ELSE
    MYASSERT(v.writeNum != 0 AND v.writeNum == num)
    LET v.writeNum = 0
  END IF
END FUNCTION

FUNCTION handleFTPutFile(v TVMRec INOUT, num INT, remaining INT) RETURNS INT
  DEFINE fileSize, numBytes INT
  DEFINE name STRING
  DEFINE chan base.Channel
  LET chan = v.chan
  LET fileSize = util.Channels.readNetInt32(chan)
  CALL getNameC(chan) RETURNING name, numBytes
  LET remaining = remaining - 4 - numBytes

  CALL log(
      SFMT("handleFTPutFile name:%1,num:%2,v.writeNum:%3,v.writeNum2:%4,v:%5'",
          name, num, v.writeNum, v.writeNum2, printV(v)))
  IF v.writeNum != 0 THEN
    LET v.writeNum2 = num
  ELSE
    LET v.writeNum = num
  END IF
  CALL log(SFMT("  v.writeNum:%1,v.writeNum2:%2", v.writeNum, v.writeNum2))
  IF createOutputStream(v, num, FTName(name), TRUE) THEN
    LET v.vmputfile = name
    CALL log(SFMT("v.vmputfile:%1,v:%2", v.vmputfile, printV(v)))
    CALL sendAck(v, num, name)
    CALL setWait(v)
  ELSE
    DISPLAY "createOutputStream failed!! for:", FTName(name)
  END IF
  RETURN remaining
END FUNCTION

FUNCTION handleFTGetFile(v TVMRec INOUT, num INT, remaining INT) RETURNS INT
  DEFINE numBytes, mId INT
  DEFINE name, sname STRING
  DEFINE chan base.Channel
  DEFINE ext STRING
  LET chan = v.chan
  CALL getNameC(chan) RETURNING name, numBytes
  LET remaining = remaining - numBytes
  IF remaining > 0 THEN --read extension list
    --LET ext=chan.readBinaryString(remaining)
    LET ext = chan.readOctets(remaining)
    DISPLAY "ext:", ext
    LET remaining = 0
  END IF
  CALL log(
      SFMT("handleFTGetFile name:'%1',num:%2, remaining:%3",
          name, num, remaining))
  IF v.FTFC THEN
    --the VM did send the FT frontcall already at this point
    CALL sendFileToVM(v, num, name)
  ELSE
    LET v.vmgetfile = name
    LET v.vmgetfilenum = num
    LET sname = os.Path.baseName(name)
    --the following is a hack because it fakes a function call
    --not coming from the VM
    LET v.rnFTNodeId = v.aui.getLength() + 1
    LET mId = v.rnFTNodeId
    LET v.VmCmd =
        SFMT('om 1 {{an 0 FunctionCall %1 {{isSystem "0"} {moduleName "standard"} {name "fgl_getfile"} {paramCount "2"} {returnCount "0"}} {{FunctionCallParameter %2 {{dataType "STRING"} {isNull "0"} {value "%3"}} {}} {FunctionCallParameter %4 {{dataType "STRING"} {isNull "0"} {value "../tmp_getfile.upload"}} {}}}}}',
            mId, mId + 1, sname, mId + 2)
    --we feed the fake cmd to the GBC
    --after the GBC did upload the file we need to send the file to the VM
    CALL handleVM(v, FALSE, 0)
  END IF
  RETURN remaining
END FUNCTION

FUNCTION handleFTAck(v TVMRec INOUT, num INT, remaining INT) RETURNS INT
  DEFINE numBytes, lastQ INT
  DEFINE name STRING
  DEFINE found BOOLEAN
  DEFINE ftg FTGetImage
  DEFINE chan base.Channel
  LET chan = v.chan
  CALL getNameC(chan) RETURNING name, numBytes
  LET remaining = remaining - numBytes
  CALL log(
      SFMT("handleFTAck name:'%1',num:%2,vmVersion:%3", name, num, v.vmVersion))
  IF v.vmVersion >= 3.2 AND name == "!!__cached__!!" THEN
    CALL loadFileFromCache(v, num)
    CALL resetWriteNum(v, num)
    CALL lookupNextImage(v)
  ELSE
    CALL ftgFromNum(v, num) RETURNING found, ftg.*
    IF found THEN
      --DISPLAY "ftg:", util.JSON.stringify(ftg)
      LET lastQ = lastIndexOf(name, "?")
      IF lastQ > 0
          AND getIndexOf(name.subString(lastQ + 1, name.getLength()), "s=")
              > 0 THEN
        CALL scanCacheParameters(v, lastQ, name, ftg.*)
      END IF
      MYASSERT(createOutputStream(v, 0, cacheFileName(ftg.name), FALSE) == TRUE)
    ELSE
      CALL log(SFMT("  no ftg for:%1", num))
    END IF
  END IF
  RETURN remaining
END FUNCTION

FUNCTION handleFTBody(v TVMRec INOUT, num INT, remaining INT) RETURNS INT
  DEFINE chan base.Channel
  LET chan = v.chan
  CALL log(SFMT("FTbody for num:%1,remaining:%2", num, remaining))
  CALL log(
      SFMT("  _v[vmidx].writeNum:%1,_v[vmidx].writeNum2:%2",
          v.writeNum, v.writeNum2))
  MYASSERT(num == v.writeNum OR num == v.writeNum2)
  IF num > 0 THEN
    MYASSERT(v.writeCPut IS NOT NULL)
    --LET written = _v[vmidx].writeCPut.write(buf)
    MYASSERT(copyBytes(chan, v.writeCPut, remaining) == TRUE)
    --DISPLAY "written FTPutfile:", written
  ELSE
    MYASSERT(v.writeC IS NOT NULL)
    --LET written = _v[vmidx].writeC.write(buf)
    MYASSERT(copyBytes(chan, v.writeC, remaining) == TRUE)
    --DISPLAY "written:", written
  END IF
  RETURN 0
END FUNCTION

FUNCTION handleFTStatus(v TVMRec INOUT, num INT, remaining INT) RETURNS INT
  DEFINE fstatus INT
  DEFINE found BOOLEAN
  DEFINE ftg FTGetImage
  DEFINE chan base.Channel
  LET chan = v.chan
  LET fstatus = util.Channels.readNetInt32(chan)
  LET remaining = remaining - 4
  CALL log(SFMT("handleFTStatus for num:%1,status:%2", num, fstatus))
  CASE fstatus
    WHEN FTOk --ok
    WHEN FStErrSource
      CALL resetWriteNum(v, num)
      CALL ftgFromNum(v, num) RETURNING found, ftg.*
      MYASSERT(found == TRUE)
      CALL handleFTNotFound(v, ftg.*)
    OTHERWISE
      CALL myErr("unhandled fstatus")
  END CASE
  RETURN remaining
END FUNCTION

FUNCTION createPutFileFC(v TVMRec INOUT)
  DEFINE dest, ftname STRING
  DEFINE mId INT
  MYASSERT(v.vmputfile IS NOT NULL)
  MYASSERT(v.httpIdx > 0)
  LET dest = v.vmputfile
  LET ftname = FTName(dest)
  LET ftname = backslash2slash(ftname)
  LET v.cliputfile = "!!!__fake__pending__!!!"
  IF _opt_gdc THEN
    LET ftname = _htpre, "putfile/", ftname, SFMT("?procId=%1", v.procId)
  END IF
  LET dest = backslash2slash(dest)
  --the following is a hack because it fakes
  --a function call
  LET v.rnFTNodeId = v.aui.getLength() + 1
  LET mId = v.rnFTNodeId
  LET v.VmCmd =
      SFMT('om 1 {{an 0 FunctionCall %1 {{isSystem "0"} {moduleName "standard"} {name "fgl_putfile"} {paramCount "2"} {returnCount "0"}} {{FunctionCallParameter %2 {{dataType "STRING"} {isNull "0"} {value "%3"}} {}} {FunctionCallParameter %4 {{dataType "STRING"} {isNull "0"} {value "%5"}} {}}}}}',
          mId, mId + 1, ftname, mId + 2, dest)
  --we feed the fake cmd to the GBC
  --after the GBC did get the file we need to complete the FTEof status
  CALL handleVM(v, FALSE, 0)
END FUNCTION

FUNCTION handleFTEof(v TVMRec INOUT, num INT)
  DEFINE found BOOLEAN
  DEFINE ftg FTGetImage
  CALL log(SFMT("handleFTEof for num:%1,v:%2", num, printV(v)))
  MYASSERT(num == v.writeNum OR num == v.writeNum2)
  IF num > 0 THEN
    MYASSERT(v.writeCPut IS NOT NULL)
    CALL v.writeCPut.close()
    LET v.writeCPut = NULL
  ELSE
    MYASSERT(v.writeC IS NOT NULL)
    CALL v.writeC.close()
    LET v.writeC = NULL
  END IF
  CALL ftgFromNum(v, num) RETURNING found, ftg.*
  IF found THEN
    CALL handleDelayedImage(v, ftg.*)
  END IF
  IF NOT v.FTFC AND v.vmputfile IS NOT NULL THEN
    CALL createPutFileFC(v)
  ELSE
    CALL resetWriteNum(v, num)
    CALL sendFTStatus(v, num, FTOk)
    CALL lookupNextImage(v)
  END IF
END FUNCTION

FUNCTION handleFT(v TVMRec INOUT, dataSize INT)
  DEFINE ftType TINYINT
  DEFINE num, remaining INT
  DEFINE chan base.Channel
  LET chan = v.chan
  LET ftType = util.Channels.readNetInt8(chan)
  LET num = util.Channels.readNetInt32(chan)
  LET remaining = dataSize - 5
  CALL log(
      SFMT("handleFT ftType:%1,num:%2, remaining:%3",
          IIF((_logChan IS NOT NULL) OR _verbose, getFT2Str(ftType), ""),
          num,
          remaining))
  CASE ftType
    WHEN FTPutFile
      LET remaining = handleFTPutFile(v, num, remaining)
    WHEN FTGetFile
      LET remaining = handleFTGetFile(v, num, remaining)
    WHEN FTAck
      LET remaining = handleFTAck(v, num, remaining)
    WHEN FTBody
      LET remaining = handleFTBody(v, num, remaining)
    WHEN FTStatus
      LET remaining = handleFTStatus(v, num, remaining)
    WHEN FTEof
      CALL handleFTEof(v, num)
    OTHERWISE
      CALL myErr("handleFT:unhandled case")
  END CASE
  MYASSERT(remaining == 0)
END FUNCTION

FUNCTION loadFileFromCache(v TVMRec INOUT, num INT)
  DEFINE ftg FTGetImage
  DEFINE found BOOLEAN
  CALL ftgFromNum(v, num) RETURNING found, ftg.*
  IF NOT found THEN
    RETURN
  END IF
  LET ftg.cache = FALSE
  CALL handleDelayedImage(v, ftg.*)
END FUNCTION

FUNCTION checkCached4Fmt(src STRING) RETURNS(BOOLEAN, STRING, INT, INT)
  DEFINE mid, realPath STRING
  DEFINE s, t, lastQ INT
  IF src.getIndexOf("__VM__/", 1) == 0 OR src.getIndexOf("?", 1) == 0 THEN
    RETURN FALSE, NULL, 0, 0
  END IF
  LET mid = src.subString(8, src.getLength())
  LET lastQ = lastIndexOf(mid, "?")
  VAR query = mid.subString(lastQ + 1, mid.getLength())
  VAR d = getQueryDict(query)
  MYASSERT(d.getLength() >= 2)
  IF d.getLength() == 0 THEN
    RETURN FALSE, NULL, 0, 0
  END IF
  LET s = d["s"]
  LET t = d["t"]
  LET realPath = mid.subString(1, lastQ - 1)
  RETURN TRUE, realPath, s, t
END FUNCTION

FUNCTION handleDelayedImage(v TVMRec INOUT, ftg FTGetImage)
  DEFINE cachedFile STRING
  DEFINE xidx INT
  LET cachedFile = cacheFileName(ftg.name);
  CALL handleDelayedImageInt(v, ftg.*, cachedFile)
  IF ftg.httpIdx == -1 THEN
    CALL handleGBCVersion(v, cachedFile)
    RETURN
  END IF
  MYASSERT(ftg.httpIdx > 0)
  LET xidx = ftg.httpIdx
  CALL handleDelayedImageX(_s[xidx], cachedFile)
END FUNCTION

FUNCTION handleDelayedImageX(x TConn INOUT, cachedFile STRING)
  MYASSERT(x.state == S_WAITFORVM)
  IF processFile(x: x, fname: cachedFile, cache: TRUE, checkExists: TRUE) THEN
    CALL finishHttp(x)
  ELSE
    CALL closeSel(x)
  END IF
END FUNCTION

FUNCTION handleFTNotFound(v TVMRec INOUT, ftg FTGetImage)
  DEFINE xidx, idx INT
  DEFINE name, vmName STRING
  IF ftg.httpIdx == -1 THEN
    CALL myErr(
        SFMT("Did not find:%1 in your remote FGLGBCDIR, is FGLGBCDIR not set probably ?",
            ftg.name))
  END IF
  MYASSERT(ftg.httpIdx > 0)
  LET xidx = ftg.httpIdx
  CALL removeImg(v, ftg.*)
  LET name = ftg.name
  CALL log(SFMT("handleFTNotFound: %1", name))
  CASE
    WHEN name.getIndexOf("gbc://", 1) == 1
      LET vmName = name.subString(7, name.getLength())
    WHEN name.getIndexOf("webcomponents/", 1) == 1
      LET idx = name.getIndexOf("/", 15)
      IF idx > 0 THEN
        LET vmName = name.subString(idx + 1, name.getLength())
      END IF
  END CASE
  CALL handleFTNotFoundX(_s[xidx], v, ftg, vmName)
END FUNCTION

FUNCTION handleFTNotFoundX(
    x TConn INOUT, v TVMRec INOUT, ftg FTGetImage INOUT, vmName STRING)
  IF vmName IS NOT NULL THEN
    CALL log(SFMT("  retry FT request with:%1", vmName))
    CALL checkRequestFT(x, v, vmName) RETURNING status
  ELSE
    IF http404(x, ftg.name) THEN
      CALL finishHttp(x)
    ELSE
      CALL closeSel(x)
    END IF
  END IF
END FUNCTION

FUNCTION handleDelayedImageInt(
    v TVMRec INOUT, ftg FTGetImage, cachedFile STRING)
  DEFINE t INT
  CALL log(
      SFMT("handleDelayedImageInt:%1,ftg:%2",
          printV(v), util.JSON.stringify(ftg)))
  CALL removeImg(v, ftg.*)
  IF NOT ftg.cache OR ftg.mtime == 0 THEN
    {
    DISPLAY "  return NOT ftg.cache OR ftg.mtime, cachedFile:",
        cachedFile,
        ", exists:",
        os.Path.exists(cachedFile)
    }
    RETURN
  END IF
  LET cachedFile = cacheFileName(ftg.name);
  MYASSERT(os.Path.exists(cachedFile))
  MYASSERT(os.Path.size(cachedFile) == ftg.fileSize)
  LET t = getLastModified(cachedFile)
  IF t <> ftg.mtime THEN
    --CALL printStderr(sfmt("t:%1<>ftg.mtime:%2 cachedFile:%3, os.Path.mtime:%4",t,ftg.mtime,cachedFile,os.Path.mtime(cachedFile)))
    CALL setLastModified(cachedFile, ftg.mtime)
    LET t = getLastModified(cachedFile)
    --CALL printStderr(sfmt("  new t:%1,os.Path.mtime:%2",t,os.Path.mtime(cachedFile)))
    MYASSERT(ftg.mtime == t)
    --IF ftg.mtime <> t THEN
    --  DISPLAY "currt2:", t, "<>", ftg.mtime
    --END IF
    MYASSERT(getLastModified(cachedFile) == ftg.mtime)
  END IF
END FUNCTION

FUNCTION checkFT2(val STRING) RETURNS(BOOLEAN, STRING, BOOLEAN)
  DEFINE realName STRING
  DEFINE cached4, exist, ft2 BOOLEAN
  DEFINE s, s2, t, t2 INT
  CALL checkCached4Fmt(val) RETURNING cached4, realName, s, t
  CALL log(SFMT("cached4:%1 realName:'%2' s:%3,t:%4", cached4, realName, s, t))
  IF cached4 THEN
    CALL lookupInCache(realName) RETURNING exist, s2, t2
    IF exist AND s == s2 AND t == t2 THEN
      CALL log(SFMT("found in cache:'%1' with s:%2,t:%3", realName, s, t))
      RETURN TRUE, realName, TRUE
    ELSE
      CALL log(
          SFMT("not found in cache:'%1' with exist:%2 s:%3,s2:%4,t:%5,t2:%6",
              realName, exist, s, s2, t, t2))
      LET val = realName
      LET ft2 = TRUE
    END IF
  END IF
  RETURN FALSE, val, ft2
END FUNCTION

FUNCTION getFTs(v TVMRec INOUT) RETURNS FTList
  RETURN v.FTs
END FUNCTION

FUNCTION getIndexOf(s STRING, sub STRING) RETURNS STRING
  RETURN s.getIndexOf(sub, 1)
END FUNCTION

FUNCTION lastIndexOf(s STRING, sub STRING) RETURNS STRING
  DEFINE startpos, idx, lastidx INT
  LET startpos = 1
  WHILE (idx := s.getIndexOf(sub, startpos)) > 0
    LET lastidx = idx
    LET startpos = idx + 1
  END WHILE
  RETURN lastidx
END FUNCTION

FUNCTION checkRequestFT(
    x TConn INOUT, v TVMRec INOUT, fname STRING)
    RETURNS BOOLEAN
  DEFINE ftg FTGetImage
  DEFINE cached, ft2 BOOLEAN
  DEFINE FTs FTList
  DEFINE realName, cachedName STRING
  DEFINE lastQ INT
  --DISPLAY sfmt("checkRequestFT x:%1,vmidx:%2,fname:%3",x,vmidx,fname)
  IF fname IS NULL THEN
    --DISPLAY "checkRequestFT: No FT value for:", vmidx
    RETURN FALSE
  END IF
  IF v.state == S_FINISH THEN
    RETURN FALSE
  END IF
  CALL checkFT2(fname) RETURNING cached, realName, ft2
  IF cached THEN --we have the file already in the cache
    LET cachedName = cacheFileName(realName)
    CALL log(
        SFMT("checkRequestFT got cached realName:%1 with:%2",
            realName, cachedName))
    IF NOT processFile(
        x: x, fname: cachedName, cache: TRUE, checkExists: TRUE) THEN
      RETURN FALSE
    END IF
    CALL finishHttp(x)
    RETURN TRUE
  ELSE
    IF ft2 THEN
      LET lastQ = lastIndexOf(fname, "?")
      LET fname = fname.subString(8, lastQ - 1)
    END IF
  END IF
  MYASSERT(v.ftNum IS NOT NULL)
  LET v.ftNum = v.ftNum - 1
  LET ftg.num = v.ftNum
  LET ftg.name = fname
  LET ftg.cache = TRUE
  LET ftg.httpIdx = x.idx
  --LET ftg.node = n
  LET ftg.ft2 = ft2
  CALL log(SFMT("requestFT for :%1,num:%2,%3", fname, v.ftNum, printV(v)))
  LET FTs = getFTs(v)
  LET FTs[FTs.getLength() + 1].* = ftg.*
  IF NOT v.state = S_ACTIVE THEN
    RETURN TRUE --?
  END IF
  CALL lookupNextImage(v)
  RETURN TRUE
END FUNCTION

FUNCTION removeImg(v TVMRec INOUT, ftg FTGetImage)
  DEFINE i INT
  DEFINE FTs FTList
  LET FTs = getFTs(v)
  --DISPLAY "before removal:", util.JSON.stringify(_v[vmidx].FTs)
  CALL log(
      SFMT("removeImg:%1 num:%2 len:%3, FTs:%4",
          ftg.name,
          ftg.num,
          FTs.getLength(),
          IIF(_verbose, util.JSON.stringify(FTs), "")))
  FOR i = 1 TO FTs.getLength()
    --remove the same number but also pending images with the same name
    IF FTs[i].num == ftg.num OR FTs[i].name == ftg.name THEN
      CALL log(
          SFMT("  removed:%1 at:%2:%3",
              ftg.name, i, IIF(_verbose, util.JSON.stringify(FTs[i]), "")))
      CALL FTs.deleteElement(i)
      LET i = i - 1
    END IF
  END FOR
  --DISPLAY "after removal:", util.JSON.stringify(_v[v].FTs)
END FUNCTION

FUNCTION updateImg(v TVMRec INOUT, ftg FTGetImage)
  DEFINE len, i INT
  DEFINE FTs FTList
  LET FTs = getFTs(v)
  LET len = FTs.getLength()
  FOR i = 1 TO len
    IF FTs[i].num == ftg.num THEN
      LET FTs[i].* = ftg.*
      RETURN
    END IF
  END FOR
END FUNCTION

FUNCTION ftgFromNum(v TVMRec INOUT, num INT) RETURNS(BOOLEAN, FTGetImage)
  DEFINE len, i INT
  DEFINE ftg FTGetImage
  DEFINE FTs FTList
  LET FTs = getFTs(v)
  LET len = FTs.getLength()
  FOR i = 1 TO len
    IF FTs[i].num == num THEN
      LET ftg.* = FTs[i].*
      RETURN TRUE, ftg.*
    END IF
  END FOR
  CALL log(SFMT("ftgFromNum: did not find image for:%1", num))
  RETURN FALSE, ftg.*
END FUNCTION

FUNCTION lookupNextImage(v TVMRec INOUT)
  DEFINE ftg FTGetImage
  DEFINE len INT
  DEFINE FTs FTList
  LET FTs = getFTs(v)
  LET len = FTs.getLength()
  CALL log(
      SFMT("lookupNextImage wait:%1,writeNum:%2,len:%3,writeC IS NOT NULL:%4,VmCmd IS NOT NULL:%5",
          v.wait, v.writeNum, len, v.writeC IS NOT NULL, v.VmCmd IS NOT NULL))
  IF v.wait
      OR (v.VmCmd IS NOT NULL AND v.clientMetaSent)
      OR (v.writeNum != 0)
      OR (len == 0)
      OR (v.writeC IS NOT NULL) THEN
    IF v.writeNum == 0 AND len == 0 AND v.writeC IS NULL THEN
      CALL log("lookupNextImage: all files transferred!")
    ELSE
      CALL log(SFMT("  v.writeNum(%1) != 0, wait:%2", v.writeNum, v.wait))
    END IF
    RETURN
  END IF
  MYASSERT(FTs.getLength() > 0)
  LET ftg.* = FTs[1].*
  CALL log(
      SFMT("  lookupNextImage:%1", IIF(_verbose, util.JSON.stringify(ftg), "")))
  LET v.writeNum = ftg.num
  IF v.vmVersion >= 3.2 THEN
    CALL checkCacheSendInformation(v, ftg.*)
  ELSE
    CALL sendGetImage(v, ftg.num, ftg.name)
  END IF
END FUNCTION

FUNCTION checkCacheSendInformation(v TVMRec INOUT, ftg FTGetImage)
  --//we append the new special query to indicate we want to get
  --//size and mtime information in the ack answer
  DEFINE s, t INT
  DEFINE exist BOOLEAN
  DEFINE name STRING
  IF ftg.cache THEN
    CALL lookupInCache(ftg.name) RETURNING exist, s, t
  END IF
  LET name = SFMT("%1%2?s=%3&t=%4", IIF(ftg.ft2, "__VM__/", ""), ftg.name, s, t)
  CALL sendGetImage(v, ftg.num, name)
END FUNCTION

FUNCTION sendGetImage(v TVMRec INOUT, num INT, fileName STRING)
  CALL sendGetImageOrAck(v, num, fileName, TRUE)
  CALL setWait(v)
END FUNCTION

FUNCTION sendAck(v TVMRec INOUT, num INT, fileName STRING)
  --DISPLAY SFMT("sendAck v:%1,num:%2,fileName:%3", printV(v), num, fileName)
  CALL sendGetImageOrAck(v, num, fileName, FALSE)
END FUNCTION

FUNCTION sendGetImageOrAck(
    v TVMRec INOUT, num INT, fileName STRING, getImage BOOLEAN)
  DEFINE pktlen, extlen, len INT
  DEFINE ext STRING
  DEFINE b0 TINYINT
  DEFINE chan base.Channel
  CALL log(
      SFMT("sendGetImageOrAck num:%1,fileName:'%2',getImage:%3",
          num, fileName, getImage))
  LET len = fileName.getLength()
  LET pktlen = 1 + 2 * size_i + len; --1st byte FT instruction
  IF getImage THEN --append imagelist
    LET ext = ".png;.PNG;.gif;.GIF;.jpg;.JPG;.tif;.TIF;.bmp;.BMP"
    LET extlen = ext.getLength()
    LET pktlen = pktlen + size_i + extlen + 1;
  END IF
  LET b0 = IIF(getImage, FTGetFile, FTAck)
  LET chan = v.chan
  MYASSERT(chan IS NOT NULL AND _channels.search(NULL, chan) > 0)
  CALL writeEncapsHeader(chan, TFileTransfer, pktlen)
  CALL util.Channels.writeNetInt8(chan, b0)
  CALL util.Channels.writeNetInt32(chan, num)
  CALL util.Channels.writeNetInt32(chan, len)
  CALL util.Channels.writeBinaryString(chan, fileName)
  IF getImage THEN
    CALL util.Channels.writeNetInt32(chan, extlen)
    CALL util.Channels.writeBinaryString(chan, ext)
    CALL util.Channels.writeNetInt8(chan, 0) --terminating 0
  END IF
  CALL chan.flush()
END FUNCTION

FUNCTION sendBody(v TVMRec INOUT, num INT, ichan base.Channel, numBytes INT)
  DEFINE pktlen INT
  DEFINE chan base.Channel
  DEFINE b0 TINYINT
  LET pktlen = 1 + size_i + numBytes
  LET chan = v.chan
  CALL writeEncapsHeader(chan, TFileTransfer, pktlen)
  LET b0 = FTBody
  CALL util.Channels.writeNetInt8(chan, b0)
  CALL util.Channels.writeNetInt32(chan, num)
  MYASSERT(copyBytes(ichan, chan, numBytes) == TRUE)
END FUNCTION

FUNCTION sendEof(v TVMRec INOUT, num INT)
  DEFINE pktlen INT
  DEFINE b0 TINYINT
  DEFINE chan base.Channel
  LET pktlen = 1 + size_i
  LET b0 = FTEof
  LET chan = v.chan
  CALL writeEncapsHeader(chan, TFileTransfer, pktlen)
  CALL util.Channels.writeNetInt8(chan, b0)
  CALL util.Channels.writeNetInt32(chan, num)
  CALL chan.flush()
END FUNCTION

FUNCTION sendFTStatus(v TVMRec INOUT, num INT, code INT)
  DEFINE pktlen INT
  DEFINE b0 TINYINT
  DEFINE chan base.Channel
  LET pktlen = 1 + 2 * size_i
  LET b0 = FTStatus
  LET chan = v.chan
  CALL writeEncapsHeader(chan, TFileTransfer, pktlen)
  CALL util.Channels.writeNetInt8(chan, b0)
  CALL util.Channels.writeNetInt32(chan, num)
  CALL util.Channels.writeNetInt32(chan, code)
  CALL chan.flush()
END FUNCTION

FUNCTION writeEncapsHeader(chan base.Channel, type TINYINT, len INT)
  CALL util.Channels.writeNetInt32(chan, len)
  CALL util.Channels.writeNetInt32(chan, len)
  CALL util.Channels.writeNetInt8(chan, type)
END FUNCTION

FUNCTION writeToVMEncaps(v TVMRec INOUT, cmd STRING)
  DEFINE chan base.Channel
  DEFINE type TINYINT
  LET chan = v.chan
  CASE cmd
    WHEN CLIENT_INTERRUPT
      LET cmd = ""
      LET type = TInterrupt
    WHEN CLIENT_CLOSE
      LET cmd = ""
      LET type = TCloseApp
    OTHERWISE
      LET type = TAuiData
  END CASE
  CALL log(SFMT("writeToVMEncaps vm:%1,cmd:%2", printV(v), limitPrintStr(cmd)))
  CALL writeEncapsHeader(chan, type, cmd.getLength())
  CALL util.Channels.writeBinaryString(chan, cmd)
  CALL chan.flush()
END FUNCTION

FUNCTION clearCache()
  DEFINE cacheDir STRING
  LET cacheDir = "cacheFT"
  IF NOT os.Path.exists(cacheDir) THEN
    RETURN
  END IF
  CALL rmrf(cacheDir)
END FUNCTION

FUNCTION rmrf(dirname STRING)
  DEFINE cmd, curr STRING
  LET curr = os.Path.fullPath(os.Path.pwd())
  MYASSERT(os.Path.isDirectory(dirname) AND NOT curr.equals(os.Path.fullPath(dirname)))
  IF isWin() THEN
    LET cmd = SFMT("rmdir /s /q %1", quote(dirname))
  ELSE
    LET cmd = SFMT("rm -rf %1", quote(dirname))
  END IF
  --DISPLAY "rmrf:",cmd
  RUN cmd
END FUNCTION

FUNCTION eatWS() RETURNS STRING
  DEFINE buf, u STRING
  DEFINE len INT
  LET buf = _p.buf
  LET len = buf.getLength();
  IF (_p.pos >= len) THEN
    RETURN -1;
  END IF
  LET u = buf.getCharAt(_p.pos);
  WHILE _p.pos <= len AND (u == ' ' OR u == '\n' OR u == '\\')
    LET _p.pos = _p.pos + 1;
    LET u = buf.getCharAt(_p.pos);
  END WHILE
  RETURN u
END FUNCTION

FUNCTION getChar() RETURNS STRING
  DEFINE u STRING
  LET u = eatWS()
  LET _p.pos = _p.pos + 1
  RETURN u
END FUNCTION

FUNCTION identFromBuf()
  DEFINE buf, u, prev STRING
  DEFINE i, len INT
  DEFINE b base.StringBuffer
  LET b = base.StringBuffer.create()
  LET buf = _p.buf;
  LET u = buf.getCharAt(_p.pos);
  LET prev = u
  LET i = 0;
  LET len = buf.getLength();
  WHILE (_p.pos <= len
      AND NOT (u.equals(' ') || u.equals('{') || u.equals('}')))
    LET _p.pos = _p.pos + 1
    LET u = buf.getCharAt(_p.pos);
    CALL b.append(prev)
    LET prev = u
    LET i = i + 1;
  END WHILE
  --//copy ident portion to ident
  --LET _p.ident = buf.subString(_p.pos - i, _p.pos - 1);
  LET _p.ident = b.toString()
  --DISPLAY "_p.ident:'",_p.ident
  --DISPLAY "b       :'",b.toString()
END FUNCTION

FUNCTION getValueWithSeparator(separator STRING)
  DEFINE valueBuf base.StringBuffer
  DEFINE buf, u STRING
  DEFINE len INT
  LET valueBuf = base.StringBuffer.create()
  LET _p.pos = _p.pos + 1 --// remove first "
  LET _p.valueStart = _p.pos
  LET buf = _p.buf;
  LET len = buf.getLength();
  WHILE (_p.pos <= len)
    LET u = buf.getCharAt(_p.pos);
    --DISPLAY "getValueWithSeparator1:", u
    CASE
      WHEN u == '\\'
        LET _p.pos = _p.pos + 1
        LET u = buf.getCharAt(_p.pos);
        --DISPLAY "getValueWithSeparator2:", u
        CALL valueBuf.append(IIF(u == 'n', '\n', u))
      WHEN u == separator
        LET _p.pos = _p.pos + 1
        EXIT WHILE
      OTHERWISE
        CALL valueBuf.append(u)
    END CASE
    LET _p.pos = _p.pos + 1
  END WHILE
  RETURN valueBuf.toString();
END FUNCTION

FUNCTION getToken()
  DEFINE numbuf, u STRING
  DEFINE testnum INT
  --LET numbuf = ""
  LET u = eatWS();
  IF u == -1 THEN
    RETURN TOK_None
  END IF
  WHILE (testnum := u) IS NOT NULL --// isdigit
    LET numbuf = numbuf, u;
    LET _p.pos = _p.pos + 1
    LET u = _p.buf.getCharAt(_p.pos);
    --DISPLAY "getToken:'", u, "',numbuf:'", numbuf, "'"
  END WHILE

  IF numbuf.getLength() <> 0 THEN
    LET _p.number = numbuf
    --DISPLAY "p.number:", p.number
    RETURN TOK_Number
  END IF

  IF u == '\"' OR u == "\'" THEN
    --DISPLAY "getValueWithSeparator:", u
    LET _p.value = getValueWithSeparator(u)
    RETURN TOK_Value;
  ELSE
    --DISPLAY "identFromBuf:"
    CALL identFromBuf();
    LET _p.value = NULL;
    RETURN TOK_Ident;
  END IF
END FUNCTION

FUNCTION parseTcl(v TVMRec INOUT, s STRING)
  DEFINE starttime DATETIME HOUR TO FRACTION(3)
  DEFINE diff INTERVAL MINUTE TO FRACTION(3)
  LET starttime = CURRENT
  --DISPLAY "before parseTcl..."
  CALL parseTclInt(v, s)
  LET diff = CURRENT - starttime
  --DISPLAY "ParseTcl time:", diff
END FUNCTION

FUNCTION parseTclInt(v TVMRec INOUT, s STRING)
  DEFINE result BOOLEAN
  MYASSERT(_p.active == FALSE)
  LET _p.active = TRUE
  LET _p.pos = 1
  LET _p.buf = s
  LET _p.number = NULL
  LET result = TRUE
  WHILE (result AND _p.pos <= s.getLength())
    MYASSERT(getToken() == TOK_Ident)
    CASE
      WHEN _p.ident == "meta"
        LET result = handleParseMeta(v);
      WHEN _p.ident == "om"
        LET result = handleParseOm(v);
      OTHERWISE
        CALL myErr(SFMT("invalid token:%1", _p.ident));
    END CASE
    LET _p.pos = _p.pos + 1
  END WHILE
  MYASSERT(result == TRUE)
  LET _p.active = FALSE
END FUNCTION

FUNCTION node(v TVMRec INOUT, id INT) RETURNS om.DomNode
  DEFINE fid, len INT
  DEFINE aui DYNAMIC ARRAY OF om.DomNode
  LET aui = v.aui
  LET fid = id + 1
  LET len = aui.getLength()
  IF len == 0 THEN
    RETURN NULL
  END IF
  MYASSERT(fid >= 1 AND fid <= len)
  RETURN aui[fid]
END FUNCTION

FUNCTION handleParseOm(v TVMRec INOUT)
  MYASSERT(handleParseOmInt(v) == TRUE)
  RETURN TRUE;
END FUNCTION

FUNCTION removePendingFT(v TVMRec INOUT)
  DEFINE rn STRING
  --we insert the remove node cmd for the pending file transfer
  LET rn = SFMT("{rn %1} ", v.rnFTNodeId)
  LET v.rnFTNodeId = 0
  LET _p.buf =
      _p.buf.subString(1, _p.pos - 1),
      rn,
      _p.buf.subString(_p.pos, _p.buf.getLength())
  LET _p.pos = _p.pos + rn.getLength()
  CALL log(SFMT("removePendingFT: %1", limitPrintStr(_p.buf)))
END FUNCTION

FUNCTION handleParseOmInt(v TVMRec INOUT)
  DEFINE firstLetter STRING
  DEFINE parentId INT
  DEFINE parentNode, n om.DomNode
  MYASSERT(getToken() == TOK_Number)
  MYASSERT(EQ(getChar(), '{'))
  IF v.rnFTNodeId <> 0 THEN
    CALL removePendingFT(v)
  END IF
  WHILE (getChar() == '{')
    MYASSERT(getToken() == TOK_Ident)
    LET firstLetter = _p.ident.getCharAt(1);
    CASE
      WHEN (firstLetter == 'a') --//'a'n or 'a'ppendNode
        MYASSERT(getToken() == TOK_Number)
        LET parentId = _p.number;
        LET parentNode = node(v, parentId);
        LET n = handleAppendNode(v, parentNode);
        MYASSERT(n IS NOT NULL)
        IF (parentNode IS NOT NULL) THEN
          CALL parentNode.appendChild(n)
        END IF

      WHEN (firstLetter == 'u') --//'u'n or 'u'pdateNode
        MYASSERT(getToken() == TOK_Number)
        LET n = node(v, _p.number);
        MYASSERT(n IS NOT NULL)
        MYASSERT(handleUpdateNode(v, n) == TRUE)
      WHEN (firstLetter == 'r') --//'r'n or 'r'emoveNode
        MYASSERT(getToken() == TOK_Number)
        CALL handleRemoveNode(v, _p.number);
      OTHERWISE
        CALL myErr(SFMT("firstletter is:%1", firstLetter))
        RETURN FALSE
    END CASE
    MYASSERT(EQ(getChar(), '}'))
  END WHILE
  RETURN TRUE;
END FUNCTION

FUNCTION handleParseMeta(v TVMRec INOUT)
  DEFINE name, value STRING
  MYASSERT(getToken() == TOK_Ident) --"Connection"
  MYASSERT(EQ(getChar(), '{'))
  WHILE EQ(getChar(), '{')
    MYASSERT(getToken() == TOK_Ident)
    LET name = _p.ident
    MYASSERT(getToken() == TOK_Value)
    LET value = _p.value
    --DISPLAY "name:", name, ",value:", value
    CASE
      WHEN name == "runtimeVersion"
        LET v.vmVersion = parseVersion(value)
        CALL log(SFMT("parsed %1 -> vmVersion:%2", name, v.vmVersion))
        {
        WHEN name == "filetransferVersion"
          LET _vmFTVersion = parseInt(value)
          CALL log(SFMT("parsed %1 -> _vmFTVersion:%2", name, _vmFTVersion))
        }
    END CASE
    MYASSERT(EQ(getChar(), '}'))
  END WHILE
  RETURN TRUE
END FUNCTION

FUNCTION handleRemoveNode(v TVMRec INOUT, nodeId INT)
  CALL recursiveRemove(v, node(v, nodeId), nodeId == 0)
END FUNCTION

FUNCTION recursiveRemove(v TVMRec INOUT, n om.DomNode, isRoot BOOLEAN)
  DEFINE ch, next om.DomNode
  MYASSERT(n IS NOT NULL)
  IF NOT isRoot THEN
    MYASSERT(n.getParent() IS NOT NULL)
  END IF
  LET ch = n.getFirstChild()
  WHILE ch IS NOT NULL
    LET next = ch.getNext()
    CALL recursiveRemove(v, ch, FALSE)
    LET ch = next
  END WHILE
  IF NOT isRoot THEN
    CALL n.getParent().removeChild(n)
  END IF
  LET v.aui[nodeId(n) + 1] = NULL
  {
  CASE
    WHEN n == _functionCall
      CALL log("reset _functionCall")
      LET _functionCall = NULL
    WHEN n == _root
      CALL log("reset _root")
      LET _root = NULL
  END CASE
  IF getAttrI(n, "_usedInVMCmd") == 1 THEN
    CALL removeNodeUsedInVMCmd(n)
  END IF
  }
  --to check in the code if a node did already die,
  --just do: IF n.parent IS NULL
END FUNCTION

FUNCTION newNode(
    v TVMRec INOUT, parentNode om.DomNode, nodeName STRING, nodeId INT)
    RETURNS om.DomNode
  {
  UNUSED_VAR(parentNode)
  UNUSED_VAR(nodeName)
  UNUSED_VAR(nodeId)
  }
  DEFINE n om.DomNode
  DEFINE doc om.DomDocument
  IF parentNode IS NULL THEN
    MYASSERT(v.doc IS NULL)
    LET doc = om.DomDocument.create(nodeName)
    LET v.doc = doc
    LET n = doc.getDocumentElement()
  ELSE
    LET n = parentNode.createChild(nodeName)
  END IF
  CALL n.setAttribute("id", nodeId)
  {
  CASE
    WHEN nodeName == "FunctionCall"
      LET _functionCall = n
  END CASE
  }
  RETURN n
END FUNCTION

FUNCTION handleAppendNode(
    v TVMRec INOUT, parentNode om.DomNode)
    RETURNS om.DomNode
  DEFINE nodeName STRING
  DEFINE nodeId INT
  DEFINE n, ch om.DomNode
  MYASSERT(getToken() == TOK_Ident)
  LET nodeName = _p.ident;
  MYASSERT(getToken() == TOK_Number)
  LET nodeId = _p.number;
  IF (parentNode IS NULL AND nodeId != 0) THEN
    RETURN NULL;
  END IF
  MYASSERT(EQ(getChar(), '{'))
  LET n = newNode(v, parentNode, nodeName, nodeId);
  LET v.aui[nodeId + 1] = n;
  MYASSERT(handleNodeAttr(v, n) == TRUE)
  MYASSERT(EQ(getChar(), '{'))
  WHILE (getChar() == '{')
    LET ch = handleAppendNode(v, n);
    CALL checkImage(v, ch, "value", NULL)
    MYASSERT(ch IS NOT NULL)
    CALL n.appendChild(ch)
    MYASSERT(EQ(getChar(), '}'))
  END WHILE
  --DISPLAY "did append node:",nodeDesc(n)
  RETURN n
END FUNCTION

FUNCTION checkImage(v TVMRec INOUT, n om.DomNode, name STRING, value STRING)
  DEFINE tag, oldVal, slashed, newVal, buf STRING
  DEFINE ch om.DomNode
  DEFINE isImage, hasFTV2, needHTPrefix, colon BOOLEAN
  DEFINE valueStart, valueEnd, occ, plus INT
  LET hasFTV2 = v.FTV2
  LET tag = n.getTagName()
  --DISPLAY "setAttribute:",tag,",name:",name,",value:",value
  IF name == "value"
      AND (tag == "FormField" OR tag == "Matrix" OR tag == "TableColumn") THEN
    --CALL printOmInt(n, 2)
    LET ch = n.getFirstChild()
    LET isImage = (ch IS NOT NULL) AND (ch.getTagName() == "Image")
    IF isImage THEN
      LET value = n.getAttribute("name")
    END IF
  END IF
  IF name == "image" OR name == "href" OR isImage THEN
    LET valueStart = n.getAttribute("_valueStart")
    LET valueStart = IIF(valueStart IS NULL, _p.valueStart, valueStart)
    LET valueEnd = n.getAttribute("_valueEnd")
    LET valueEnd = IIF(valueEnd IS NULL, _p.pos - 2, valueEnd)
    LET oldVal = n.getAttribute(name)
    IF _opt_gdc AND _direct_mode THEN
      LET needHTPrefix = TRUE
    END IF
    --we need to prefix windows paths and workaround GDC image names
    IF oldVal.getLength() > 0
        AND (oldVal.getIndexOf("font:", 1) <> 1)
        AND ((needHTPrefix
            OR (hasFTV2 AND (colon := (oldVal.getIndexOf(":", 1) == 2))))) THEN
      LET newVal = _p.buf.subString(valueStart, valueEnd)
      --replace '\\' with '/' and add a FT2 like marker and
      --manipulate the protocol line
      IF colon THEN
        CALL backslash2slashCnt(oldVal) RETURNING slashed, occ
        MYASSERT(oldVal.getLength() + occ == newVal.getLength())
        LET newVal = "__VM__/", slashed, "?F=1"
        LET plus = 11 -- length("__VM__/") + length("?F=1")
      END IF
      IF needHTPrefix THEN
        LET newVal = _htpre, "gbc/", newVal
        LET plus = plus + _htpre.getLength() + 4
      END IF
      LET buf = _p.buf
      LET _p.buf =
          buf.subString(1, valueStart - 1),
          newVal,
          buf.subString(valueEnd + 1, buf.getLength())
      LET _p.pos = (_p.pos + plus) - occ
      --DISPLAY "!!! set image:'", newVal, "',oldVal:'", oldVal, "'"
      CALL log(SFMT("checkImage: replace '%1' with '%2'", oldVal, newVal))
    END IF
  END IF
END FUNCTION

FUNCTION setAttribute(
    v TVMRec INOUT, n om.DomNode, name STRING, value STRING, update BOOLEAN)
  CALL n.setAttribute(name, value)
  CASE
    WHEN name == "image" OR name == "href" OR (update AND name == "value")
      CALL checkImage(v, n, name, value)
    WHEN name == "value"
      CALL n.setAttribute("_valueStart", _p.valueStart)
      CALL n.setAttribute("_valueEnd", _p.pos - 2)
  END CASE
END FUNCTION

FUNCTION handleNodeAttr(v TVMRec INOUT, n om.DomNode)
  --DEFINE d TStringDict
  DEFINE name STRING
  WHILE (getChar() == '{')
    MYASSERT(getToken() == TOK_Ident)
    LET name = _p.ident;
    MYASSERT(getToken() == TOK_Value)
    --//set the attribute
    --LET d[name] = _p.value
    CALL setAttribute(v, n, name, _p.value, FALSE)
    MYASSERT(EQ(getChar(), '}'))
  END WHILE
  --CALL afterUpdateDone(n, d)
  RETURN TRUE;
END FUNCTION

FUNCTION handleUpdateNode(v TVMRec INOUT, n om.DomNode)
  --DEFINE d TStringDict
  DEFINE name, val, oldval STRING
  MYASSERT(EQ(getChar(), '{'))
  WHILE (getChar() == '{')
    MYASSERT(getToken() == TOK_Ident)
    LET name = _p.ident;
    MYASSERT(getToken() == TOK_Value)
    LET val = _p.value
    LET oldval = n.getAttribute(name)
    --IF NEQ(oldval, val) THEN
    IF NOT oldval.equals(val) THEN
      --LET d[name] = oldval
      CALL setAttribute(v, n, name, _p.value, TRUE)
    END IF
    MYASSERT(EQ(getChar(), '}'))
  END WHILE
  --CALL afterUpdateDone(n, d)
  RETURN TRUE;
END FUNCTION

{
FUNCTION afterUpdateDone(n om.DomNode, changed TStringDict)
  --DEFINE tag STRING
  --DEFINE isMenuAction BOOLEAN
  --CALL checkFTItem(n, changed)
  --IF NOT _qa THEN
  --  RETURN
  --END IF
  LET tag = n.getTagName()
  IF (isMenuAction := (tag == "MenuAction")) == TRUE OR tag == "Action" THEN
    CALL handleQAReady(n, isMenuAction)
  END IF
END FUNCTION
}

FUNCTION printOmInt(n om.DomNode, indent INT)
  DEFINE x STRING
  DEFINE ch om.DomNode
  DEFINE i INT
  FOR i = 1 TO indent
    LET x = x, " "
  END FOR
  LET x = x, nodeDesc(n)
  --LET x = x
  DISPLAY x
  LET ch = n.getFirstChild()
  WHILE ch IS NOT NULL
    CALL printOmInt(ch, indent + 2)
    LET ch = ch.getNext()
  END WHILE
END FUNCTION

FUNCTION hasAttr(n om.DomNode, attrName STRING)
  DEFINE cnt, i INT
  LET cnt = n.getAttributesCount()
  FOR i = 1 TO cnt
    IF n.getAttributeName(i) == attrName THEN
      RETURN TRUE
    END IF
  END FOR
  RETURN FALSE
END FUNCTION

{
FUNCTION checkFTItem(n om.DomNode, changed TStringDict)
  DEFINE tag STRING
  LET tag = n.getTagName()
  IF changed.contains("image") THEN
    DISPLAY "changed image:",changed["image"]," of:",tag
  ELSE
    CASE tag
      WHEN "ImageFont"
        CALL requestFT(n, "href", changed)
      WHEN "Image"
        VAR p = n.getParent()
        VAR ptag = p.getTagName()
        CASE
          WHEN ptag == "FormField"
            CALL requestFT(n, "value", changed)
          WHEN ptag == "Matrix" OR ptag = "TableColumn"
            DISPLAY "checkFTItem: Matrix TableColumn for Image not handled yet"
        END CASE
    END CASE
  END IF
END FUNCTION
}

FUNCTION getAttrI(n om.DomNode, attr STRING)
  DEFINE intVal INT
  DEFINE value STRING
  LET value = n.getAttribute(attr)
  LET intVal = value
  LET intVal = IIF(intVal IS NULL, 0, intVal)
  RETURN intVal
END FUNCTION

FUNCTION isActive(n om.DomNode) RETURNS BOOLEAN
  RETURN getAttrI(n, "active")
END FUNCTION

FUNCTION nodeId(n om.DomNode) RETURNS INT
  RETURN getAttrI(n, "id")
END FUNCTION

FUNCTION nodeDesc(n om.DomNode)
  DEFINE i, len INT
  DEFINE sb base.StringBuffer
  LET sb = base.StringBuffer.create()
  CALL sb.append(n.getTagName())
  LET len = n.getAttributesCount()
  FOR i = 1 TO len
    CALL sb.append(
        SFMT(" %1='%2'", n.getAttributeName(i), n.getAttributeValue(i)))
  END FOR
  RETURN sb.toString()
END FUNCTION

FUNCTION genSID(short BOOLEAN)
  DEFINE s STRING
&ifdef NO_JAVA
  UNUSED_VAR(short)
  CALL util.Math.srand()
  LET s = util.Math.rand(100000)
&else
  DEFINE rand SecureRandom
  DEFINE barr MyByteArray
  DEFINE enc Encoder
  DEFINE numdigits INT
  LET rand = SecureRandom.create()
  LET numdigits = IIF(short, 20, 25)
  LET barr = MyByteArray.create(numdigits)
  CALL rand.nextBytes(barr);
  LET enc = Base64.getUrlEncoder().withoutPadding();
  LET s = enc.encodeToString(barr);
  LET s = replace(s, ".", "_")
  LET s = replace(s, ":", "C")
  LET s = replace(s, "-", "A")
&endif
  CALL log(SFMT("genSID:%1", s))
  RETURN s
END FUNCTION

FUNCTION interpretchars(s STRING) RETURNS STRING
  DEFINE c, hex STRING
  DEFINE i, len INT
  DEFINE sb base.StringBuffer
  CONSTANT ascji =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz1234567890!@#$%^&*()-=_+~`{}[] |:;\"'<>,.?/\\"
  --CONSTANT  "\"\\"
  LET len = s.getLength()
  LET sb = base.StringBuffer.create()
  FOR i = 1 TO len
    LET c = s.getCharAt(i)
    CASE
      WHEN ascji.getIndexOf(c, 1) > 0
        CALL sb.append(c)
      WHEN c == '\r'
        CALL sb.append("\\r")
      WHEN c == '\b'
        CALL sb.append("\\b")
      WHEN c == '\t'
        CALL sb.append("\\t")
      WHEN c == '\n'
        CALL sb.append("\\n")
      OTHERWISE
        LET hex = util.Integer.toHexString(ORD(c))
        LET hex = IIF(hex.getLength() == 1, SFMT("0%1", hex), hex)
        CALL sb.append(SFMT("\\x%1", hex))
    END CASE
  END FOR
  RETURN sb.toString()
END FUNCTION
