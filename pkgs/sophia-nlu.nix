{ lib, stdenvNoCC }:

# The Sophia NLU engine: a closed-source, statically linked binary.
#
# Upstream publishes it only in the private Forgejo repo behind its Home
# Assistant OS add-on, which needs your per-customer download token. The
# daemon-side fetchers (pkgs.fetchurl) don't send credentials, so this uses
# builtins.fetchurl, which runs in the evaluating nix client and sends
# credentials from nix.conf's `netrc-file`. See the README for the netrc entry.
#
# Pins live in sources.json; bump them with the update-sophia-nlu skill
# (scripts/update.py).
let
  source = (lib.importJSON ./sources.json).engine;
in
stdenvNoCC.mkDerivation {
  pname = "sophia-nlu";
  inherit (source) version;

  # The store path depends only on this name and the hash, so a binary you
  # downloaded another way can be added with `nix store add --mode flat
  # --name sophia-amd64-<version>` and nothing is fetched.
  src = builtins.fetchurl {
    name = "sophia-amd64-${source.version}";
    url = "https://git.cicero.sh/api/v1/repos/aquila/sophia-ha-app/raw/sophia_nlu/sophia-amd64?ref=${source.rev}";
    sha256 = source.hash;
  };

  dontUnpack = true;
  installPhase = ''
    runHook preInstall
    install -Dm755 $src $out/bin/sophia
    runHook postInstall
  '';

  meta = {
    description = "Deterministic NLU conversation engine for Home Assistant";
    homepage = "https://nlu.to/ha/";
    changelog = "https://git.cicero.sh/aquila/sophia-ha-app/src/commit/${source.rev}/sophia_nlu/CHANGELOG.md";
    license = lib.licenses.unfree;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
    mainProgram = "sophia";
  };
}
