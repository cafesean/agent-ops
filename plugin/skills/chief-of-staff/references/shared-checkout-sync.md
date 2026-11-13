# Syncing a shared checkout that many sessions write into

Read when a worker must pull or push a checkout other sessions also write into (their uncommitted edits, untracked
copies, dirty tracked files), e.g. a docs or context repo on one machine.

## Symptom
`git pull --rebase` aborts with `could not detach HEAD` or "untracked working tree files would be overwritten":
files that exist untracked here are now tracked on origin.

## Procedure (no reset --hard, no clean, no force push)
1. `git fetch`. Blocking set = `comm -12 <(untracked, sorted) <(git ls-tree -r --name-only origin/<br>, sorted)`
   (untracked list: `git status --porcelain --untracked-files=all -z`).
2. For each blocking file: `git show "origin/<br>:$f" | cmp -s - "$f"` → identical = drop; different = copy to
   `<backup-dir>/untracked-differ/<path>` first, then drop. Write both lists into `<backup-dir>`.
3. Foreign tracked edits: copy every modified file to `<backup-dir>/tracked-modified/<path>` + the porcelain list,
   then `git stash push -m "<worker> <date> pre-rebase tracked edits (other sessions)"`.
4. `git pull --rebase`. In a rebase **ours = upstream**, theirs = the local commit. Index or table conflicts: take
   upstream when it is a superset, else union the rows and keep the newer `updated:` date. Check no markers remain.
5. Push. Then `git stash pop`; resolve the same way. Modify/delete (`UD`) where upstream changed a file the stash
   deleted: keep upstream (it is the newer truth).
6. Proof: every file in `<backup-dir>/tracked-modified/` byte-equals the working tree (`cmp`), except files you
   resolved on purpose; `git status -sb` shows no ahead/behind. Keep the stash as a safety net; never drop it yourself.

## Many-thousand dirty files (no local commits, only behind)
1. **Secret scan before any add:** copy text files ≤ 5 MB to a scratch dir and run a secret scanner over it with
   redaction on; report file + rule only. Hit files stay uncommitted unless hand-checked as false positives.
2. **Size:** commit nothing over 5 MB unless origin already holds such files; gitignore build binaries. Hosts reject
   very large files and pushes → push one commit at a time: `git push origin "${h}:refs/heads/<br>"`.
3. Overlap = dirty ∩ `git diff --name-only HEAD origin/<br>`; compare `git hash-object` with
   `git rev-parse "origin/<br>:<f>"`. Same → drop after backup. Diverged → keep the newer or superset side at the
   path: upstream text is already in history, so only a losing local version needs saving (commit it as a dated
   sibling file).
4. Back up the overlap, `checkout --` / `rm` it, `git merge --ff-only`, restore, then commit by top folder with
   `GIT_LITERAL_PATHSPECS=1 git add --pathspec-from-file=- --pathspec-file-nul` (names with spaces or brackets).
5. Live sessions keep writing: after pushing, re-list dirty files minus your exclude list, scan + commit the late ones.

## Traps
- **zsh `$h:r` is a modifier** (strip extension): `git push origin $h:refs/heads/main` fails with a mangled refspec.
  Brace it: `"${h}:refs/…"`.
- `git rebase` refuses with excluded files still dirty → check `git rev-list --count HEAD..origin/<br>` first;
  `--autostash` only if behind.
- **A `git diff` patch backup leaks secrets**: edits that redact a key carry the removed key on `-` lines. Back up
  file copies, not a patch; scan the backup dir for key patterns before reporting.
- zsh does not word-split `$(git diff --name-only …)` into args → pipe to `xargs git add --`.
- After a conflicted pop, `git add <files> && git reset -q` restores "unstaged edits" (pop never restores the index).
- A committed symlink whose target is an absolute local path, or an untracked file, is broken on every other
  machine → commit the real file instead.
