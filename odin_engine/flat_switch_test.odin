#+test
package main

import "base:runtime"
import vmem "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:testing"

// Check parser-derived switch shape independently of Julia policy configuration.
@(test)
odin_engine_test_flat_switch :: proc(t: ^testing.T) {
    arena: vmem.Arena
    error := vmem.arena_init_static(&arena)
    testing.expect(t, error == nil)
    if error != nil {
        return
    }
    defer vmem.arena_destroy(&arena)
    allocator := vmem.arena_allocator(&arena)
    cases := []struct {body: string, eligible: bool, outside: int}{
        {"switch x {\ncase 1:\nreturn 1\ncase:\nreturn 0\n}", true, 0},
        {"#partial switch x {\ncase 1:\nreturn 1\n}", true, 0},
        {"switch x in y {\ncase int:\nreturn x\ncase:\nreturn 0\n}", true, 0},
        {"#partial switch x in y {\ncase int:\nreturn x\n}", true, 0},
        {"switch x {\ncase 1:\n{{return 1}}\ncase:\n{}\n}", true, 0},
        {"x := 0\nswitch y {\ncase:\nx = 1\n}\nreturn x", true, 2},
        {"switch x {\ncase:\ncall(); other()\n}", false, 0},
        {"switch x {\ncase:\n{call(); other()}\n}", false, 0},
        {"switch x {\ncase:\nif true {\nreturn\n}\n}", false, 0},
        {"switch x {\ncase:\nfallthrough\n}", false, 0},
        {"switch x {\ncase:\nreturn a && b\n}", false, 0},
        {"switch x {\ncase:\nreturn a if b else c\n}", false, 0},
        {"switch x {\ncase:\nreturn a or_else b\n}", false, 0},
        {"switch x {\ncase:\na &&= b\n}", false, 0},
        {"switch x {\ncase:\nreturn\n}\nswitch y {\ncase:\nreturn\n}", false, 0},
    }
    for item in cases {
        verify_flat_switch_fixture(t, item.body, item.eligible, item.outside, allocator)
    }
}

// Verify LF/CRLF source evidence and scope-safe parser classification.
verify_flat_switch_fixture :: proc(
    t: ^testing.T, body: string, eligible: bool, outside: int,
    allocator: runtime.Allocator) {
    source := strings.concatenate(
        {"package fixture\nsample :: proc() {\n", body, "\n}\n"}, allocator)
    newlines := []string{"\n", "\r\n"}
    for newline in newlines {
        converted, _ := strings.replace_all(source, "\n", newline, allocator)
        fixture := write_analysis_test_fixture(t, converted, allocator)
        defer if fixture.directory != "" {
            _ = os.remove_all(fixture.directory)
        }
        summary := analyze_file(fixture.path, allocator)
        testing.expect(t, summary.parsed)
        testing.expect_value(t, summary.syntax_errors, 0)
        if len(summary.procedures) != 1 {
            testing.expect_value(t, len(summary.procedures), 1)
            continue
        }
        metric := summary.procedures[0]
        testing.expect_value(t, metric.flat_switch_candidate, eligible)
        if eligible {
            testing.expect_value(t, len(metric.flat_switch_outside_lines), outside)
        }
    }
}
