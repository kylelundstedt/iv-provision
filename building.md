---
title: "Maintaining"
---

There is no image build **in this repository**. The base images are built and
published from [`kylelundstedt/exeslim`](https://github.com/kylelundstedt/exeslim)
(`Dockerfile` → `exeslim`, `Dockerfile.dev` → `exeslim-dev`, both to GHCR by
GitHub Actions on push plus a weekly rebuild for Ubuntu security updates).

This repository owns the layer above that: VMs get the IV tooling from
`provision-iv.sh` at a pinned git tag/sha. To change what VMs receive, edit the
provisioning script and/or the vendored skills, then commit and tag.

Which repo to change:

| Change | Repo | Reaches existing VMs |
| ------ | ---- | -------------------- |
| OS packages, systemd units, image labels | `exeslim` | only by recreating the VM |
| Pinned tool versions, skills, agent config | this repo | re-provision in place (~23s) |
| OS security patches | neither — `iv-apt-upgrade.timer` | automatically, daily |

## Changing tool versions

Tool versions and per-architecture checksums are pinned inside
`provision-iv.sh`. Change both the version and checksum values, run the local
validation suite, test provisioning on a disposable VM, then
commit and tag the revision. The provisioner checks installed versions and
upgrades mismatches when it is re-run.

```bash
cd ~/iv-provision
$EDITOR provision-iv.sh
./tests/test-ssh-guard.sh
python3 -m unittest discover -s tests -p 'test_*.py' -v
bin/render-site .
# provision + tests/smoke-provision.sh on a disposable VM
```

## Cutting a release

Provisioning releases are Git tags, not OCI image tags. Prepare and review a
release branch, merge it to `main`, then tag the exact tested merge commit:

```bash
git switch main
git pull --ff-only
# verify HEAD is the reviewed release commit and rerun the validation suite
git tag -a 2.5.0 -m "iv provisioning 2.5.0"
git push origin main
git push origin 2.5.0
```

Never move an existing release tag. Consumers pin the recipe by checking out the
tag before running `provision-iv.sh`.

### Bump the `create-vm` pin *in* the release, not after it

`skills-local/create-vm/SKILL.md` hard-codes the `iv-provision` tag a new VM
checks out, in four places, and it is the tag the skill's own "**Always pin the
tag**" rule is about. So it must name the release it ships in.

The natural sequence gets this wrong. Tag `main`, notice the pin is stale, bump
it, merge — and now the tag you cut points at a skill telling the next VM to
provision the release *before* it. `3.0.17` and `3.0.18` both shipped that way,
which is why `3.0.19` exists. It is self-correcting only in the sense that every
release fixes its predecessor and breaks itself.

Put the bump on the release branch, so the pin and the tag are the same commit:

```bash
sed -i 's/<previous>/<this release>/g' skills-local/create-vm/SKILL.md
# ...merge the release branch, then tag the merge commit
```

A doc-only release is still a release here: the fleet reads these skills from a
detached checkout at a tag, so an unbumped pin is invisible until a VM is created
from it.

## Refreshing the vendored skills

Team skills are vendored into `skills/` (committed to the repo so they are
frozen — `provision-iv.sh` copies them in with no node/npx on the VM). To
refresh the snapshot, run `vendor-skills.sh` on any machine with node, then
commit the result.

```bash
./vendor-skills.sh             # refreshes skills/ — needs node/npx
# review the diff, commit, tag
```

`vendor-skills.sh` installs into a throwaway `HOME` and requires `node`/`npx`;
it is the only maintenance step that needs node.

**Re-run it when cutting a release.** Skills have no version string, so unlike a
pinned tool — where `apex_version=1.1.13` in a lock file next to
`APEX_VERSION=1.1.16` in the script is drift you can see at a glance — a stale
snapshot is invisible. `vendor-skills.sh` is itself the drift detector: run it and
read `git status`. A clean tree means no upstream moved; a diff is the report.

This is deliberately *not* a separate cadence. Skills refresh on the same clock as
every other pin here: edit, commit, tag, re-provision. Nor is it automated into a
scheduled bot PR, because the diff wants real review — skills carry executable
code (`install-duckdb/eval.sh`, various `.py` files) and one source is a bare
`curl` of a remote `SKILL.md`, so "latest upstream" means third-party code landing
on every VM.

Provisioning stays offline and reproducible for the same reason: two VMs
provisioned from one git sha must get identical skills, which fetching-at-install
would break.
