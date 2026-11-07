# nix-sophia

[Sophia NLU](https://nlu.to/ha/) for Home Assistant on NixOS, without Home
Assistant OS, its add-on, or HACS.

Sophia is a commercial, deterministic natural-language engine that replaces
Home Assistant's built-in intent matching in an Assist pipeline. Upstream
ships it as a Home Assistant OS add-on (the engine, a static binary) plus a
HACS integration (the conversation agent). This flake packages both and wires
them together with a NixOS module:

- **`sophia-nlu`**: the engine, pinned by commit and hash and fetched with
  your download token.
- **`sophia-nlu-integration`**: the `sophia_nlu` custom component, built
  against the Python of your `services.home-assistant.package`. It's
  installed through `services.home-assistant.customComponents`.
- **`services.sophia-nlu`**: a hardened systemd unit that runs the engine the
  way the add-on does. It runs as `hass`, with Home Assistant's config
  directory mounted read-only at `/config`, and keeps its state in
  `/var/lib/sophia-nlu`. Its network is **locked down by default**: the
  engine can reach only localhost and the addresses you allow, such as an
  LLM server for its fallback.

The engine never gets a Home Assistant token. The integration sends it each
sentence over TCP on localhost, and Home Assistant runs the intents it
returns.

> This project is not affiliated with Sophia NLU or its authors. Sophia NLU
> and its integration are proprietary software under their own EULA. You need
> your own license and download token. This repository contains only Nix
> expressions and helper scripts, and redistributes nothing.

## Requirements

- An `x86_64-linux` NixOS host running `services.home-assistant` (upstream
  only ships an amd64 binary).
- A Sophia NLU license and its **download token**. It's the token the HA OS
  add-on repository uses, from your account at <https://nlu.to/>.
- Unfree packages allowed for `sophia-nlu` and `cicero-ai/sophia_nlu`.

## Quick start

### 1. Give nix your download token

The engine lives in a private repository on `git.cicero.sh`. Nix's
daemon-side fetchers don't send credentials, so the package uses
`builtins.fetchurl`. It runs in the evaluating `nix` client and uses
nix.conf's `netrc-file`. On the machine that evaluates your configuration,
create a netrc with your token:

```
machine git.cicero.sh
login hadown
password <your download token>
```

and point nix at it:

```nix
nix.settings.netrc-file = "/path/to/netrc";
```

The file must be readable by whoever runs `nix build` or `nixos-rebuild`
(the client reads it, not only the daemon). Render it from a secret manager
such as sops-nix or agenix rather than committing the token. Only machines
that evaluate the configuration need it; the target host just receives the
built closure.

If you already have the `sophia-amd64` binary, you can skip the token. The
store path depends only on the name and hash, so add it by hand and the fetch
is never attempted:

```sh
nix store add --mode flat --name sophia-amd64-2.3.5 ./sophia-amd64
```

### 2. Add the flake

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix-sophia = {
      url = "github:bleetube/nix-sophia";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, nix-sophia, ... }: {
    nixosConfigurations.homeserver = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        nix-sophia.nixosModules.default
        {
          nixpkgs.config.allowUnfreePredicate = nix-sophia.lib.isUnfreeSophia;

          services.home-assistant.enable = true;
          services.sophia-nlu.enable = true;
        }
      ];
    };
  };
}
```

If you already have an `allowUnfreePredicate`, add the names in
`nix-sophia.lib.unfreePackageNames` to it.

The module builds the packages from your own `pkgs`, so the integration
matches your Home Assistant's Python. `nixpkgs.follows` only saves a
download.

### 3. First-time setup

The license, admin login, settings, tags, and custom sentences are engine
state in `/var/lib/sophia-nlu/sophia/`, set up once through its web UI:

1. Deploy with `services.sophia-nlu.network.allowInternet = true`, which
   activation needs. Until you set its bind host, the engine listens on the
   host's LAN address, and the NixOS firewall keeps the port closed. Tunnel to
   it, for example with `ssh -L 10520:<host LAN IP>:10520 <host>`, and open
   `http://127.0.0.1:10520/`.
