{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.sophia-nlu;
  hass = config.services.home-assistant;
  inherit (lib)
    mkEnableOption
    mkOption
    mkIf
    types
    ;

  # The engine is static and does its own DNS, sending queries straight to
  # resolv.conf's servers instead of through nscd. With the network locked
  # down those are unreachable, but it does read /etc/hosts, so hosts it must
  # reach by name are pinned in a private copy.
  hostsFile = pkgs.writeText "sophia-nlu-hosts" (
    ''
      127.0.0.1 localhost
      ::1 localhost
    ''
    + lib.concatStrings (
      lib.mapAttrsToList (ip: names: "${ip} ${lib.concatStringsSep " " names}\n") cfg.network.hosts
    )
  );
in
{
  options.services.sophia-nlu = {
    enable = mkEnableOption "the Sophia NLU engine, a conversation agent for Home Assistant";

    package = mkOption {
      type = types.package;
      default = pkgs.callPackage ../pkgs/sophia-nlu.nix { };
      defaultText = lib.literalExpression "pkgs.callPackage ./pkgs/sophia-nlu.nix { }";
      description = "The Sophia NLU engine package.";
    };

    port = mkOption {
      type = types.port;
      default = 10520;
      description = ''
        Port of the engine's TCP endpoint for the integration and its web
        admin panel. Set the panel's bind host to 127.0.0.1 after first setup.
      '';
    };

    configDir = mkOption {
      type = types.path;
      default = hass.configDir;
      defaultText = lib.literalExpression "config.services.home-assistant.configDir";
      description = ''
        Home Assistant's config directory. It's mounted read-only at /config,
        where the engine reads the registries and YAML, as in the HA OS add-on.
      '';
    };

    user = mkOption {
      type = types.str;
      default = "hass";
      description = ''
        User the engine runs as. It must be able to read {option}`configDir`;
        Home Assistant's UMask leaves that readable only by hass.
      '';
    };

    group = mkOption {
      type = types.str;
      default = "hass";
      description = "Group the engine runs as.";
    };

    extraArgs = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Extra command-line arguments for the engine.";
    };

    network = {
      allowInternet = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether the engine may reach any host. It needs the internet only to
          activate its license and to upload misinterpretations. Enable it for
          activation, then turn it back off. When off, the engine can reach
          only localhost and {option}`network.allowedAddresses`, and the
          only names it resolves are those in {option}`network.hosts`.
        '';
      };

      allowedAddresses = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "192.0.2.10" ];
        description = ''
          Addresses or prefixes, besides localhost, that the engine may reach
          while {option}`network.allowInternet` is off, such as an LLM server
          for its fallback (systemd's IPAddressAllow).
        '';
      };

      hosts = mkOption {
        type = types.attrsOf (types.listOf types.str);
        default = { };
        example = {
          "192.0.2.10" = [ "llm.example.lan" ];
        };
        description = ''
          /etc/hosts entries the engine sees while
          {option}`network.allowInternet` is off. Name each host it must reach
          by name, such as the LLM fallback's.
        '';
      };
    };

    integration = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether to add the sophia_nlu integration to
          {option}`services.home-assistant.customComponents`.
        '';
      };

      responseTimeout = mkOption {
        type = types.ints.positive;
        default = 35;
        description = ''
          Seconds the integration waits for the engine to answer a sentence,
          LLM fallback included. Upstream's 10 can be too short when the LLM
          server has to load a model; the engine's own LLM limit is 30.
        '';
      };

      vacuumModeScript = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "set_cleaning_mode";
        description = ''
          A Home Assistant script (name without `script.`) taking a `mode`
          field of `vacuum`, `mop`, or `vacuum_then_mop`. When set, the
          integration calls it before a vacuum intent, with the mode read from
          the sentence's verb: "vacuum" is vacuum, "mop" is mop, and "clean"
          or anything else is vacuum then mop.
        '';
      };

      package = mkOption {
        type = types.package;
        default = pkgs.callPackage ../pkgs/sophia-nlu-integration.nix {
          # Build against the Python of the Home Assistant actually deployed.
          buildHomeAssistantComponent = pkgs.buildHomeAssistantComponent.override {
            home-assistant = hass.package;
          };
          inherit (cfg.integration) responseTimeout vacuumModeScript;
        };
        defaultText = lib.literalMD "built for {option}`services.home-assistant.package`";
        description = "The sophia_nlu Home Assistant integration package.";
      };
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.integration.enable -> hass.enable;
        message = "services.sophia-nlu.integration needs services.home-assistant.enable, or set integration.enable = false.";
      }
    ];

    warnings = lib.optional cfg.network.allowInternet "services.sophia-nlu.network.allowInternet is on. Turn it off once the license is activated.";

    services.home-assistant.customComponents = mkIf cfg.integration.enable [ cfg.integration.package ];

    systemd.services.sophia-nlu = {
      description = "Sophia NLU engine";
      after = [
        "network.target"
        "home-assistant.service"
      ];
      wantedBy = [ "multi-user.target" ];
      environment = {
        # License, settings, tags, and vocabulary go to $XDG_DATA_HOME/sophia,
        # kept out of Home Assistant's home.
        HOME = "/var/lib/sophia-nlu";
        XDG_DATA_HOME = "/var/lib/sophia-nlu";
      };
      serviceConfig = {
        ExecStart = lib.escapeShellArgs (
          [
            (lib.getExe cfg.package)
            "-d"
            "--port"
            (toString cfg.port)
          ]
          ++ cfg.extraArgs
        );
        User = cfg.user;
        Group = cfg.group;
        # The engine writes into $XDG_DATA_HOME/sophia without creating it
        # first, and license activation fails with ENOENT otherwise.
        StateDirectory = [
          "sophia-nlu"
          "sophia-nlu/sophia"
        ];
        WorkingDirectory = "/var/lib/sophia-nlu";
        BindReadOnlyPaths = [
          "${cfg.configDir}:/config"
        ]
        ++ lib.optional (!cfg.network.allowInternet) "${hostsFile}:/etc/hosts";
        # It handles no SIGHUP, so a HUP kills it, and on-failure would treat
        # that as a clean exit.
        Restart = "always";
        RestartSec = 5;
      }
      // lib.optionalAttrs (!cfg.network.allowInternet) {
        IPAddressDeny = "any";
        IPAddressAllow = [ "localhost" ] ++ cfg.network.allowedAddresses;
      };
    };
  };
}
