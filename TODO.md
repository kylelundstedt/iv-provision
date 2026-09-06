# TODO

Open work only. Release history → the table in `index.qmd`. Historical
research (custom-image / arm64 era) → `registry.md`.

## Decouple from the personal dotfiles repo

The team layer must stand alone: a fleet VM should provision fully without
`kylelundstedt/dotfiles`. Ordered by severity.

Done so far (all 2026-08-18): `tailscale`, `uv`, `claude`, and `codex` are
installed here, and the `provisioning/` manifests moved in-tree, retiring
`dotfiles-manifest.pin`. `provision-iv.sh` now has no functional dotfiles
dependency.

`node`/fnm was considered and deliberately left to dotfiles: the only thing that
needs it is `vendor-skills.sh`, which runs at authoring time and never on a VM.

Dotfiles-side edits. `repo-dotfiles` is attached to `vm:iv-provision` with
**write** (verified 2026-08-19 by a real push-and-delete, correcting the old
"read-only from every host" note), so these are done from this VM.

- [x] ~~Retire `diff-provisioning.sh`.~~ Done differently than framed — it was
      not retired, because it has live jobs (skills.manifest, the shared-doc
      markers, and the very tools partition below). dotfiles PR #17 instead
      trimmed its dead `dotfiles-manifest.pin` checks and fixed its
      `IV_IMAGE_DIR` default, which still pointed at the pre-rename path and so
      silently skipped every iv-provision-side check.
