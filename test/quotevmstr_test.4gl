--Unit test for quoteVMStr() in fgljp.4gl: quoting of string values sent to
--the VM. Example: sending the text 'a"{' in a configure event goes on the
--wire as
--  {{ConfigureEvent 0{{idRef "112"}{ text "a\"\{"}}}}
--i.e. \ " $ { } and newline get a backslash prefix (newline becomes \n).
--
--Since the DOC-6487 conversion (pattern replaces on a StringBuffer instead
--of a getCharAt(i) loop) the function is character exact under BOTH length
--semantics -- the Makefile 'test' target runs this with BYTE and with CHAR.
--The replace order matters: backslash doubling must come first so it never
--doubles the backslashes the other replaces insert; several cases below
--(real newline, backslash+quote) fail for any other order.
IMPORT FGL fgljp

MAIN
    DEFINE v fgljp.TVMRec
    DEFINE n om.DomNode
    DEFINE raw STRING

    DISPLAY "quotevmstr_test: FGL_LENGTH_SEMANTICS=",
            NVL(fgl_getenv("FGL_LENGTH_SEMANTICS"), "(default)")

    --1: the ConfigureEvent example: text 'a"{' goes on the wire as a\"\{
    CALL expect('a"{', 'a\\"\\{')

    --2: each escaped character on its own
    CALL expect('\\', '\\\\')
    CALL expect('\n', '\\n') --real newline -> backslash n (order sensitive)
    CALL expect('"', '\\"')
    CALL expect('$', '\\$')
    CALL expect('{', '\\{')
    CALL expect('}', '\\}')

    --3: replace-order hazards
    --backslash+n stays distinguishable from a real newline
    CALL expect('\\n', '\\\\n')
    --backslash+quote: \" -> \\\" (4 chars); quote-before-backslash order
    --would yield \\\\" (5 chars)
    CALL expect('\\"', '\\\\\\"')
    --consecutive specials
    CALL expect('{{}}$', '\\{\\{\\}\\}\\$')

    --4: non-ASCII passes through unmangled; the old getCharAt(i) loop
    --mangled these under BYTE length semantics (DOC-6487)
    CALL expect('ÄÖÜß€', 'ÄÖÜß€')
    CALL expect('Ä"Ö{ß€}', 'Ä\\"Ö\\{ß€\\}')

    --5: NULL/empty input yields a zero length result. Note: it is NOT NULL,
    --StringBuffer.toString() of an empty buffer returns a non NULL zero
    --length STRING -- same as with the old getCharAt loop implementation,
    --which also fell through to sb.toString() for NULL input
    CALL check(length(fgljp.quoteVMStr(NULL)) == 0, "NULL yields empty")

    --6: round trip: parseTcl's getValueWithSeparator decodes exactly the
    --escape set quoteVMStr produces
    LET raw = 'q"uote b\\ack n\new br{ace} d$ollar ÄÖÜ'
    LET v.rnFTNodeId = 0
    CALL fgljp.parseTcl(v,
        SFMT('om 0 {{an 0 RT 0 {{t "%1"}} {}}}', fgljp.quoteVMStr(raw)))
    LET n = fgljp.node(v, 0)
    CALL check(n IS NOT NULL, "round trip node exists")
    CALL check(n.getAttribute("t") == raw,
               SFMT("round trip exact: got '%1', want '%2'",
                    n.getAttribute("t"), raw))

    DISPLAY "quotevmstr_test: TEST OK"
END MAIN

FUNCTION expect(raw STRING, want STRING)
    DEFINE got STRING
    LET got = fgljp.quoteVMStr(raw)
    CALL check(got == want,
               SFMT("quoteVMStr('%1'): got '%2', want '%3'", raw, got, want))
END FUNCTION

FUNCTION check(cond BOOLEAN, msg STRING)
    IF cond THEN
        DISPLAY "ok: ", msg
    ELSE
        DISPLAY "FAILED: ", msg
        EXIT PROGRAM 1
    END IF
END FUNCTION
