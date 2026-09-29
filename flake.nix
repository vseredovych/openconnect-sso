{
  description = "OpenConnect wrapper supporting Azure AD (SAMLv2) authentication to Cisco SSL-VPNs";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" "x86_64-linux" "aarch64-linux" ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAll (pkgs: rec {
        openconnect-sso = pkgs.callPackage ./nix/package.nix { };
        default = openconnect-sso;
      });

      overlays.default = final: prev: {
        openconnect-sso = final.callPackage ./nix/package.nix { };
      };

      darwinModules.default = import ./nix/darwin-module.nix self;

      devShells = forAll (pkgs: {
        default = pkgs.mkShell {
          inputsFrom = [ self.packages.${pkgs.stdenv.hostPlatform.system}.openconnect-sso ];
          packages = with pkgs.python3Packages; [ black pytest pytest-asyncio pytest-httpserver ];
        };
      });
    };
}
