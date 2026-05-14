# NanoKVM USB control-plane protocol constants.
#
# These are wire-format choices: MAC addresses baked into the gadget,
# IP addresses chosen for the ECM /24, and TCP ports each side listens
# on. Keep this file authoritative; code that hard-codes any of these
# constants is a bug.
{
  # USB CDC-ECM gadget MAC addresses (locally administered, 0x02 bit).
  targetMac = "02:1a:11:00:01:01";
  hostMac = "02:1a:11:00:01:02";

  # USB ECM subnet. Target is .1, host is .2.
  targetIp = "10.55.0.1";
  hostIp = "10.55.0.2";
  prefix = "24";

  ports = {
    # Target busybox telnet shell (debug only).
    debugShell = 2323;
    # Host listens here for status text from the target.
    statusSink = 2324;
    # Target listens here for one kexec request per connection.
    kexecCtrl = 2325;
    # Host serves the live rootfs EROFS as NBD.
    nbdRootfs = 10809;
    # Host serves the kexec payload EROFS as NBD.
    nbdPayload = 10810;
  };
}
