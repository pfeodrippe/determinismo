// SPDX-License-Identifier: MIT

// Command determinismo-catalog writes each Go package's assertion catalog: a file
// (determinismo_catalog.go) whose init declares every call to the SDK's assertions whose message
// is a literal, so that an assertion no timeline reaches is judged too (Antithesis's catalog; Go
// has no hook to find them as code loads). Run it before building, from go generate:
//
//	//go:generate go run github.com/pfeodrippe/determinismo/sdk/go/cmd/determinismo-catalog ./...
//
// Arguments are directories, or patterns ending in /... (each directory under it).
package main

import (
	"bytes"
	"fmt"
	"go/ast"
	"go/format"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

const sdkPath = "github.com/pfeodrippe/determinismo/sdk/go"
const output = "determinismo_catalog.go"

// The SDK's assertions: their kind, and where the message is among the arguments.
var assertions = map[string]struct {
	kind     string
	position int
}{
	"Always": {"always", 1}, "AlwaysOrUnreachable": {"always_or_unreachable", 1},
	"Sometimes": {"sometimes", 1}, "Reachable": {"reachable", 0}, "Unreachable": {"unreachable", 0},
	"AlwaysSome": {"always", 1}, "SometimesAll": {"sometimes", 1},
}

func init() {
	for _, relation := range []string{"GreaterThan", "GreaterThanOrEqual", "LessThan", "LessThanOrEqual",
		"GreaterThanOrEqualTo", "LessThanOrEqualTo"} {
		assertions["Always"+relation] = struct {
			kind     string
			position int
		}{"always", 2}
		assertions["Sometimes"+relation] = struct {
			kind     string
			position int
		}{"sometimes", 2}
	}
}

type declaration struct{ kind, message string }

func main() {
	patterns := os.Args[1:]
	if len(patterns) == 0 {
		patterns = []string{"./..."}
	}
	written := 0
	for _, pattern := range patterns {
		for _, directory := range directories(pattern) {
			wrote, err := catalog(directory)
			if err != nil {
				fmt.Fprintf(os.Stderr, "determinismo-catalog: %s: %v\n", directory, err)
				os.Exit(1)
			}
			if wrote {
				written++
			}
		}
	}
	fmt.Fprintf(os.Stderr, "determinismo-catalog: %d packages' catalogs written\n", written)
}

func directories(pattern string) []string {
	if !strings.HasSuffix(pattern, "/...") {
		return []string{pattern}
	}
	var found []string
	root := strings.TrimSuffix(pattern, "/...")
	filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		name := entry.Name()
		if entry.IsDir() && path != root && (strings.HasPrefix(name, ".") || name == "vendor" || name == "testdata") {
			return filepath.SkipDir
		}
		if entry.IsDir() {
			found = append(found, path)
		}
		return nil
	})
	return found
}

// catalog writes the directory's catalog file if its package has assertions with literal messages
// (and removes a stale one if it has none).
func catalog(directory string) (bool, error) {
	files, err := filepath.Glob(filepath.Join(directory, "*.go"))
	if err != nil {
		return false, err
	}
	set := token.NewFileSet()
	packageName := ""
	found := map[declaration]bool{}
	for _, file := range files {
		base := filepath.Base(file)
		if strings.HasSuffix(base, "_test.go") || base == output {
			continue
		}
		parsed, err := parser.ParseFile(set, file, nil, 0)
		if err != nil {
			return false, err
		}
		packageName = parsed.Name.Name
		names := map[string]bool{}
		for _, spec := range parsed.Imports {
			path, _ := strconv.Unquote(spec.Path.Value)
			if path != sdkPath {
				continue
			}
			name := "determinismo"
			if spec.Name != nil {
				name = spec.Name.Name
			}
			names[name] = true
		}
		if len(names) == 0 {
			continue
		}
		ast.Inspect(parsed, func(node ast.Node) bool {
			call, ok := node.(*ast.CallExpr)
			if !ok {
				return true
			}
			function := call.Fun
			if index, ok := function.(*ast.IndexExpr); ok { // AlwaysGreaterThan[int](...)
				function = index.X
			}
			selector, ok := function.(*ast.SelectorExpr)
			if !ok {
				return true
			}
			receiver, ok := selector.X.(*ast.Ident)
			if !ok || !names[receiver.Name] {
				return true
			}
			assertion, ok := assertions[selector.Sel.Name]
			if !ok || assertion.position >= len(call.Args) {
				return true
			}
			literal, ok := call.Args[assertion.position].(*ast.BasicLit)
			if !ok || literal.Kind != token.STRING {
				return true
			}
			message, err := strconv.Unquote(literal.Value)
			if err == nil && message != "" {
				found[declaration{assertion.kind, message}] = true
			}
			return true
		})
	}
	target := filepath.Join(directory, output)
	if len(found) == 0 {
		os.Remove(target)
		return false, nil
	}
	declarations := make([]declaration, 0, len(found))
	for entry := range found {
		declarations = append(declarations, entry)
	}
	sort.Slice(declarations, func(a, b int) bool {
		if declarations[a].kind != declarations[b].kind {
			return declarations[a].kind < declarations[b].kind
		}
		return declarations[a].message < declarations[b].message
	})
	var source bytes.Buffer
	fmt.Fprintf(&source, "// Code generated by determinismo-catalog. DO NOT EDIT.\n\npackage %s\n\n", packageName)
	fmt.Fprintf(&source, "import determinismo_catalog %q\n\n", sdkPath)
	source.WriteString("// The package's assertions, declared before they run (determinismo's catalog).\nfunc init() {\n")
	for _, entry := range declarations {
		fmt.Fprintf(&source, "\tdeterminismo_catalog.Declare(%q, %q)\n", entry.kind, entry.message)
	}
	source.WriteString("}\n")
	formatted, err := format.Source(source.Bytes())
	if err != nil {
		return false, err
	}
	return true, os.WriteFile(target, formatted, 0o644)
}
