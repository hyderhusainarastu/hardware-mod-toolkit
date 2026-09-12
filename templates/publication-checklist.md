<!--
HOW TO USE THIS TEMPLATE
1. Run through this checklist once, in order, before making a private hardware-mod repo
   public. Every item is here because a real project found the corresponding problem only
   at publish time, when it's expensive to fix (git history rewrites are disruptive to
   anyone with an existing clone).
2. This checklist assumes git. If you use another VCS, translate "history rewrite" to
   whatever your tool's equivalent is (most have one; none of them are pleasant).
3. Do the history-rewrite items ONCE, as late as possible before the actual publish, so you
   don't have to redo it for commits made in between.
4. Also run the `hygiene-auditor` agent / `publish-audit` workflow from this toolkit if
   available — it automates the grep-based checks below; this checklist is the manual
   fallback and the thing to read to understand *why* each check exists.
-->

# Publication checklist — <PROJECT>

This repo is not ready to publish as-is until every box below is checked.

- [ ] **Decide: history rewrite, or fresh-history export.** Either strip sensitive data from
      every commit in place (`git filter-repo`, preferred over `filter-branch`), or build a
      fresh orphan branch / squashed export from the current tree and abandon the old
      history entirely for the public copy. Redacting only the working tree does not remove
      already-committed secrets from history — a `git log -p` or `git show <old-sha>` still
      exposes them. Either way, do this **once**, right before publishing.

- [ ] **Grep the full history for identifiers, not just the working tree.** At minimum:
      Wi-Fi SSIDs/passwords, device serial numbers, MAC addresses, hostnames, a person's
      name/username/email, absolute home-directory paths, machine names. A string redacted
      in a later commit still exists in the commit(s) before it.

  ```
  # example sweep — adjust the pattern list to your own identifiers
  git log -p --all | grep -inE '<ssid-pattern>|<mac-pattern>|<serial-pattern>|/Users/[a-z]+|/home/[a-z]+'
  ```

- [ ] **Confirm dumps/vendor-firmware/backups are untracked, not just gitignored going
      forward.** `git ls-files <backups-dir>/` must return nothing. Re-check this *after* any
      history rewrite — a rewrite can resurrect a path that was only ever excluded going
      forward (added to `.gitignore` after the file was already committed), not purged from
      earlier commits retroactively.

- [ ] **Decide what identity survives in commit trailers.** Commits may carry
      `Co-Authored-By:` or other attribution trailers with a real name/email. Decide
      deliberately whether that should survive publication; if not, scrub it in the same
      history-rewrite pass as the identifier sweep above (`git filter-repo` rewrites commit
      messages, not just file contents).

- [ ] **Review capture files for identifiers the automated redaction pass missed.** Serial/
      USB capture logs are often redacted by a capture script's best-effort pass, but
      best-effort is not a guarantee — grep the actual tracked files under a captures
      directory for MAC addresses, device serials, hostnames, SSIDs *before* the history
      rewrite captures them permanently. Doing this after the rewrite means doing the
      rewrite twice.

- [ ] **Grep for vendor binaries and vendor text.** Nothing under version control should ship
      a byte of a vendor's firmware image, vendor SDK source, or vendor documentation text
      beyond short, clearly-attributed quotation. Confirm the actual tracked file list, not
      just the gitignore rules:

  ```
  git ls-files | xargs file | grep -iE 'executable|ELF|Mach-O|PE32'
  ```

- [ ] **Pick and add a LICENSE.** State explicitly, in the README, what license covers the
      *original code and documentation* — and, separately and explicitly, that any vendor
      firmware/binary referenced or analyzed is **not** redistributed and remains the
      vendor's own property. These are two different statements; don't let one imply the
      other.

- [ ] **State the reverse-engineering framing in the README.** Make clear the repo is
      original documentation/tooling produced by observing and analyzing a device the author
      owns, not a redistribution of the vendor's software — this is both a legal clarity
      point and a courtesy to readers deciding whether to trust the repo's contents.

- [ ] **Final full-tree grep, after every above step, on the exact tree about to be
      published** (not the working repo — the actual export/branch that will go public):

  ```
  git ls-files | xargs grep -linE '<owner-name-pattern>|/Users/|/home/|<serial-pattern>|<mac-pattern>|<ssid-pattern>' 2>/dev/null
  ```

  An empty result is the bar. If anything hits, fix it and re-run — don't publish on a
  "probably fine."
