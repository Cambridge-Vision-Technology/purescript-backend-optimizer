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
          offlineSpago = pkgs.writeShellApplication {
            name = "spago";
            text = ''
              exec ${lib.getExe tools.spago} "$@" --offline --pure
            '';
          };
          copyLayout = name: layout: pkgs.stdenvNoCC.mkDerivation {
            inherit name;
            buildCommand = ''
              exec ${lib.getExe' pkgs.coreutils "cp"} --recursive --dereference ${layout}/. ${builtins.placeholder "out"}
            '';
          };
          checkSource = lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.unions [
              ./package.json
              ./backend-es/test/Main.purs
              ./backend-es/test/Utils.purs
              ./backend-es/test/Utils.js
              ./backend-es/test/SnapshotPolicy.purs
              ./backend-es/test/SnapshotRunner.purs
              ./backend-es/test/Platform/Node/SnapshotProcess.purs
              ./backend-es/test/Platform/Node/SnapshotProcess.js
            ];
          };
          bundledLauncher = pkgs.writeTextFile {
            name = "backend-es-index";
            executable = true;
            text = builtins.replaceStrings [ "#!/usr/bin/env node" ] [ "#!${lib.getExe tools.nodejs}" ]
              (builtins.readFile ./backend-es/index.js);
          };
          checkLayout = {
            src = "${source}/src";
            output = "${runtime}/output";
            "spago.yaml" = "${source}/spago.yaml";
            "spago.lock" = "${source}/spago.lock";
            "package.json" = "${checkSource}/package.json";
            "backend-es/src" = "${source}/backend-es/src";
            "backend-es/test" = "${checkSource}/backend-es/test";
            "backend-es/spago.yaml" = "${source}/backend-es/spago.yaml";
            "backend-es/package.json" = "${runtime}/backend-es/package.json";
            "backend-es/runtime.js" = "${runtime}/backend-es/runtime.js";
            "backend-es/index.dev.js" = "${runtime}/backend-es/index.dev.js";
            "backend-es/index.js" = bundledLauncher;
          };
          checkWorkspace = copyLayout "backend-es-check-workspace"
            (pkgs.linkFarm "backend-es-check-layout" checkLayout);
          mkCheck = name: src: command: pkgs.mkSpagoDerivation {
            inherit name src;
            spagoYaml = ./spago.yaml;
            spagoLock = ./spago.lock;
            nativeBuildInputs = [
              offlineSpago
              tools.purs
              tools.nodejs
              tools.esbuild
              pkgs.diffutils
            ];
            buildPhase = ''
              exec ${command} > ${builtins.placeholder "out"}
            '';
          };
          snapshotSource = lib.fileset.toSource {
            root = ./backend-es/test-snapshots;
            fileset = lib.fileset.unions [
              ./backend-es/test-snapshots/src
              ./backend-es/test-snapshots/spago.yaml
              ./backend-es/test-snapshots/spago.lock
            ];
          };
          snapshotDependencies = pkgs.buildDotSpago {
            spagoLock = ./backend-es/test-snapshots/spago.lock;
          };
          snapshotCompiled = pkgs.mkSpagoDerivation {
            name = "backend-es-snapshot-compiled";
            src = snapshotSource;
            spagoYaml = ./backend-es/test-snapshots/spago.yaml;
            spagoLock = ./backend-es/test-snapshots/spago.lock;
            nativeBuildInputs = [ tools.purs ];
            buildPhase = ''
              exec ${lib.getExe tools.purs} compile "src/**/*.purs" ".spago/packages/*/src/**/*.purs" --codegen js,corefn --output ${builtins.placeholder "out"}
            '';
          };
          snapshotFixtures = lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.unions [
              ./backend-es/test-snapshots/src
              ./backend-es/test-snapshots/spago.yaml
              ./backend-es/test-snapshots/spago.lock
              ./backend-es/test-snapshots/snapshots-out
            ];
          };
          snapshotLayout = checkLayout // {
            "backend-es/test-snapshots/src" = "${snapshotFixtures}/backend-es/test-snapshots/src";
            "backend-es/test-snapshots/spago.yaml" = "${snapshotFixtures}/backend-es/test-snapshots/spago.yaml";
            "backend-es/test-snapshots/spago.lock" = "${snapshotFixtures}/backend-es/test-snapshots/spago.lock";
            "backend-es/test-snapshots/snapshots-out" = "${snapshotFixtures}/backend-es/test-snapshots/snapshots-out";
            "backend-es/test-snapshots/output" = snapshotCompiled;
            "backend-es/test-snapshots/.spago" = "${snapshotDependencies}/.spago";
          };
          snapshotWorkspace = selector: extraArgs:
            copyLayout "backend-es-snapshot-workspace-${selector}"
              (pkgs.linkFarm "backend-es-snapshot-layout-${selector}" (snapshotLayout // {
                "backend-es/spago.yaml" = pkgs.writeText "backend-es-snapshot-config-${selector}.yaml"
                  ((builtins.readFile ./backend-es/spago.yaml) + "\n    execArgs: ${builtins.toJSON ([ "--filter" selector ] ++ extraArgs)}\n");
              }));
          mkSnapshotCheck = selector:
            assert selector == "Snapshot.*" ||
              (builtins.pathExists (./backend-es/test-snapshots/src + "/${selector}.purs") &&
                builtins.pathExists (./backend-es/test-snapshots/snapshots-out + "/${selector}.js"));
            mkCheck "backend-es-snapshots-${selector}" (snapshotWorkspace selector [])
              "${lib.getExe' tools.nodejs "npm"} run test";
          incrementalSource = lib.fileset.toSource {
            root = ./backend-es/test;
            fileset = lib.fileset.unions [
              ./backend-es/test/Incremental.purs
              ./backend-es/test/Utils.purs
              ./backend-es/test/Utils.js
              ./backend-es/test/SnapshotPolicy.purs
              ./backend-es/test/SnapshotRunner.purs
              ./backend-es/test/Platform/Node/SnapshotProcess.purs
              ./backend-es/test/Platform/Node/SnapshotProcess.js
            ];
          };
          mkIncrementalCheck = selector:
            mkCheck "backend-es-${selector}"
              (copyLayout "backend-es-${selector}-workspace"
                (pkgs.linkFarm "backend-es-${selector}-layout" (checkLayout // {
                  "backend-es/test" = incrementalSource;
                  "backend-es/spago.yaml" = pkgs.writeText "backend-es-${selector}-config.yaml"
                    ((builtins.replaceStrings [ "main: Test.Main" ] [ "main: Test.Incremental" ]
                      (builtins.readFile ./backend-es/spago.yaml)) + "\n    execArgs: ${builtins.toJSON [ selector ]}\n");
                })))
              "${lib.getExe' tools.nodejs "npm"} run test";
          implementationTests = pkgs.linkFarm "backend-es-test-implementation" {
            incremental-clean-reuse = mkIncrementalCheck "incremental-clean-reuse";
            incremental-on-prepare-module = mkIncrementalCheck "incremental-on-prepare-module";
          };
          formatSource = lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.unions [
              ./src
              ./backend-es/src
              ./backend-es/test/Main.purs
              ./backend-es/test/Incremental.purs
              ./backend-es/test/Utils.purs
              ./backend-es/test/SnapshotPolicy.purs
              ./backend-es/test/SnapshotRunner.purs
              ./backend-es/test/Platform/Node/SnapshotProcess.purs
              ./.tidyrc.json
            ];
          };
        in
        {
          packages = {
            inherit purs-backend-es;
            default = purs-backend-es;
            test-incremental-clean-reuse = mkIncrementalCheck "incremental-clean-reuse";
            test-incremental-on-prepare-module = mkIncrementalCheck "incremental-on-prepare-module";
            test-implementation = implementationTests;
            test-snapshot-html = mkSnapshotCheck "Snapshot.Html";
            test-snapshot-tco03 = mkSnapshotCheck "Snapshot.Tco03";
            test-snapshot-case-guarded = mkSnapshotCheck "Snapshot.CaseGuarded";
            test-snapshot-primop-number01 = mkSnapshotCheck "Snapshot.PrimOpNumber01";
            test-snapshot-string-literal01 = mkSnapshotCheck "Snapshot.StringLiteral01";
            test-snapshot-timeout-control = mkCheck "backend-es-snapshot-timeout-control"
              (snapshotWorkspace "Snapshot.StringLiteral01" [ "--diagnostic-timeout" "--deadline-ms" "3000" ])
              "${lib.getExe' tools.nodejs "npm"} run test";
            test-snapshot-empty-selection-control = mkCheck "backend-es-snapshot-empty-selection-control"
              (snapshotWorkspace "Snapshot.__DEV1073NonexistentSnapshot__" [])
              "${lib.getExe' tools.nodejs "npm"} run test";
          };
          checks = {
            test-implementation = implementationTests;
            build = mkCheck "backend-es-pedantic-build" checkWorkspace
              "${lib.getExe' tools.nodejs "npm"} run build -- --pedantic-packages";
            snapshots = mkSnapshotCheck "Snapshot.*";
            output-diff = mkCheck "backend-es-output-diff" checkWorkspace
              "${lib.getExe' tools.nodejs "npm"} --prefix backend-es run test:output-diff";
            format = pkgs.stdenvNoCC.mkDerivation {
              name = "backend-es-format";
              src = formatSource;
              buildPhase = ''
                exec ${lib.getExe tools.purs-tidy} check src backend-es/src backend-es/test > ${builtins.placeholder "out"}
              '';
            };
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
      checks = forAllSystems (system: perSystem.${system}.checks);
      devShells = forAllSystems (system: { default = perSystem.${system}.devShell; });
      apps = forAllSystems (system: {
        default = perSystem.${system}.app;
        purs-backend-es = perSystem.${system}.app;
      });
    };
}
