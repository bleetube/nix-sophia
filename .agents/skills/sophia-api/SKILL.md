---
name: sophia-api
description: Read and manage a Sophia NLU engine through its web admin panel. Use for Sophia's entity tags (listing, adding, changing, clearing), which entities it has loaded, its settings, version, license, and activity log ("what did Sophia resolve that sentence to", "tag the lamp with desk").
---

# Sophia NLU admin panel

Sophia NLU is a conversation agent for Home Assistant. This flake runs its
engine as `systemd.services.sophia-nlu` ([module](../../../modules/sophia-nlu.nix)),
and the engine serves an admin panel on its port (10520 by default). Updating
the engine is the `update-sophia-nlu` skill.

## Calling it

The panel has no JSON API and no docs. It's server-rendered HTML (2.3.5) with
form posts behind a `session` cookie, so
[`scripts/sophia-api`](scripts/sophia-api) logs in on every run and parses
the pages. Configure it with:

- `SOPHIA_URL`: the panel, `http://127.0.0.1:10520` by default. If the panel
  is behind a reverse proxy on another host, use that URL.
- `SOPHIA_CREDENTIALS`: a directory holding `username` and `password` files
  with the panel's admin login, `~/.config/sophia-api/` by default. Don't
  print them or read them any other way.

```sh
api=.agents/skills/sophia-api/scripts/sophia-api
$api entities                       # every loaded entity: section, type, name, entity_id, tags
$api entities --tagged              # only those with tags
$api entities --domain light --area living_room --search lamp
$api settings                       # the Settings form; API keys show as "(set)"
$api text about                     # version
$api text license_info
$api text log                       # recent sentences, resolved intent and entity, response
$api text sentences                 # custom sentences
$api html entities/export/download  # Sophia's YAML view of areas and devices (no tags)
```

## Endpoints

These were worked out from the panel's HTML on engine 2.3.5. Re-check them
after an engine update.

| Route | Notes |
|---|---|
| `POST /login` | form `username`, `password`; sets `session` (HttpOnly, SameSite=Strict); 302s to `/login` without one |
| `GET /entities` | table per section (Devices; Scenes, Scripts, and Automations; Persons; Timers) with a `tag_<entity_id>` input per row. Query: `filter=tagged`, `area=<area id>`, `domain=`, `search=` |
| `POST /entities/tags` | form `tag_<entity_id>=<comma-separated tags>`. **Merges**: entities not in the post keep their tags, so post only the ones you change. An empty value clears that entity |
| `POST /entities/tags/delete-all` | clears every tag. Not exposed by the script |
| `GET /entities/export/download` | YAML of floors, areas, and devices sent to support. Has no tags; every `area_id` is empty |
| `GET`/`POST /settings` | one form posting every field together; `mode` is a hidden field with a fixed value |
| `GET`/`POST /sentences` | custom sentences mapped to a custom intent, script, scene, or automation |
| `GET /log`, `/misinterpretations` | activity log; misinterpretation upload (needs internet, which the module denies by default) |
| `GET /about`, `/license_info` | version, license dates |

No route sends a CSRF token.

## Tags

Sophia only scores entities it has loaded, which are the ones exposed to
Assist. For each one, it uses the friendly name, the entity ID, the area, and
these tags. Tags help it choose between candidate devices, so they should be
words people say for the device that its name doesn't already contain. If the
user keeps a record of their tags and why each was chosen, read it first.

To change tags:

1. `$api entities` and find the entity's current tags.
2. `tag` replaces an entity's whole tag string. To add or remove one tag,
   write the full new list:
   ```sh
   $api tag light.living_room_lamp 'lamp, light, living room, couch'
   $api tag todo.shopping_list 'list, groceries' fan.air_purifier ''
   ```
   It refuses entity IDs Sophia hasn't loaded (not exposed to Assist, or a
   typo), posts only the named entities, and prints them as re-read from the
   panel.
3. Tags live only in the engine's state (`/var/lib/sophia-nlu/sophia/tags.dat`),
   not in Nix. Update the user's record of them if they keep one, or suggest
   backing them up with `tags-dat decode` (below).

Only change tags when the user asks. Never use *Delete All Tags*. After a
change, suggest asking the affected questions again and checking
`$api text log` for the entity each one resolved to.

### Fallback: editing `tags.dat`

If the panel breaks (it's undocumented and may change between engine
versions), edit the file on the host instead. This needs root on the
Sophia host, so only do it when the user says so. Tested on 2.3.5:

- The engine reads `tags.dat` only at startup. It keeps tags in memory and
  rewrites the whole file on every panel save. Its 5 s config reload
  doesn't re-read it.
- It handles no SIGHUP, so a HUP kills it. Restart the unit instead; the
  module sets `Restart=always`, and HA's integration reconnects on its own.
- [`scripts/tags-dat`](scripts/tags-dat) converts the file to and from JSON.
  It refuses a file that doesn't decode exactly, which would mean the format
  changed. Encoding drops empty tags, as the engine does.

On the Sophia host, as root:

```sh
d=/var/lib/sophia-nlu/sophia
tags=.agents/skills/sophia-api/scripts/tags-dat
cp $d/tags.dat tags.dat.orig                  # keep a backup
$tags decode < tags.dat.orig > tags.json      # edit tags.json
$tags encode < tags.json > $d/.tags.dat.new
chown hass:hass $d/.tags.dat.new && chmod 644 $d/.tags.dat.new
mv $d/.tags.dat.new $d/tags.dat && systemctl restart sophia-nlu
```

Don't save tags in the panel between reading the file and the restart, or
the engine overwrites the edit with its in-memory copy. Afterwards, check
`$api entities --tagged` (if the panel works) or `journalctl -u sophia-nlu`.

## Other changes

Settings, custom sentences, and the license are UI state in
`/var/lib/sophia-nlu/sophia/`, not Nix. The script only reads them. If the
user asks for a change there, have them make it in the panel, and don't post
`/settings` by hand. That form submits every field at once, including the
LLM API keys, whose inputs render without values. Never log out a browser
session or trigger the misinterpretation upload.

Don't probe the engine with commands to test it. A sentence it can't place
goes to its LLM fallback, which may act on it (start the vacuum, unlock a
door). Questions, and sentences already known to match, are safe.
