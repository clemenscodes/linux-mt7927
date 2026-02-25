{
  inputs = {
    nixpkgs = {
      url = "github:NixOS/nixpkgs/nixos-unstable";
    };
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
    };
  };
  outputs = {
    self,
    nixpkgs,
    flake-parts,
    ...
  } @ inputs: let
    system = "x86_64-linux";
  in
    flake-parts.lib.mkFlake {inherit inputs;} {
      imports = [inputs.flake-parts.flakeModules.easyOverlay];
      systems = [system];
      flake = {
        nixosModules = {
          mt7927 = {
            pkgs,
            lib,
            config,
            ...
          }: let
            cfg = config.mt7927;

            mt76 = {
              pkgs,
              lib,
              kernel ? pkgs.linuxPackages_latest.kernel,
            }:
              pkgs.stdenv.mkDerivation {
                pname = "mt76-kernel-module";
                inherit (kernel) src version postPatch nativeBuildInputs;

                kernel_dev = kernel.dev;
                kernelVersion = kernel.modDirVersion;
                modulePath = "drivers/net/wireless/mediatek/mt76";

                dontStrip = true;
                dontPatchELF = true;

                buildPhase = ''
                  BUILT_KERNEL=$kernel_dev/lib/modules/$kernelVersion/build
                  cp $BUILT_KERNEL/Module.symvers .
                  cp $BUILT_KERNEL/.config .
                  cp $kernel_dev/vmlinux .

                  make "-j$NIX_BUILD_CORES" modules_prepare
                  make "-j$NIX_BUILD_CORES" M=$modulePath modules
                '';

                installPhase = ''
                  make \
                    INSTALL_MOD_PATH="$out" \
                    XZ="xz -T$NIX_BUILD_CORES" \
                    M="$modulePath" \
                    modules_install
                '';

                meta = {
                  description = "MT7927 WiFi kernel module";
                  license = lib.licenses.gpl2;
                };
              };

            mt7927-wlan-firmware = let
              src = pkgs.stdenvNoCC.mkDerivation {
                pname = "mt7927-wlan-driver-zip";
                version = "V5.6.0.3998";
                nativeBuildInputs = with pkgs; [curl jq cacert];
                outputHashMode = "flat";
                outputHashAlgo = "sha256";
                outputHash = "sha256-s3f/+iggi7FnGg6yGchMYvukzW+SFht05LCQlHYwfMg=";
                dontUnpack = true;
                SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
                buildPhase = ''
                  file_path="https:%2F%2Fdlcdnta.asus.com%2Fpub%2FASUS%2Fmb%2F08WIRELESS%2FDRV_WiFi_MTK_MT7925_MT7927_TP_W11_64_V5603998_20250709R.zip%3Fmodel%3DROG%2520CROSSHAIR%2520X870E%2520HERO"
                  api="https://cdnta.asus.com/api/v1/TokenHQ"
                  json=$(curl -sS -X POST -H "Origin: https://rog.asus.com" "$api?filePath=$file_path&systemCode=rog")
                  expires=$(jq -r '.result.expires // empty' <<<"$json")
                  signature=$(jq -r '.result.signature // empty' <<<"$json")
                  key=$(jq -r '.result.keyPairId // empty' <<<"$json")
                  decoded_path=$(printf '%b' "''${file_path//%/\\x}")
                  url="$decoded_path&Signature=$signature&Expires=$expires&Key-Pair-Id=$key"
                  curl -fL -o "$out" "$url"
                '';
              };
              extraction = pkgs.writeText "extract_mt6639.py" ''
                #!/usr/bin/env python3
                import os
                import struct
                import sys
                import re

                TARGETS = { "WIFI_MT6639_PATCH_MCU_2_1_hdr.bin", "WIFI_RAM_CODE_MT6639_2_1.bin" }
                NAME_RE = re.compile(rb"[A-Za-z0-9_.-]+\.bin")

                def align4(x):
                    return (x + 3) & ~3

                def extract(container_path, out_dir):
                    with open(container_path, "rb") as f:
                        data = f.read()

                    os.makedirs(out_dir, exist_ok=True)
                    found = set()

                    for match in NAME_RE.finditer(data):
                        name = match.group(0).decode(errors="ignore")

                        if name not in TARGETS:
                            continue

                        entry_pos = match.end()

                        while entry_pos < len(data) and data[entry_pos] == 0:
                            entry_pos += 1

                        if entry_pos + 14 < len(data):
                            chunk = data[entry_pos:entry_pos+14]
                            if all(48 <= b <= 57 for b in chunk):
                                entry_pos += 14

                        entry_pos = align4(entry_pos)

                        if entry_pos + 8 > len(data):
                            continue

                        data_offset = struct.unpack_from("<I", data, entry_pos)[0]
                        data_size = struct.unpack_from("<I", data, entry_pos + 4)[0]

                        blob = data[data_offset:data_offset+data_size]

                        out_path = os.path.join(out_dir, name)
                        with open(out_path, "wb") as out:
                            out.write(blob)

                        found.add(name)

                if __name__ == "__main__":
                    extract(sys.argv[1], sys.argv[2])
              '';
            in
              pkgs.stdenvNoCC.mkDerivation {
                pname = "mt7927-wlan-firmware";
                version = "V5.6.0.3998";
                inherit src;
                nativeBuildInputs = with pkgs; [unzip python3];
                dontConfigure = true;
                dontBuild = true;
                unpackPhase = ''
                  mkdir source
                  cd source
                  unzip $src
                '';
                installPhase = ''
                  mkdir -p $out/lib/firmware/mediatek/mt7927
                  python3 ${extraction} "mtkwlan.dat" "$out/lib/firmware/mediatek/mt7927"
                '';
              };

            mt7927-bt-firmware = let
              src = pkgs.stdenvNoCC.mkDerivation {
                pname = "mt7927-bt-driver-zip";
                version = "V1.1043.0.542";
                nativeBuildInputs = with pkgs; [curl jq];
                outputHashMode = "flat";
                outputHashAlgo = "sha256";
                outputHash = "sha256-+OE5iy3Zjd7/pO3oK1UwVFGSQ+Zo/LN6sCUpKb9mIZQ=";
                dontUnpack = true;
                SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
                buildPhase = ''
                  file_path="https:%2F%2Fdlcdnta.asus.com%2Fpub%2FASUS%2Fmb%2F02BT%2FDRV_Bluetooth_MTK_MT7925_27_TP_W11_64_V110430542_20250709R.zip%3Fmodel%3DROG%2520CROSSHAIR%2520X870E%2520HERO"
                  api="https://cdnta.asus.com/api/v1/TokenHQ"
                  json=$(curl -sS -X POST -H "Origin: https://rog.asus.com" "$api?filePath=$file_path&systemCode=rog")
                  expires=$(jq -r '.result.expires // empty' <<<"$json")
                  signature=$(jq -r '.result.signature // empty' <<<"$json")
                  key=$(jq -r '.result.keyPairId // empty' <<<"$json")
                  decoded_path=$(printf '%b' "''${file_path//%/\\x}")
                  url="$decoded_path&Signature=$signature&Expires=$expires&Key-Pair-Id=$key"
                  curl -fL -o "$out" "$url"
                '';
              };
              extraction = pkgs.writeTextFile {
                name = "extract_firmware.py";
                text = ''
                  #!/usr/bin/env python3

                  import os
                  import struct
                  import sys

                  FIRMWARE_NAME = b"BT_RAM_CODE_MT6639_2_1_hdr.bin"

                  def extract(mtkbt_path, output_path):
                      with open(mtkbt_path, "rb") as f:
                          data = f.read()
                      idx = data.find(FIRMWARE_NAME)
                      entry_pos = idx + len(FIRMWARE_NAME)
                      while entry_pos < len(data) and data[entry_pos] == 0x00:
                          entry_pos += 1
                      if all(48 <= b <= 57 for b in data[entry_pos : entry_pos + 14]):
                          entry_pos += 14
                      entry_pos = (entry_pos + 3) & ~3
                      data_offset = struct.unpack_from("<I", data, entry_pos)[0]
                      data_size = struct.unpack_from("<I", data, entry_pos + 4)[0]
                      blob = data[data_offset : data_offset + data_size]
                      out_dir = os.path.dirname(output_path)
                      if out_dir:
                          os.makedirs(out_dir, exist_ok=True)
                      with open(output_path, "wb") as f:
                          f.write(blob)

                  if __name__ == "__main__":
                      if len(sys.argv) != 3:
                          sys.exit(1)
                      extract(sys.argv[1], sys.argv[2])
                '';
              };
            in
              pkgs.stdenvNoCC.mkDerivation {
                pname = "mt7927-bt-firmware";
                version = "V1.1043.0.542";
                inherit src;
                nativeBuildInputs = with pkgs; [unzip python3];
                dontConfigure = true;
                dontBuild = true;
                unpackPhase = ''
                  mkdir source
                  cd source
                  unzip $src
                '';
                installPhase = ''
                  mkdir -p $out/lib/firmware/mediatek/mt6639
                  python3 ${extraction} "mtkbt.dat" "$out/lib/firmware/mediatek/mt6639/BT_RAM_CODE_MT6639_2_1_hdr.bin"
                '';
              };

            bluetooth = {
              pkgs,
              lib,
              kernel ? pkgs.linuxPackages_latest.kernel,
            }:
              pkgs.stdenv.mkDerivation {
                pname = "bluetooth-kernel-module";
                inherit (kernel) src version postPatch nativeBuildInputs;

                kernel_dev = kernel.dev;
                kernelVersion = kernel.modDirVersion;

                modulePath = "drivers/bluetooth";

                buildPhase = ''
                  BUILT_KERNEL=$kernel_dev/lib/modules/$kernelVersion/build

                  cp $BUILT_KERNEL/Module.symvers .
                  cp $BUILT_KERNEL/.config        .
                  cp $kernel_dev/vmlinux          .

                  make "-j$NIX_BUILD_CORES" modules_prepare
                  make "-j$NIX_BUILD_CORES" M=$modulePath modules
                '';

                installPhase = ''
                  make \
                    INSTALL_MOD_PATH="$out" \
                    XZ="xz -T$NIX_BUILD_CORES" \
                    M="$modulePath" \
                    modules_install
                '';

                meta = {
                  description = "Bluetooth kernel module with patch for MT7927 chips";
                  license = lib.licenses.gpl3;
                };
              };
          in {
            options = {
              mt7927 = {
                enable = lib.mkEnableOption "Enable MT7927 support";
              };
            };
            config = lib.mkIf cfg.enable {
              hardware = {
                firmware = [
                  (pkgs.callPackage mt7927-wlan-firmware {})
                  (pkgs.callPackage mt7927-bt-firmware {})
                ];
              };
              boot = {
                extraModulePackages = let
                  inherit (config.boot.kernelPackages) kernel;
                in [
                  ((pkgs.callPackage mt76 {inherit kernel;}).overrideAttrs (o: {
                    patches = [./mt7927-wifi.patch];
                  }))
                  ((pkgs.callPackage bluetooth {inherit kernel;}).overrideAttrs (o: {
                    patches = [./mt7927-bt.patch];
                  }))
                ];
              };
            };
          };
        };
      };
    };
}
