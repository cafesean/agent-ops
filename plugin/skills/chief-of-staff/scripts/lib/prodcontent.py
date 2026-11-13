#!/usr/bin/env python3
"""Is it on prod? Answered from CONTENT, never from commit ancestry.

Why: hold-out cuts revert work on main while the commits stay in main's history, so `git cherry`,
`git log main`, `merge-base --is-ancestor` and "is commit X on main" all report held work as SHIPPED.


Method (read-only: git log / diff / diff-tree / ls-tree / show / blame; no ref, worktree, index or object written):
  * held files  = `git diff --name-only <prod> <dev>`  (the real tree difference).
  * a differing file does NOT mean every commit that touched it is missing. Per file we walk the
    develop history of that file (blob ids, --full-history --topo-order) and keep only the commits
    between main's version of the file and develop's version of it (`missing_for_file`). Re-land
    commits (a restore of held work) are traced back to the feature commits they re-land.
  * one commit on prod (`commit_on_prod`): per file it touches — prod's blob equals the commit's or
    develop's → present; the commit is in that file's missing set → held; else its added lines that
    develop STILL has (later rewrites on develop = superseded, not held) must all be in prod's copy.
    Commits not on develop (main merges, hotfixes): same line check against develop + prod.
    Repos with no develop branch at all: in prod history and not reverted → present; not in
    history → its added lines in prod's copy (squash / cherry-pick) decide.
Results are per file, never per hash. Git content only — not proof of what a host is running.
"""
import os, subprocess

ZERO = "0" * 40


def git(repo, *a, inp=None, env=None):
    """Real git, never the rtk proxy (it rewrites output)."""
    r = subprocess.run(["git", "-C", repo, *a], capture_output=True, text=True, input=inp,
                       env={**os.environ, **(env or {})})
    return r.returncode, r.stdout


