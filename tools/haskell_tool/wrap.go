package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path"
	"sort"
	"strings"
)

// wrap replaces ghc_wrapper.py: it runs GHC with the remaining arguments,
// GHC's stdout sent to stderr (buck2 drops a successful action's stdout),
// then writes the module's ABI hash and the dep files that tell buck2 which
// tagged inputs the compile used.
var wrapOptions = []option{
	{name: "--buck2-dep", arity: one},
	{name: "--buck2-packagedb-dep", arity: one},
	// Repeatable, as compile.bzl passes it once per db: every db goes in the
	// packagedb dep file, so buck2 counts each one as used.
	{name: "--buck2-package-db", arity: many, repeated: true},
	{name: "--ghc", arity: one, required: true},
	{name: "--ghc-dir", arity: one},
	{name: "--ghc-argsfile", arity: one},
	{name: "--abi-out", arity: one},
	{name: "--abi-from-plugin", arity: one},
	// "true" when the oneshot plugin is loaded: the dep file then names the
	// hash files of the interfaces the compile read, which the plugin lists.
	// The name shares no prefix with the other options, so every
	// abbreviation argparse accepted before still parses the same.
	{name: "--read-interfaces-dep", arity: one},
	{name: "--bin-path", arity: one, repeated: true},
	{name: "--bin-exe", arity: one, repeated: true},
	{name: "--extra-env-key", arity: one, repeated: true},
	{name: "--extra-env-value", arity: one, repeated: true},
}

func wrap(args []string) int {
	expanded, err := expandFiles(args)
	if err != nil {
		return usage("wrap", err)
	}
	p, err := parseKnown(expanded, wrapOptions)
	if err != nil {
		return usage("wrap", err)
	}
	ghc, _ := p.last("--ghc")

	cmd := append([]string{ghc}, p.extras...)
	if argsfile, ok := p.last("--ghc-argsfile"); ok && argsfile != "" {
		cmd = append(cmd, "@"+argsfile)
	}

	searchPath := os.Getenv("PATH")
	for _, dir := range p.values["--bin-path"] {
		dir = pythonPath(dir)
		if info, err := os.Stat(dir); err == nil && info.IsDir() {
			searchPath += ":" + dir
		}
	}
	for _, exe := range p.values["--bin-exe"] {
		searchPath += ":" + pythonDirname(pythonPath(exe))
	}
	keys, values := p.values["--extra-env-key"], p.values["--extra-env-value"]
	if len(keys) != len(values) {
		fmt.Fprintln(os.Stderr, "AssertionError: number of --extra-env-key and --extra-env-value flags must match")
		return 1
	}
	env := setEnv(os.Environ(), "PATH", searchPath)
	for i, k := range keys {
		env = setEnv(env, k, values[i])
	}

	readList := ""
	if v, ok := p.last("--read-interfaces-dep"); ok && v == "true" {
		dir, err := os.MkdirTemp("", "haskell-tool-")
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
		defer os.RemoveAll(dir)
		readList = path.Join(dir, "read-interfaces")
		env = setEnv(env, readInterfacesVar, readList)
	}

	if code := run(cmd, env, os.Stderr); code != 0 {
		return code
	}

	if abiOut, ok := p.last("--abi-out"); ok {
		if err := writeAbiHash(ghc, pythonPath(abiOut)); err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
	}
	if fromPlugin, ok := p.last("--abi-from-plugin"); ok {
		if err := checkPluginAbiHash(pythonPath(fromPlugin)); err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
	}
	if dep, ok := p.last("--buck2-dep"); ok && dep != "" {
		// Without the plugin's list, empty: every file the abi tag covers is
		// unused, and compile.bzl leaves the hash files untagged, so a
		// dependency's interface can change without rerunning this compile
		// unless some hash below it does.
		content := "\n"
		if readList != "" {
			var err error
			if content, err = hashDepFile(readList); err != nil {
				fmt.Fprintln(os.Stderr, err)
				return 1
			}
		}
		if err := writeOrRemove(dep, content); err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
	}
	if dep, ok := p.last("--buck2-packagedb-dep"); ok && dep != "" {
		var b strings.Builder
		for _, db := range p.values["--buck2-package-db"] {
			b.WriteString(db + "\n")
		}
		if b.Len() == 0 {
			b.WriteString("\n")
		}
		if err := writeOrRemove(dep, b.String()); err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
	}
	return 0
}

