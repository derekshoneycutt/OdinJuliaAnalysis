#+test
package main

import "core:testing"

// Verify the Odin greeting remains stable.
@(test)
greeting_test :: proc(t: ^testing.T) {
    testing.expect(t, greeting() == "Hello from Odin!")
}