- [x] ~~Move `claude`/`codex`/`uv` `personal` → `team` in `tools.manifest`.~~
      Done (dotfiles PR #17). Also fixed a latent bug it exposed: the `claude`
      guard in install.sh was not `want claude`, so `--upgrade` on an IV VM
      would have reinstalled the floating copy over the pin. Macos parity holds
      because `want()` skips team tools only on IV VMs. Restoring the drift
      check caught a stale iv-image-vs-iv-provision comment in the shared
      AGENTS.md block, now converged across all three copies.
- [ ] Drop the copy of `entire-push-exclude.txt` that moved to `provisioning/`
      here. **Re-scoped 2026-08-19:** it is _not_ a dead duplicate — the dotfiles
      copy is the live input read by dotfiles' own `entire-push-check`
      (`maint/.local/bin/entire-push-check`, run by the launchd plist). Deduping
      means repointing that checker at a single source first, then dropping the
      copy; it is its own change, not a delete.
- [x] ~~**Copy over the load-bearing rationale** now cross-linked into
      `dotfiles/agent_docs/`.~~ Already present: `vm-disk-weight.md` and
      `exe-dev-remediation.md` both exist in dotfiles `agent_docs/` (verified
      2026-08-19), so the `exeslim/FORK.md` and iv-provision README references
      resolve rather than dangle. Nothing to copy.

## Own the Entire ACR capture path

Done 2026-08-18: the CLI (pinned 0.8.42, checksummed), the
`entire-agent-shelley` plugin (0.1.3), and the vendored
`entire-agent-agentsview` adapter are installed by `provision-iv.sh` and recorded
in the lock file; `entire enable` is deliberately left out as a per-repo
governance action; and `entire-push-exclude.txt`
moved into `provisioning/`. `entire-push-check` itself stays in dotfiles, being
macOS-only and part of the auditing control plane rather than the audited VMs.
What remains:

- [x] ~~Enroll `ave-adapters` in Entire ACR capture.~~ Done: `ff5cc95 chore:
    enable Entire Shelley capture` (2026-08-18) is on `origin/main`, settings
      byte-identical to `fannie-sflpd`/`iv-docs` (git-branch backend, telemetry
      off, external agents on), tracking only `.entire/settings.json` and
      `.entire/.gitignore` so all nine worktrees and future clones inherit it.
      Confirmed 2026-08-19 from `iv-ave-adapters`: `entire status` reports
      **Enabled** on `main` with the Shelley lifecycle hooks registered and
      checkpoints syncing to origin.
- [x] ~~Re-qualify `entire-agent-shelley` against a current Entire CLI.~~ Done
      (release 3.0.15). CLI bumped 0.8.42 → 0.10.1 after re-qualifying plugin
      0.1.3 against it on `iv-entire-agent-shelley` — full live suite incl. real
      checkpoint condensation passed; 0.10.0 passed identically, 0.10.1 pinned
      as the newer stable. Evidence in the plugin repo
      (`QUALIFICATION-v0.1.3-cli0.10.1.md`). Fleet re-provisioned to 3.0.15;
      every VM now runs Entire CLI 0.10.1 with plugin 0.1.3.
- [ ] Evaluate the `refs` checkpoint backend (do **not** flip yet). CLI 0.10.1's
      `entire enable` recommends `--checkpoint-backend refs` (one git ref per
      checkpoint) over the `branch` backend the fleet uses (a shared
      `entire/checkpoints/v1` orphan branch). Bench-measured on
      `iv-entire-agent-shelley` 2026-08-19 against plugin 0.1.3: `refs` produces
      `"type":"git-refs"`, seeds no orphan branch at enable, and the plugin
      captures correctly under it — commit trailer added, transcript captured,
      metadata byte-identical (`full.jsonl`/`metadata.json`/`prompt.txt`/
      `transcript.jsonl`). Storage moves to `refs/entire/checkpoints/<shard>/<id>`,
      **outside** `refs/heads/*`; propagation is the backend-aware `entire hooks
    git pre-push` hook, not a push refspec. So the plugin side is cheap. The
      cost is elsewhere, and is why this is not a flag flip: 1. **Qualify `refs` against 0.1.3** — the live suite
      (`test-shelley-live.sh`) hard-codes `refs/heads/entire/checkpoints/v1`
      in four places (settings, the `--checkpoint-backend` flag, and the
      verification block L204-208), so it currently _cannot_ qualify `refs`;
      it needs a `refs`-aware variant. ~an afternoon. 2. **Qualify `entire-agent-agentsview` attachment under `refs`.** The
      adapter reads the local AgentsView session archive and hands a
      transcript to Entire; it does not read either checkpoint layout.
      Therefore the gate is an end-to-end attach test proving that Entire
      persists the resulting checkpoint under `refs/entire/*`, not an
      AgentsView compatibility claim about Git refs. 3. **Decide existing history** — a switch does not migrate it. `iv-docs`
      already has 16 checkpoint commits on `origin/entire/checkpoints/v1`;
      new checkpoints would go to `refs/entire/*`, stranding the old ones
      unless a dual-read or a one-time migration copies them. Per enrolled
      repo (`iv-docs`, `fannie-sflpd*`, `ave-adapters`, ...). 4. **Flip fleet-wide as one coordinated change** — `settings.json` is
      committed and inherited by all worktrees/clones, so mixing backends
      across enrolled repos fragments how checkpoints are read. All-or-nothing.
      Trigger to actually do it: upstream deprecating `branch`, or hitting the
      push-contention `refs` was built for (we are not — low concurrency per
      repo). Until then `branch` is qualified, fleet-consistent, and carrying
      real history.

## AgentsView

- [ ] Upstream request: throttle re-sync. Every Shelley write to
      `shelley.db-wal` retriggers a full reprojection of all conversations
      (~every 15s while active; 7.1% of one core sustained, 344 MB RSS).
      `serve` exposes no knob — only `--events-coalesce-interval` (SSE) and
      `--no-sync` (all-or-nothing).
- [ ] `usage_events` is empty, so `cost_usd` is null and `agentsview usage` /
      `token-use` report nothing. Determine whether Shelley's usage data can be
      projected, or drop the cost-analytics claim.

## Base image (`kylelundstedt/exeslim`)

- [x] ~~Merge upstream `ryanlewis/exeslim`.~~ Nothing to merge — re-verified
      2026-08-19 against a real `git fetch upstream`, not the stale SHAs the
      prior note carried. `git merge-base --is-ancestor upstream/main main`
      returns true: upstream's head `9e681cc` ("adopt the shared Renovate
      config") is **fully contained** in our `main`, brought in by our merge
      commit `a22636d`. `git log main..upstream/main` is empty. The earlier
      "one housekeeping commit behind" was written before that merge landed.
      Our fork adds eight commits upstream lacks (own GHCR namespace, the
      `exeslim-dev` image, `openssh-client`/`nginx-light`/`libyaml-0-2`, Shelley
      units, `FORK.md`) — all legitimate fork content, none of it upstream-bound.
      The structural point still holds as an _ongoing_ task, not a backlog item:
      the weekly rebuild runs against **our** Dockerfile, so re-fetch upstream
      periodically and merge if it moves — there is simply nothing outstanding
      right now.
- [ ] **Decide a base-image recreate cadence, or accept the drift explicitly.**
      A VM cannot be migrated to a newer image — exe.dev fixes the image at
      creation and offers no swap — so this is a recreate decision, not an
      upgrade one.

      What a stale base actually costs is narrow, and worth stating plainly so
          the decision is not made out of vague unease: CVEs land via
          `iv-apt-upgrade.timer` on every VM daily, so a stale base does **not** mean
          unpatched packages. What it misses is *newly added* packages (e.g.
          `nginx-light`, `openssh-client`) and image-level changes to the boot path.

          Fleet state 2026-08-29 -- the pre-exeslim `exeuntu` base is fully retired:

          | Base | Shell | VMs |
          | ---- | ----- | --- |
          | `exeslim-dev` `2026-08-19.13.1` | bash | `iv-cli`, `fannie-sflpd-poc` |
          | `exeslim-dev` `2026-08-18.11.1` | bash | `iv-provision`, `kgl-songs`, `telnyx-vm`, `kgl-thoughts` |
          | `exeslim-dev` `2026-07-29.6.1` | zsh | `iv-docs`, `iv-ave-adapters`, `iv-gitlake`, `iv-gitlake-examples`, `iv-home`, `iv-entire-agent-shelley`, `iv-foundry-stage2` |

          Done 2026-08-19/20: `kgl-apex` dropped (only ever used to open a PR);
          `kgl-songs`, `telnyx-vm`, and `kgl-thoughts` recreated onto `exeslim-dev`.
          **No exeuntu-base VMs remain.**

          **Every VM above predates the `.bashrc` PATH fix** (exeslim#6, first in
          `2026-08-28.24.1`). On the bash-shell rows the `~/.local/bin` export is
          below skel's non-interactive guard, so `ssh <vm> '<cmd>'` gets no user
          PATH -- `provision-docsite` failed exactly that way on `iv-cli` and
          `fannie-sflpd-poc` (2026-08-29). The zsh rows are accidentally immune
          (`.zshenv` is read on every invocation), which is why the bug survived so
          long. `iv-cli`, `kgl-songs` and `fannie-sflpd-poc` carry a hand-applied
          fix (backup at `~/.bashrc.pre-pathfix`); it survives re-provisioning but
          NOT recreation. Recreating onto `2026-08-28.24.1`+ is the durable fix and
          makes the hand patches unnecessary.

          3.0.20 also pins the interpreter of the installed doc-site tools, so those
          no longer depend on the user PATH at all -- the two fixes are independent
          and both wanted (systemd, cron and `sudo` secure_path have no
          `~/.local/bin` regardless of the image).

### Base recreate playbook (from the kgl-songs / telnyx-vm / kgl-thoughts migrations)

exe.dev fixes the image at creation with no swap, and `cp` copies the image too,
so a base change is **delete + `new --image=<target>` + restore**, reusing the
**same VM name** to preserve the `<name>.exe.xyz` origin (iPad IndexedDB state,
Telnyx webhook URL, blog DNS all key off it). What bit us, in order of surprise:

- **`vm:` integration attachments do NOT survive a recreate.** All three of
  telnyx-vm's integrations (`repo-telnyx-vm-rw`, `svc-telnyx-test`,
  `bucket-telnyx-vm`) came back detached; only the `tailnet` _tag_ survived,
  because `--tag=tailnet` was passed at `new`. **Prefer a durable tag over `vm:`
  for anything a recreate must keep** (as `kgl-songs` already does via
  `tag:kylelundstedt-songs`). Re-attach `vm:` integrations by hand after `new`.
