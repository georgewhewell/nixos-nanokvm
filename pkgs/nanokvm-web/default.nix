{
  lib,
  buildNpmPackage,
  fetchPnpmDeps,
  nanokvm-patched-src,
  nodejs_24,
  pnpm_10,
  pnpmConfigHook,
}:

buildNpmPackage (finalAttrs: {
  pname = "nanokvm-web";
  version = "unstable";

  src = "${nanokvm-patched-src}/web";

  npmDeps = null;
  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs) pname version src;
    pnpm = pnpm_10;
    fetcherVersion = 3;
    hash = "sha256-jg54njECFqP3+hHm4hOQZBfYLBLaJPnpCmcBGLJlGSw=";
  };

  nativeBuildInputs = [
    nodejs_24
    pnpm_10
  ];
  npmConfigHook = pnpmConfigHook;

  installPhase = ''
    runHook preInstall

    cp -r dist "$out"

    runHook postInstall
  '';

  meta = {
    description = "NanoKVM web UI";
    homepage = "https://github.com/sipeed/NanoKVM";
    license = lib.licenses.gpl3Only;
  };
})
