{
  description = "AppImage bundler";

  inputs = {
    nixpkgs.url = "nixpkgs/nixos-22.05";

    flake-utils = {
      url = "github:numtide/flake-utils";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };

    appimage-runtime = {
      url = "github:AppImageCrafters/appimage-runtime";
      flake = false;
    };

    squashfuse = {
      url = "github:vasi/squashfuse";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, flake-utils, ... }@inputs:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = (import nixpkgs {
          inherit system;
        }).pkgsStatic;

        # nixpkgs has an old version so we need to package our own
        own-squashfuse = pkgs.stdenv.mkDerivation {
          name = "squashfuse";
          src = inputs.squashfuse;
          nativeBuildInputs = with pkgs; [ autoreconfHook libtool pkg-config ];
          buildInputs = with pkgs; [ lz4 xz zlib lzo zstd fuse ];
        };
      in
      rec {
        packages.apprun = pkgs.runCommandCC "AppRun" { } ''
          $CC ${./apprun.c} -o $out
        '';

        packages.runtime =
          let
            git-commit = "0000000";
          in
          pkgs.runCommandCC "runtime"
            {
              nativeBuildInputs = with pkgs; [ pkg-config ];
              buildInputs = with pkgs; [
                fuse
                own-squashfuse
                zstd
                zlib
                lzma
                lz4
                lzo
              ];
            } ''
            NIX_CFLAGS_COMPILE="$(pkg-config --cflags fuse) $NIX_CFLAGS_COMPILE"

            # extra includes to make things work
            mkdir -p include/squashfuse
            echo "#include_next <squashfuse/squashfuse.h>" > include/squashfuse/squashfuse.h
            cp ${inputs.squashfuse}/fuseprivate.h -t include/squashfuse

            $CC ${inputs.appimage-runtime}/src/main.c -o $out \
              -I./include -D_FILE_OFFSET_BITS=64 -DGIT_COMMIT='"${git-commit}"' \
              -lfuse -lsquashfuse_ll -lzstd -lz -llzma -llz4 -llzo2 \
              -T ${inputs.appimage-runtime}/src/data_sections.ld

            # Add AppImage Type 2 Magic Bytes to runtime
            printf "AI2" > magic_bytes
            dd if=magic_bytes of=$out bs=1 count=3 seek=8 conv=notrunc status=none
          '';

        # Produce an (probably non-conforming) AppImage.
        #
        # The AppImage type 2 format is simply the runtime binary concatenated
        # with a squashfs. When running the AppImage, the squashfs binary is
        # extracted/mounted at an arbitrary place and the AppRun binary within
        # run.
        mkappimage = { drv, entrypoint, name }:
          let
            arch = builtins.head (builtins.split "-" system);
            closure = pkgs.writeReferencesToFile drv;
            extras = [
              "AppRun f 555 0 0 cat ${packages.apprun}"
              "entrypoint s 555 0 0 ${entrypoint}"
            ];
            extra-args = pkgs.lib.concatMapStrings (x: " -p \"${x}\"") extras;
          in
          pkgs.runCommand "${name}-${arch}.AppImage"
            {
              nativeBuildInputs = with pkgs; [ squashfsTools ];
            } ''
            mksquashfs $(cat ${closure}) $out \
              -no-strip \
              -offset $(stat -L -c%s ${packages.runtime}) \
              -comp zstd \
              -all-root \
              -noappend \
              -b 1M \
              ${extra-args}
            dd if=${packages.runtime} of=$out conv=notrunc
            chmod 755 $out
          '';

        bundlers.default =
          let
            basename = p: pkgs.lib.lists.last (builtins.split "/" p);

            mainProgram = drv:
              if drv?meta && drv.meta?mainProgram then drv.meta.mainProgram
              else (builtins.parseDrvName (builtins.unsafeDiscardStringContext drv.name)).name;

            program = drv:
              let
                # use same auto-detect that <https://github.com/NixOS/bundlers> uses
                main =
                  if drv?meta && drv.meta?mainProgram then drv.meta.mainProgram
                  else (builtins.parseDrvName (builtins.unsafeDiscardStringContext drv.name)).name;
                mainPath = "${drv}/bin/${main}";
              in
              assert pkgs.lib.assertMsg (builtins.pathExists mainPath) "main program ${mainPath} does not exist";
              mainPath;

            handler = {
              app = drv: mkappimage {
                drv = drv.program;
                entrypoint = drv.program;
                name = basename drv.program;
              };
              derivation = drv: mkappimage {
                drv = drv;
                entrypoint = program drv;
                name = drv.name;
              };
            };
            known-types = builtins.concatStringsSep ", " (builtins.attrNames handler);
          in
          drv:
            assert pkgs.lib.assertMsg (handler ? ${drv.type}) "don't know how to make app image for type '${drv.type}'; only know ${known-types}";
            handler.${drv.type} drv;
      });
}
