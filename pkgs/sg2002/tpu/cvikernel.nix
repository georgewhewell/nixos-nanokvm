{
  lib,
  stdenv,
  fetchFromGitHub,
  cmake,
  ninja,
}:
stdenv.mkDerivation {
  pname = "sophgo-cvikernel";
  version = "0-unstable-2024-10-10";
  src = fetchFromGitHub {
    owner = "sophgo";
    repo = "cvikernel";
    rev = "0b37e46607be203bf9d4d29995f6fa4bbab69435";
    hash = "sha256-rmi0cMgX3w8bNfwWh9Rh4yPn/Yk+NhjlP/xEXQgaIP4=";
  };
  nativeBuildInputs = [
    cmake
    ninja
  ];
  cmakeFlags = [
    "-DCHIP=cv181x"
    "-DCMAKE_POLICY_VERSION_MINIMUM=3.5"
  ];
  # Upstream treats all warnings as errors, including new GCC diagnostics.
  postPatch = ''
    substituteInPlace CMakeLists.txt --replace-fail '-Werror ' ""
  '';
  meta = {
    description = "Sophgo CV181x TPU instruction generator (source available)";
    homepage = "https://github.com/sophgo/cvikernel";
    # No repository license or grant in the files used here at this revision.
    license = lib.licenses.unfree;
    platforms = lib.platforms.linux;
  };
}