- **The `<name>-1` tailnet collision is now the norm on recreate.** The narrowed
  credential (`auth_keys`, no `devices:core`) cannot delete the stale node, so
  the new VM joins as `<name>-1` and provisioning prints the warning added in
  3.0.14. Fix in the Tailscale admin console: delete the old node, rename
  `<name>-1` -> `<name>`. Cosmetic only — the exe.dev origin is already correct.
- **The exeslim-dev base is deliberately minimal.** telnyx-vm's webhook needed
  `python3`, `python3-venv`, and `ffmpeg` via apt that the old exeuntu base had
  by default. Inventory a VM's real runtime deps before deleting it.
- **Back up untracked state first, and make it durable, not a migration one-off.**
  telnyx-vm held ~2.2 MB of irreplaceable untracked data (voicemail recordings,
  signed LOA PDFs, the secrets env file, Maildir). Now backed up nightly to the
  `bucket-telnyx-vm` Tigris integration via a committed systemd timer
  (`telnyx-webhook` repo `BACKUP.md`), so it survives future recreates too.
- **Verify the pin twice, minutes apart** (socket-activation race, 3.0.1) and
  confirm the base actually changed in `~/iv-provision.lock`. Shelley
  self-updated to 0.971 on the fresh telnyx-vm and provisioning correctly
  re-pinned it to 0.959.
