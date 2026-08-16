package main

import "core:fmt"

GREETING :: "Hello from Odin!"

// Return the sample's Odin greeting.
greeting :: proc() -> string {
    return GREETING
}

// Print the Odin greeting.
main :: proc() {
    fmt.println(greeting())
}
