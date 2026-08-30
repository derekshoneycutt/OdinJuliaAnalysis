#+test
package main

import "base:runtime"
import vmem "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:testing"

Analysis_Test_Fixture :: struct {
    directory: string,
    path: string,
}

PROCEDURE_METRICS_FIXTURE :: `package fixture

Sample_Type :: struct {
    sample_field: int,
}

Sample_Enum :: enum {
    Sample_Value,
}

SAMPLE_CONSTANT :: 1
Forwarded_Type :: external.Forwarded_Type
FORWARDED_CONSTANT :: external.FORWARDED_CONSTANT
PACKAGE_GLOBAL := 2
@(rodata)
RODATA_GLOBAL := [?]int{3, 4}
@(rodata)
RODATA_FIRST, RODATA_SECOND := 5, 6

foreign import fixture_library "system:fixture.lib"

foreign fixture_library {
    Bad_Foreign :: proc(
        Bad_A, Bad_B, Bad_C, Bad_D, Bad_E, Bad_F: int) ->
        (first, second: int, flag: bool) ---
}

// Return the selected value.
choose :: proc(a, b: int) -> int {
    local_value := a
    _ = b
    if a > 0 {
        return local_value
    }
    return b
}

// Return three values for result-count analysis.
triple :: proc() -> (first, second: int, flag: bool) {
    return 1, 2, true
}

undocumented :: proc() {}

caller :: proc() {
    choose(1, 2)
}
`

ALLOCATION_CLASSIFICATION_FIXTURE :: `package fixture

// Exercise representative allocation forms.
allocate :: proc() {
    values := make([dynamic]int)
    append(&values, 1)
    _ = new(int, context.allocator)
}
`

// Write one temporary Odin source fixture using the supplied arena.
write_analysis_test_fixture :: proc(
    t: ^testing.T,
    source: string,
    allocator: runtime.Allocator) -> Analysis_Test_Fixture {
    directory, directory_error := os.make_directory_temp(
        "", "odinjuliaanalysis-odin-engine-*", allocator)
    testing.expect(t, directory_error == nil)
    if directory_error != nil {
        return {}
    }
    path, path_error := filepath.join({directory, "fixture.odin"}, allocator)
    testing.expect(t, path_error == nil)
    if path_error != nil {
        return {directory = directory}
    }
    write_error := os.write_entire_file(path, source)
    testing.expect(t, write_error == nil)
    return {directory = directory, path = path}
}

// Return the named procedure metric from an analyzed file.
find_test_procedure :: proc(
    summary: ^File_Summary,
    name: string) -> (^Procedure_Metric, bool) {
    for &procedure in summary.procedures {
        if procedure.name == name {
            return &procedure, true
        }
    }
    return nil, false
}

// Return the first finding matching a rule and optional operation.
find_test_finding :: proc(
    summary: ^File_Summary,
    rule_id: string,
    operation := "") -> (^Finding, bool) {
    for &finding in summary.findings {
        if finding.rule_id == rule_id &&
            (operation == "" || finding.operation == operation) {
            return &finding, true
        }
    }
    return nil, false
}

// Return the first declaration symbol matching a name and kind.
find_test_symbol :: proc(
    summary: ^File_Summary,
    name: string,
    kind: string) -> (^Declaration_Symbol, bool) {
    for &symbol in summary.symbols {
        if symbol.name == name && symbol.kind == kind {
            return &symbol, true
        }
    }
    return nil, false
}

// Verify one named symbol remains a variable while carrying read-only data metadata.
test_expect_rodata_symbol :: proc(
    t: ^testing.T, summary: ^File_Summary, name: string) {
    symbol, found := find_test_symbol(summary, name, "variable")
    testing.expect(t, found)
    if found {
        testing.expect(t, symbol.is_rodata)
    }
}

// Return the first explicit call edge matching one caller and callee.
find_test_call_edge :: proc(
    summary: ^File_Summary,
    caller: string,
    callee: string) -> (^Call_Edge, bool) {
    for &edge in summary.call_edges {
        if edge.caller == caller && edge.callee == callee {
            return &edge, true
        }
    }
    return nil, false
}

// Return one parser-tokenized procedure body by declaration name.
find_test_procedure_body :: proc(
    summary: ^File_Summary,
    name: string) -> (^Procedure_Body, bool) {
    for &body in summary.procedure_bodies {
        if body.name == name {
            return &body, true
        }
    }
    return nil, false
}

