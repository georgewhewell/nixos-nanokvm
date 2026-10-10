{
  lib,
  stdenv,
  fetchFromGitHub,
  cmake,
  ninja,
  flatbuffers,
  sophgo-cvikernel,
  sophgo-cvibuilder,
  sg2002-tpu,
}:
stdenv.mkDerivation {
  pname = "sophgo-cviruntime";
  version = "0-unstable-2024-10-10";
  src = fetchFromGitHub {
    owner = "sophgo";
    repo = "cviruntime";
    rev = "ef8044988c2b4a5d491125d13e6f048b5f8a1389";
    sha256 = "06mmy6929v3af7n4jcjp4p1q8n9gbjb2v41bwx7akh65k43apqws";
  };
  patches = [ ./mainline-backend.patch ];
  nativeBuildInputs = [
    cmake
    ninja
  ];
  buildInputs = [
    sophgo-cvikernel
    sg2002-tpu
  ];
  cmakeFlags = [
    "-DCMAKE_POLICY_VERSION_MINIMUM=3.5"
    "-DCHIP=cv181x"
    "-DRUNTIME=SOC"
    "-DFLATBUFFERS_PATH=${flatbuffers}"
    "-DCVIKERNEL_PATH=${sophgo-cvikernel}"
    "-DCVIBUILDER_PATH=${sophgo-cvibuilder}"
    "-DENABLE_PMU=OFF"
    "-DENABLE_TEST=OFF"
    "-DENABLE_TOOLS=OFF"
  ];
  meta = {
    description = "Sophgo CV181x model runtime using the SG2002 mainline TPU driver";
    homepage = "https://github.com/sophgo/cviruntime";
    license = lib.licenses.unfree;
    platforms = [ "riscv64-linux" ];
  };
}
