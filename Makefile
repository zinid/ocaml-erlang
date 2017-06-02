all:
	ocamlbuild -use-ocamlfind -lib unix -pkgs "delimcc" test.native
