{
  lib,
  buildHomeAssistantComponent,
  fetchFromGitHub,
  # Seconds the integration waits for the engine's whole turn. Upstream waits
  # 10, which an LLM fallback can exceed when the model server has to load a
  # model (the engine's own LLM limit is 30 s).
  responseTimeout ? 35,
  # Name of a Home Assistant script (without `script.`) taking a `mode` field
  # of vacuum, mop, or vacuum_then_mop. When set, vacuum intents call it
  # first with the mode read from the sentence's verb. null leaves it out.
  vacuumModeScript ? null,
}:

# Home Assistant conversation agent that sends sentences to the Sophia NLU
# engine over TCP and runs the intents it returns. Replaces the HACS install.
# Versioned separately from the engine; pinned in sources.json.
let
  source = (lib.importJSON ./sources.json).integration;
  conversation = "custom_components/sophia_nlu/conversation.py";
in
buildHomeAssistantComponent {
  owner = "cicero-ai";
  domain = "sophia_nlu";
  inherit (source) version;

  src = fetchFromGitHub {
    owner = "cicero-ai";
    repo = "sophia-ha-integration";
    tag = source.version;
    inherit (source) hash;
  };

  # Sophia gives "vacuum the kitchen", "mop the kitchen", and "clean the
  # kitchen" the same intent, and HA's vacuum intents can't carry a mode, so
  # the patch reads the verb: "vacuum" is vacuum only, "mop" is mop only,
  # "clean" or anything else is vacuum then mop.
  patches = lib.optional (vacuumModeScript != null) ./patches/vacuum-cleaning-mode.patch;

  # The engine's own errors come back as the spoken reply, URL and all
  # ("Unable to connect to server at llm.example.lan:8080"), so a
  # host.domain:port in a reply is cut down to the bare host name.
  postPatch = ''
    substituteInPlace ${conversation} \
      --replace-fail "import logging" $'import logging\nimport re' \
      --replace-fail "reader.read(65536), timeout=10.0" "reader.read(65536), timeout=${toString responseTimeout}.0" \
      --replace-fail 'respond_text = results[0].get("data", {}).get("text", "").strip()' \
        'respond_text = re.sub(r"\b([A-Za-z][\w-]*)(?:\.[\w-]+)+:\d+\b", r"\1", results[0].get("data", {}).get("text", "").strip())'
  ''
  + lib.optionalString (vacuumModeScript != null) ''
    substituteInPlace ${conversation} \
      --replace-fail '"script", "set_cleaning_mode"' '"script", "${vacuumModeScript}"'
  '';

  meta = {
    description = "Home Assistant integration for the Sophia NLU engine";
    homepage = "https://github.com/cicero-ai/sophia-ha-integration";
    license = lib.licenses.unfree;
  };
}
