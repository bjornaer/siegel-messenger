package main

import (
	_ "embed"
	"strings"
)

// ID-06: reserved and offensive names, kept as plain lists product can edit.
var (
	//go:embed usernames/reserved.txt
	reservedTxt string
	//go:embed usernames/offensive.txt
	offensiveTxt string

	reserved       = map[string]bool{}
	offensiveExact = map[string]bool{}
	offensiveParts []string
	lookalikes     = strings.NewReplacer("0", "o", "1", "i", "3", "e", "4", "a", "5", "s", "7", "t", "_", "", ".", "")
)

func init() {
	for _, l := range strings.Split(reservedTxt, "\n") {
		if l = strings.TrimSpace(l); l != "" && l[0] != '#' {
			reserved[l] = true
		}
	}
	for _, l := range strings.Split(offensiveTxt, "\n") {
		if l = strings.TrimSpace(l); l == "" || l[0] == '#' {
			continue
		} else if w, ok := strings.CutPrefix(l, "="); ok {
			offensiveExact[w] = true
		} else {
			offensiveParts = append(offensiveParts, l)
		}
	}
}

// blockedUsername is true for a reserved or offensive name, including look-alikes such as
// "Adm1n", "president_2026" or "siegel.support".
func blockedUsername(name string) bool {
	trimmed := strings.TrimRight(name, "0123456789_.")
	n := lookalikes.Replace(trimmed)
	if reserved[n] || offensiveExact[n] {
		return true
	}
	// "siegel" plus a reserved word ("siegelsupport", "officialsiegel"); "siegelmann" stays fine.
	if rest := strings.Replace(n, "siegel", "", 1); rest != n && (rest == "" || reserved[rest]) {
		return true
	}
	for _, w := range []string{"official", "oficial", "offiziell"} {
		if strings.Contains(n, w) {
			return true
		}
	}
	for _, p := range offensiveParts {
		if strings.Contains(n, p) {
			return true
		}
	}
	return false
}