// Verify procedure counts, return counts, complexity, and documentation state.
verify_test_procedure_metrics :: proc(t: ^testing.T, summary: ^File_Summary) {
    choose, choose_found := find_test_procedure(summary, "choose")
    testing.expect(t, choose_found)
    if choose_found {
        testing.expect_value(t, choose.parameter_count, 2)
        testing.expect_value(t, choose.return_count, 1)
        testing.expect_value(t, choose.cyclomatic_complexity, 2)
        testing.expect(t, choose.documented)
    }
    triple, triple_found := find_test_procedure(summary, "triple")
    testing.expect(t, triple_found)
    if triple_found {
        testing.expect_value(t, triple.return_count, 3)
    }
    undocumented, undocumented_found := find_test_procedure(summary, "undocumented")
    testing.expect(t, undocumented_found)
    if undocumented_found {
        testing.expect_value(t, undocumented.cyclomatic_complexity, 1)
        testing.expect(t, !undocumented.documented)
    }
}

// Verify documentation and mutable-global findings from the metrics fixture.
verify_test_analysis_findings :: proc(t: ^testing.T, summary: ^File_Summary) {
    missing_doc, missing_doc_found := find_test_finding(summary, "ODIN-DOC-MISSING")
    testing.expect(t, missing_doc_found)
    if missing_doc_found {
        testing.expect_value(t, missing_doc.subject, "undocumented")
        testing.expect_value(t, missing_doc.certainty, "definite")
    }
    missing_doc_count := 0
    for finding in summary.findings {
        if finding.rule_id == "ODIN-DOC-MISSING" {
            missing_doc_count += 1
        }
    }
    testing.expect_value(t, missing_doc_count, 2)
    mutable_global, mutable_global_found := find_test_finding(
        summary, "ODIN-NONCONST-GLOBAL")
    testing.expect(t, mutable_global_found)
    if mutable_global_found {
        testing.expect_value(t, mutable_global.subject, "PACKAGE_GLOBAL")
        testing.expect_value(t, mutable_global.operation, "global")
        testing.expect_value(t, mutable_global.certainty, "definite")
    }
    mutable_global_count := 0
    for finding in summary.findings {
        if finding.rule_id == "ODIN-NONCONST-GLOBAL" {
            mutable_global_count += 1
        }
    }
    testing.expect_value(t, mutable_global_count, 1)
}

// Verify all declaration kinds emitted from the metrics fixture.
verify_test_declaration_symbols :: proc(t: ^testing.T, summary: ^File_Summary) {
    _, type_found := find_test_symbol(summary, "Sample_Type", "type")
    _, field_found := find_test_symbol(summary, "sample_field", "field")
    _, enum_found := find_test_symbol(summary, "Sample_Enum", "type")
    _, enum_value_found := find_test_symbol(summary, "Sample_Value", "enum_value")
    _, constant_found := find_test_symbol(summary, "SAMPLE_CONSTANT", "constant")
    _, forwarded_type_found := find_test_symbol(summary, "Forwarded_Type", "type")
    _, forwarded_constant_found := find_test_symbol(
        summary, "FORWARDED_CONSTANT", "constant")
    _, procedure_found := find_test_symbol(summary, "choose", "procedure")
    _, foreign_procedure_found := find_test_symbol(
        summary, "Bad_Foreign", "procedure")
    _, foreign_parameter_found := find_test_symbol(
        summary, "Bad_A", "parameter")
    _, parameter_found := find_test_symbol(summary, "a", "parameter")
    _, variable_found := find_test_symbol(summary, "local_value", "variable")
    testing.expect(t, type_found)
    testing.expect(t, field_found)
    testing.expect(t, enum_found)
    testing.expect(t, enum_value_found)
    testing.expect(t, constant_found)
    testing.expect(t, forwarded_type_found)
    testing.expect(t, forwarded_constant_found)
    testing.expect(t, procedure_found)
    testing.expect(t, !foreign_procedure_found)
    testing.expect(t, !foreign_parameter_found)
    testing.expect(t, parameter_found)
    testing.expect(t, variable_found)
    test_expect_rodata_symbol(t, summary, "RODATA_GLOBAL")
    test_expect_rodata_symbol(t, summary, "RODATA_FIRST")
    test_expect_rodata_symbol(t, summary, "RODATA_SECOND")
    _, discard_found := find_test_symbol(summary, "_", "variable")
    testing.expect(t, !discard_found)
}

// Verify explicit native call extraction and lexical caller scope.
verify_test_call_edges :: proc(t: ^testing.T, summary: ^File_Summary) {
    edge, found := find_test_call_edge(summary, "caller", "choose")
    testing.expect(t, found)
    if found {
        testing.expect_value(t, edge.kind, "direct")
    }
}

