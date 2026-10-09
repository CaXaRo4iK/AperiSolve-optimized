# Fork maintenance (AperiSolve-optimized)

This fork tracks `Zeecka/AperiSolve` and carries a small set of changes:

- third-party front-end assets are self-hosted (downloaded by
  `scripts/vendor_assets.sh` in the `vendor` Docker stage, not committed);
- Dockerfile: dependency layer before app code, headless JRE, gthread gunicorn;
- release workflow: no QEMU, layer cache, builds on tags only, own image name;
- `.gitattributes` keeps LF in files that run inside Linux containers.

Remotes: `origin` = this fork, `upstream` = Zeecka/AperiSolve.

## Taking a new upstream release

```bash
git fetch upstream --tags
git checkout -b sync-X.Y.Z upstream/X.Y.Z   # or: git rebase upstream/main on your branch
git apply --3way patches/optimized.patch    # re-apply the fork changes
```

If `git apply --3way` reports conflicts they are almost always the CDN `<link>`
lines in `templates/base.html` or an image name; resolve, then:

```bash
bash scripts/vendor_assets.sh   # only needed for running without Docker
docker build -t aperisolve-opt:test .
```

## Upgrading a bundled library

Change the version at the top of `scripts/vendor_assets.sh`, update the matching
`/static/vendor/<lib>/<version>/...` path in `templates/base.html` /
`templates/map.html`, rebuild. Versions are part of the URL, so nginx and browser
caches never serve a stale file and a rollback to an older image keeps working.

## Regenerating the patch after changing the fork

```bash
git add -N . && git diff upstream/main -- . ':!patches' > patches/optimized.patch
```
