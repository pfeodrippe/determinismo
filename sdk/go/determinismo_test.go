// SPDX-License-Identifier: MIT

package determinismo

import (
	"bytes"
	"math/rand/v2"
	"os"
	"strings"
	"testing"
)

func TestOutsideDeterminismo(t *testing.T) {
	file := t.TempDir() + "/events.jsonl"
	os.Setenv("DETERMINISMO_SDK_LOCAL_OUTPUT", file)
	Always(RandomBelow(1) == 0, "the draw is zero", map[string]any{"n": 0})
	AlwaysGreaterThanOrEqualTo(3, 3, "three ties three", nil)
	SometimesAll([]NamedBool{{"a", true}, {"b", false}}, "a and b", nil)
	Event("started", nil)
	Output(map[string]any{"custom": 1})
	BuggifyPause("anywhere")
	if Buggify("anywhere") {
		t.Fatal("buggify outside determinismo")
	}
	if Random() >= 1 || Decide("which", []string{"a", "b"}) > 1 {
		t.Fatal("randomness out of range")
	}
	generator := rand.New(Prng())
	if generator.IntN(10) >= 10 || rand.New(Source()).IntN(5) >= 5 {
		t.Fatal("generators out of range")
	}
	Declare("sometimes", "declared in a test")
	var listed bytes.Buffer
	if err := CatalogWrite(&listed); err != nil || !strings.Contains(listed.String(), "declared in a test") {
		t.Fatalf("catalog: %q %v", listed.String(), err)
	}
	events, _ := os.ReadFile(file)
	for _, want := range []string{`"message":"the draw is zero"`, `"line":`, `"guidance"`, `"custom":1`, `"event":"started"`} {
		if !strings.Contains(string(events), want) {
			t.Fatalf("local output lacks %s:\n%s", want, events)
		}
	}
}