// Verify native body tokenization excludes formatting while retaining syntax.
verify_test_procedure_bodies :: proc(t: ^testing.T, summary: ^File_Summary) {
    body, found := find_test_procedure_body(summary, "caller")
    testing.expect(t, found)
    if found {
        testing.expect(t, len(body.tokens) > 0)
        testing.expect_value(t, body.tokens[0], "{")
    }
}

// Verify representative implicit, growth, and explicit allocation findings.
verify_test_allocation_findings :: proc(t: ^testing.T, summary: ^File_Summary) {
    implicit, implicit_found := find_test_finding(
        summary, "ODIN-ALLOCATION-IMPLICIT", "make")
    testing.expect(t, implicit_found)
    if implicit_found {
        testing.expect_value(t, implicit.procedure, "allocate")
        testing.expect_value(t, implicit.target, "[dynamic]int")
        testing.expect_value(t, implicit.certainty, "definite")
    }
    growth, growth_found := find_test_finding(
        summary, "ODIN-ALLOCATION-DYNAMIC-GROWTH", "append")
    testing.expect(t, growth_found)
    if growth_found {
        testing.expect_value(t, growth.target, "values")
        testing.expect_value(t, growth.certainty, "potential")
    }
    unknown, unknown_found := find_test_finding(
        summary, "ODIN-ALLOCATION-UNKNOWN", "new")
    testing.expect(t, unknown_found)
    if unknown_found {
        testing.expect_value(t, unknown.allocator_source, "context.allocator")
    }
}

// Verify parser-backed procedure metrics and documentation findings.
@(test)
odin_engine_test_procedure_metrics :: proc(t: ^testing.T) {
    arena: vmem.Arena
    arena_error := vmem.arena_init_static(&arena)
    testing.expect(t, arena_error == nil)
    if arena_error != nil {
        return
    }
    defer vmem.arena_destroy(&arena)
    allocator := vmem.arena_allocator(&arena)
    context.allocator = allocator
    fixture := write_analysis_test_fixture(t, PROCEDURE_METRICS_FIXTURE, allocator)
    defer if fixture.directory != "" {
        _ = os.remove_all(fixture.directory)
    }

    summary := analyze_file(fixture.path, allocator)
    testing.expect(t, summary.parsed)
    testing.expect_value(t, summary.syntax_errors, 0)
    testing.expect_value(t, len(summary.procedures), 4)
    testing.expect_value(t, len(summary.interop_signatures), 1)
    testing.expect_value(t, summary.interop_signatures[0].symbol, "Bad_Foreign")
    testing.expect_value(t, summary.interop_signatures[0].direction, "import")
    testing.expect_value(t, summary.struct_count, 1)
    verify_test_procedure_metrics(t, &summary)
    verify_test_analysis_findings(t, &summary)
    verify_test_declaration_symbols(t, &summary)
    verify_test_call_edges(t, &summary)
    verify_test_procedure_bodies(t, &summary)
}

// Verify allocation findings retain category, procedure, target, and certainty.
@(test)
odin_engine_test_allocation_classification :: proc(t: ^testing.T) {
    arena: vmem.Arena
    arena_error := vmem.arena_init_static(&arena)
    testing.expect(t, arena_error == nil)
    if arena_error != nil {
        return
    }
    defer vmem.arena_destroy(&arena)
    allocator := vmem.arena_allocator(&arena)
    context.allocator = allocator
    fixture := write_analysis_test_fixture(
        t, ALLOCATION_CLASSIFICATION_FIXTURE, allocator)
    defer if fixture.directory != "" {
        _ = os.remove_all(fixture.directory)
    }

    summary := analyze_file(fixture.path, allocator)
    testing.expect(t, summary.parsed)
    verify_test_allocation_findings(t, &summary)
}

// Verify malformed Odin source produces parser errors without procedure metrics.
@(test)
odin_engine_test_syntax_failure :: proc(t: ^testing.T) {
    arena: vmem.Arena
    arena_error := vmem.arena_init_static(&arena)
    testing.expect(t, arena_error == nil)
    if arena_error != nil {
        return
    }
    defer vmem.arena_destroy(&arena)
    allocator := vmem.arena_allocator(&arena)
    context.allocator = allocator
    fixture := write_analysis_test_fixture(
        t, "package fixture\n\nbroken :: proc( {\n", allocator)
    defer if fixture.directory != "" {
        _ = os.remove_all(fixture.directory)
    }

    summary := analyze_file(fixture.path, allocator)
    testing.expect(t, summary.parsed)
    testing.expect(t, summary.syntax_errors > 0)
    testing.expect_value(t, len(summary.procedures), 0)
}
