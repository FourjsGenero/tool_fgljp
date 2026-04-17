MAIN
  DEFINE name STRING
  MENU
    COMMAND "exit"
      EXIT MENU
  END MENU
  MESSAGE "last"
  CALL ui.Interface.refresh()
  CALL ui.Interface.frontcall("standard","feInfo",["feName"],[name])
  DISPLAY "name:",name
END MAIN
