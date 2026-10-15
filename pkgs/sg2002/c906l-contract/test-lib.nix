{ lib }:

let
  contract = import ./lib.nix { inherit lib; };
  base = contract.resolveProfile "base";
  timer4 = contract.resolveProfile "timer4";
  timer5 = contract.resolveProfile "timer5";
  timer6 = contract.resolveProfile "timer6";
  timer7 = contract.resolveProfile "timer7";
  allTimers = contract.resolveProfile "all-timers";
  lcd = contract.resolveProfile "picoclaw-lcd";
  mixedLcd = forceTry (contract.resolvePeripherals [ "picoclawLcd" "timer4" ]);
  allTimersUnordered = contract.resolvePeripherals [ "timer7" "timer5" "timer4" "timer6" ];
  forceTry = value: builtins.tryEval (builtins.deepSeq value true);
  unknownProfile = forceTry (contract.resolveProfile "missing");
  duplicatePeripheral = forceTry (contract.resolvePeripherals [ "timer4" "timer4" ]);
  unknownPeripheral = forceTry (contract.resolvePeripherals [ "uart99" ]);
in
assert base.expectedCapabilities == 11;
assert timer4.expectedCapabilities == 15;
assert timer5.expectedCapabilities == 27;
assert timer6.expectedCapabilities == 43;
assert timer7.expectedCapabilities == 75;
assert allTimers.expectedCapabilities == 127;
assert base.sha256 == "2a7e99101e8b7f8ec326c6f4b00eca45443cc93ac9b84aa0f4393bed52d7171f";
assert timer4.sha256 == "94669a96c5b333776b841691e5fc2a4d6f31e1b71f74e0fe8b2e6f1e8832eed3";
assert timer5.sha256 == "334c0f3443c5842035f510eb5054eb18684219c9d6598a35379f8c29701d022b";
assert timer6.sha256 == "9c719ef5d827bf6e3b000f60830c376b750a4d3498ec40908516fa7195302fd0";
assert timer7.sha256 == "740ea5301db69ae204c72eafb03035c6e58725523c4b3be2feb3864ced89064a";
assert allTimers.sha256 == "a733712d2aa85baff6f7f2083311ffc483319fafd55fc027b1b146615ec391b1";
assert lcd.sha256 == "53470c33b715731019865a658dd8a7affdb69a80b414a5195428f2fb16dab355";
assert lcd.expectedCapabilities == 139;
assert lcd.dormantCapabilities == 11;
assert lcd.leaseMask == 16;
assert lcd.profileId == 17;
assert lcd.manifestFlags == 3;
assert lcd.sortedPeripherals == [ "picoclawLcd" ];
assert (contract.resolvePeripherals [ "picoclawLcd" ]).sha256 == lcd.sha256;
assert !mixedLcd.success;
assert base.sha256 != timer4.sha256;
assert base.sortedPeripherals == [ ];
assert timer4.sortedPeripherals == [ "timer4" ];
assert timer5.sortedPeripherals == [ "timer5" ];
assert timer6.sortedPeripherals == [ "timer6" ];
assert timer7.sortedPeripherals == [ "timer7" ];
assert allTimers.sortedPeripherals == [ "timer4" "timer5" "timer6" "timer7" ];
assert allTimersUnordered.profileName == "all-timers";
assert allTimersUnordered.sha256 == allTimers.sha256;
assert base.dormantCapabilities == 11;
assert timer4.dormantCapabilities == 11;
assert base.leaseMask == 0;
assert timer4.leaseMask == 1;
assert timer5.leaseMask == 2;
assert timer6.leaseMask == 4;
assert timer7.leaseMask == 8;
assert allTimers.leaseMask == 15;
assert base.profileId == 1;
assert timer4.profileId == 2;
assert timer5.profileId == 3;
assert timer6.profileId == 5;
assert timer7.profileId == 9;
assert allTimers.profileId == 16;
assert base.manifestFlags == 2;
assert timer4.manifestFlags == 3;
assert timer5.manifestFlags == 3;
assert timer6.manifestFlags == 3;
assert timer7.manifestFlags == 3;
assert allTimers.manifestFlags == 3;
assert (contract.resolvePeripherals [ ]).profileName == "base";
assert (contract.resolvePeripherals [ "timer4" ]).profileName == "timer4";
assert (contract.resolvePeripherals [ "timer5" ]).profileName == "timer5";
assert (contract.resolvePeripherals [ "timer6" ]).profileName == "timer6";
assert (contract.resolvePeripherals [ "timer7" ]).profileName == "timer7";
assert allTimers.profileName == "all-timers";
assert !unknownProfile.success;
assert !duplicatePeripheral.success;
assert !unknownPeripheral.success;
assert base.resolvedContract.memory.firmware.address == 2413821952;
assert base.resolvedContract.memory.shared.address == 2414870528;
assert base.resolvedContract.memory.shared.regions.bulk.offset
  + base.resolvedContract.memory.shared.regions.bulk.size
  == base.resolvedContract.memory.shared.size;
{
  inherit
    allTimers
    base
    lcd
    timer4
    timer5
    timer6
    timer7
    ;
}
