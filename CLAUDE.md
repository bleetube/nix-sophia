# CLAUDE.md

A Nix flake that packages the Sophia NLU engine and its Home Assistant
integration and runs them with a NixOS module. [README.md](README.md) covers
usage and first-time setup.

## Layout

- `pkgs/sophia-nlu.nix`: the engine, a closed-source static binary fetched
  with `builtins.fetchurl` so the evaluating client sends netrc credentials.
- `pkgs/sophia-nlu-integration.nix`: the `sophia_nlu` custom component.
  `postPatch` raises the response timeout, adds `import re`, and shortens
  `host.domain:port` in spoken replies. `patches/vacuum-cleaning-mode.patch`
  is applied only when `vacuumModeScript` is set; it relies on that
  `import re`.
- `pkgs/sources.json`: version pins for both (`engine`, `integration`).
- `modules/sophia-nlu.nix`: `services.sophia-nlu`. The module builds both
  packages from the user's `pkgs`, building the integration against
  `services.home-assistant.package`.
- `.agents/skills/`: agent skills (`sophia-api`, `update-sophia-nlu`), linked
  from `.claude/skills/`.

## Working here

- Validate with:
  ```sh
  nix build .#sophia-nlu .#sophia-nlu-integration --no-link
  nix build .#checks.x86_64-linux.module --no-link
  ```
  Evaluating the engine needs a Sophia download token in nix.conf's
  `netrc-file`, unless the binary is already in the store. Without one, you
  can still check the integration and the module's options, but not the
  engine.
- Bump versions with the `update-sophia-nlu` skill, not by hand.
- Keep this repository generic. Use documentation-range addresses
  (`192.0.2.0/24`) and `example.lan` names in examples, and never commit
  tokens, hostnames, or deployment details.
- Sophia's EULA forbids reverse engineering the engine binary; don't
  disassemble it. The panel routes in the `sophia-api` skill come from its
  rendered HTML.
- Scripts use only Python 3's standard library and run with `python3 -I`.
- Format Nix with `nix fmt`.
