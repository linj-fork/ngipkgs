{
  coreutils,
  jq,
  lib,
  nix,
  opam-nix,
  stdenv,
  writeShellApplication,
}:

rec {
  # Description: run `mirage configure` on source,
  # with mirage, dune, and ocaml from `opam-nix`.
  configure =
    {
      pname,
      version,
      mirageDir ? ".",
      query,
      src,
      opamPackages ? opam-nix.queryToScope { } ({ mirage = "*"; } // query),
      ...
    }:
    target:
    stdenv.mkDerivation {
      name = "mirage-${pname}-${target}";
      inherit src version;
      buildInputs = with opamPackages; [ mirage ];
      nativeBuildInputs = with opamPackages; [
        dune
        ocaml
      ];
      buildPhase = ''
        runHook preBuild
        mirage configure -f ${mirageDir}/config.ml -t ${target}
        # Move Opam file to root so a recursive search for opam files isn't required.
        # Prefix it so it doesn't interfere with other packages.
        cp ${mirageDir}/mirage/${pname}-${target}.opam mirage-${pname}-${target}.opam
        runHook postBuild
      '';
      installPhase = ''
        runHook preInstall
        cp -R . $out
        runHook postInstall
      '';
    };

  # Description: read opam files from mirage configuration
  # and build a unikernel in a separate output
  # for each one of the given targets.
  build = lib.extendMkDerivation {
    constructDrv = stdenv.mkDerivation;
    excludeDrvArgNames = [
      "monorepoMaterializedDir"
      "monorepoQuery"
      "overrideUnikernel"
      "packagesMaterializedDir"
      "query"
      "queryArgs"
    ];
    extendDrvArgs =
      finalAttrs:
      {
        pname,
        version,
        targets,
        src,
        monorepoQuery,
        packagesMaterializedDir,
        monorepoMaterializedDir,
        mirageDir ? ".",
        queryArgs ? { },
        query ? { },
        overrideUnikernel ? finalAttrs: previousAttrs: { },
        ...
      }@args:
      let
        name = "mirage-${pname}";
        mirageConf = configure args;
        mirageConfUnmaterialized =
          target:
          configure (
            args
            // {
              opamPackages = packagesUnmaterialized target;
            }
          ) target;
        packagesMaterialized =
          target: opam-nix.materializeOpamProject { } "${name}-${target}" (mirageConf target) query;
        monorepoMaterialized =
          target: opam-nix.materializeBuildOpamMonorepo { } (mirageConf target) monorepoQuery;
        monorepoUnmaterialized =
          target: opam-nix.unmaterializeQueryToMonorepo { } (monorepoMaterializedDir + "/${target}.json");
        packagesUnmaterialized =
          target:
          (opam-nix.materializedDefsToScope {
            sourceMap."${name}-${target}" = finalAttrs.passthru.mirageConfUnmaterialized.${target};
          } (packagesMaterializedDir + "/${target}.json")).overrideScope
            (
              finalOpam: previousOpam: {
                "${name}-${target}" = previousOpam."${name}-${target}".overrideAttrs (
                  lib.composeExtensions (finalUnikernel: previousUnikernel: {
                    inherit version;
                    __intentionallyOverridingVersion = true;

                    env =
                      previousUnikernel.env or { }
                      // lib.optionalAttrs (finalOpam ? "ocaml-solo5") {
                        OCAMLFIND_CONF = finalOpam.ocaml-solo5 + "/lib/findlib.conf";
                      };

                    buildPhase = ''
                      runHook preBuild
                      mkdir duniverse
                      echo '(vendored_dirs *)' > duniverse/dune
                      ${lib.concatStringsSep "\n" (
                        lib.mapAttrsToList (name: path: "cp -r ${path} duniverse/${lib.toLower name}") (
                          finalAttrs.passthru.monorepoUnmaterialized.${target}
                        )
                      )}
                      dune build ${mirageDir} --profile release
                      runHook postBuild
                    '';

                    installPhase = ''
                      runHook preInstall
                      mkdir -p $out/lib/
                      cp -L ${mirageDir}/dist/${pname}* $out/lib/
                      runHook postInstall
                    '';

                    # Reduce the full closure size by several hundreds MiB
                    doNixSupport = false;
                    # Strip more heavily than the default '-S',
                    # since if you're using an unikernel you probably care about this.
                    stripDebugFlags = previousUnikernel.stripDebugFlags or [ ] ++ [ "--strip-unneeded" ];
                  }) overrideUnikernel
                );
              }
            );
      in
      {
        inherit name;
        inherit src;
        outputs = [ "out" ] ++ targets;
        installPhase = ''
          runHook preBuild
          ${
            if stdenv.hostPlatform.isLinux && lib.elem "unix" targets then
              "ln -s $unix $out"
            else if stdenv.hostPlatform.isDarwin && lib.elem "macosx" targets then
              "ln -s $macosx $out"
            else
              "mkdir $out"
          }
          ${lib.concatMapStringsSep "\n" (target: ''
            cp -R ${finalAttrs.passthru.packagesUnmaterialized.${target}."${name}-${target}"} ''$${target}
          '') targets}
          runHook postBuild
        '';
        passthru = {
          updateScript = writeShellApplication {
            name = "dnsvizor-update";
            runtimeInputs = [
              coreutils
              jq
              nix
            ];
            text = ''
              set -x
              packagesDir=$(nix --extra-experimental-features nix-command -L eval \
                -f. ${pname}.passthru.packagesMaterializedDir)
              monorepoDir=$(nix --extra-experimental-features nix-command -L eval \
                -f. ${pname}.passthru.monorepoMaterializedDir)
            ''
            + lib.concatMapStringsSep "\n" (target: ''
              packagesJson=$(nix --extra-experimental-features nix-command -L build \
                --no-link --print-out-paths --allow-import-from-derivation --show-trace \
                -f. ${pname}.passthru.packagesMaterialized.${target})
              jq <"$packagesJson" |
              install -Dm660 /dev/stdin "''${packagesDir}/${target}.json"

              monorepoJson=$(nix --extra-experimental-features nix-command -L build \
                --no-link --print-out-paths --allow-import-from-derivation --show-trace \
                -f. ${pname}.passthru.monorepoMaterialized.${target})
              jq <"$monorepoJson" |
              install -Dm660 /dev/stdin "''${monorepoDir}/${target}.json"
            '') targets;
          };
          mirageConf = lib.genAttrs targets mirageConf;
          mirageConfUnmaterialized = lib.genAttrs targets mirageConfUnmaterialized;
          monorepoMaterialized = lib.genAttrs targets monorepoMaterialized;
          packagesMaterialized = lib.genAttrs targets packagesMaterialized;
          packagesUnmaterialized = lib.genAttrs targets packagesUnmaterialized;
          monorepoUnmaterialized = lib.genAttrs targets monorepoUnmaterialized;
          inherit packagesMaterializedDir;
          inherit monorepoMaterializedDir;
        };
      };
  };

  possibleTargets = [
    "genode"
    "hvt"
    "macosx"
    "muen"
    "qubes"
    "spt"
    "unix"
    "virtio"
    "xen"
  ];
}
