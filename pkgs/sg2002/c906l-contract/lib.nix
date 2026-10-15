{ lib }:

let
  rawContract = builtins.fromJSON (builtins.readFile ./contract.json);

  fail = message: throw "SG2002 C906L contract: ${message}";
  require = condition: message:
    if condition then true else fail message;

  hexDigits = {
    "0" = 0;
    "1" = 1;
    "2" = 2;
    "3" = 3;
    "4" = 4;
    "5" = 5;
    "6" = 6;
    "7" = 7;
    "8" = 8;
    "9" = 9;
    a = 10;
    b = 11;
    c = 12;
    d = 13;
    e = 14;
    f = 15;
  };

  parseHex = value:
    let
      lowered = lib.toLower value;
      valid = builtins.match "^0x[0-9a-f]+$" lowered != null;
      digits = lib.stringToCharacters (lib.removePrefix "0x" lowered);
    in
    if !valid then
      fail "invalid hexadecimal integer `${value}`"
    else
      lib.foldl' (total: digit: total * 16 + hexDigits.${digit}) 0 digits;

  parseNatural = value:
    if builtins.isInt value && value >= 0 then
      value
    else if builtins.isString value then
      parseHex value
    else
      fail "expected a non-negative integer or 0x-prefixed string";

  normalize = value:
    if builtins.isList value then
      map normalize value
    else if builtins.isAttrs value then
      lib.mapAttrs (_: normalize) value
    else if builtins.isString value
      && builtins.match "^0[xX][0-9a-fA-F]+$" value != null
    then
      parseHex value
    else
      value;

  # Documentation-only edits must not invalidate a running firmware contract.
  # The epoch exists for maintainers to deliberately invalidate every profile.
  stripDocumentation = value:
    if builtins.isList value then
      map stripDocumentation value
    else if builtins.isAttrs value then
      lib.mapAttrs (_: stripDocumentation)
        (builtins.removeAttrs value [ "description" "spdxLicense" ])
    else
      value;

  contract = normalize rawContract;
  names = builtins.attrNames;
  values = builtins.attrValues;
  allUnique = list: builtins.length list == builtins.length (lib.unique list);
  powerOfTwo = value: value > 0 && builtins.bitAnd value (value - 1) == 0;
  pow2 = exponent: if exponent == 0 then 1 else 2 * pow2 (exponent - 1);
  validKey = value:
    builtins.isString value
    && builtins.match "^[a-z][A-Za-z0-9]*$" value != null;
  validSlug = value:
    builtins.isString value
    && builtins.match "^[a-z][a-z0-9-]*$" value != null;
  uppercase = lib.stringToCharacters "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
  macroName = value:
    lib.toUpper (builtins.replaceStrings
      (uppercase ++ [ "-" ])
      ((map (character: "_${character}") uppercase) ++ [ "_" ])
      value);

  # These are the four DW APB timer slices routed to C906L on SG2002.  Keep
  # the SoC-specific topology here instead of accepting arbitrary addresses
  # that merely happen to fit inside the timer bank.
  sg2002TimerDescriptors = {
    timer4 = {
      channel = 4;
      irq = 55;
      leaseBit = 0;
      capabilityBit = 2;
      failureFlagBit = 2;
      gateMask = parseHex "0x00002000";
      resetMask = parseHex "0x00040000";
      sourceMask = parseHex "0x00000010";
    };
    timer5 = {
      channel = 5;
      irq = 56;
      leaseBit = 1;
      capabilityBit = 4;
      failureFlagBit = 8;
      gateMask = parseHex "0x00004000";
      resetMask = parseHex "0x00080000";
      sourceMask = parseHex "0x00000020";
    };
    timer6 = {
      channel = 6;
      irq = 57;
      leaseBit = 2;
      capabilityBit = 5;
      failureFlagBit = 9;
      gateMask = parseHex "0x00008000";
      resetMask = parseHex "0x00100000";
      sourceMask = parseHex "0x00000040";
    };
    timer7 = {
      channel = 7;
      irq = 58;
      leaseBit = 3;
      capabilityBit = 6;
      failureFlagBit = 10;
      gateMask = parseHex "0x00010000";
      resetMask = parseHex "0x00200000";
      sourceMask = parseHex "0x00000080";
    };
  };

  mkExpectedSg2002Timer = peripheralName: descriptor:
    let
      channelName = toString descriptor.channel;
      channelAddress = parseHex "0x030a0000" + descriptor.channel * 20;
    in
    {
      kind = "dw-apb-timer-channel";
      inherit (descriptor) leaseBit irq;
      cargoFeature = peripheralName;
      capability = "${peripheralName}SelfTest";
      failureFlag = "${peripheralName}SelfTestFailed";
      bank = {
        address = parseHex "0x030a0000";
        size = parseHex "0x00010000";
        ownership = "shared-bank-exclusive-channel";
        channel = descriptor.channel;
      };
      registers = {
        load = {
          address = channelAddress;
          access = "read-write";
        };
        current = {
          address = channelAddress + 4;
          access = "read-only";
        };
        control = {
          address = channelAddress + 8;
          access = "read-write";
        };
        eoi = {
          address = channelAddress + 12;
          access = "read-clear";
        };
        status = {
          address = channelAddress + 16;
          access = "read-only";
        };
      };
      sharedPreconditions = {
        clockXtalMisc = {
          address = parseHex "0x03002000";
          mask = parseHex "0x00004000";
          expected = parseHex "0x00004000";
          access = "read-only";
        };
        resetTimerIp = {
          address = parseHex "0x03003008";
          mask = parseHex "0x00002000";
          expected = parseHex "0x00002000";
          access = "read-only";
        };
        clockSource = {
          address = parseHex "0x030001a0";
          mask = descriptor.sourceMask;
          expected = 0;
          access = "read-only";
        };
      } // {
        "clockTimer${channelName}" = {
          address = parseHex "0x0300200c";
          mask = descriptor.gateMask;
          expected = descriptor.gateMask;
          access = "read-only";
        };
        "resetTimer${channelName}" = {
          address = parseHex "0x03003008";
          mask = descriptor.resetMask;
          expected = descriptor.resetMask;
          access = "read-only";
        };
      };
      selfTest = {
        clockHz = 25000000;
        periodTicks = 2500000;
        timeoutRtosTicks = 100;
        rtosTickHz = 200;
      };
      linuxLease = {
        policy = "static-exclusive-subresource";
        mustNotClaimIrq = descriptor.irq;
        mustNotAccessChannel = descriptor.channel;
        sharedGlobalRegisters = "read-only";
      };
    };

  expectedSg2002Timers = lib.mapAttrs mkExpectedSg2002Timer
    sg2002TimerDescriptors;
  validateNames = groupName: entries:
    let
      entryNames = names entries;
      macroNames = map macroName entryNames;
    in
    builtins.deepSeq [
      (require (lib.all validKey entryNames)
        "${groupName} contains a key that cannot be emitted safely")
      (require (allUnique macroNames)
        "${groupName} contains colliding generated identifiers")
    ]
      true;

  expectedMessage = {
    size = 8;
    alignment = 8;
    fields = [
      { name = "service"; offset = 0; width = 1; }
      { name = "opcode"; offset = 1; width = 1; }
      { name = "sequence"; offset = 2; width = 2; }
      { name = "value"; offset = 4; width = 4; }
    ];
  };
  expectedStatus = {
    size = 64;
    alignment = 64;
    fields = [
      { name = "magic"; offset = 0; width = 4; }
      { name = "abiMajor"; offset = 4; width = 2; }
      { name = "abiMinor"; offset = 6; width = 2; }
      { name = "structSize"; offset = 8; width = 4; }
      { name = "state"; offset = 12; width = 4; }
      { name = "generation"; offset = 16; width = 4; }
      { name = "flags"; offset = 20; width = 4; }
      { name = "heartbeat"; offset = 24; width = 8; }
      { name = "capabilities"; offset = 32; width = 8; }
      { name = "lastRequest"; offset = 40; width = 8; }
      { name = "lastResponse"; offset = 48; width = 8; }
      { name = "activationState"; offset = 56; width = 1; }
      { name = "activationError"; offset = 57; width = 1; }
      { name = "activationAttempts"; offset = 58; width = 2; }
      { name = "activationRequestId"; offset = 60; width = 4; }
    ];
  };
  expectedManifestFields = [
    { name = "magic"; offset = 0; width = 4; }
    { name = "formatMajor"; offset = 4; width = 2; }
    { name = "formatMinor"; offset = 6; width = 2; }
    { name = "structSize"; offset = 8; width = 4; }
    { name = "generation"; offset = 12; width = 4; }
    { name = "contractEpoch"; offset = 16; width = 4; }
    { name = "profileId"; offset = 20; width = 4; }
    { name = "abiMajor"; offset = 24; width = 2; }
    { name = "abiMinor"; offset = 26; width = 2; }
    { name = "capabilityWidth"; offset = 28; width = 2; }
    { name = "leaseWidth"; offset = 30; width = 2; }
    { name = "finalCapabilities"; offset = 32; width = 8; }
    { name = "dormantCapabilities"; offset = 40; width = 8; }
    { name = "leaseMask"; offset = 48; width = 8; }
    { name = "flags"; offset = 56; width = 4; }
    { name = "reserved0"; offset = 60; width = 4; }
    { name = "contractSha256"; offset = 64; width = 32; }
    { name = "reserved1"; offset = 96; width = 28; }
    { name = "commit"; offset = 124; width = 4; }
  ];
  expectedRequestFields = [
    { name = "magic"; offset = 0; width = 4; }
    { name = "formatMajor"; offset = 4; width = 2; }
    { name = "formatMinor"; offset = 6; width = 2; }
    { name = "structSize"; offset = 8; width = 4; }
    { name = "generation"; offset = 12; width = 4; }
    { name = "requestId"; offset = 16; width = 4; }
    { name = "contractEpoch"; offset = 20; width = 4; }
    { name = "profileId"; offset = 24; width = 4; }
    { name = "abiVersion"; offset = 28; width = 4; }
    { name = "finalCapabilities"; offset = 32; width = 8; }
    { name = "leaseMask"; offset = 40; width = 8; }
    { name = "contractSha256"; offset = 48; width = 32; }
    { name = "reserved"; offset = 80; width = 44; }
    { name = "commit"; offset = 124; width = 4; }
  ];

  validateFields = recordName: record:
    let
      result = lib.foldl'
        (state: field:
          let
            fieldEnd = field.offset + field.width;
          in
          builtins.deepSeq [
            (require (builtins.isString field.name && field.name != "")
              "${recordName} contains an unnamed field")
            (require (field.offset == state.next)
              "${recordName}.${field.name} starts at ${toString field.offset}, expected ${toString state.next}")
            (require (builtins.elem field.width [ 1 2 4 8 28 32 44 ])
              "${recordName}.${field.name} has unsupported width ${toString field.width}")
            (require (fieldEnd <= record.size)
              "${recordName}.${field.name} extends past the record")
          ]
            {
              next = fieldEnd;
              fieldNames = state.fieldNames ++ [ field.name ];
            }
        )
        { next = 0; fieldNames = [ ]; }
        record.fields;
    in
    builtins.deepSeq [
      (require (powerOfTwo record.alignment)
        "${recordName} alignment must be a power of two")
      (require (record.size > 0 && lib.mod record.size record.alignment == 0)
        "${recordName} size must be a positive multiple of its alignment")
      (require (result.next == record.size)
        "${recordName} fields do not exactly fill its declared size")
      (require (allUnique result.fieldNames)
        "${recordName} contains duplicate field names")
    ]
      true;

  validateBits = groupName: width: entries:
    let bits = map (entry: entry.bit) (values entries);
    in builtins.deepSeq [
      (require (allUnique bits) "${groupName} contains duplicate bit assignments")
      (require (lib.all (bit: builtins.isInt bit && bit >= 0 && bit < width) bits)
        "${groupName} contains a bit outside its ${toString width}-bit field")
    ]
      true;

  dramStart = contract.soc.dram.address;
  dramEnd = dramStart + contract.soc.dram.size;
  firmwareEnd = contract.memory.firmware.address + contract.memory.firmware.size;
  shared = contract.memory.shared;
  sharedEnd = shared.address + shared.size;
  pageSize = 4096;
  orderedRegions = lib.sort
    (left: right: left.offset < right.offset)
    (values shared.regions);
  regionPartition = lib.foldl'
    (state: region:
      builtins.deepSeq [
        (require (region.size > 0) "shared-memory regions must not be empty")
        (require
          (lib.mod region.offset pageSize == 0
            && lib.mod region.size pageSize == 0)
          "shared-memory regions must be page-aligned")
        (require (region.offset == state.next)
          "shared-memory regions overlap or leave a hole at offset ${toString state.next}")
      ]
        { next = region.offset + region.size; }
    )
    { next = 0; }
    orderedRegions;

  mailbox = contract.soc.mailbox;
  mailboxChannels = values mailbox.channels;
  mailboxProcessorIds = values mailbox.processorIds;
  mailboxHwspin = mailbox.hardwareSpinlock;
  mailboxHwspinBase = mailbox.address + mailboxHwspin.registerOffset;
  mailboxHwspinEnd = mailboxHwspinBase
    + mailboxHwspin.registerCount * mailboxHwspin.registerStride;
  mailboxHwspinTokenValueMask = pow2 mailboxHwspin.tokenWidth - 1;
  mailboxHwspinLinuxTokenMask = mailboxHwspinTokenValueMask
    * pow2 mailboxHwspin.linuxTokenShift;
  mailboxHwspinC906lTokenMask = mailboxHwspinTokenValueMask
    * pow2 mailboxHwspin.c906lTokenShift;
  rpmsg = contract.rpmsg;
  resourceRegion = shared.regions.${rpmsg.resourceTable.region};
  vring0Region = shared.regions.${rpmsg.vrings.driverToDeviceRegion};
  vring1Region = shared.regions.${rpmsg.vrings.deviceToDriverRegion};
  bufferRegion = shared.regions.${rpmsg.buffers.region};
  driverRingBytes = 16 * rpmsg.vrings.descriptors
    + 6 + 2 * rpmsg.vrings.descriptors;
  usedRingBytes = 6 + 8 * rpmsg.vrings.descriptors;

  validateTimerPeripheral = peripheralName: peripheral:
    let
      registerAddresses = map (register: register.address)
        (values peripheral.registers);
      bankStart = peripheral.bank.address;
      bankEnd = bankStart + peripheral.bank.size;
    in
    builtins.deepSeq [
      (require (builtins.hasAttr peripheralName expectedSg2002Timers)
        "`${peripheralName}` is not a C906L-routed SG2002 timer channel")
      (require
        (builtins.hasAttr peripheralName expectedSg2002Timers
          && peripheral == expectedSg2002Timers.${peripheralName})
        "peripheral `${peripheralName}` does not match the exact SG2002 timer topology")
      (require (builtins.hasAttr peripheral.failureFlag contract.abi.flags)
        "peripheral `${peripheralName}` names an unknown failure flag")
      (require (validSlug peripheral.cargoFeature)
        "peripheral `${peripheralName}` has an unsafe Cargo feature name")
      (validateNames "peripherals.${peripheralName}.registers"
        peripheral.registers)
      (validateNames "peripherals.${peripheralName}.sharedPreconditions"
        peripheral.sharedPreconditions)
      (require (allUnique registerAddresses)
        "peripheral `${peripheralName}` contains duplicate register addresses")
      (require
        (lib.all (address: address >= bankStart && address + 4 <= bankEnd)
          registerAddresses)
        "peripheral `${peripheralName}` register lies outside its bank")
      (require
        (lib.all
          (precondition:
            precondition.access == "read-only"
            && builtins.bitAnd precondition.expected precondition.mask
            == precondition.expected
          )
          (values peripheral.sharedPreconditions))
        "peripheral `${peripheralName}` has an invalid shared-register precondition")
      (require
        (peripheral.selfTest.clockHz > 0
          && peripheral.selfTest.periodTicks > 0
          && peripheral.selfTest.timeoutRtosTicks > 0
          && peripheral.selfTest.rtosTickHz > 0)
        "peripheral `${peripheralName}` self-test timing must be positive")
    ]
      true;

  # Board wiring, ownership protocol and padding are one frozen composite
  # lease. Keep its semantic fingerprint explicit, as with the exact timer
  # topology above: edits require deliberate review of both validators.
  validateLcdPeripheral = peripheralName: peripheral:
    builtins.deepSeq [
      (require (peripheralName == "picoclawLcd")
        "the LCD descriptor must use the PicoClaw lease identity")
      (require
        (builtins.hashString "sha256" (builtins.toJSON (stripDocumentation peripheral))
          == "0cf1c1b2130feaef12138e6eeb181ae093ef369da3689725fccf065392f41133")
        "PicoClaw LCD does not match the frozen board and framebuffer contract")
      (require
        (contract.abi.capabilities.picoclawLcd.bit == 7
          && contract.abi.flags.picoclawLcdFailed.bit == 11)
        "PicoClaw LCD has incorrect ABI capability/status bits")
      (require
        (shared.address + shared.regions.bulk.offset
          == peripheral.constants.ownership0Address
          && peripheral.constants.frameSlot1Address + peripheral.constants.frameSize
          <= shared.address + shared.regions.bulk.offset + shared.regions.bulk.size)
        "PicoClaw framebuffer does not fit the shared bulk region")
    ]
      true;

  validatePeripheral = peripheralName: peripheral:
    builtins.deepSeq [
      (require (validKey peripheralName)
        "peripheral `${peripheralName}` has an unsafe name")
      (require (builtins.isString peripheral.kind)
        "peripheral `${peripheralName}` has no kind")
      (require (builtins.hasAttr peripheral.capability contract.abi.capabilities)
        "peripheral `${peripheralName}` names an unknown capability")
      (require
        (builtins.isInt peripheral.leaseBit
          && peripheral.leaseBit >= 0
          && peripheral.leaseBit < contract.activation.leaseWireWidth)
        "peripheral `${peripheralName}` has an invalid lease bit")
      (if peripheral.kind == "dw-apb-timer-channel" then
        validateTimerPeripheral peripheralName peripheral
      else if peripheral.kind == "picoclaw-st7789" then
        validateLcdPeripheral peripheralName peripheral
      else
        fail "peripheral `${peripheralName}` has unsupported kind `${peripheral.kind}`")
    ]
      true;

  validateTimerAbiAssignment = peripheralName: descriptor:
    let
      capabilityName = "${peripheralName}SelfTest";
      failureFlagName = "${peripheralName}SelfTestFailed";
    in
    builtins.deepSeq [
      (require
        (builtins.hasAttr capabilityName contract.abi.capabilities
          && contract.abi.capabilities.${capabilityName}.bit
          == descriptor.capabilityBit)
        "`${capabilityName}` does not use its assigned ABI capability bit")
      (require
        (builtins.hasAttr failureFlagName contract.abi.flags
          && contract.abi.flags.${failureFlagName}.bit
          == descriptor.failureFlagBit)
        "`${failureFlagName}` does not use its assigned ABI status-flag bit")
    ]
      true;

  baseCapabilities = contract.profiles.base.capabilities;
  peripheralValues = values contract.peripherals;
  timerValues = lib.filter (peripheral: peripheral.kind == "dw-apb-timer-channel")
    peripheralValues;
  peripheralCargoFeatures = map (peripheral: peripheral.cargoFeature)
    peripheralValues;
  peripheralCapabilities = map (peripheral: peripheral.capability)
    peripheralValues;
  peripheralFailureFlags = map (peripheral: peripheral.failureFlag)
    peripheralValues;
  peripheralIrqs = map (peripheral: peripheral.irq) timerValues;
  peripheralChannels = map (peripheral: peripheral.bank.channel)
    timerValues;
  peripheralRegisterAddresses = lib.concatMap
    (peripheral: map (register: register.address)
      (values peripheral.registers))
    timerValues;
  orderedPeripheralRanges = lib.sort
    (left: right: left.start < right.start)
    (map
      (peripheral: {
        start = peripheral.registers.load.address;
        end = peripheral.registers.status.address + 4;
      })
      timerValues);
  peripheralRangePartition = lib.foldl'
    (state: range:
      builtins.deepSeq
        (require (range.start >= state.next)
          "C906L timer channel register slices overlap")
        { next = range.end; })
    { next = 0; }
    orderedPeripheralRanges;

  validateProfile = profileName: profile:
    let
      unknownPeripherals = lib.filter
        (name: !builtins.hasAttr name contract.peripherals)
        profile.peripherals;
      unknownCapabilities = lib.filter
        (name: !builtins.hasAttr name contract.abi.capabilities)
        profile.capabilities;
      missingLeaseCapabilities = lib.filter
        (peripheralName:
          let capability = contract.peripherals.${peripheralName}.capability;
          in !builtins.elem capability profile.capabilities)
        profile.peripherals;
      expectedCapabilities = lib.unique
        (baseCapabilities ++ map
          (peripheralName: contract.peripherals.${peripheralName}.capability)
          profile.peripherals);
    in
    builtins.deepSeq [
      (require (profileName != "") "profile names must not be empty")
      (require (validSlug profileName)
        "profile `${profileName}` has an unsafe name")
      (require (allUnique profile.peripherals)
        "profile `${profileName}` contains duplicate peripherals")
      (require
        (!builtins.elem "picoclawLcd" profile.peripherals
          || profile.peripherals == [ "picoclawLcd" ])
        "PicoClaw LCD must be selected alone")
      (require (allUnique profile.capabilities)
        "profile `${profileName}` contains duplicate capabilities")
      (require (unknownPeripherals == [ ])
        "profile `${profileName}` names unknown peripherals: ${lib.concatStringsSep ", " unknownPeripherals}")
      (require (unknownCapabilities == [ ])
        "profile `${profileName}` names unknown capabilities: ${lib.concatStringsSep ", " unknownCapabilities}")
      (require (missingLeaseCapabilities == [ ])
        "profile `${profileName}` omits a selected peripheral capability")
      (require
        (
          lib.sort builtins.lessThan profile.capabilities
          == lib.sort builtins.lessThan expectedCapabilities
        ) "profile `${profileName}` capabilities are not exactly its base and lease capabilities")
    ]
      true;

  validation = [
    (require (contract.schemaVersion == 1) "unsupported schemaVersion")
    # Hardware protocol metadata and additive status-flag meanings are covered
    # by the semantic digest.  They do not change ABI 1.1's wire layouts or
    # framing, so this addition deliberately does not advance contractEpoch.
    (require (contract.contractEpoch == 2)
      "ABI 1.1 requires contractEpoch 2")
    (require (contract.abi.endianness == "little") "only the little-endian ABI is supported")
    (require (contract.abi.major == 1 && contract.abi.minor == 1)
      "this contract must describe the committed ABI 1.1")
    (require (contract.abi.magic == 1297501006) "unexpected status magic")
    (require (contract.abi.message == expectedMessage)
      "abi.message does not match the frozen schema-1 wire layout")
    (require (contract.abi.status == expectedStatus)
      "abi.status does not match the frozen schema-1 wire layout")
    (require (contract.activation.manifest.fields == expectedManifestFields)
      "activation.manifest does not match the frozen ABI-1.1 wire layout")
    (require (contract.activation.request.fields == expectedRequestFields)
      "activation.request does not match the frozen ABI-1.1 wire layout")
    (validateFields "abi.message" contract.abi.message)
    (validateFields "abi.status" contract.abi.status)
    (validateFields "activation.manifest" contract.activation.manifest)
    (validateFields "activation.request" contract.activation.request)
    (validateNames "abi.states" contract.abi.states)
    (validateNames "abi.services" contract.abi.services)
    (validateNames "abi.opcodes" contract.abi.opcodes)
    (validateNames "abi.capabilities" contract.abi.capabilities)
    (validateNames "abi.flags" contract.abi.flags)
    (validateNames "activation.states" contract.activation.states)
    (validateNames "activation.results" contract.activation.results)
    (validateNames "activation.manifestFlags"
      contract.activation.manifestFlags)
    (validateNames "soc.mailbox.channels" contract.soc.mailbox.channels)
    (validateNames "memory.shared.regions" contract.memory.shared.regions)
    (validateBits "abi.capabilities" contract.abi.capabilityWireWidth
      contract.abi.capabilities)
    (validateBits "abi.flags" 32 contract.abi.flags)
    (validateBits "activation.manifestFlags" 32
      contract.activation.manifestFlags)
    (require (allUnique (values contract.abi.states)) "ABI states are not unique")
    (require (allUnique (values contract.abi.services)) "ABI services are not unique")
    (require (allUnique (values contract.abi.opcodes)) "ABI opcodes are not unique")
    (require (contract.abi.capabilityWireWidth == 64)
      "ABI 1.1 capability width must be 64 bits")
    (require (contract.abi.opcodes.activateLeases == 4)
      "ABI 1.1 activation opcode must remain 0x04")
    (require (allUnique (values contract.activation.states))
      "activation states are not unique")
    (require
      (lib.all (value: value >= 0 && value < pow2 8)
        (values contract.activation.states))
      "activation states must fit their u8 status field")
    (require (allUnique (values contract.activation.results))
      "activation results are not unique")
    (require
      (lib.all (value: value >= 0 && value < pow2 8)
        (values contract.activation.results))
      "activation results must fit their u8 status field")
    (require
      (allUnique
        (map (peripheral: peripheral.leaseBit) (values contract.peripherals)))
      "peripheral lease bits are not unique")
    (require (names contract.peripherals == [ "picoclawLcd" ] ++ names expectedSg2002Timers)
      "the SG2002 C906L topology must contain PicoClaw LCD and Timer4 through Timer7")
    (require (allUnique peripheralCargoFeatures)
      "peripheral Cargo features are not unique")
    (require (allUnique peripheralCapabilities)
      "peripheral capabilities are not unique")
    (require (allUnique peripheralFailureFlags)
      "peripheral failure flags are not unique")
    (require (allUnique peripheralIrqs)
      "peripheral C906L IRQs are not unique")
    (require (allUnique peripheralChannels)
      "peripheral timer bank channels are not unique")
    (require (allUnique peripheralRegisterAddresses)
      "peripheral timer registers overlap")
    (require (peripheralRangePartition.next > 0)
      "the SG2002 C906L timer register range set is empty")
    (require
      (builtins.hasAttr "base" contract.profiles
        && contract.profiles.base.peripherals == [ ])
      "profiles.base must exist and have no peripheral leases")
    (require
      (builtins.match "^[A-Za-z0-9._-]+$"
        contract.rpmsg.echoService.name != null)
      "RPMsg service name cannot be emitted safely")
    (require (powerOfTwo contract.soc.cacheLineSize)
      "cacheLineSize must be a power of two")
    (require (contract.abi.status.size == contract.soc.cacheLineSize)
      "status must occupy exactly one cache line")
    (require
      (
        contract.activation.leaseWireWidth > 0
          && contract.activation.leaseWireWidth == 32
      ) "lease wire width must fit the stable 32-bit profile identifier")
    (require
      (
        contract.activation.manifest.offset == contract.abi.status.size
          && contract.activation.manifest.size == 128
          && contract.activation.manifest.alignment == contract.soc.cacheLineSize
          && lib.mod contract.activation.manifest.offset
          contract.soc.cacheLineSize == 0
          && lib.mod contract.activation.manifest.size
          contract.soc.cacheLineSize == 0
          && contract.activation.request.offset
          == contract.activation.manifest.offset
          + contract.activation.manifest.size
          && contract.activation.request.size == 128
          && contract.activation.request.alignment == contract.soc.cacheLineSize
          && lib.mod contract.activation.request.offset
          contract.soc.cacheLineSize == 0
          && lib.mod contract.activation.request.size
          contract.soc.cacheLineSize == 0
          && contract.activation.request.offset + contract.activation.request.size
          <= shared.regions.status.size
      ) "ABI-1.1 records do not form disjoint cacheline-owned status-page ranges")
    (require
      (
        contract.activation.manifest.magic == 826493774
          && contract.activation.manifest.formatMajor == 1
          && contract.activation.manifest.formatMinor == 0
          && contract.activation.manifest.commit == 1414090051
          && contract.activation.request.magic == 826362702
          && contract.activation.request.formatMajor == 1
          && contract.activation.request.formatMinor == 0
          && contract.activation.request.commit == 827016001
          && contract.activation.linuxResponseTimeoutMs > 0
      ) "ABI-1.1 manifest or activation framing constants changed")
    (require (firmwareEnd == shared.address)
      "firmware and shared memory must be contiguous")
    (require (sharedEnd == dramEnd)
      "the C906L reservation must end at the top of DRAM")
    (require (contract.memory.firmware.address >= dramStart)
      "firmware lies below DRAM")
    (require (regionPartition.next == shared.size)
      "shared-memory regions do not exactly fill the carveout")
    (require (shared.regions.status.size >= contract.abi.status.size)
      "status region is smaller than the status ABI")
    (require
      (
        mailbox.slotCount == 8
          && mailbox.slotSize == contract.abi.message.size
      ) "mailbox slot geometry changed")
    (require (allUnique mailboxChannels) "mailbox channels are not unique")
    (require
      (lib.all (channel: channel >= 0 && channel < mailbox.slotCount)
        mailboxChannels) "mailbox channel exceeds the hardware slot count")
    (require (allUnique mailboxProcessorIds) "mailbox processor IDs are not unique")
    (require
      (
        mailbox.processorCount == 4
          && lib.all
          (processor:
            processor >= 0 && processor < mailbox.processorCount
          )
          mailboxProcessorIds
      ) "mailbox processor geometry changed")
    (require
      (mailbox.payloadAddress >= mailbox.address
        && mailbox.payloadAddress + mailbox.slotCount * mailbox.slotSize
        <= mailbox.address + mailbox.size)
      "mailbox payload slots lie outside the controller range")
    (require
      (
        mailboxHwspin.registerOffset == 192
          && mailboxHwspin.registerCount == 8
          && mailboxHwspin.registerStride == 4
          && mailboxHwspin.accessWidth == 2
          && mailboxHwspin.mailboxField == 4
      ) "mailbox hardware-spinlock register geometry changed")
    (require
      (
        mailboxHwspinBase >= mailbox.address
          && mailboxHwspinEnd <= mailbox.address + mailbox.size
          && mailboxHwspin.mailboxField < mailboxHwspin.registerCount
      ) "mailbox hardware-spinlock fields lie outside the controller range")
    (require
      (
        mailboxHwspin.tokenWidth == 8
          && mailboxHwspin.linuxTokenShift == 0
          && mailboxHwspin.c906lTokenShift == 8
          && builtins.bitAnd mailboxHwspinLinuxTokenMask
          mailboxHwspinC906lTokenMask == 0
          && mailboxHwspinLinuxTokenMask + mailboxHwspinC906lTokenMask
          < pow2 (8 * mailboxHwspin.accessWidth)
      ) "mailbox hardware-spinlock token namespaces changed")
    (require
      (
        mailboxHwspin.taskAcquireAttempts > 0
          && mailboxHwspin.irqAcquireAttempts > 0
          && mailboxHwspin.irqConsecutiveDeferralLimit > 0
          && mailboxHwspin.irqAcquireAttempts
          <= mailboxHwspin.taskAcquireAttempts
      ) "mailbox hardware-spinlock acquisition bounds are invalid")
    (require (rpmsg.resourceTable.serializedSize <= resourceRegion.size)
      "RPMsg resource table does not fit its region")
    (require
      (
        rpmsg.resourceTable.version == 1
          && rpmsg.resourceTable.entries == 1
          && rpmsg.resourceTable.entryOffset == 20
          && rpmsg.resourceTable.configLength == 0
          && rpmsg.resourceTable.vringCount == 2
          && rpmsg.resourceTable.serializedSize == 88
      ) "RPMsg resource table does not match the frozen two-vring layout")
    (require (powerOfTwo rpmsg.vrings.alignment)
      "RPMsg vring alignment must be a power of two")
    (require (powerOfTwo rpmsg.vrings.descriptors)
      "RPMsg descriptor count must be a power of two")
    (require
      (driverRingBytes <= rpmsg.vrings.driverBytes
        && rpmsg.vrings.driverBytes <= rpmsg.vrings.usedOffset)
      "RPMsg driver ring does not fit before the used ring")
    (require
      (rpmsg.vrings.usedOffset + usedRingBytes <= vring0Region.size
        && rpmsg.vrings.usedOffset + usedRingBytes <= vring1Region.size)
      "RPMsg used ring does not fit its reserved region")
    (require
      (rpmsg.buffers.payloadSize
        == rpmsg.buffers.bufferSize - rpmsg.buffers.headerSize)
      "RPMsg payload size does not match buffer minus header")
    (require (lib.mod bufferRegion.size rpmsg.buffers.bufferSize == 0)
      "RPMsg buffer region is not an integral number of buffers")
    (require (sharedEnd <= pow2 32)
      "RPMsg device addresses exceed the 32-bit resource-table ABI")
  ]
  ++ lib.mapAttrsToList validateTimerAbiAssignment sg2002TimerDescriptors
  ++ lib.mapAttrsToList validatePeripheral contract.peripherals
  ++ lib.mapAttrsToList validateProfile contract.profiles;

  validated = builtins.deepSeq validation contract;

  capabilityMask = capabilityNames:
    lib.foldl'
      (mask: capabilityName:
        mask + pow2 validated.abi.capabilities.${capabilityName}.bit
      ) 0
      capabilityNames;

  resolvePeripheralsUnchecked = profileName: peripherals:
    let
      sortedPeripherals = lib.sort builtins.lessThan peripherals;
      selectedLeases = builtins.listToAttrs (map
        (name: {
          inherit name;
          value = validated.peripherals.${name};
        })
        sortedPeripherals);
      sortedCapabilities = lib.sort builtins.lessThan (lib.unique
        (baseCapabilities ++ map
          (name: validated.peripherals.${name}.capability)
          sortedPeripherals));
      expectedCapabilities = capabilityMask sortedCapabilities;
      dormantCapabilities = capabilityMask baseCapabilities;
      leaseMask = lib.foldl'
        (mask: name: mask + pow2 selectedLeases.${name}.leaseBit)
        0
        sortedPeripherals;
      profileId = leaseMask + 1;
      activationRequired = sortedPeripherals != [ ];
      manifestFlags =
        pow2 validated.activation.manifestFlags.rpmsgWhileDormant.bit
        + (if activationRequired then
          pow2 validated.activation.manifestFlags.ackRequired.bit
        else
          0);
      resolvedContract = builtins.removeAttrs validated [ "profiles" "peripherals" ] // {
        profile = {
          name = profileName;
          peripherals = sortedPeripherals;
          capabilities = sortedCapabilities;
          inherit
            activationRequired
            dormantCapabilities
            expectedCapabilities
            leaseMask
            manifestFlags
            profileId
            ;
        };
        peripheralLeases = selectedLeases;
      };
      canonicalJson = builtins.toJSON resolvedContract;
      digestJson = builtins.toJSON (stripDocumentation resolvedContract);
      sha256 = builtins.hashString "sha256" digestJson;
    in
    {
      _profileIdFits = require (profileId < pow2 32)
        "profile identifier does not fit 32 bits";
      inherit
        canonicalJson
        digestJson
        expectedCapabilities
        dormantCapabilities
        leaseMask
        manifestFlags
        profileId
        profileName
        resolvedContract
        sha256
        sortedCapabilities
        sortedPeripherals
        ;
    };

  resolveProfileUnchecked = profileName:
    if builtins.hasAttr profileName validated.profiles then
      resolvePeripheralsUnchecked profileName
        validated.profiles.${profileName}.peripherals
    else
      fail "unknown profile `${profileName}`";

  resolveProfile = profileName:
    let resolved = builtins.deepSeq validated (resolveProfileUnchecked profileName);
    in builtins.deepSeq resolved._profileIdFits
      (builtins.removeAttrs resolved [ "_profileIdFits" ]);

  resolvePeripherals = peripherals:
    let
      duplicateFree = allUnique peripherals;
      sorted = lib.sort builtins.lessThan peripherals;
      unknownPeripherals = lib.filter
        (name: !builtins.hasAttr name validated.peripherals)
        sorted;
      matchingProfiles = lib.filter
        (profileName:
          lib.sort builtins.lessThan validated.profiles.${profileName}.peripherals
          == sorted)
        (names validated.profiles);
      profileName =
        if builtins.length matchingProfiles == 1 then
          builtins.head matchingProfiles
        else
          "custom-${lib.concatStringsSep "-" sorted}";
    in
    if !duplicateFree then
      fail "peripheral selection contains duplicates"
    else if unknownPeripherals != [ ] then
      fail "unknown peripherals: ${lib.concatStringsSep ", " unknownPeripherals}"
    else if builtins.elem "picoclawLcd" sorted && sorted != [ "picoclawLcd" ] then
      fail "PicoClaw LCD must be selected alone"
    else if builtins.length matchingProfiles > 1 then
      fail "multiple named profiles match peripherals: ${lib.concatStringsSep ", " sorted}"
    else
      let resolved = resolvePeripheralsUnchecked profileName sorted;
      in builtins.deepSeq resolved._profileIdFits
        (builtins.removeAttrs resolved [ "_profileIdFits" ]);
in
{
  inherit
    capabilityMask
    parseNatural
    resolvePeripherals
    resolveProfile
    ;
  contract = validated;
  profiles = lib.mapAttrs (name: _: resolveProfile name) contract.profiles;
}
