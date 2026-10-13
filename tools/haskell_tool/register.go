package main

import (
	"os"
	"strings"
)

// register replaces ghc_pkg_registerer.py: a package db holding one package,
// made with ghc-pkg init and then ghc-pkg register.
var registerOptions = []option{
	{name: "--help", short: "-h", arity: zero},
	{name: "--ghc-pkg", arity: one, required: true},
	{name: "--output", arity: one, required: true},
	{name: "--package-conf", arity: one, required: true},
}

// parseRegister is parse_args: parse_known_args, refusing anything unknown.
func parseRegister(args []string) (p parsed, help bool, err error) {
	p, err = parseKnown(args, registerOptions)
	if err == nil && !p.help && len(p.extras) > 0 {
		err = usageError("unrecognized arguments: " + strings.Join(p.extras, " "))
	}
	return p, err == nil && p.help, err
}

func register(args []string) int {
	p, help, err := parseRegister(args)
	if help {
		os.Stdout.WriteString("usage: register --ghc-pkg GHC_PKG --output OUTPUT --package-conf PACKAGE_CONF\n")
		return 0
	}
	if err != nil {
		return usage("register", err)
	}
	ghcPkg, _ := p.last("--ghc-pkg")
	output, _ := p.last("--output")
	conf, _ := p.last("--package-conf")
	env := os.Environ()
	if code := run([]string{ghcPkg, "init", output}, env, os.Stdout); code != 0 {
		return code
	}
	return run([]string{ghcPkg, "register", "--package-conf", output, "--no-expand-pkgroot", conf, "--force", "-v0"}, env, os.Stdout)
}
