{ fetchurl }:

rec {
  version = "7.2-rc1";
  modDirVersion = "7.2.0-rc1";
  src = fetchurl {
    url = "https://git.kernel.org/torvalds/t/linux-${version}.tar.gz";
    hash = "sha256-tGDnTPoKQoQWiBBjgh72quimpMaYkbmrEPz07fdwzg0=";
  };
}