class Repo:
    def __init__(self, path, prod, dev):
        self.path, self.prod, self.dev = path, prod, dev   # refs, e.g. origin/main, origin/develop
        self._blob, self._hist, self._miss, self._trees, self._held, self._lc = {}, {}, {}, {}, {}, {}

    # ---- primitives -------------------------------------------------------------------------
    def tree(self, ref):
        """Whole tree of a branch ref as {path: blob}, one `ls-tree -r` per ref."""
        if ref not in self._trees:
            rc, out = git(self.path, "ls-tree", "-r", "-z", ref)
            t = {}
            for e in out.split("\0"):
                if "\t" in e:
                    meta, path = e.split("\t", 1); t[path] = meta.split()[2]
            self._trees[ref] = t
        return self._trees[ref]

    def blob(self, ref, f):
        if ref in (self.prod, self.dev): return self.tree(ref).get(f, ZERO)
        k = (ref, f)
        if k not in self._blob:
            rc, out = git(self.path, "ls-tree", ref, "--", f)
            self._blob[k] = out.split()[2] if rc == 0 and out.strip() else ZERO
        return self._blob[k]

    def is_anc(self, a, b):
        return git(self.path, "merge-base", "--is-ancestor", a, b)[0] == 0

    def held_files(self):
        """Files whose content differs between prod and develop (renames off: one path = one file)."""
        rc, out = git(self.path, "diff", "--no-renames", "--name-only", self.prod, self.dev)
        return [l for l in out.splitlines() if l] if rc == 0 else []

    def history(self, f):
        """Non-merge develop commits touching f, newest first (topo): dicts sha, short, author, date, subj, old, new."""
        if f in self._hist: return self._hist[f]
        rc, out = git(self.path, "log", "--full-history", "--no-merges", "--topo-order", "--no-renames",
                      "--format=\x1e%H\x1f%H\x1f%an\x1f%ad\x1f%s", "--date=short", "--raw", "--no-abbrev",
                      self.dev, "--", f)
        rows = []
        for chunk in out.split("\x1e")[1:]:
            lines = chunk.splitlines()
            head = (lines[0].split("\x1f") + [""] * 5)[:5]
            old = new = None
            for l in lines[1:]:
                if l.startswith(":") and "\t" in l and l.split("\t", 1)[1] == f:
                    p = l.split("\t", 1)[0].split()
                    old, new = p[2], p[3]
            if old is None: continue
            rows.append({"sha": head[0], "short": head[0][:9], "author": head[2], "date": head[3],
                         "subj": head[4], "old": old, "new": new})
        self._hist[f] = rows
        return rows

    # ---- per file: which develop commits are missing on prod -----------------------------------
    def missing_for_file(self, f):
        """→ (commits, how). commits = the feature commits whose change to f is not on prod.
        how: 'traced' (main's version found in develop history) · 'new-file' (f absent on prod) ·
        'blamed' (prod's version never existed as a develop commit's result — merges, hotfixes, repeated
        hold/re-land cycles — so each develop commit is judged by its own surviving lines, see _blame) ·
        'removed-lines' (develop only deletes lines prod still has: newest real change named — confirm) ·
        'same' (no difference)."""
        if f in self._miss: return self._miss[f]
        pb, db = self.blob(self.prod, f), self.blob(self.dev, f)
        h = self.history(f)
        if pb == db:
            res = ([], "same")
        else:
            starts = [i for i, c in enumerate(h) if c["new"] == db]
            if not starts:
                res = self._blame(f, h)
            else:
                seen, out, how = set(), [], "traced"
                todo = [max(starts)]          # oldest commit that first produced develop's version
                while todo:
                    i = todo.pop()
                    while i < len(h):
                        c = h[i]
                        if c["new"] == pb: break           # reached main's version: older commits are on prod
                        if c["sha"] not in seen:
                            seen.add(c["sha"]); out.append(c)
                            # a re-land: its result equals an OLDER version → trace that version's feature commits
                            older = [j for j in range(i + 1, len(h)) if h[j]["new"] == c["new"] and h[j]["sha"] not in seen]
                            if older: todo.append(older[0])
                        if c["old"] == pb: break           # first change away from main's version
                        i += 1
                    else:
                        if pb != ZERO: how = "own-edits"
                if how == "own-edits":
                    res = self._blame(f, h)
                else:
                    if pb == ZERO: how = "new-file"
                    # drop re-land commits whose content we traced to the feature commits they restore
                    feats = [c for c in out if not any(o is not c and o["new"] == c["new"] and h.index(o) > h.index(c) for o in out)]
                    res = (feats or out, how)
                    self._held[f] = {c["sha"] for c in out}      # incl. re-land commits, for commit_on_prod
        self._miss[f] = res
        return res

    def _restores(self, h):
        """Commits that put back a version the file already had (hold-out reverts, re-lands, plain reverts)."""
        out = set()
        for i, c in enumerate(h):
            if any(c["new"] in (o["new"], o["old"]) for o in h[i + 1:]): out.add(c["sha"])
        return out

    def _blame(self, f, h):
        """Line-level, for files whose prod version is not a develop version: every non-restore develop
        commit on f is judged by its OWN lines that develop still has (one `git log -p` for the file).
        Held = some of those lines are not in prod's copy. Restore commits (re-lands) are skipped: the
        feature commits they restore carry the same lines."""
        restores = self._restores(h)
        rc, out = git(self.path, "log", "--full-history", "--no-merges", "--no-renames", "-p", "--format=\x1e%H",
                      self.dev, "--", f)
        dev, prod = self._lines(self.dev, f), self._lines(self.prod, f)
        by = {c["sha"]: c for c in h}
        res = []
        for chunk in out.split("\x1e")[1:]:
            sha, _, body = chunk.partition("\n")
            sha = sha.strip()
            if sha in restores or sha not in by: continue
            st = self._judge(body, dev, prod)[0]
            if st != "✅": res.append(by[sha])
        if not res:
            real = [c for c in h if c["sha"] not in restores]
            return (real[:1] or h[:1], "removed-lines")
        return (res, "blamed")

    @staticmethod
    def _judge(patch, dev, prod):
        """One commit's patch to one file vs develop's and prod's lines (sets of stripped lines)."""
        def pick(sign):
            return [l[1:].strip() for l in patch.splitlines()
                    if l.startswith(sign) and not l.startswith(sign * 3) and len(l[1:].strip()) > 3]
        added = pick("+")
        if added:
            surv = [l for l in added if l in dev]
            if not surv: return "✅", "superseded on develop too"
            n = sum(1 for l in surv if l in prod)
            if n == len(surv): return "✅", "change present"
            return ("✗", "change missing") if n == 0 else ("≈", f"{n}/{len(surv)} lines there — confirm")
        gone = [l for l in pick("-") if l not in dev]
        if not gone: return "✅", "no line-level change to check"
        n = sum(1 for l in gone if l in prod)
        return ("✅", "deletion present") if n == 0 else ("✗", "deleted lines still on prod") if n == len(gone) else ("≈", "partly — confirm")

    # ---- per commit: is its change on prod ---------------------------------------------------
    def files_of(self, sha):
        """[(path, blob after the commit)] vs its first parent; one diff-tree call."""
        rc, out = git(self.path, "diff-tree", "-r", "-z", "--no-renames", "--no-commit-id", f"{sha}^1", sha)
        if rc != 0:   # root commit
            rc, out = git(self.path, "diff-tree", "-r", "-z", "--no-renames", "--no-commit-id", "--root", sha)
        p, res = out.split("\0"), []
        for i in range(0, len(p) - 1, 2):
            if p[i].startswith(":"): res.append((p[i + 1], p[i].split()[3]))
        return res

    def _lines(self, ref, f):
        k = (ref, f)
        if k not in self._lc:
            if self.blob(ref, f) == ZERO: self._lc[k] = set()
            else:
                _, body = git(self.path, "show", f"{ref}:{f}")
                self._lc[k] = {l.strip() for l in body.splitlines()}
        return self._lc[k]

    def _survivor_state(self, sha, f):
        """The commit's own lines that develop still has must all be in prod's copy (see _judge)."""
        rc, patch = git(self.path, "diff", f"{sha}^1", sha, "--", f)
        if rc != 0 or not patch.strip(): return "≈", "binary or empty patch — confirm"
        return self._judge(patch, self._lines(self.dev, f), self._lines(self.prod, f))

    def commit_on_prod(self, sha):
        """→ (sym, files) sym ✅ every file's change on prod · ✗ at least one held · ≈ cannot tell (confirm);
        files = [(path, sym, why)]."""
        if not self.dev:
            # no develop branch (plugin repos): hold-outs need develop, so ancestry + a revert search is the
            # best git can say here — labelled as such. Not in history → its added lines in prod's copy.
            anc = self.is_anc(sha, self.prod)
            rc, rv = git(self.path, "log", self.prod, "--format=%h", "-F", f"--grep=This reverts commit {sha[:7]}", "-n", "1")
            if anc and not rv.strip(): return "✅", [("*", "✅", "in prod history; no develop to compare")]
            if anc: return "✗", [("*", "✗", f"reverted on prod {rv.strip()}")]
            res = []
            for f, cb in self.files_of(sha):
                if cb == self.blob(self.prod, f): res.append((f, "✅", "same as commit")); continue
                rc, patch = git(self.path, "diff", f"{sha}^1", sha, "--", f)
                added = [l[1:].strip() for l in patch.splitlines() if l.startswith("+") and not l.startswith("+++") and len(l[1:].strip()) > 3]
                have = self._lines(self.prod, f); n = sum(1 for l in added if l in have)
                res.append((f, *(("✅", "lines present (squash/cherry-pick)") if added and n == len(added) else
                                ("✗", "not in prod history") if n == 0 else ("≈", f"{n}/{len(added)} lines — confirm"))))
            syms = {x[1] for x in res} or {"✗"}
            return ("✗" if "✗" in syms else "≈" if "≈" in syms else "✅"), res
        on_dev = self.is_anc(sha, self.dev)
        res = []
        for f, cb in self.files_of(sha):
            pb = self.blob(self.prod, f)
            if cb == pb: res.append((f, "✅", "same as commit")); continue
            db = self.blob(self.dev, f)
            if pb == db and on_dev: res.append((f, "✅", "same as develop")); continue
            miss, how = self.missing_for_file(f) if on_dev else ([], "off-develop")
            exact = how in ("traced", "new-file")   # blob-traced = exact; blamed / removed-lines → judge the commit's own lines
            if exact and (cb == db or sha in self._held.get(f, set()) or any(c["sha"] == sha for c in miss)):
                res.append((f, "✗", "held: change not in prod file")); continue
            s, why = self._survivor_state(sha, f)   # the commit's own lines, judged against develop + prod
            res.append((f, s, why))
        if not res: return "≈", res
        syms = {s for _, s, _ in res}
        return ("✗" if "✗" in syms else "≈" if "≈" in syms else "✅"), res

    def close(self):
        """Nothing on disk to clean (kept so callers can always close)."""
