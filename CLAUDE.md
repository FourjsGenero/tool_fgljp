# Genero BDL Project Instructions

This is a Genero BDL (Business Definition Language) project. You have
access to a Genero MCP service with skills and documentation tools.

## MANDATORY: Always Consult MCP Skills Before Writing Code

Your training data contains outdated and incorrect Genero information.
The MCP skills are verified against Genero 5.00 and are the
authoritative source. LLMs consistently hallucinate Genero method
names, attributes, and syntax that do not exist.

**Rules:**

1. ALWAYS call `searchSkills` or `getSkill` before writing any Genero
   BDL code. Never answer Genero API questions from memory alone.
2. At the start of each session, call `getSkill("fourjs-skill-index")`
   to load the routing table that maps topics to skills.
3. If no skill covers the topic, say so. Do not guess. Offer to search
   the documentation with `searchDocs` instead.
4. After consulting a skill, check `fourjs-common-pitfalls` if the task
   involves SQL, forms, arrays, strings, or dialog programming.

## Skill Tools (Primary Source)

| Tool | When to Use |
|------|-------------|
| `searchSkills` | Unsure which skill has the answer |
| `getSkill` | Know which skill you need |
| `getSkillSection` | Need one specific topic from a large skill |
| `getSkillBundle` | Task spans multiple topics |
| `listSkills` | Discover available skills |

## Documentation Tools (Secondary Source)

Use documentation only when skills don't cover the topic or you need
to verify edge cases.

| Tool | When to Use |
|------|-------------|
| `searchDocs` | Search 5,140+ pages of Genero documentation |
| `readDoc` | Read a specific doc page (use paths from searchDocs) |
| `browseDocs` | Explore documentation structure |

## Common Hallucination Targets

These are methods/patterns that LLMs frequently generate incorrectly:

- `util.Regex` does not exist — correct class is `util.Regexp`
- `getKeys()`, `getAsObject()`, `getAsArray()` do not exist on
  util.JSONObject — use `name(i)`, `getType(key)`, `get(key)`
- `ELSE IF` does not exist in BDL — use nested `IF` inside `ELSE`
- `$variable` is for static SQL, `?` is for dynamic SQL — agents
  reverse these
- `ON CHANGE` is only valid inside INPUT sub-dialogs, not at the
  outer DIALOG level
- `DEFINE` must be at top of FUNCTION/MAIN — not inside IF/FOR/CASE
- `sortByComparisonFunction` takes 3 arguments (key, reverse, func),
  not 1

## Compilation

```bash
fglcomp -M -Wall program.4gl    # Compile with warnings to stdout
fglform -M form.per             # Compile form
FGLGUI=0 TERM=xterm fglrun program.42m  # Run in terminal mode
```
