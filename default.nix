{ nixpkgs ? import <nixpkgs> {}, ...
}:

with nixpkgs;
let
  z3WithOcaml = stdenv.mkDerivation rec {
      name = "z3-${version}";
      version = "4.8.5";

      src = fetchFromGitHub {
	owner  = "Z3Prover";
	repo   = "z3";
	rev    = "Z3-${version}";
	sha256 = "11sy98clv7ln0a5vqxzvh6wwqbswsjbik2084hav5kfws4xvklfa";
      };

      buildInputs = [ python fixDarwinDylibNames ]
        ++ [ ocaml ]
        ++ (with ocamlPackages; [ findlib num ])
        ;
      propagatedBuildInputs = [ python.pkgs.setuptools ];
      enableParallelBuilding = true;

      configurePhase = ''
        ocamlfind query num # && sleep 1m
        mkdir -p $(ocamlfind printconf destdir)
	${python.interpreter} scripts/mk_make.py --prefix=$out --python --ml --pypkgdir=$out/${python.sitePackages}
	cd build
      '';

      postInstall = ''
	mkdir -p $dev $lib $python/lib $ocaml/lib
	mv $out/lib/python*  $python/lib/
	mv $out/lib/ocaml*   $ocaml/lib/
	mv $out/lib          $lib/lib
	mv $out/include      $dev/include
	ln -sf $lib/lib/libz3${stdenv.hostPlatform.extensions.sharedLibrary} $python/${python.sitePackages}/z3/lib/libz3${stdenv.hostPlatform.extensions.sharedLibrary}
      '';

      outputs = [ "out" "lib" "dev" "python" "ocaml" ];

      meta = {
	description = "A high-performance theorem prover and SMT solver";
	homepage    = "https://github.com/Z3Prover/z3";
	license     = stdenv.lib.licenses.mit;
	platforms   = stdenv.lib.platforms.unix;
	maintainers = [ stdenv.lib.maintainers.thoughtpolice ];
      };
  };

in
  stdenv.mkDerivation rec {
    name    = "verifast-env";

    buildInputs = [
      ocaml git coreutils which

      z3WithOcaml
      z3WithOcaml.ocaml
      z3WithOcaml.lib

      glib

      pkgconfig
      gnome2.gtksourceview
      gtk2-x11

      gnumake

    ] ++ (with ocamlPackages; [
      num findlib camlp4
      lablgtk
    ]);

    # dontStrip = true;
    # phases = "buildPhase";

    Z3_DLL_DIR="${z3WithOcaml.lib}/lib";
    LD_LIBRARY_PATH = "${z3WithOcaml.lib}/lib";

    # buildCommand = ''
    #     cp -r $src .
    #     cd $(basename $src)
    #     chmod -R +w .
    #     cd src
    #     ls -laF
    #     pwd

    #     make
    #     mkdir -p $out
    #     mv ../bin $out/
    # '';
  }

