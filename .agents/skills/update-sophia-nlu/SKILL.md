---
name: update-sophia-nlu
description: Update the pinned Sophia NLU engine and its Home Assistant integration in this flake to the newest upstream release. Use when asked to update, check, or bump Sophia NLU, or when its CHANGELOG mentions a fix that's wanted.
---

# Update Sophia NLU

Sophia NLU is a commercial, closed-source conversation agent for Home
Assistant. This flake pins two pieces, both in
[`pkgs/sources.json`](../../../pkgs/sources.json):

- **engine**: the static `sophia-amd64` binary from the private HA OS add-on
  repo `git.cicero.sh/aquila/sophia-ha-app`, pinned by commit (default branch
  HEAD) with its version from `sophia_nlu/config.yaml`. It's fetched at eval
  time with credentials from nix.conf's `netrc-file`, which must hold the
  user's Sophia download token (see the README).
- **integration**: `cicero-ai/sophia-ha-integration` on GitHub, pinned by tag.
  It is versioned separately from the engine.

## Workflow

Run from the repository root.

1. Check versions (prints the new CHANGELOG entries for the engine):

   ```sh
   .agents/skills/update-sophia-nlu/scripts/update.py --check
   ```

2. If either is newer, update the pins:

   ```sh
   .agents/skills/update-sophia-nlu/scripts/update.py
   ```

   The script prefetches the new binary with `nix store prefetch-file` and the
   integration with `nix flake prefetch`, then rewrites `sources.json`.

3. Build both packages and the module check:

   ```sh
   nix build .#sophia-nlu .#sophia-nlu-integration --no-link
   nix build .#checks.x86_64-linux.module --no-link
   ```

   The integration's `postPatch` uses `--replace-fail`, and the module check
   applies the optional vacuum patch, so an upstream change to those lines
   fails here. Fix the replacement strings or refresh
   `pkgs/patches/vacuum-cleaning-mode.patch` against the new tag.

4. Commit `pkgs/sources.json` (and any patch fixes) with the new versions in
   the message. Don't deploy anything: users bump this flake input in their
   own configuration. A new integration version needs a Home Assistant
   restart, which a NixOS switch does.

## Notes

- A 404 from git.cicero.sh means the request had no credentials: the netrc
  is missing, has no `git.cicero.sh` entry, or the token was revoked. The
  plain `/raw/` web paths always 404 for this repo; only the `api/v1/.../raw/`
  endpoint accepts the token.
- `--netrc <file>` overrides the netrc path.
- After an engine update, re-check the admin panel routes the `sophia-api`
  skill relies on.
- The EULA forbids reverse engineering the binary; don't disassemble it.
