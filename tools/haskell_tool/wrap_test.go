package main

import (
	"os"
	"path/filepath"
	"testing"
)

// The test binary stands in for GHC when HASKELL_TOOL_FAKE_GHC is set, so
// wrap runs a real child process without a compiler on the machine.
func TestMain(m *testing.M) {
	if os.Getenv("HASKELL_TOOL_FAKE_GHC") == "1" {
		os.Exit(0)
	}
	os.Exit(m.Run())
}

// fakeGhc is this test binary by absolute path: os.Args[0] can be relative,
// as buck2 runs it, and stops resolving once a test changes directory.
func fakeGhc(t *testing.T) string {
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	return exe
}

func TestWrapWritesDepFiles(t *testing.T) {
	t.Setenv("HASKELL_TOOL_FAKE_GHC", "1")
	dir := t.TempDir()
	dep, dbDep := filepath.Join(dir, "x.dep"), filepath.Join(dir, "x.package-db.dep")
	code := wrap([]string{
		"--ghc", fakeGhc(t),
		"--buck2-dep", dep,
		"--buck2-packagedb-dep", dbDep,
		"--buck2-package-db", "a",
		"--buck2-package-db", "b",
		"-c", "X.hs",
	})
	if code != 0 {
		t.Fatalf("wrap exited %d", code)
	}
	if got, _ := os.ReadFile(dep); string(got) != "\n" {
		t.Errorf("dep file %q, want an empty line", got)
	}
	// Only the last --buck2-package-db survives, as with argparse's store action:
	// the dep file names one db (fixed in the change after this one).
	if got, _ := os.ReadFile(dbDep); string(got) != "b\n" {
		t.Errorf("packagedb dep file %q", got)
	}
}

func TestWrapStopsWhenThePluginWroteNoHash(t *testing.T) {
	t.Setenv("HASKELL_TOOL_FAKE_GHC", "1")
	dir := t.TempDir()
	dep := filepath.Join(dir, "x.dep")
	code := wrap([]string{
		"--ghc", fakeGhc(t),
		"--abi-from-plugin", filepath.Join(dir, "X.dyn_hi.hash"),
		"--buck2-dep", dep,
		"-c", "X.hs",
	})
	if code != 1 {
		t.Errorf("wrap exited %d, want 1 for a hash the plugin never wrote", code)
	}
	if _, err := os.Stat(dep); err == nil {
		t.Errorf("dep file written although the ABI hash check failed")
	}
}
