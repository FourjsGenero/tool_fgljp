#+ The URLs fgljp gives the VM for its resources must be relative.
#+
#+ The VM publishes resource URLs in the AUI tree: an ImageFont node per
#+ image2font font (FontAwesome and friends, taken from FGLIMAGEPATH's mapping
#+ files) plus the images it resolves the same way. The front end fetches them
#+ itself, so an absolute "http://localhost:<fgljp port>/..." only works while
#+ the browser sits on the machine fgljp runs on. It breaks as soon as
#+ something is in between -- a forwarded port (VS Code's form preview over
#+ Remote-SSH), an ssh tunnel, a reverse proxy: the browser then reaches fgljp
#+ under a different origin and the absolute URL points at nothing, which shows
#+ up as icons rendered in the fallback font. A relative URL is resolved
#+ against the page origin and holds in all of those setups.
#+
#+ Run under fgljp ("../fgljp urlprefix"); exits non-zero on the first URL that
#+ is not relative.
MAIN
  --every check runs inside the QA session: a program that leaves before the
  --front end connected leaves fgljp waiting for a browser that never comes
  CALL ui.Interface.frontCall("qa", "startQA", [], [])
  MENU
    COMMAND "qa_menu_ready"
      CALL checkRelative("FGL_PRIVATE_URL_PREFIX",
          fgl_getenv("FGL_PRIVATE_URL_PREFIX"))
      CALL checkRelative("FGL_PUBLIC_URL_PREFIX",
          fgl_getenv("FGL_PUBLIC_URL_PREFIX"))
      --the ImageFont nodes appear when the front end connects, not before
      CALL checkImageFonts()
      EXIT MENU
  END MENU
  DISPLAY "urlprefix: TEST OK"
END MAIN

#+ every font the VM published must be reachable from any page origin
FUNCTION checkImageFonts()
  DEFINE root, n om.DomNode
  DEFINE nl om.NodeList
  DEFINE i, cnt INT
  LET root = ui.Interface.getRootNode()
  LET nl = root.selectByTagName("ImageFont")
  LET cnt = nl.getLength()
  IF cnt == 0 THEN
    --no mapping file in FGLIMAGEPATH: this install has no fonts to publish
    DISPLAY "urlprefix: no ImageFont node, nothing to check"
    RETURN
  END IF
  FOR i = 1 TO cnt
    LET n = nl.item(i)
    CALL checkRelative(
        SFMT("ImageFont '%1' href", n.getAttribute("name")),
        n.getAttribute("href"))
  END FOR
  DISPLAY SFMT("urlprefix: %1 ImageFont href(s) relative", cnt)
END FUNCTION

FUNCTION checkRelative(what STRING, url STRING)
  IF url IS NULL OR url.getLength() == 0 THEN
    CALL fail(SFMT("%1 is empty", what))
  END IF
  IF NOT url.getCharAt(1).equals("/") THEN
    CALL fail(
        SFMT("%1 must be relative to the page origin, got '%2'", what, url))
  END IF
END FUNCTION

FUNCTION fail(msg STRING)
  DISPLAY "urlprefix: FAILED: ", msg
  EXIT PROGRAM 1
END FUNCTION
