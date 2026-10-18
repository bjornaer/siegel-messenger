package main

import "testing"

func TestBlockedUsername(t *testing.T) { // ID-06
	for _, n := range []string{"admin", "adm1n", "admin_2", "president", "presidente2026", "guardia.civil",
		"siegel_support", "siegelteam", "theofficialana", "bundeskanzler", "fuck_you", "xnigg3rx", "puta", "pedo", "rey"} {
		if !blockedUsername(n) {
			t.Error("must be blocked:", n)
		}
	}
	for _, n := range []string{"ana", "computadora", "torpedo", "siegelmann", "kingston", "grape", "scrapbook", "nazir", "pedro", "reyes"} {
		if blockedUsername(n) {
			t.Error("must be allowed:", n)
		}
	}
}