2. Activate the license. Either use *Activate License*, which logs in at
   nlu.to, or do it offline: paste the page's *License Key* at
   <https://nlu.to/members/activate>, then paste the signed key back into the
   page. Then create the admin account it asks for.
3. Under *Settings*, leave the Home Assistant config directory as `/config`
   and set the bind host to `127.0.0.1`.
4. Set `allowInternet = false` (the default) and deploy again. Check the
   lockdown with
   `systemctl show sophia-nlu -p IPAddressDeny -p IPAddressAllow`.
5. In Home Assistant, go to *Settings → Devices & services → Add integration
   → Sophia NLU*. Replace the pre-filled LAN address with host `127.0.0.1`,
   port `10520`.
6. In *Settings → Voice assistants*, add an assistant with *Sophia NLU* as its
   conversation agent, plus your speech-to-text and text-to-speech engines.
   Make it the preferred assistant if you like, and keep the stock one as a
   fallback.

Sophia only sees entities exposed to Assist (*Settings → Voice assistants →
Expose*). It re-reads Home Assistant's config every 5 seconds and logs how
many areas and entities it loaded (`journalctl -u sophia-nlu`).

### Reaching the admin panel later

After step 3 the panel listens only on localhost. To reach it from elsewhere,
put a reverse proxy in front of it and restrict who can connect. The panel
has its own login but no CSRF protection. With Caddy:

```nix
services.caddy.virtualHosts."sophia.example.lan:4443".extraConfig = ''
  @allowed remote_ip 192.0.2.0/24
  handle @allowed {
    reverse_proxy http://127.0.0.1:10520
  }
  handle {
    respond "Forbidden" 403
  }
'';
```

## Options

| Option | Default | |
|---|---|---|
| `enable` | `false` | Run the engine. |
| `package` | built from your `pkgs` | The engine. |
| `port` | `10520` | The engine's port for the integration and its admin panel. |
| `configDir` | `services.home-assistant.configDir` | Mounted read-only at `/config`. |
| `user`, `group` | `"hass"` | Must be able to read `configDir`. |
| `extraArgs` | `[ ]` | Extra engine arguments. |
| `network.allowInternet` | `false` | Lift the network lockdown (for license activation and misinterpretation uploads). |
| `network.allowedAddresses` | `[ ]` | Addresses besides localhost the engine may reach, such as an LLM server. |
| `network.hosts` | `{ }` | `/etc/hosts` entries the engine sees, as `{ "192.0.2.10" = [ "llm.example.lan" ]; }`. |
| `integration.enable` | `true` | Install the integration into Home Assistant. |
| `integration.responseTimeout` | `35` | Seconds the integration waits for a reply (upstream: 10). |
| `integration.vacuumModeScript` | `null` | See [vacuum modes](#vacuum-modes). |
| `integration.package` | built for your HA | The integration. |

All options are under `services.sophia-nlu`.

## LLM fallback

Sophia can send sentences it can't place to an OpenAI-compatible LLM (set in
its *Settings* page). With the lockdown on, allow that server explicitly. The
engine is statically linked and does its own DNS, querying `resolv.conf`'s
servers directly rather than through nscd, so the lockdown blocks name
resolution too. Pin the server's name instead:

```nix
services.sophia-nlu.network = {
  allowedAddresses = [ "192.0.2.10" ];
  hosts."192.0.2.10" = [ "llm.example.lan" ];
};
```

Upstream's integration waits only 10 seconds for an answer. A fallback that
has to load a model can take longer, so this flake raises the timeout to 35
seconds, just past the engine's own 30-second LLM limit
(`integration.responseTimeout`). The integration also shortens any
`host.domain:port` in a spoken reply to the bare host name, so an engine
error like "Unable to connect to server at llm.example.lan:8080" isn't read
aloud character by character.

## Vacuum modes

