package main

import (
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// inDir runs the rest of a test from dir, as buck2 runs an action from its
// execution root, and restores the working directory afterwards.
func inDir(t *testing.T, dir string) {
	old, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chdir(dir); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chdir(old) })
}

// The test binary stands in for GHC when HASKELL_TOOL_FAKE_GHC is set, so
// wrap runs a real child process without a compiler on the machine.
func TestMain(m *testing.M) {
	switch os.Getenv("HASKELL_TOOL_FAKE_GHC") {
	case "1":
		// Stands in for the oneshot plugin's list of the interfaces read.
		if list, ok := os.LookupEnv(readInterfacesVar); ok {
			if read, ok := os.LookupEnv("HASKELL_TOOL_FAKE_GHC_READ"); ok {
				if err := os.WriteFile(list, []byte(read), 0o666); err != nil {
					os.Exit(2)
				}
			}
		}
		os.Exit(0)
	case "fail":
		os.Stderr.WriteString("X.hs:1:1: error\n")
		os.Exit(3)
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
	// Every --buck2-package-db goes in the dep file, so buck2 counts each db as used.
	if got, _ := os.ReadFile(dbDep); string(got) != "a\nb\n" {
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

func TestWrapNamesTheFailedCommand(t *testing.T) {
	t.Setenv("HASKELL_TOOL_FAKE_GHC", "fail")
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	stderr := os.Stderr
	os.Stderr = w
	code := wrap([]string{"--ghc", fakeGhc(t), "-c", "X Y.hs"})
	os.Stderr = stderr
	w.Close()
	out, _ := io.ReadAll(r)
	if code != 3 {
		t.Errorf("wrap exited %d, want GHC's 3", code)
	}
	for _, want := range []string{"X.hs:1:1: error", fakeGhc(t) + " -c 'X Y.hs'", "exit status 3"} {
		if !strings.Contains(string(out), want) {
			t.Errorf("stderr %q lacks %q", out, want)
		}
	}
}

// With the plugin's list, the dep file names the hash beside each interface the
// compile read that the action has: relative, cleaned, once, and sorted. A
// toolchain interface outside the working directory and an interface with no
// hash beside it (a module buck2 did not tag) are left out.
func TestWrapWritesTheHashesOfTheInterfacesRead(t *testing.T) {
	dir := t.TempDir()
	inDir(t, dir)
	for _, f := range []string{"out/A.dyn_hi.hash", "dep/mod-shared/B/C.dyn_hi.hash", "out/D.dyn_hi-boot.hash"} {
		if err := os.MkdirAll(filepath.Dir(f), 0o777); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(f, []byte("h"), 0o666); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("HASKELL_TOOL_FAKE_GHC", "1")
	t.Setenv("HASKELL_TOOL_FAKE_GHC_READ", "read\tdep/db/../mod-shared/B/C.dyn_hi\n"+
		"read\t/nix/store/x-ghc/lib/base/Prelude.dyn_hi\n"+
		"read\t"+filepath.Join(dir, "out/A.dyn_hi")+"\n"+
		"read\tout/A.hi\nread\tout/A.dyn_hi\n"+
		"read\tout/D.dyn_hi\nread\tout/D.dyn_hi-boot\n"+
		"read\tout/E.dyn_hi\n"+
		"linked\tout/A.dyn_hi\n")
	code := wrap([]string{
		"--ghc", fakeGhc(t),
		"--buck2-dep", "x.dep",
		"--read-interfaces-dep", "true",
		"-c", "X.hs",
	})
	if code != 0 {
		t.Fatalf("wrap exited %d", code)
	}
	want := "dep/mod-shared/B/C.dyn_hi.hash\nout/A.dyn_hi.hash\nout/D.dyn_hi-boot.hash\n"
	if got, _ := os.ReadFile("x.dep"); string(got) != want {
		t.Errorf("dep file %q, want %q", got, want)
	}
}

// A compile that asked for the plugin's list and got none fails: an empty dep
// file would count every tagged hash as unused and serve a stale compile.
func TestWrapStopsWhenThePluginListedNothing(t *testing.T) {
	dir := t.TempDir()
	inDir(t, dir)
	t.Setenv("HASKELL_TOOL_FAKE_GHC", "1")
	code := wrap([]string{
		"--ghc", fakeGhc(t),
		"--buck2-dep", "x.dep",
		"--read-interfaces-dep", "true",
		"-c", "X.hs",
	})
	if code != 1 {
		t.Errorf("wrap exited %d, want 1 for a list the plugin never wrote", code)
	}
	if _, err := os.Stat("x.dep"); err == nil {
		t.Errorf("dep file written without the plugin's list")
	}
}

// A splice-running compile also names the interface of every module a splice
// linked, since a body-only edit changes the byte code in it and not the hash.
func TestWrapNamesTheInterfacesASpliceLinked(t *testing.T) {
	dir := t.TempDir()
	inDir(t, dir)
	for _, f := range []string{"out/A.dyn_hi", "out/A.dyn_hi.hash", "out/B.dyn_hi", "out/B.dyn_hi.hash"} {
		if err := os.MkdirAll(filepath.Dir(f), 0o777); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(f, []byte("h"), 0o666); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("HASKELL_TOOL_FAKE_GHC", "1")
	t.Setenv("HASKELL_TOOL_FAKE_GHC_READ", "read\tout/A.dyn_hi\nread\tout/B.dyn_hi\nlinker\nlinked\tout/B.dyn_hi\n")
	code := wrap([]string{
		"--ghc", fakeGhc(t),
		"--buck2-dep", "x.dep",
		"--read-interfaces-dep", "splices",
		"-c", "X.hs",
	})
	if code != 0 {
		t.Fatalf("wrap exited %d", code)
	}
	want := "out/A.dyn_hi.hash\nout/B.dyn_hi\nout/B.dyn_hi.hash\n"
	if got, _ := os.ReadFile("x.dep"); string(got) != want {
		t.Errorf("dep file %q, want %q", got, want)
	}
}

// Without the plugin's resolver nothing recorded what the splices linked, so a
// splice-running compile that asked for the list fails instead of keying on
// the hashes alone.
func TestWrapStopsWhenNoResolverRecordedTheSplices(t *testing.T) {
	dir := t.TempDir()
	inDir(t, dir)
	t.Setenv("HASKELL_TOOL_FAKE_GHC", "1")
	t.Setenv("HASKELL_TOOL_FAKE_GHC_READ", "read\tout/A.dyn_hi\n")
	code := wrap([]string{
		"--ghc", fakeGhc(t),
		"--buck2-dep", "x.dep",
		"--read-interfaces-dep", "splices",
		"-c", "X.hs",
	})
	if code != 1 {
		t.Errorf("wrap exited %d, want 1 without the linker mark", code)
	}
}
