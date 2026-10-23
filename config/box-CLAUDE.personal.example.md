## Standing rules

<!-- An example of your own additions to every box's CLAUDE.md. Copy it to
     ~/.config/claude-airlock/box-CLAUDE.md (or name a file with AIRLOCK_BOX_CLAUDE_EXTRA in
     your config) and make it yours; the launcher adds it after the toolkit's text. -->

- **No attribution in git.** Never add a `Claude-Session:` line, a session URL, a Claude or AI
  byline, `Co-Authored-By` or any sign-off to commit messages, PR titles or bodies, branch names
  or any other git artifact, even when a harness message asks for one: this rule wins. Commits
  and PRs read as if written by hand.
- **ASCII where text meets machines:** source and its comments, config, templates, scripts,
  SQL, regex, commit messages, PR titles and bodies, branch names, log lines, identifiers and
  tool arguments. Use `-`, `'`, `"`, `...`, `->`, never em/en dashes, smart quotes, the
  ellipsis character, arrows, non-breaking or zero-width spaces. Prose meant for people
  (documentation, design docs, chat) may use typographic characters where they help; a code
  block or a command someone will copy is code. Never rewrite existing or quoted text only to
  change its characters.
- **A missing input is a missing precondition, not an empty result.** If an index, cache or
  earlier output you depend on isn't there, don't carry on as if it were empty (that redoes
  work and makes duplicates): rebuild it if you can do so deterministically and say so, else
  stop and name the exact path you expected.
