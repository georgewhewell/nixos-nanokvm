{ config
, lib
, pkgs
, ...
}:

let
  cfg = config.sg2002.auxCore;
  contract = pkgs.sg2002-c906l-contract-for cfg.peripherals;
  controlModule =
    pkgs.sg2002-c906l-control-for config.boot.kernelPackages.kernel contract;
  lcdEnabled = builtins.elem "picoclawLcd" cfg.peripherals;
  framebufferModule =
    pkgs.sg2002-c906l-framebuffer-for config.boot.kernelPackages.kernel contract;
  wifiPowerModule =
    pkgs.sg2002-c906l-wifi-power-for config.boot.kernelPackages.kernel contract;
  remoteprocModule =
    pkgs.sg2002-c906l-remoteproc-for config.boot.kernelPackages.kernel contract;
  memoryMap = import ../pkgs/sg2002/c906l-memory-map.nix { inherit lib; };
  inherit (memoryMap) firmwareAddress sharedMemoryAddress;
  carveoutSize = memoryMap.firmwareSize;
  firmwareContractFields = [
    "c906lContract"
    "contractEpoch"
    "contractSha256"
    "dormantCapabilities"
    "enabledPeripherals"
    "firmwareAddress"
    "firmwareFile"
    "firmwareSize"
    "leaseMask"
    "manifestFlags"
    "profileId"
    "profileName"
    "protocolVersion"
    "requiredCapabilities"
    "sharedMemoryAddress"
    "sharedMemorySize"
  ];
  firmwareHasContract = lib.all (name: builtins.hasAttr name cfg.firmware) firmwareContractFields;
  expectedCapabilities = contract.requiredCapabilities;
  firmwareContractMatches = firmwareHasContract
    && toString cfg.firmware.c906lContract == toString contract
    && cfg.firmware.contractEpoch == contract.contractEpoch
    && cfg.firmware.contractSha256 == contract.contractSha256
    && cfg.firmware.dormantCapabilities == contract.dormantCapabilities
    && cfg.firmware.enabledPeripherals == contract.enabledPeripherals
    && cfg.firmware.firmwareAddress == firmwareAddress
    && cfg.firmware.firmwareSize == carveoutSize
    && cfg.firmware.leaseMask == contract.leaseMask
    && cfg.firmware.manifestFlags == contract.manifestFlags
    && cfg.firmware.profileId == contract.profileId
    && cfg.firmware.profileName == contract.profileName
    && cfg.firmware.protocolVersion == contract.protocolVersion
    && cfg.firmware.requiredCapabilities == expectedCapabilities
    && cfg.firmware.sharedMemoryAddress == sharedMemoryAddress
    && cfg.firmware.sharedMemorySize == memoryMap.sharedMemorySize;
  fdtContractFields = [
    "contractEpoch"
    "contractSha256"
    "dormantCapabilities"
    "enabledPeripherals"
    "firmwareAddress"
    "firmwareSize"
    "leaseMask"
    "manifestFlags"
    "profileId"
    "profileName"
    "protocolVersion"
    "requiredCapabilities"
    "sharedMemoryAddress"
    "sharedMemorySize"
  ];
  fdtHasContract = lib.all (name: builtins.hasAttr name cfg.fdt) fdtContractFields;
  fdtContractMatches = fdtHasContract
    && cfg.fdt.contractEpoch == contract.contractEpoch
    && cfg.fdt.contractSha256 == contract.contractSha256
    && cfg.fdt.dormantCapabilities == contract.dormantCapabilities
    && cfg.fdt.enabledPeripherals == contract.enabledPeripherals
    && cfg.fdt.firmwareAddress == firmwareAddress
    && cfg.fdt.firmwareSize == carveoutSize
    && cfg.fdt.leaseMask == contract.leaseMask
    && cfg.fdt.manifestFlags == contract.manifestFlags
    && cfg.fdt.profileId == contract.profileId
    && cfg.fdt.profileName == contract.profileName
    && cfg.fdt.protocolVersion == contract.protocolVersion
    && cfg.fdt.requiredCapabilities == contract.requiredCapabilities
    && cfg.fdt.sharedMemoryAddress == sharedMemoryAddress
    && cfg.fdt.sharedMemorySize == memoryMap.sharedMemorySize;
