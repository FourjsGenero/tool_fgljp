#+ simple RUN test which also checks correct Webcomponent resource loading
IMPORT util
IMPORT os
IMPORT FGL testutils
--IMPORT FGL fgldialog

&define MYASSERT(x) IF NOT NVL(x,0) THEN CALL testutils.myErr("ASSERTION failed in line:"||__LINE__||":"||#x) END IF
&define MYASSERT_MSG(x,msg) IF NOT NVL(x,0) THEN CALL testutils.myErr("ASSERTION failed in line:"||__LINE__||":"||#x||","||msg) END IF

DEFINE _arg STRING
MAIN
  DEFINE code INT
  DEFINE destlogo, ret STRING
  LET _arg = arg_val(1)
  IF _arg IS NOT NULL THEN
    DISPLAY "arg1:", _arg
    MESSAGE "arg1:", _arg
  END IF
  {IF _arg IS NULL THEN
    CALL fgl_winMessage(title: "info","Open debug console","info")
  END IF}

  CALL ui.Interface.frontCall("qa", "startQA", [], [])
  {MENU --uncomment for debug
    COMMAND "EXIT"
      EXIT MENU
  END MENU}
  DEFER INTERRUPT
  CALL testInterrupt()
  LET destlogo=IIF(testutils.isWin(),"logo,.png","logo?.png")
  MYASSERT(os.Path.copy("logo.png",destlogo)==TRUE)
  CALL menuShowForm(1,destlogo)
  MENU _arg
    COMMAND "qa_menu_ready"
      CALL testProcessing()
      RUN SFMT("fglrun test %1", IIF(_arg == "child", "child2", "child"))
          RETURNING code
      MYASSERT(code == 0)
      --CALL fgl_winMessage(title: "info","after first run","info")
      --run again
      RUN SFMT("fglrun test %1", IIF(_arg == "child", "child2", "child"))
          RETURNING code
      --CALL fgl_winMessage(title: "info","after 2nd run","info")
      MYASSERT(code == 0)
      --COMMAND "RUN WITHOUT WAITING"
      --  RUN SFMT("fglrun demo %1 %2", _arg || "+", arg_val(2)) WITHOUT WAITING
      EXIT MENU
    COMMAND "EXIT"
      EXIT MENU
  END MENU
  CALL menuShowForm(2,"num001.png")
  --CALL fgl_winMessage(title: "info",sfmt("test went thru for arg:%1",_arg),"info")
  CALL ui.Interface.frontCall("standard", "feinfo", ["fename"], [ret])
  DISPLAY "last feinfo:", ret
  DISPLAY IIF(_arg == "child", "RETURN from child", "TEST OK")
END MAIN

FUNCTION testInterrupt()
  OPEN FORM f FROM "interrupt"
  DISPLAY FORM f
  MENU
    COMMAND "qa_menu_ready"
      LET int_flag=0
      CALL ui.Interface.frontCall("fgljp","click_on_element_with_text",["Interrupt",100],[])
      SLEEP 5
      MYASSERT_MSG(int_flag,"int_flag wasn't set")
      EXIT MENU
  END MENU
  CLOSE FORM f
END FUNCTION

FUNCTION menuShowForm(num INT,img STRING)
  DEFINE f64, w64,title STRING
  DEFINE idx INT
  DISPLAY "menuShowForm ",_arg,",num:",num,",img:",img
  LET title=sfmt("%1.%2",_arg,num)
  MENU title
    BEFORE MENU
      CALL DIALOG.setActionHidden("qa_menu_ready",1)
      IF num==2 THEN
        CALL DIALOG.setActionActive("qa_menu_ready",0)
        CALL showForm(img)
      END IF
    ON ACTION qa_menu_ready
      DISPLAY "  qa_menu_ready"
      CALL showForm(img)
    COMMAND "Show Form"
      CALL showForm(img)
    ON ACTION gotimage ATTRIBUTE(DEFAULTVIEW = NO)
      MESSAGE "Got image"
      --DISPLAY "  gotimage"
      LET f64 = util.Strings.base64Encode(img)
      CALL ui.Interface.frontCall(
          "webcomponent", "call", ["formonly.w", "getImgSrc"], [w64])
      --DISPLAY "  frontcall ended"
      DISPLAY "w64:",limitPrintStr(w64)
      IF (idx := w64.getIndexOf(";base64,", 1)) > 0 THEN
        LET w64 = w64.subString(idx + 8, w64.getLength())
      END IF
      MYASSERT_MSG(f64.equals(w64), sfmt("f64:%1 <> w64:%2", f64.subString(1, 40), w64.subString(1, 40)))
      IF _arg == "child2" THEN
        DISPLAY "RETURN from child2"
        --CALL fgl_winMessage(title: "info","RETURN from child2","info")
        EXIT PROGRAM
      END IF
      EXIT MENU
    ON ACTION noimage ATTRIBUTE(DEFAULTVIEW = NO)
      ERROR "no image"
      --CALL myErr("No image")
  END MENU
END FUNCTION

FUNCTION showForm(img STRING)
  OPEN FORM f FROM arg_val(0)
  DISPLAY FORM f
  MYASSERT_MSG(os.Path.exists(img) AND os.Path.size(img) > 0,sfmt("img:%1",img))
  DISPLAY "Entry" TO entry
  DISPLAY SFMT('{"value": "WebComponent", "src":"%1"}',
          ui.Interface.filenameToURI(img))
      TO w
  DISPLAY img TO logo
END FUNCTION

FUNCTION testProcessing()
  DEFINE i INT
  OPEN WINDOW processing AT 1,1 WITH 10 ROWS,10 COLUMNS
  FOR i=1 TO 3
    MESSAGE sfmt("Processing %1",i)
    CALL ui.Interface.refresh()
    IF i==3 THEN
      CALL ui.Interface.frontCall("standard","feInfo",["feName"],[])
    END IF
  END FOR
  CLOSE WINDOW processing
END FUNCTION

FUNCTION limitPrintStr(s STRING)
  DEFINE len INT
  LET len = s.getLength()
  IF len > 323 THEN
    RETURN s.subString(1, 160) || "..." || s.subString(len - 160, len)
  ELSE
    RETURN s
  END IF
END FUNCTION

FUNCTION myErr(errstr STRING)
  DEFINE ch base.Channel
  LET ch = base.Channel.create()
  CALL ch.openFile("<stderr>", "w")
  CALL ch.writeLine(
      SFMT("ERROR:%1 stack:\n%2", errstr, base.Application.getStackTrace()))
  CALL ch.close()
  EXIT PROGRAM 1
END FUNCTION
