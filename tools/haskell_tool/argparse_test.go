package main

import (
	"embed"
	"encoding/json"
	"io/fs"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

//go:embed testdata/cases.json testdata/at
var testdata embed.FS

// testdata/cases.json is CPython 3.13's own argparse, pathlib and str.splitlines
// on the same inputs (testdata/gen_cases.py), so each case is the answer the
// Python tools gave.
type golden struct {
	Python string `json:"python"`
	Parse  []struct {
		Tool   string              `json:"tool"`
		Argv   []string            `json:"argv"`
		Status int                 `json:"status"`
		Values map[string][]string `json:"values"`
		Extras []string            `json:"extras"`
	} `json:"parse"`
	Paths []struct {
		In            string  `json:"in"`
		Path          string  `json:"path"`
		Dirname       string  `json:"dirname"`
		WithoutSuffix *string `json:"without_suffix"`
	} `json:"paths"`
	Lines []struct {
		In    string   `json:"in"`
		Lines []string `json:"lines"`
	} `json:"lines"`
	Abi struct {
		Files map[string]string `json:"files"`
		Cases []struct {
			Path  string  `json:"path"`
			Error *string `json:"error"`
		} `json:"cases"`
	} `json:"abi"`
}

// load reads the golden cases and lays the argument files the "@" cases name
// out under a temporary working directory, so the test passes from any cwd.
func load(t *testing.T) golden {
	dir := t.TempDir()
	err := fs.WalkDir(testdata, "testdata", func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		content, err := testdata.ReadFile(path)
		if err != nil {
			return err
		}
		if err := os.MkdirAll(filepath.Join(dir, filepath.Dir(path)), 0o755); err != nil {
			return err
		}
		return os.WriteFile(filepath.Join(dir, path), content, 0o644)
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Chdir(dir)
	raw, err := testdata.ReadFile("testdata/cases.json")
	if err != nil {
		t.Fatal(err)
	}
	var g golden
	if err := json.Unmarshal(raw, &g); err != nil {
		t.Fatal(err)
	}
	return g
}

func nonEmpty(m map[string][]string) map[string][]string {
	out := map[string][]string{}
	for k, v := range m {
		if len(v) > 0 {
			out[k] = v
		}
	}
	return out
}

func TestParseMatchesCPython(t *testing.T) {
	g := load(t)
	for _, c := range g.Parse {
		var p parsed
		var err error
		status := 0
		switch c.Tool {
		case "wrap":
			var argv []string
			if argv, err = expandFiles(c.Argv); err == nil {
				p, err = parseKnown(argv, wrapOptions)
			}
		case "register":
			var help bool
			p, help, err = parseRegister(c.Argv)
			if help {
				p = parsed{}
			}
		}
		if err != nil {
			status = 2
		}
		if status != c.Status {
			t.Errorf("%s %q: status %d, CPython %d (%v)", c.Tool, c.Argv, status, c.Status, err)
			continue
		}
		if status != 0 || c.Values == nil {
			continue
		}
		got := nonEmpty(p.values)
		delete(got, "--help")
		if want := nonEmpty(c.Values); !reflect.DeepEqual(got, want) {
			t.Errorf("%s %q: values %q, CPython %q", c.Tool, c.Argv, got, want)
		}
		if len(p.extras) != len(c.Extras) || (len(c.Extras) > 0 && !reflect.DeepEqual(p.extras, c.Extras)) {
			t.Errorf("%s %q: extras %q, CPython %q", c.Tool, c.Argv, p.extras, c.Extras)
		}
	}
	t.Logf("%d cases from CPython %s", len(g.Parse), g.Python)
}

func TestPathsMatchCPython(t *testing.T) {
	for _, c := range load(t).Paths {
		if got := pythonPath(c.In); got != c.Path {
			t.Errorf("pythonPath(%q) = %q, pathlib %q", c.In, got, c.Path)
		}
		if got := pythonDirname(pythonPath(c.In)); got != c.Dirname {
			t.Errorf("pythonDirname(%q) = %q, os.path %q", c.Path, got, c.Dirname)
		}
		if c.WithoutSuffix != nil {
			if got := pythonWithoutSuffix(pythonPath(c.In)); got != *c.WithoutSuffix {
				t.Errorf("pythonWithoutSuffix(%q) = %q, pathlib %q", c.Path, got, *c.WithoutSuffix)
			}
		}
	}
}

func TestSplitLinesMatchesCPython(t *testing.T) {
	for _, c := range load(t).Lines {
		got := splitLines(c.In)
		if len(got) != len(c.Lines) || (len(got) > 0 && !reflect.DeepEqual(got, c.Lines)) {
			t.Errorf("splitLines(%q) = %q, str.splitlines %q", c.In, got, c.Lines)
		}
	}
}

func TestPluginAbiHashCheckMatchesCPython(t *testing.T) {
	g := load(t)
	for name, content := range g.Abi.Files {
		if err := os.MkdirAll(filepath.Dir(name), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(name, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	for _, c := range g.Abi.Cases {
		err := checkPluginAbiHash(pythonPath(c.Path))
		switch {
		case c.Error == nil && err != nil:
			t.Errorf("%s: %v, CPython accepts it", c.Path, err)
		case c.Error != nil && (err == nil || err.Error() != *c.Error):
			t.Errorf("%s: %v, CPython %q", c.Path, err, *c.Error)
		}
	}
}