- **Custom domains do NOT survive a recreate either.** kgl-thoughts'
  `lundstedt.us` / `www.lundstedt.us` had to be re-added with `exe.dev domain
add kgl-thoughts <domain>` after `new`; Cloudflare DNS must stay DNS-only
  (grey cloud) pointing at `<name>.exe.xyz`. Same recreate-invalidates-a-held-
  binding class as `vm:` integrations.
- **A recreate silently drops the VM from AgentsView aggregation.** _Resolved in 3.0.23: the collector reconciles its fan-in from the `av-src-*` integration list daily, and a recreated VM keeps its integration._ Re-provision
  mints a _new_ per-host source token, which orphans the token the klundstedt-mini
  aggregator holds in `~/.agentsview/config.toml`; it then polls that host `401
Unauthorized` forever with no alert (telnyx-vm and kgl-thoughts had both gone
  dark this way, and kgl-songs/iv-provision were never in the list at all).
  After a recreate, copy the host's current `~/.config/agentsview/source.env`
  token into the aggregator's config and restart it. Move the token VM->config
  via an stdin pipe, never a shell arg -- it is a live tailnet auth token and
  the transcript is itself an AgentsView source. Fixed 2026-08-20; all 11
  configured hosts now poll clean.
- **A stock nginx image needs two nudges to serve a `~`-rooted site.** The base
  ships an enabled `default` site owning the proxy port, and `$HOME` is `0750`
  (no world-execute) so nginx (www-data) cannot traverse to `~/www` -- every
  path 404s. kgl-thoughts' `install-nginx.sh` now removes the default site and
  does `chmod o+x $HOME`; a `mktemp -d` release also needed world-read perms.

      A site that renders with quarto (only `lundstedt.us`) is the one exeslim
      exception: quarto is not on the base and not in apt, so its repo carries a
      pinned, sha256-verified `scripts/install-quarto.sh` (the `.deb` from
      Posit), and the committed `.render-with-quarto` marker makes
      `remove_legacy_quarto` leave it alone (PR #28, in 3.0.16). Provision such a
      VM at a tag >= 3.0.16 or the guard is absent and quarto's PATH symlink is
      stripped again.

## Other

- [x] ~~`provision-docsite`: separate the rendered build directory from the
      nginx docroot so a preview render cannot modify the live site.~~ Done: it
      renders to the build tree (`_site`, which `render-md-site` wipes with
      `shutil.rmtree` each run) and only on a successful render publishes to a
      timestamped release under `<repo>/.docsite/releases/`, flipping an atomic
      `current` symlink that nginx's docroot follows. A failed or in-flight
      render never touches the live site; the prune keeps the last 3 releases
      and refuses to delete the one `current` points at. Verified end-to-end on
      the authoring host (200 across a re-render; a no-`index.html` render keeps
      the previous release live).
- [x] ~~The pre-exeslim `exeuntu` VMs carried duplicate agent binaries in
      `/usr/local/bin` (`claude`, `codex`, `uv`), shadowed by the `~/.local/bin`
      copies that win PATH.~~ Resolved 2026-08-20: all three (`kgl-songs`,
      `telnyx-vm`, `kgl-thoughts`) shed them by recreating onto exeslim-dev,
      which ships none of them in `/usr/local/bin`. No exeuntu VMs remain.
- [x] ~~`iv-entire-agent-shelley` unreachable over the tailnet.~~ Resolved
      2026-08-19: `tag:dev` added to the node in the Tailscale console, alongside
      its existing `tag:iv-aperture-pilot`. The VM was never off the tailnet —
      `tailscale ping` answered in 3 ms throughout — it was the SSH policy
      dropping TCP/22, since that rule is keyed on `tag:dev`. Upgraded to 3.0.9
      the same day; it was the last VM on 2.9.0. Whole fleet is now on one tag.

## Authoring and access

- [x] ~~**Create the `tailnet` exe.dev tag and attach `api-tailscale` to it.**~~
      Done 2026-08-19: owner created the `tailnet` tag, attached `api-tailscale`
      to it, and tagged all 11 VMs. Verified from tagged VMs that the token
      mints (`api-tailscale=YES` fleet-wide). The credential was subsequently
      narrowed to `auth_keys` on `tag:dev` (see "Narrow the tailnet credential"
      below, and `tailnet.md`). Rationale kept for the record:

      Decided 2026-08-19: a **dedicated** tag rather than reusing `tag:iv`.
          `iv` already means "gets the MCP integrations"; adding key-minting to it
          would make one tag mean two unrelated things, the second far stronger —
          the same widening `auto:all` was rejected for, but disguised as reuse.
          `auto:all` stays rejected outright: it would cover every future VM,
          including sandboxes running untrusted code.

          Why it is worth doing: a recreated VM currently cannot rejoin unattended,
          and cannot be fixed from another VM — it is not on the tailnet yet, and
          `*.exe.xyz` needs an exe.dev SSH key no VM holds, so the bootstrap is
          breakable only from a workstation.

          Note `tailnet` is an **exe.dev** tag, unrelated to Tailscale's `tag:dev`.
          Tailscale's side needs no fleet decision — `provision-iv.sh` hardcodes
          `"tags":["tag:dev"]` into every join key, so any VM this repo joins is
          tagged by construction; only a node joined by some other path can miss it,
          as `iv-entire-agent-shelley` did.

- [ ] Consolidate `tag:iv` and `mcp-agent`, which overlap — both effectively
      mean "an IV fleet VM that gets the MCP integrations", and the fleet is
      split across them (`iv-provision` has `iv`; most others have `mcp-agent`).
      Deliberately _not_ bundled with the `tailnet` tag work above: pairing a
      rename-and-retag with a security-relevant grant is how one of the two ends
      up unreviewed.
- [x] ~~Narrow the tailnet credential.~~ Done 2026-08-19: `auth_keys` on
      `tag:dev` only, `devices:core` dropped, old client revoked. Verified after
      the swap — join path mints preauthorized `tag:dev` keys (200), everything
      else 403. A broker proved unnecessary; Tailscale's scopes covered it. What
      a broker would still add is a _per-VM_ bound, which the scope model cannot
      express since every tagged VM shares one credential — revisit only if that
      specific property is wanted.
- [ ] Establish that control-plane facts are checked **off-VM**. Three
      consecutive corrections to `tailnet.md`'s tag section were the same
      mistake: reasoning about exe.dev attachment from inside a VM.
      `reflection.int.exe.xyz` reports a VM's own tags and its own integrations,
      never the attachment _rules_, so from a VM there is no way to tell whether
      an integration arrived by `vm:`, `tag:`, or `auto:all` — effects are
      visible, rules are not. `ssh exe.dev integrations` is the authority.

      **The gap is closable, and "a VM cannot reach the control plane" was too
          strong a claim.** What a VM lacks is an *SSH key* in the exe.dev account —
          but exe.dev also exposes the same CLI over HTTPS at `POST https://exe.dev/exec`,
          authenticated by a bearer token, and that endpoint is reachable from here
          (it answers 401, not a connection failure). A scoped, expiring token would
          let the authoring host verify attachment rules for itself instead of
          routing every such question through the owner.

          **It is one command, run from a workstation** (`--cmds` is the allow-list,
          `--label` creates a separately revocable SSH key behind the token):

          ```bash
          ssh exe.dev ssh-key generate-api-key \
            --label=iv-provision-ro --cmds=integrations,ls,tags --exp=30d
          ```

          Then, on this VM, with the token in a `0600` file outside the repo:

          ```bash
          curl -X POST https://exe.dev/exec \
            -H "Authorization: Bearer $(cat ~/.config/exe/api-token)" -d 'integrations'
          ```

          Three properties make this a bounded grant rather than an open one.
          `cmds` is an allow-list of *command names*, and subcommands must be listed
          explicitly — granting `integrations` does not grant `integrations attach`,
          so the token literally cannot attach, detach, create or delete. `exp`
          bounds replay. And `--label` mints a dedicated SSH key, so revoking is
          removing that one key, with normal SSH access unaffected.

          Still a real credential on a VM, which is exactly what the integration
          model exists to avoid — so it is the owner's call, not an assumption. The
          argument for it is that three documentation errors in one evening all came
          from *inferring* control-plane state that a one-line query would have
          settled.

          Until then, any claim in these docs about *how* something is attached needs
          an owner-side check before it is written down.

- [ ] Re-attaching `repo-iv-provision-rw` to a second VM should be an event, not
      a state. On 2026-08-19 it was attached to `iv-foundry-stage2` as an
      expedient, a dozen commits were pushed from there, and it was detached the
      same day. The README's "Authoring boundary" section now documents the
      single-writer rule and what to do when an exception is genuinely needed;
      there is no mechanical enforcement beyond the attachment itself, so this
      stays a thing to notice rather than a thing that is guaranteed.
- [ ] `api-tailscale` is currently attached to nothing, which is the intended
      steady state (attach → join → detach). Note that a _joined_ VM stays joined
      after detachment — verified on `iv-provision` 2026-08-19, which has been
      routing all fleet SSH with the integration detached. Nothing to do; recorded
      so the next person does not "fix" the absence.
