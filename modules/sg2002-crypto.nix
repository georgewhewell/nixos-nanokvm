{ config, lib, ... }:
let
  cfg = config.sg2002;
  enabled = cfg.kernel == "mainline" && cfg.crypto.enable;
in {
  options.sg2002.crypto.enable = lib.mkEnableOption ''
    SG2002 CryptoDMA for kernel Crypto API consumers. Large requests can
    benefit, but small requests are slower than software. Applications
    using their own crypto libraries do not automatically use this engine
  '';

  config = lib.mkIf cfg.enable {
    assertions = [ {
      assertion = !cfg.crypto.enable || cfg.kernel == "mainline";
      message = "sg2002.crypto.enable requires the mainline kernel.";
    } ];

    # A module alone is not opt-in: the DT modalias would load it via udev.
    boot.blacklistedKernelModules = lib.optional
      (cfg.kernel == "mainline" && !enabled) "sg2002-crypto";
    boot.kernelModules = lib.optional enabled "sg2002-crypto";
    boot.initrd.availableKernelModules = lib.optional enabled "sg2002-crypto";
    boot.initrd.kernelModules = lib.optional enabled "sg2002-crypto";
    sg2002.initrd.availableKernelModules = lib.optional enabled "sg2002-crypto";
    sg2002.initrd.kernelModules = lib.optional enabled "sg2002-crypto";
  };
}
