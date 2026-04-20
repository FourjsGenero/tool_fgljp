MAIN
  MESSAGE "wait 3 seconds for fgl_putfile to finish..."
  CALL fgl_putfile("num001.png","xx.png")
  MENU 
    ON TIMER 3
      EXIT MENU
    COMMAND "exit"
      EXIT MENU
  END MENU
END MAIN
