# Single source of truth for the mainline kernel the SG2002 targets.
#
# This tracks nixpkgs' 7.3 series rather than pinning a tarball and hash
# here. Stable 7.3.x updates then arrive with a flake lock bump, which is
# reviewable and reproducible, instead of a hand-edited hash pointing at a
# release candidate in torvalds/t/ that kernel.org eventually deletes.
#
# It stays a separate file because three places need to agree on it: the
# kernel package, the DTB build (which compiles the in-tree carrier DTS)
# and the clock KUnit suite (which builds an x86 test kernel from the same
# tree, so the driver under test is the one the board runs).
{ linux_7_3 }:
{
  inherit (linux_7_3) src version modDirVersion;
  kernel = linux_7_3;
}
