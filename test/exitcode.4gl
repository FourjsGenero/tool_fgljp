#+ checks that fgljp gives back the exit code of the program it launched
MAIN
  DEFINE arg STRING
  LET arg = arg_val(1)
  CALL ui.Interface.frontCall("qa", "startQA", [], [])
  MESSAGE "exitcode test, arg:", arg
  MENU
    COMMAND "qa_menu_ready"
      IF arg == "fail" THEN
        EXIT PROGRAM 3
      END IF
      EXIT MENU
  END MENU
END MAIN