// readInterfacesVar names the file the oneshot plugin lists the interfaces
// it read in; Buck2Haskell.OneshotLinkables reads the same variable.
const readInterfacesVar = "BUCK2_HASKELL_READ_INTERFACES"

// hashDepFile turns the plugin's list of interfaces into the dep file: the
// hash file beside each interface, as a path under the working directory,
// for the ones the action has. buck2 tagged every dependency module's hash,
// so a hash left out is one whose change does not rerun this compile, and a
// list the plugin never wrote fails the action rather than keying it on
// nothing. Interfaces outside the working directory are the toolchain's
// packages, whose files buck2 does not tag.
func hashDepFile(list string) (string, error) {
	data, err := os.ReadFile(list)
	if err != nil {
		return "", fmt.Errorf("the oneshot plugin wrote no list of the interfaces it read: %w", err)
	}
	cwd, err := os.Getwd()
	if err != nil {
		return "", err
	}
	seen := map[string]bool{}
	var out []string
	for _, line := range strings.Split(string(data), "\n") {
		if line == "" {
			continue
		}
		p := path.Clean(line)
		if path.IsAbs(p) {
			rel, ok := strings.CutPrefix(p, path.Clean(cwd)+"/")
			if !ok {
				continue
			}
			p = rel
		}
		if p == ".." || strings.HasPrefix(p, "../") {
			continue
		}
		hash := p + ".hash"
		if seen[hash] {
			continue
		}
		seen[hash] = true
		if info, err := os.Stat(hash); err == nil && info.Mode().IsRegular() {
			out = append(out, hash)
		}
	}
	if len(out) == 0 {
		return "\n", nil
	}
	sort.Strings(out)
	return strings.Join(out, "\n") + "\n", nil
}

// writeAbiHash reads the hash GHC records in the interface beside abiOut
// (abiOut without its last suffix), with the caller's environment rather than
// the compile's, as ghc_wrapper.py did.
func writeAbiHash(ghc, abiOut string) error {
	hi := pythonWithoutSuffix(abiOut)
	if abiOut == "." {
		return errors.New("ValueError: PosixPath('.') has an empty name")
	}
	cmd := exec.Command(lookPath(ghc, os.Getenv("PATH")), "-v0", "-package-env=-", "--show-iface-abi-hash", hi)
	cmd.Args[0] = ghc
	cmd.Stderr = os.Stderr
	out, err := cmd.Output()
	if err != nil {
		return fmt.Errorf("%s --show-iface-abi-hash %s: %w", ghc, hi, err)
	}
	fields := strings.Fields(string(out))
	if len(fields) == 0 {
		return errors.New("IndexError: ghc printed no ABI hash for " + hi)
	}
	return os.WriteFile(abiOut, []byte(fields[0]), 0o666)
}

// checkPluginAbiHash checks the oneshot driver plugin wrote the ABI hash buck2
// declared, in place of starting a second GHC. Naming the path here is the
// only place the build's derivation of it, from the interface path it gives
// GHC, meets the plugin's, from GHC's ModLocation. When the file is missing it
// lists what the plugin did write for the module, which names a disagreement
// between the two instead of leaving it to be guessed at.
func checkPluginAbiHash(abiOut string) error {
	info, err := os.Stat(abiOut)
	if err != nil {
		dir, name := path.Split(abiOut)
		if dir == "" {
			dir = "."
		}
		stem, _, _ := strings.Cut(name, ".")
		var siblings []string
		entries, _ := os.ReadDir(dir)
		for _, e := range entries {
			if !strings.HasPrefix(e.Name(), stem) || strings.HasPrefix(e.Name(), ".") && !strings.HasPrefix(stem, ".") {
				continue
			}
			if fi, err := os.Stat(path.Join(dir, e.Name())); err == nil && fi.Mode().IsRegular() {
				siblings = append(siblings, e.Name())
			}
		}
		sort.Strings(siblings)
		return fmt.Errorf("the oneshot plugin wrote no ABI hash at %s; files for this module: %s", abiOut, pythonListRepr(siblings))
	}
	if info.Size() == 0 {
		return fmt.Errorf("the oneshot plugin wrote an empty ABI hash at %s", abiOut)
	}
	return nil
}

