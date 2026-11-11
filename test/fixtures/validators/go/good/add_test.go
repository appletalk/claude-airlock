package smoke

import "testing"

func TestAdd(t *testing.T) {
	if got := Add(2, 3); got != 5 {
		t.Fatalf("Add(2, 3) = %d, want 5", got)
	}
}

func FuzzAdd(f *testing.F) {
	f.Add(1, 2)
	f.Fuzz(func(t *testing.T, a, b int) {
		if Add(a, b) != Add(b, a) {
			t.Fatalf("Add is not commutative for %d, %d", a, b)
		}
	})
}