Sophia returns the same intent for "vacuum the kitchen", "mop the kitchen",
and "clean the kitchen". Home Assistant's vacuum intents can't carry a mode.
With `integration.vacuumModeScript` set, the integration reads the verb and
calls your script with `mode` before starting the clean. "vacuum" gives
`vacuum`, "mop" gives `mop`, and "clean" or anything else (or both verbs)
gives `vacuum_then_mop`. This works for a robot with a mode select entity,
such as [Valetudo](https://valetudo.cloud/)'s:

```nix
services.sophia-nlu.integration.vacuumModeScript = "set_cleaning_mode";

services.home-assistant.config.script.set_cleaning_mode = {
  alias = "Set cleaning mode";
  mode = "queued";
  fields.mode = {
    required = true;
    selector.select.options = [ "vacuum" "mop" "vacuum_then_mop" ];
  };
  sequence = [
    {
      action = "select.select_option";
      target.entity_id = "select.robot_mode";
      data.option = "{{ mode }}";
    }
    # So a clean started right after uses the new mode.
    {
      wait_template = "{{ is_state('select.robot_mode', mode) }}";
      timeout = 10;
    }
  ];
};
```

Don't expose the script to Assist.

## Tips

- **Tags beat aliases.** Sophia scores every exposed entity by its friendly
  name, entity ID, area, and the tags you set on its *Entities* page. It
  sometimes ignores aliases. Tag each device with words people say for it
  that its name doesn't contain. Friendly names are read aloud in answers,
  so make them speakable ("Indoor Temperature", not "Ecobee My ecobee
  Current Temperature").
- **Avoid names that collide with Sophia's vocabulary.** For example,
  "home" reads as presence, so "Home Temperature" breaks temperature
  questions.
- **Back up the engine state.** Tags, settings, and custom sentences live
  only in `/var/lib/sophia-nlu/sophia/`. The `tags-dat` script below
  converts the tags file to JSON.
- **Don't test with commands.** A sentence the engine can't place goes to
  the LLM fallback, which can act on it. Test with questions, or with
  sentences you know match.
- **SIGHUP kills the engine.** It doesn't handle the signal. The unit uses
  `Restart=always`, and the integration reconnects by itself.

## Agent skills

`.agents/skills/` (linked from `.claude/skills/`) holds two skills for
coding agents such as Claude Code and Codex:

- **sophia-api**: reads and manages the admin panel from the command line.
  The panel has no JSON API, so
  [`scripts/sophia-api`](.agents/skills/sophia-api/scripts/sophia-api) logs in
  and parses its HTML. It lists loaded entities and their tags, sets tags,
  and reads settings, the activity log, and the license. Point it at your
  panel with `SOPHIA_URL` and a directory of `username`/`password` files in
  `SOPHIA_CREDENTIALS`. The skill also documents the panel's routes and the
  `tags.dat` format
  ([`scripts/tags-dat`](.agents/skills/sophia-api/scripts/tags-dat)).
- **update-sophia-nlu**: bumps the pins in
  [`pkgs/sources.json`](pkgs/sources.json).
  [`scripts/update.py`](.agents/skills/update-sophia-nlu/scripts/update.py)
  finds the add-on repository's newest commit and the integration's newest
  tag, prints the engine's new changelog entries, and prefetches both hashes.

Both scripts need only Python 3's standard library, and both work without an
agent too.

## Updating

```sh
.agents/skills/update-sophia-nlu/scripts/update.py --check   # report only
.agents/skills/update-sophia-nlu/scripts/update.py           # rewrite pkgs/sources.json
nix build .#sophia-nlu .#sophia-nlu-integration .#checks.x86_64-linux.module --no-link
```

The engine and integration are versioned separately. The script uses the
netrc from nix.conf, or `--netrc <file>`.

## Layout

```
flake.nix                         packages, overlay, module, check
modules/sophia-nlu.nix            services.sophia-nlu
pkgs/sophia-nlu.nix               engine
pkgs/sophia-nlu-integration.nix   Home Assistant integration
pkgs/patches/                     optional integration patches
pkgs/sources.json                 version pins
.agents/skills/                   agent skills and their scripts
```

## License

The Nix expressions, patches, and scripts here are MIT licensed (see
[LICENSE](LICENSE)). Sophia NLU itself is proprietary; see its EULA.