// pythonListRepr is repr() of a list of str, as SystemExit prints it.
func pythonListRepr(items []string) string {
	parts := make([]string, len(items))
	for i, s := range items {
		quote := "'"
		if strings.Contains(s, "'") && !strings.Contains(s, "\"") {
			quote = "\""
		}
		esc := strings.ReplaceAll(s, "\\", "\\\\")
		if quote == "'" {
			esc = strings.ReplaceAll(esc, "'", "\\'")
		}
		parts[i] = quote + esc + quote
	}
	return "[" + strings.Join(parts, ", ") + "]"
}

func writeOrRemove(name, content string) error {
	if err := os.WriteFile(name, []byte(content), 0o666); err != nil {
		os.Remove(name)
		return err
	}
	return nil
}

func setEnv(env []string, key, value string) []string {
	prefix := key + "="
	out := env[:0:0]
	for _, kv := range env {
		if !strings.HasPrefix(kv, prefix) {
			out = append(out, kv)
		}
	}
	return append(out, prefix+value)
}

// lookPath resolves a command without a slash against the child's PATH, as
// subprocess does, rather than this process's.
func lookPath(name, searchPath string) string {
	if strings.Contains(name, "/") {
		return name
	}
	for _, dir := range strings.Split(searchPath, ":") {
		if dir == "" {
			dir = "."
		}
		candidate := path.Join(dir, name)
		if info, err := os.Stat(candidate); err == nil && !info.IsDir() && info.Mode()&0o111 != 0 {
			return candidate
		}
	}
	return name
}

// run starts argv with env and returns what sys.exit would have made of
// subprocess's return code: the status, or for a signal, -signal & 0xff.
func run(argv, env []string, stdout *os.File) int {
	var searchPath string
	for _, kv := range env {
		if v, ok := strings.CutPrefix(kv, "PATH="); ok {
			searchPath = v
		}
	}
	cmd := exec.Command(lookPath(argv[0], searchPath), argv[1:]...)
	cmd.Args[0] = argv[0]
	cmd.Env = env
	cmd.Stdin = os.Stdin
	cmd.Stdout = stdout
	cmd.Stderr = os.Stderr
	err := cmd.Run()
	if err == nil {
		return 0
	}
	// The child's stderr is already ours, but a child killed by a signal, or
	// one that exits non-zero in silence, leaves the action with no reason.
	fmt.Fprintln(os.Stderr, shellJoin(argv))
	var exit *exec.ExitError
	if !errors.As(err, &exit) {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	fmt.Fprintf(os.Stderr, "%s: %s\n", argv[0], exit)
	if code := exit.ExitCode(); code >= 0 {
		return code
	}
	return exitCodeOfSignal(exit)
}

// shellJoin is shlex.join: argv quoted so it can be pasted into a shell.
func shellJoin(argv []string) string {
	quoted := make([]string, len(argv))
	for i, a := range argv {
		if a != "" && strings.Trim(a, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./-_") == "" {
			quoted[i] = a
		} else {
			quoted[i] = "'" + strings.ReplaceAll(a, "'", `'"'"'`) + "'"
		}
	}
	return strings.Join(quoted, " ")
}

// pythonPath is str(pathlib.PurePosixPath(p)): repeated slashes and "."
// components go, ".." stays, and exactly two leading slashes are kept.
func pythonPath(p string) string {
	if p == "" {
		return "."
	}
	root := ""
	switch {
	case strings.HasPrefix(p, "//") && !strings.HasPrefix(p, "///"):
		root = "//"
	case strings.HasPrefix(p, "/"):
		root = "/"
	}
	var parts []string
	for _, part := range strings.Split(p, "/") {
		if part != "" && part != "." {
			parts = append(parts, part)
		}
	}
	if len(parts) == 0 {
		if root == "" {
			return "."
		}
		return root
	}
	return root + strings.Join(parts, "/")
}

// pythonDirname is os.path.dirname: everything before the last slash, with
// trailing slashes dropped unless that leaves nothing but slashes.
func pythonDirname(p string) string {
	i := strings.LastIndex(p, "/") + 1
	head := p[:i]
	if head != "" && strings.Trim(head, "/") != "" {
		head = strings.TrimRight(head, "/")
	}
	return head
}

// pythonWithoutSuffix is PurePosixPath.with_suffix(""): the last suffix of the
// final component goes, unless the only dot leads the name or ends it.
func pythonWithoutSuffix(p string) string {
	slash := strings.LastIndex(p, "/") + 1
	name := p[slash:]
	if i := strings.LastIndex(name, "."); i > 0 && i < len(name)-1 {
		return p[:slash] + name[:i]
	}
	return p
}
