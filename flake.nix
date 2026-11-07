{
  description = "Sophia NLU, a Home Assistant conversation agent, packaged for NixOS";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux"; # the only platform upstream ships a binary for
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfreePredicate = self.lib.isUnfreeSophia;
      };
    in
    {
      lib = {
        # Names for nixpkgs.config.allowUnfreePredicate. Both pieces are
        # under Sophia's commercial EULA.
        unfreePackageNames = [
          "sophia-nlu"
          "cicero-ai/sophia_nlu"
        ];
        isUnfreeSophia = pkg: builtins.elem (nixpkgs.lib.getName pkg) self.lib.unfreePackageNames;
      };

      packages.${system} = {
        sophia-nlu = pkgs.callPackage ./pkgs/sophia-nlu.nix { };
        sophia-nlu-integration = pkgs.callPackage ./pkgs/sophia-nlu-integration.nix { };
        default = self.packages.${system}.sophia-nlu;
      };

      overlays.default = final: prev: {
        sophia-nlu = final.callPackage ./pkgs/sophia-nlu.nix { };
        sophia-nlu-integration = final.callPackage ./pkgs/sophia-nlu-integration.nix { };
      };

      nixosModules.default = import ./modules/sophia-nlu.nix;
      nixosModules.sophia-nlu = self.nixosModules.default;

      # Evaluates (and with `nix flake check`, builds) a minimal host with the
      # module enabled. The engine fetch needs the download token in netrc.
      checks.${system}.module =
        (nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            self.nixosModules.default
            {
              nixpkgs.config.allowUnfreePredicate = self.lib.isUnfreeSophia;
              boot.loader.grub.enable = false;
              fileSystems."/" = {
                device = "none";
                fsType = "tmpfs";
              };
              system.stateVersion = "25.11";
              services.home-assistant.enable = true;
              services.sophia-nlu = {
                enable = true;
                integration.vacuumModeScript = "set_cleaning_mode";
                network.allowedAddresses = [ "192.0.2.10" ];
                network.hosts."192.0.2.10" = [ "llm.example.lan" ];
              };
            }
          ];
        }).config.system.build.toplevel;

      formatter.${system} = pkgs.nixfmt-tree;
    };
}
