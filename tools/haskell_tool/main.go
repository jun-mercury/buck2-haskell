// haskell_tool runs the steps buck2-haskell's one-shot actions wrap around
// GHC, as one static binary instead of a Python interpreter and its standard
// library in every action's inputs.
//
//	haskell_tool wrap [ghc_wrapper.py's arguments]
//	haskell_tool register [ghc_pkg_registerer.py's arguments]
package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"syscall"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: haskell_tool wrap|register [arguments]")
		os.Exit(2)
	}
	switch os.Args[1] {
	case "wrap":
		os.Exit(wrap(os.Args[2:]))
	case "register":
		os.Exit(register(os.Args[2:]))
	default:
		fmt.Fprintf(os.Stderr, "haskell_tool: unknown subcommand %q\n", os.Args[1])
		os.Exit(2)
	}
}

// usage is argparse's error: a message on stderr and status 2.
func usage(prog string, err error) int {
	var u usageError
	if !errors.As(err, &u) {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	fmt.Fprintf(os.Stderr, "%s: error: %s\n", prog, u)
	return 2
}

// exitCodeOfSignal is sys.exit(-signal), which the C runtime reports as
// -signal & 0xff.
func exitCodeOfSignal(exit *exec.ExitError) int {
	if status, ok := exit.Sys().(syscall.WaitStatus); ok && status.Signaled() {
		return -int(status.Signal()) & 0xff
	}
	return 1
}
