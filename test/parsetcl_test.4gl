--Unit test for the Tcl AUI scanner in fgljp.4gl (parseTcl and friends).
--
--The regular suite never exercises the scanner: with a modern DVM
--(filetransferVersion 2 + filetransferFC) handleVMLine() forwards om lines
--verbatim ("no need to parse the protocol anymore"); the scanner only runs
--for old VMs without FT2/FTFC or with --gdc. So this test drives parseTcl()
--directly: append/update/remove ops, nested children, escape sequences,
--non-ASCII values and the removePendingFT splice.
--
--Since the DOC-6487 conversion (STRING.split(NULL) character array instead
--of getCharAt(i) walking) the scanner is character exact under BOTH length
--semantics -- the Makefile 'test' target runs this with BYTE and with CHAR.
IMPORT FGL fgljp

MAIN
    DEFINE v fgljp.TVMRec
    DEFINE n om.DomNode
    DEFINE umlaut, want STRING

    DISPLAY "parsetcl_test: FGL_LENGTH_SEMANTICS=",
            NVL(fgl_getenv("FGL_LENGTH_SEMANTICS"), "(default)")
    LET v.rnFTNodeId = 0

    --1: root node with non-ASCII attribute values
    LET umlaut = "ÄÖÜß€-value"
    CALL fgljp.parseTcl(v,
        SFMT('om 0 {{an 0 UserInterface 0 {{text "%1"} {name "täst"}} {}}}',
             umlaut))
    LET n = fgljp.node(v, 0)
    CALL check(n IS NOT NULL, "root node exists")
    CALL check(n.getAttribute("text") == umlaut,
               SFMT("non-ASCII value intact: got '%1', want '%2'",
                    n.getAttribute("text"), umlaut))
    CALL check(n.getAttribute("name") == "täst", "2nd non-ASCII attribute")

    --2: escape sequences of getValueWithSeparator: \" \\ \n \{ \} \$
    --wire value: q\"uote b\\ack n\new br\{ace\} d\$ollar
    CALL fgljp.parseTcl(v,
        'om 1 {{an 0 Esc 1 {{v "q\\\"uote b\\\\ack n\\new br\\{ace\\} d\\$ollar"}} {}}}')
    LET want = 'q"uote b\\ack n\new br{ace} d$ollar'
    LET n = fgljp.node(v, 1)
    CALL check(n IS NOT NULL, "escape node exists")
    CALL check(n.getAttribute("v") == want,
               SFMT("escapes decoded: got '%1', want '%2'",
                    n.getAttribute("v"), want))

    --3: multiple ops in one om: append then update, then remove
    CALL fgljp.parseTcl(v, 'om 2 {{an 0 Child 2 {{x "1"}} {}} {un 2 {{x "2"}}}}')
    LET n = fgljp.node(v, 2)
    CALL check(n.getAttribute("x") == "2", "un updated the attribute")
    CALL fgljp.parseTcl(v, 'om 3 {{rn 2}}')
    CALL check(fgljp.node(v, 2) IS NULL, "rn removed the node")

    --4: nested child list of an append
    CALL fgljp.parseTcl(v,
        'om 4 {{an 0 Parent 3 {{p "1"}} {{Kid 4 {{k "ä"}} {}}}}}')
    LET n = fgljp.node(v, 4)
    CALL check(n IS NOT NULL, "nested child exists")
    CALL check(n.getTagName() == "Kid", "nested child tag")
    CALL check(n.getAttribute("k") == "ä", "nested child non-ASCII value")

    --5: removePendingFT splices "{rn <id>} " at the parse position; the
    --injected op is meant for the downstream client (forwarded VmCmd) and
    --is deliberately skipped by the local parser: _p.pos must advance
    --exactly past the splice so the following op still parses correctly
    LET v.rnFTNodeId = 4
    CALL fgljp.parseTcl(v, 'om 5 {{an 0 After 5 {{a "1"}} {}}}')
    CALL check(fgljp.node(v, 5) IS NOT NULL, "op after the splice parsed")
    CALL check(fgljp.node(v, 4) IS NOT NULL,
               "splice is client-only, local node untouched")
    CALL check(v.rnFTNodeId == 0, "rnFTNodeId reset")

    DISPLAY "parsetcl_test: TEST OK"
END MAIN

FUNCTION check(cond BOOLEAN, msg STRING)
    IF cond THEN
        DISPLAY "ok: ", msg
    ELSE
        DISPLAY "FAILED: ", msg
        EXIT PROGRAM 1
    END IF
END FUNCTION
