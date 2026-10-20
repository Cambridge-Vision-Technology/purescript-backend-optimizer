{
  description = "PureScript backend optimizer";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    purescript-overlay = {
      url = "github:thomashoneyman/purescript-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    mkSpagoDerivation = {
      url = "github:jeslie0/mkSpagoDerivation";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.ps-overlay.follows = "purescript-overlay";
    };
  };

  outputs = { nixpkgs, purescript-overlay, mkSpagoDerivation, ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      perSystem = forAllSystems (system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [
              (_final: prev: { nodejs = prev.nodejs_22; })
              purescript-overlay.overlays.default
              mkSpagoDerivation.overlays.default
            ];
          };
          inherit (pkgs) lib;
          tools = {
            nodejs = pkgs.nodejs_22;
            purs = pkgs.purs-bin.purs-0_15_15;
            spago = pkgs.spago-bin.spago-0_93_45;
            purs-tidy = pkgs.purs-tidy-bin.purs-tidy-0_11_1;
            inherit (pkgs) esbuild;
          };
          source = lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.unions [
              ./src
              ./backend-es/src
              ./spago.yaml
              ./spago.lock
              ./backend-es/spago.yaml
            ];
          };
          runtimeSource = lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.unions [
              ./backend-es/index.dev.js
              ./backend-es/runtime.js
              ./backend-es/package.json
            ];
          };
          version = (builtins.fromJSON (builtins.readFile ./backend-es/package.json)).version;
          compiled = pkgs.mkSpagoDerivation {
            pname = "purs-backend-es-compiled";
            inherit version;
            src = source;
            spagoLock = ./spago.lock;
            nativeBuildInputs = [ tools.purs ];
            buildPhase = ''
              exec ${lib.getExe tools.purs} compile "src/**/*.purs" "backend-es/src/**/*.purs" ".spago/packages/*/src/**/*.purs" --codegen js,corefn --output ${builtins.placeholder "out"}
            '';
          };
          runtimeLayout = pkgs.linkFarm "purs-backend-es-layout" {
            output = compiled;
            backend-es = "${runtimeSource}/backend-es";
          };
          runtime = pkgs.stdenvNoCC.mkDerivation {
            pname = "purs-backend-es-runtime";
            inherit version;
            buildCommand = ''
              exec ${lib.getExe' pkgs.coreutils "cp"} --recursive --dereference ${runtimeLayout}/. ${builtins.placeholder "out"}
            '';
          };
          purs-backend-es = pkgs.writeShellApplication {
            name = "purs-backend-es";
            runtimeInputs = [ tools.esbuild ];
            text = ''
              exec ${lib.getExe tools.nodejs} ${runtime}/backend-es/index.dev.js "$@"
            '';
            derivationArgs.passthru = {
              inherit compiled runtime source tools;
            };
          };
        in
        {
          packages = {
            inherit purs-backend-es;
            default = purs-backend-es;
          };
          devShell = pkgs.mkShellNoCC {
            packages = (builtins.attrValues tools) ++ [
              pkgs.coreutils
              pkgs.diffutils
              pkgs.findutils
              pkgs.git
            ];
          };
          app = {
            type = "app";
            program = lib.getExe purs-backend-es;
          };
        });
    in
    {
      packages = forAllSystems (system: perSystem.${system}.packages);
      devShells = forAllSystems (system: { default = perSystem.${system}.devShell; });
      apps = forAllSystems (system: {
        default = perSystem.${system}.app;
        purs-backend-es = perSystem.${system}.app;
      });
    };
}
