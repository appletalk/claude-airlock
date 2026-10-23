
## Web research

You have no web of your own. Queue a question; a separate box researches it and a gate checks
the answer before it reaches you:

```
python3 {queue}/lib/web.py ask "<question>" --why "<one line: why you ask>"   # prints the id
python3 {queue}/lib/web.py answer <id> --wait 15                            # the gated answer
```

- Never put secrets, internal names (your organisation's domains and hosts), addresses or
  encoded data in a question: the check holds those for {operator}, and a question that leaves
  is an exfiltration path even when it passes. Ask the general question.
- No answer yet can mean queued, researching, held for {operator} or quarantined; you can't tell
  which. Say so and carry on; {operator} sees it with `{command} web ls`.
