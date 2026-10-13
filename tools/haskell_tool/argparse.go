package main

import (
	"fmt"
	"os"
	"regexp"
	"strings"
	"unicode/utf8"
)

// The subset of CPython 3.13's argparse that ghc_wrapper.py and
// ghc_pkg_registerer.py used, reproduced exactly, because the build's argument
// files were written for it: a repeated store option keeps its last value, a
// nargs="*" option takes every following token that does not look like an
// option, a long option may be abbreviated to any unique prefix, and
// "@file" expands to the file's lines, recursively.
// https://docs.python.org/3.13/library/argparse.html

type arity int

const (
	one  arity = iota // nargs=None: exactly one value
	many              // nargs="*": zero or more values
	zero              // a flag such as --help
)

type option struct {
	name     string // "--ghc-dir"
	short    string // "-h", if it has one
	arity    arity
	repeated bool // action="append"
	required bool
}

type parsed struct {
	values map[string][]string // by option name; absent when never given
	extras []string            // what parse_known_args returns as unknown
	help   bool                // a zero-arity option stopped the parse, as --help exits
}

func (p parsed) last(name string) (string, bool) {
	v, ok := p.values[name]
	if !ok || len(v) == 0 {
		return "", false
	}
	return v[len(v)-1], true
}

type usageError string

func (e usageError) Error() string { return string(e) }

var negativeNumber = regexp.MustCompile(`^-\d+$|^-\d*\.\d+$`)

type match struct {
	opt      *option
	explicit *string // the value after "=", if any
}

// classify is argparse's _parse_optional: nil for a positional ('A'), a match
// with a nil opt for an unknown optional ('O').
func classify(arg string, opts []option) (*match, error) {
	if arg == "" || arg[0] != '-' {
		return nil, nil
	}
	for i := range opts {
		if opts[i].name == arg || opts[i].short != "" && opts[i].short == arg {
			return &match{opt: &opts[i]}, nil
		}
	}
	if len(arg) == 1 {
		return nil, nil
	}
	if before, after, ok := strings.Cut(arg, "="); ok {
		for i := range opts {
			if opts[i].name == before || opts[i].short != "" && opts[i].short == before {
				return &match{opt: &opts[i], explicit: &after}, nil
			}
		}
	}
	var found []match
	if strings.HasPrefix(arg, "--") {
		prefix, after, hasValue := strings.Cut(arg, "=")
		for i := range opts {
			if strings.HasPrefix(opts[i].name, prefix) {
				m := match{opt: &opts[i]}
				if hasValue {
					value := after
					m.explicit = &value
				}
				found = append(found, m)
			}
		}
	} else {
		// "-hx" is -h with the explicit argument "x". A long option can match
		// only as a prefix, which it cannot be: "--x" never starts with "-y".
		for i := range opts {
			if opts[i].short != "" && opts[i].short == arg[:2] {
				rest := arg[2:]
				found = append(found, match{opt: &opts[i], explicit: &rest})
			} else if strings.HasPrefix(opts[i].name, arg) {
				found = append(found, match{opt: &opts[i]})
			}
		}
	}
	if len(found) > 1 {
		names := make([]string, len(found))
		for i, m := range found {
			names[i] = m.opt.name
		}
		return nil, usageError(fmt.Sprintf("ambiguous option: %s could match %s", arg, strings.Join(names, ", ")))
	}
	if len(found) == 1 {
		return &found[0], nil
	}
	if negativeNumber.MatchString(arg) || strings.Contains(arg, " ") {
		return nil, nil
	}
	return &match{}, nil
}

// splitLines is Python's str.splitlines: every line boundary it knows, and no
// empty last line for a trailing terminator.
func splitLines(s string) []string {
	var lines []string
	start := 0
	for i := 0; i < len(s); {
		r, size := rune(s[i]), 1
		if r >= 0x80 {
			r, size = utf8.DecodeRuneInString(s[i:])
		}
		switch r {
		case '\n', '\v', '\f', '\x1c', '\x1d', '\x1e', 0x85, 0x2028, 0x2029:
			lines = append(lines, s[start:i])
			i += size
			start = i
		case '\r':
			lines = append(lines, s[start:i])
			i += size
			if i < len(s) && s[i] == '\n' {
				i++
			}
			start = i
		default:
			i += size
		}
	}
	if start < len(s) {
		lines = append(lines, s[start:])
	}
	return lines
}

// expandFiles is argparse's _read_args_from_files with "@" as the prefix.
func expandFiles(args []string) ([]string, error) {
	var out []string
	for _, arg := range args {
		if arg == "" || arg[0] != '@' {
			out = append(out, arg)
			continue
		}
		content, err := os.ReadFile(arg[1:])
		if err != nil {
			return nil, usageError(err.Error())
		}
		inner, err := expandFiles(splitLines(string(content)))
		if err != nil {
			return nil, err
		}
		out = append(out, inner...)
	}
	return out, nil
}

// parseKnown is parse_known_args, after any "@" expansion.
func parseKnown(args []string, opts []option) (parsed, error) {
	type token struct {
		m          *match
		positional bool // a value an option may take; "--" is not one
	}
	tokens := make([]token, len(args))
	for i, arg := range args {
		if arg == "--" {
			// No option takes "--" as a value. It and everything after it
			// are positionals, which here pass through as extras.
			for j := i + 1; j < len(args); j++ {
				tokens[j] = token{positional: true}
			}
			break
		}
		m, err := classify(arg, opts)
		if err != nil {
			return parsed{}, err
		}
		tokens[i] = token{m: m, positional: m == nil}
	}

	p := parsed{values: map[string][]string{}}
	for i := 0; i < len(args); {
		t := tokens[i]
		if t.positional || t.m == nil || t.m.opt == nil {
			p.extras = append(p.extras, args[i])
			i++
			continue
		}
		opt := t.m.opt
		var values []string
		i++
		switch {
		case opt.arity == zero:
			if t.m.explicit != nil {
				return parsed{}, usageError(fmt.Sprintf("argument %s: ignored explicit argument '%s'", opt.name, *t.m.explicit))
			}
			p.help = true
			return p, nil
		case t.m.explicit != nil:
			values = []string{*t.m.explicit}
		case opt.arity == one:
			if i >= len(args) || !tokens[i].positional {
				return parsed{}, usageError(fmt.Sprintf("argument %s: expected one argument", opt.name))
			}
			values = []string{args[i]}
			i++
		default:
			for i < len(args) && tokens[i].positional {
				values = append(values, args[i])
				i++
			}
		}
		if opt.repeated {
			p.values[opt.name] = append(p.values[opt.name], values...)
		} else {
			p.values[opt.name] = values
		}
	}
	var missing []string
	for _, opt := range opts {
		if _, ok := p.values[opt.name]; opt.required && !ok {
			missing = append(missing, opt.name)
		}
	}
	if len(missing) > 0 {
		return parsed{}, usageError("the following arguments are required: " + strings.Join(missing, ", "))
	}
	return p, nil
}
