# Mainline DTBs for the Sipeed LicheeRV Nano B-W variant.
#
# Starts from the upstream `sg2002-licheerv-nano-b.dts` in the mainline
# kernel tree (passed in as `linuxSrc`) and concatenates one or more
# overlay dtsi files — dtc merges nodes, so later properties replace
# earlier ones. All variants include the shared CPUFreq/thermal description.
# The basic outputs are:
#
#   .dtb     — bw.dtsi (default: WiFi/SDIO1 enabled).
#   .dtbOled — bw.dtsi + bw-oled.dtsi (SDIO1 disabled, IIC1 + SH1107
#              child on the freed-up SD1 pads). Pair with builds that
#              also turn sg2002.wifi.enable off.
#   .dtbs    — directory-shaped wrapper for NixOS's
#              `hardware.deviceTree.package` (covers the default DTB).
{ lib
, runCommand
, dtc
, gcc
, linuxSrc
, python3
, writeText
,
}:
let
  c906lMemoryMap = import ../c906l-memory-map.nix { inherit lib; };
  # Each overlay has to be interpolated into the script body individually
  # — `toString [path1 path2]` doesn't trigger Nix's path-to-store import,
  # it just stringifies the raw source paths, which are then missing from
  # the build's closure. `${p}` per element does the import.
  buildDtb = name: overlays:
    runCommand "${name}.dtb"
      {
        nativeBuildInputs = [ dtc gcc ];
      } ''
      tar -xf ${linuxSrc}
      SRC=$(echo linux-*/)
      DTS=$SRC/arch/riscv/boot/dts/sophgo/sg2002-licheerv-nano-b.dts

      cat "$DTS" ${lib.concatMapStringsSep " " (p: "${p}") overlays} \
        ${./sg2002-cpufreq.dtsi} > merged.dts

      cpp -nostdinc -undef -x assembler-with-cpp \
        -I "$SRC/include" \
        -I "$SRC/arch/riscv/boot/dts/sophgo" \
        -o merged.pre.dts merged.dts

      dtc -I dts -O dtb -o "$out" merged.pre.dts
    '';

  dtb = buildDtb "sg2002-licheerv-nano-bw" [
    ./sg2002-licheerv-nano-bw.dtsi
  ];

  dtbOled = buildDtb "sg2002-licheerv-nano-bw-oled" [
    ./sg2002-licheerv-nano-bw.dtsi
    ./sg2002-licheerv-nano-bw-oled.dtsi
  ];

  dtbNoWifi = buildDtb "sg2002-licheerv-nano-bw-nowifi" [
    ./sg2002-licheerv-nano-bw.dtsi
    ./sg2002-licheerv-nano-bw-nowifi.dtsi
  ];

  leaseGuardTests = runCommand "sg2002-c906l-dtb-lease-guard-tests"
    {
      nativeBuildInputs = [ dtc python3 ];
    } ''
    for fixture in enabled-overlap disabled-overlap non-overlap; do
      dtc -q -I dts -O dtb \
        -o "$TMPDIR/$fixture.dtb" \
        ${./fixtures}/c906l-lease-$fixture.dts
    done

    if python3 ${./verify-c906l-leases.py} \
      --dtc ${dtc}/bin/dtc \
      --dtb "$TMPDIR/enabled-overlap.dtb" \
      >"$TMPDIR/enabled.stdout" 2>"$TMPDIR/enabled.stderr"; then
      echo "enabled overlapping Linux node unexpectedly passed" >&2
      exit 1
    fi
    grep -F \
      "enabled Linux node /soc/timer-channel@50 MMIO [0x30a0050,0x30a0064) overlaps C906L lease [0x30a0050,0x30a0064)" \
      "$TMPDIR/enabled.stderr"

    python3 ${./verify-c906l-leases.py} \
      --dtc ${dtc}/bin/dtc \
      --dtb "$TMPDIR/disabled-overlap.dtb"
    python3 ${./verify-c906l-leases.py} \
      --dtc ${dtc}/bin/dtc \
      --dtb "$TMPDIR/non-overlap.dtb"
    touch "$out"
  '';

  # Contract-specific DT for the FSBL-started C906L.  Its FIP and this DTB are
  # an atomic pair: Linux must never allocate from the final 2 MiB while the
  # auxiliary core is executing there, and Linux must never activate a lease
  # unless every generated identity field matches the running firmware.
  buildC906LDtb = name: carrierOverlays: contract:
    let
      unchecked = buildDtb "${name}-${contract.profileName}-unchecked"
        (carrierOverlays ++ [ "${contract}/dts/sg2002-c906l-contract.dtsi" ]);
      expectedCapabilities = contract.requiredCapabilities;
      dormantCapabilities = contract.dormantCapabilities;
      leaseMask = contract.leaseMask;
      profileId = contract.profileId;
      activationRequired = contract.contract.profile.activationRequired;
    in
    runCommand "${name}-${contract.profileName}.dtb"
      {
        nativeBuildInputs = [ dtc python3 ];
        passthru = c906lMemoryMap // {
          inherit
            (contract)
            contractEpoch
            contractSha256
            dormantCapabilities
            enabledPeripherals
            leaseMask
            manifestFlags
            profileId
            profileName
            protocolVersion
            requiredCapabilities
            ;
          tests.leaseGuard = leaseGuardTests;
        };
      } ''
      cp ${unchecked} "$out"

      test "$(fdtget -t x "$out" /reserved-memory/c906l-firmware@8fe00000 reg)" = \
        "${lib.toLower (lib.toHexString c906lMemoryMap.firmwareAddress)} ${lib.toLower (lib.toHexString c906lMemoryMap.firmwareSize)}"
      test "$(fdtget -t x "$out" /reserved-memory/c906l-shmem@8ff00000 reg)" = \
        "${lib.toLower (lib.toHexString c906lMemoryMap.sharedMemoryAddress)} ${lib.toLower (lib.toHexString c906lMemoryMap.sharedMemorySize)}"
      test "$(fdtget -t s "$out" /c906l-control compatible)" = \
        "sophgo,sg2002-c906l-control"
      test "$(fdtget -t s "$out" /c906l-rproc compatible)" = \
        "sophgo,sg2002-c906l-rproc"
      for node in /c906l-control /c906l-rproc; do
        digest="$(for byte in $(fdtget -t bx "$out" "$node" sophgo,contract-sha256); do
          printf '%02x' "0x$byte"
        done)"
        test "$digest" = ${contract.contractSha256}
        test "$(fdtget -t x "$out" "$node" sophgo,contract-epoch)" = \
          "${lib.toLower (lib.toHexString contract.contractEpoch)}"
        test "$(fdtget -t x "$out" "$node" sophgo,abi-version)" = \
          "${lib.toLower (lib.toHexString (contract.protocolVersion.major * 65536 + contract.protocolVersion.minor))}"
        test "$(fdtget -t x "$out" "$node" sophgo,expected-capabilities)" = \
          "0 ${lib.toLower (lib.toHexString expectedCapabilities)}"
        test "$(fdtget -t x "$out" "$node" sophgo,dormant-capabilities)" = \
          "0 ${lib.toLower (lib.toHexString dormantCapabilities)}"
        test "$(fdtget -t x "$out" "$node" sophgo,lease-mask)" = \
          "0 ${lib.toLower (lib.toHexString leaseMask)}"
        test "$(fdtget -t x "$out" "$node" sophgo,profile-id)" = \
          "${lib.toLower (lib.toHexString profileId)}"
        test "$(fdtget -t x "$out" "$node" sophgo,manifest-flags)" = \
          "${lib.toLower (lib.toHexString contract.manifestFlags)}"
        test "$(fdtget -t s "$out" "$node" sophgo,profile)" = \
          ${lib.escapeShellArg contract.profileName}
        ${if activationRequired then ''
          fdtget "$out" "$node" sophgo,activation-required >/dev/null
        '' else ''
          if fdtget "$out" "$node" sophgo,activation-required >/dev/null 2>&1; then
            echo "unexpected activation-required property on base profile" >&2
            exit 1
          fi
        ''}
      done
      set -- $(fdtget -t x "$out" /c906l-rproc mboxes)
      test "$#" -eq 6
      test "$1" = "$4"
      test "$2 $3 $5 $6" = "1 2 2 2"
      test "$(fdtget -t s "$out" /c906l-rproc mbox-names)" = \
        "vq-kick vq-notify"
      test "$(fdtget -t s "$out" /soc/mailbox@1900000 compatible)" = \
        "sophgo,cv1800b-mailbox"
      python3 ${./verify-c906l-leases.py} \
        --dtc ${dtc}/bin/dtc \
        --dtb "$out"
    '';

  dtbNoWifiC906LFor = buildC906LDtb
    "sg2002-licheerv-nano-bw-nowifi-c906l"
    [
      ./sg2002-licheerv-nano-bw.dtsi
      ./sg2002-licheerv-nano-bw-nowifi.dtsi
    ];

  # LicheeRV-Nano with the RJ45 wired: gmac0 + internal EPHY on.
  dtbEth = buildDtb "sg2002-licheerv-nano-bw-eth" [
    ./sg2002-licheerv-nano-bw.dtsi
    ./sg2002-licheerv-eth.dtsi
  ];

  # Full-speed USB fallbacks for the bare Nano. The carrier description
  # runs high-speed (validated on the Nano W, 2026-09-19); these keep the
  # old 12 Mbit/s link for A/B diagnostics and for host ports that fail
  # high-speed enumeration.
  dtbFullSpeed = buildDtb "sg2002-licheerv-nano-bw-full-speed" [
    ./sg2002-licheerv-nano-bw.dtsi
    ./sg2002-usb-full-speed.dtsi
  ];

  dtbNoWifiFullSpeed = buildDtb "sg2002-licheerv-nano-bw-nowifi-full-speed" [
    ./sg2002-licheerv-nano-bw.dtsi
    ./sg2002-licheerv-nano-bw-nowifi.dtsi
    ./sg2002-usb-full-speed.dtsi
  ];

  # PicoClaw: keep the proven no-WiFi USB/NFS base, then add the onboard
  # ST7789 SPI panel and its three GPIO control lines. The carrier stays
  # at full-speed. Retested at high-speed on 2026-09-19 with the shipped
  # FIFO layout: the 2026-08 -71 EPROTO enumeration errors did not return
  # and throughput matched the Nano W (225/181 Mbit/s), but 12 minutes
  # into a board-to-host soak the gadget's bulk-IN path stopped completing
  # requests with no kernel message on either side; EP0 and bulk-OUT kept
  # working, and only a host-side port reset brought usb0 back. Two later
  # soaks of 20 and 30 minutes were clean. A transport that can silently
  # stop is worse than one that is slow, so the pin remains until that
  # wedge is understood; picoclaw-lcd-high-speed is the retest DTB.
  dtbPicoClawLcd = buildDtb "sg2002-licheerv-nano-picoclaw-lcd" [
    ./sg2002-licheerv-nano-bw.dtsi
    ./sg2002-licheerv-nano-bw-nowifi.dtsi
    ./sg2002-licheerv-nano-picoclaw-lcd.dtsi
    ./sg2002-usb-full-speed.dtsi
  ];

  # PicoClaw WiFi-root variant: retain the B-W board's SDIO1/AIC8800
  # wiring while adding the ST7789 panel. The LCD consumes SPI1/GPIOs,
  # not the SDIO1 pins, so the overlays can coexist.
  dtbPicoClawLcdWifi = buildDtb "sg2002-licheerv-nano-picoclaw-lcd-wifi" [
    ./sg2002-licheerv-nano-bw.dtsi
    ./sg2002-licheerv-nano-picoclaw-lcd.dtsi
    ./sg2002-usb-full-speed.dtsi
  ];

  # Opt-in high-speed PicoClaw for retesting that carrier.
  dtbPicoClawLcdHighSpeed = buildDtb "sg2002-licheerv-nano-picoclaw-lcd-high-speed" [
    ./sg2002-licheerv-nano-bw.dtsi
    ./sg2002-licheerv-nano-bw-nowifi.dtsi
    ./sg2002-licheerv-nano-picoclaw-lcd.dtsi
  ];

  # Dedicated auxiliary-core LCD image.  This deliberately does not compose
  # the Linux spidev LCD overlay: SPI1 and the complete GPIOA bank belong to
  # the C906L, while the Linux control endpoint retains the shared pad/clock
  # preparation resources for the lifetime of the activated lease.
  dtbPicoClawC906LLcdFor = contract:
    assert lib.assertMsg (contract.profileName == "picoclaw-lcd")
      "the PicoClaw C906L LCD DT requires the picoclaw-lcd contract profile";
    let
      digestCells = lib.concatStringsSep " " (lib.genList
        (index: builtins.substring (index * 2) 2 contract.contractSha256)
        32);
      framebufferContractOverlay = writeText
        "sg2002-c906l-picoclaw-framebuffer-contract.dtsi" ''
        / {
          c906l_wifi_power: c906l-wifi-power {
            compatible = "sophgo,sg2002-c906l-wifi-power";
            memory-region = <&c906l_shmem>;
            sophgo,contract-sha256 = [${digestCells}];
            regulator-name = "picoclaw-wifi-power";
            regulator-min-microvolt = <3300000>;
            regulator-max-microvolt = <3300000>;
          };
          c906l-framebuffer {
            compatible = "sophgo,sg2002-c906l-framebuffer";
            memory-region = <&c906l_shmem>;
            sophgo,contract-sha256 = [${digestCells}];
            sophgo,contract-epoch = <${toString contract.contractEpoch}>;
            sophgo,abi-version = <0x${lib.toHexString (contract.protocolVersion.major * 65536 + contract.protocolVersion.minor)}>;
            sophgo,expected-capabilities = /bits/ 64 <0x${lib.toHexString contract.requiredCapabilities}>;
            sophgo,dormant-capabilities = /bits/ 64 <0x${lib.toHexString contract.dormantCapabilities}>;
            sophgo,lease-mask = /bits/ 64 <0x${lib.toHexString contract.leaseMask}>;
            sophgo,profile-id = <0x${lib.toHexString contract.profileId}>;
            sophgo,manifest-flags = <0x${lib.toHexString contract.manifestFlags}>;
            sophgo,profile = "${contract.profileName}";
            sophgo,activation-required;
          };
        };
      '';
      composed = buildC906LDtb
        "sg2002-licheerv-nano-picoclaw-c906l-lcd"
        [
          ./sg2002-licheerv-nano-bw.dtsi
          ./sg2002-licheerv-nano-bw-nowifi.dtsi
          ./sg2002-licheerv-nano-picoclaw-c906l-lcd.dtsi
          framebufferContractOverlay
          ./sg2002-usb-full-speed.dtsi
        ]
        contract;
    in
    runCommand "sg2002-licheerv-nano-picoclaw-c906l-lcd-verified.dtb"
      {
        nativeBuildInputs = [ dtc python3 ];
        passthru = c906lMemoryMap // {
          boardProfile = "picoclaw-c906l-lcd";
          wifiPowerProvider = "c906l-regulator";
          inherit
            (contract)
            contractEpoch
            contractSha256
            dormantCapabilities
            enabledPeripherals
            leaseMask
            manifestFlags
            profileId
            profileName
            protocolVersion
            requiredCapabilities
            ;
          tests.leaseGuard = leaseGuardTests;
        };
      } ''
      cp ${composed} "$out"
      test "$(fdtget -t s "$out" / model)" = \
        "Sipeed LicheeRV Nano PicoClaw (C906L LCD)"
      for node in \
        /soc/spi@4190000 \
        /soc/gpio@3020000 \
        /soc/i2c@4000000 \
        /soc/ethernet@4070000; do
        test "$(fdtget -t s "$out" "$node" status)" = disabled
      done
      fdtget "$out" /c906l-control sophgo,picoclaw-lcd-handoff >/dev/null
      test "$(fdtget -t s "$out" /c906l-framebuffer compatible)" = \
        sophgo,sg2002-c906l-framebuffer
      test "$(fdtget -t x "$out" /c906l-framebuffer memory-region)" = \
        "$(fdtget -t x "$out" /c906l-control memory-region)"
      framebuffer_digest="$(for byte in $(fdtget -t bx "$out" \
        /c906l-framebuffer sophgo,contract-sha256); do
        printf '%02x' "0x$byte"
      done)"
      test "$framebuffer_digest" = ${contract.contractSha256}
      test "$(fdtget -t s "$out" /c906l-framebuffer sophgo,profile)" = \
        picoclaw-lcd
      test "$(fdtget -t s "$out" /c906l-control pinctrl-names)" = \
        picoclaw-lcd-handoff
      test "$(fdtget -t s "$out" /c906l-control clock-names)" = "spi pclk"
      test "$(fdtget -t s "$out" /c906l-control reset-names)" = "spi gpio"
      test "$(fdtget -t u "$out" /c906l-control sophgo,spi-clock-hz)" = \
        187500000
      test "$(fdtget -t u "$out" /c906l-control sophgo,pclk-hz)" = \
        300000000
      if fdtget "$out" /soc/mmc@4320000 wifi-power-gpios >/dev/null 2>&1; then
        echo "Linux WiFi node still claims C906L-owned GPIOA26" >&2
        exit 1
      fi
      if fdtget "$out" /soc/mmc@4320000 sophgo,wifi-power-pinmux-reg >/dev/null 2>&1; then
        echo "Linux SDIO still overrides the C906L Wi-Fi power pinmux" >&2
        exit 1
      fi
      test "$(fdtget -t s "$out" /soc/mmc@4320000 status)" = okay
      test "$(fdtget -t s "$out" /soc/mmc@4320000 clock-names)" = "core bus timer"
      set -- $(fdtget -t x "$out" /c906l-control clocks)
      clock_provider="$1"
      set -- $(fdtget -t x "$out" /soc/mmc@4320000 clocks)
      test "$#" -eq 6
      test "$1 $3 $5" = "$clock_provider $clock_provider $clock_provider"
      # CLK_AXI4_SD1, CLK_SD1 and CLK_SD1_100K from sophgo,cv1800.h.
      test "$2 $4 $6" = "1e 1f 20"
      test "$(fdtget -t x "$out" /soc/mmc@4320000 vmmc-supply)" = \
        "$(fdtget -t x "$out" /c906l-wifi-power phandle)"
      test "$(fdtget -t x "$out" /c906l-wifi-power memory-region)" = \
        "$(fdtget -t x "$out" /c906l-control memory-region)"
      test "$(fdtget -t bx "$out" /c906l-wifi-power sophgo,contract-sha256)" = \
        "$(fdtget -t bx "$out" /c906l-framebuffer sophgo,contract-sha256)"
      ${dtc}/bin/dtc -q -I dtb -O dts "$out" > "$TMPDIR/final.dts"
      if grep -F 'picoclaw-lcd-status' "$TMPDIR/final.dts"; then
        echo "Linux PicoClaw LCD consumer leaked into the C906L DT" >&2
        exit 1
      fi
    '';

  # NanoKVM-PCIe: bw.dtsi (WiFi/SDIO1 on) + ethernet enable overlay.
  dtbPcie = buildDtb "sg2002-nanokvm-pcie" [
    ./sg2002-licheerv-nano-bw.dtsi
    ./sg2002-nanokvm-pcie.dtsi
  ];

  # LicheeRV-Nano with the GC4653 camera FFC: ethernet + camera overlay
  # (IIC4 on PWR_WAKEUP0/PWR_BUTTON1, CAM_MCLK1 on MIPIRX0N, sensor reset
  # on GPIOE1, 2-lane CSI capture).
  dtbCam = buildDtb "sg2002-licheerv-nano-bw-cam" [
    ./sg2002-licheerv-nano-bw.dtsi
    ./sg2002-licheerv-nano-bw-nowifi.dtsi
    ./sg2002-licheerv-eth.dtsi
    ./sg2002-licheerv-camera-gc4653.dtsi
  ];

  dtbPcieNoWifi = buildDtb "sg2002-nanokvm-pcie-nowifi" [
    ./sg2002-licheerv-nano-bw.dtsi
    ./sg2002-nanokvm-pcie.dtsi
    ./sg2002-licheerv-nano-bw-nowifi.dtsi
  ];

  # Product-carrier C906L composition.  Keep every PCIe carrier resource
  # (SD0, Ethernet, OLED wiring and the capture/media pipeline), disable only
  # the optional SDIO WiFi function, then reserve the top-of-RAM firmware and
  # transport carveouts.  This must remain distinct from the LicheeRV-Nano
  # bring-up DT above: selecting that DT on the product would silently drop
  # most of the carrier hardware.
  dtbPcieNoWifiC906LFor = contract:
    let
      composed = buildC906LDtb
        "sg2002-nanokvm-pcie-nowifi-c906l"
        [
          ./sg2002-licheerv-nano-bw.dtsi
          ./sg2002-nanokvm-pcie.dtsi
          ./sg2002-licheerv-nano-bw-nowifi.dtsi
        ]
        contract;
    in
    runCommand "sg2002-nanokvm-pcie-nowifi-c906l-${contract.profileName}-verified.dtb"
      {
        nativeBuildInputs = [ dtc python3 ];
        passthru = c906lMemoryMap // {
          inherit
            (contract)
            contractEpoch
            contractSha256
            dormantCapabilities
            enabledPeripherals
            leaseMask
            manifestFlags
            profileId
            profileName
            protocolVersion
            requiredCapabilities
            ;
          tests.leaseGuard = leaseGuardTests;
        };
      } ''
      cp ${composed} "$out"
      test "$(fdtget -t s "$out" /soc/ethernet@4070000 status)" = okay
      test "$(fdtget -t s "$out" /soc/mmc@4310000 status)" = okay
      test "$(fdtget -t s "$out" /soc/i2c@4040000 status)" = okay
      test "$(fdtget -t s "$out" /video-capture@a0c2000 compatible)" = \
        "sophgo,sg2002-csi-capture"
      test "$(fdtget -t s "$out" /vpss@a080000 status)" = okay
    '';

  # NanoKVM-PCIe full-speed fallback; the carrier's high-speed link has
  # not been separately validated, so this remains available for A/Bs.
  dtbPcieFullSpeed = buildDtb "sg2002-nanokvm-pcie-full-speed" [
    ./sg2002-licheerv-nano-bw.dtsi
    ./sg2002-nanokvm-pcie.dtsi
    ./sg2002-usb-full-speed.dtsi
  ];

  dtbs = runCommand "sg2002-dtbs" { } ''
    mkdir -p $out/sophgo
    cp ${dtb} $out/sophgo/sg2002-licheerv-nano-bw.dtb
  '';
in
{
  inherit dtb dtbs;
  full-speed = dtbFullSpeed;
  eth = dtbEth;
  oled = dtbOled;
  nowifi = dtbNoWifi;
  nowifi-c906l-for = dtbNoWifiC906LFor;
  nowifi-full-speed = dtbNoWifiFullSpeed;
  picoclaw-lcd = dtbPicoClawLcd;
  picoclaw-lcd-wifi = dtbPicoClawLcdWifi;
  picoclaw-lcd-high-speed = dtbPicoClawLcdHighSpeed;
  picoclaw-c906l-lcd-for = dtbPicoClawC906LLcdFor;
  pcie = dtbPcie;
  pcie-nowifi = dtbPcieNoWifi;
  pcie-nowifi-c906l-for = dtbPcieNoWifiC906LFor;
  pcie-full-speed = dtbPcieFullSpeed;
  cam = dtbCam;
}