in
{
  options.sg2002.auxCore = {
    enable = lib.mkEnableOption "the SG2002 C906L real-time auxiliary core";

    peripherals = lib.mkOption {
      type = lib.types.listOf (lib.types.enum [
        "timer4"
        "timer5"
        "timer6"
        "timer7"
        "picoclawLcd"
      ]);
      default = [ ];
      example = [ "timer4" ];
      description = ''
        Statically leased C906L peripherals.  Each selection enables its Rust
        driver and C interrupt glue in the same firmware derivation.  There is
        intentionally no wildcard: every new lease needs an ownership audit,
        DT review, bounded self-test, and explicit capability bit.
      '';
    };

    firmware = lib.mkOption {
      type = lib.types.package;
      default = pkgs.sg2002-c906l-firmware-for cfg.peripherals;
      defaultText = lib.literalExpression
        "pkgs.sg2002-c906l-firmware-for config.sg2002.auxCore.peripherals";
      description = ''
        C906L firmware package.  It must publish the complete memory layout,
        enabled peripheral set, required capabilities, and protocol version
        passthru contract understood by the FIP, runner, DT, and Linux side.
      '';
    };

    fdt = lib.mkOption {
      type = lib.types.package;
      default = pkgs.sg2002-dtb-mainline-nowifi-c906l-for contract;
      defaultText = lib.literalExpression ''
        pkgs.sg2002-dtb-mainline-nowifi-c906l-for
          (pkgs.sg2002-c906l-contract-for config.sg2002.auxCore.peripherals)
      '';
      description = ''
        Board-composed device tree containing the C906L reservations and
        transport nodes.  Board modules with additional carrier hardware must
        override this default with their matching composed DT; substituting a
        generic development-board DT can silently remove unrelated devices.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.sg2002.kernel == "mainline";
        message = "sg2002.auxCore currently supports only the mainline kernel";
      }
      {
        assertion = config.sg2002.uboot == "mainline";
        message = "sg2002.auxCore requires the verified mainline FIP composition path";
      }
      {
        assertion = !config.sg2002.wifi.enable
          || (lcdEnabled && (cfg.fdt.wifiPowerProvider or null) == "c906l-regulator");
        message = ''
          sg2002.auxCore Wi-Fi requires the dedicated PicoClaw DT with the
          C906L power regulator; other profiles still use the no-WiFi DT
        '';
      }
      {
        assertion = cfg.peripherals == lib.unique cfg.peripherals;
        message = "sg2002.auxCore.peripherals must not contain duplicates";
      }
      {
        assertion = !lcdEnabled || cfg.peripherals == [ "picoclawLcd" ];
        message = "the board-specific picoclawLcd lease must be selected alone";
      }
      {
        assertion = !lcdEnabled
          || (cfg.fdt.boardProfile or null) == "picoclaw-c906l-lcd";
        message = ''
          the picoclawLcd lease requires the dedicated PicoClaw DT, which
          disables Linux SPI1, the entire GPIOA bank, I2C0 and Ethernet, and
          routes SDIO power through the C906L regulator
        '';
      }
      {
        assertion = firmwareHasContract;
        message = ''
          sg2002.auxCore.firmware must expose firmwareAddress, firmwareFile,
          firmwareSize, enabledPeripherals, shared-memory layout, and the
          complete generated contract identity in passthru attributes
        '';
      }
      {
        assertion = firmwareContractMatches;
        message = ''
          sg2002.auxCore.firmware must match the DT contract: firmware at
          0x8fe00000/1MiB, shared memory at 0x8ff00000/1MiB, and the exact
          ABI, digest, profile, capabilities, lease mask, manifest flags,
          and configured peripheral lease set
        '';
      }
      {
        assertion = fdtHasContract;
        message = ''
          sg2002.auxCore.fdt must expose firmwareAddress, firmwareSize,
          sharedMemoryAddress, sharedMemorySize, and the complete generated
          contract identity in passthru attributes
        '';
      }
      {
        assertion = fdtContractMatches;
        message = ''
          sg2002.auxCore.fdt must reserve the exact C906L firmware and shared
          memory ranges and match the generated ABI, digest, profile,
          capabilities, lease mask, and manifest flags
        '';
      }
    ];

    # Firmware selection, FIP packing, and the Linux memory reservation move
    # together.  A partially enabled auxiliary core could let Linux's CMA
    # allocator overwrite executing firmware, so these are deliberately
    # non-overridable while the option is enabled.
    system.build.c906lFirmware = cfg.firmware;
    system.build.fip = lib.mkForce (pkgs.sg2002-fip-mainline-uboot-for cfg.firmware);
    system.build.fipFastboot = lib.mkForce (pkgs.sg2002-fip-mainline-fastboot-for cfg.firmware);
    sg2002.fdt = lib.mkForce cfg.fdt;
    boot.extraModulePackages = [
      controlModule
      remoteprocModule
    ] ++ lib.optionals lcdEnabled [ framebufferModule wifiPowerModule ];
    boot.kernelModules = [
      "sg2002-c906l-control"
      "sg2002-c906l-remoteproc"
    ] ++ lib.optionals lcdEnabled [ "sg2002-c906l-wifi-power" "sg2002-c906l-framebuffer" ];
    # The C906L regulator powers the AIC8800, and module load order cannot
    # put it ahead of the Wi-Fi driver.
    sg2002.wifi.loadDriverAtBoot = lib.mkIf lcdEnabled false;
    environment.systemPackages = [ (pkgs.sg2002-c906l-ctl-for contract) ];
  };
}
