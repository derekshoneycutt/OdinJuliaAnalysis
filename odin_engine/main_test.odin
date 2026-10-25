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

// Verify native control findings use body tokens rather than header line spans.
@(test)
odin_engine_test_control_bodies :: proc(t: ^testing.T) {
    arena: vmem.Arena
    arena_error := vmem.arena_init_static(&arena)
    testing.expect(t, arena_error == nil)
    if arena_error != nil {
        return
    }
    defer vmem.arena_destroy(&arena)
    allocator := vmem.arena_allocator(&arena)
    context.allocator = allocator
    source := "package fixture\n" +
        "sample :: proc() {\n" +
        "    if true {} else do return\n" +
        "    for {}\n" +
        "    for value in values do consume(value)\n" +
        "    if true {\n        return\n    }\n" +
        "}\n"
    fixture := write_analysis_test_fixture(t, source, allocator)
    defer if fixture.directory != "" {
        _ = os.remove_all(fixture.directory)
    }
    summary := analyze_file(fixture.path, allocator)
    testing.expect(t, summary.parsed)
    testing.expect_value(t, summary.syntax_errors, 0)
    expected_lines := [4]int{3, 3, 4, 5}
    expected_columns := [4]int{13, 21, 9, 25}
    count := 0
    for finding in summary.findings {
        if finding.rule_id == "ODIN-SINGLE-LINE-CONTROL-BODY" ||
            finding.rule_id == "ODIN-DO-CONTROL-BODY" {
            if count < 4 {
                testing.expect_value(t, finding.line, expected_lines[count])
                testing.expect_value(t, finding.column, expected_columns[count])
            }
            count += 1
        }
    }
    testing.expect_value(t, count, 4)
}

// Verify declaration and expression ASTs classify spacing separators once.
@(test)
odin_engine_test_separator_evidence :: proc(t: ^testing.T) {
    arena: vmem.Arena
    arena_error := vmem.arena_init_static(&arena)
    testing.expect(t, arena_error == nil)
    if arena_error != nil {
        return
    }
    defer vmem.arena_destroy(&arena)
    allocator := vmem.arena_allocator(&arena)
    context.allocator = allocator
    source := "package fixture\n" +
        "typed: int = 1\n" +
        "typed_constant: int : 2\n" +
        "inferred := 3\n" +
        "split_inferred : = 4\n" +
        "CONSTANT :: 4\n" +
        "SPLIT_CONSTANT : /* internal */ : 5\n" +
        "Point :: struct { x: int, y: int }\n" +
        "example :: proc(parameter: int = 1) {\n" +
        "    value = parameter\n" +
        "    consume(named = 2)\n" +
        "    Point{x = 1}\n" +
        "}\n"
    fixture := write_analysis_test_fixture(t, source, allocator)
    defer if fixture.directory != "" {
        _ = os.remove_all(fixture.directory)
    }
    summary := analyze_file(fixture.path, allocator)
    testing.expect(t, summary.parsed)
    testing.expect_value(t, summary.syntax_errors, 0)
    testing.expect_value(t, len(summary.separators), 17)
    testing.expect_value(t, separator_evidence_counts(&summary), [4]int{5, 5, 2, 5})
    testing.expect_value(
        t, separator_adjacency_counts(&summary), [2]int{4, 2})
}

// Count parser-backed separators by the four configured syntax policies.
separator_evidence_counts :: proc(summary: ^File_Summary) -> [4]int {
    counts := [4]int{}
    for item in summary.separators {
        if item.kind == "colon" {
            counts[0] += 1
        } else if item.kind == "equals" {
            counts[1] += 1
        } else if item.kind == "inferred" {
            counts[2] += 1
        } else if item.kind == "constant" {
            counts[3] += 1
        }
    }
    return counts
}

// Count adjacent and split punctuation in logical declaration operators.
separator_adjacency_counts :: proc(summary: ^File_Summary) -> [2]int {
    counts := [2]int{}
    for item in summary.separators {
        if item.internal_required {
            if item.internal_adjacent {
                counts[0] += 1
            } else {
                counts[1] += 1
            }
        }
    }
    return counts
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

import vmem "core:mem/virtual"

// Exercise representative allocation forms.
allocate :: proc() {
    static_arena: vmem.Arena
    _ = vmem.arena_init_static(&static_arena)
    growing_arena: vmem.Arena
    _ = vmem.arena_init_growing(&growing_arena)
    values := make([dynamic]int)
    append(&values, 1)
    _ = new(int, context.allocator)
}
`

CONTEXT_ALLOCATOR_FIXTURE :: `package fixture

use_ambient :: proc(value: int = context.allocator) -> bool {
    return true
}

custom_owner :: proc() {
    owner_allocator := heap_allocator()
    external_allocator_api(owner_allocator)
}

context_restore :: proc() {
    saved_allocator := context.allocator
    context.allocator = nil_allocator()
    context.allocator = saved_allocator
}

positional_call :: proc() {
    external_allocator_api(context.allocator)
}

named_call :: proc() {
    external_allocator_api(
        allocator = context.allocator,
    )
}

third_party_call :: proc() {
    _, _ = filepath.join([]string{"one", "two"}, context.allocator)
}

unrestored :: proc() {
    retained_allocator := context.allocator
    external_allocator_api(retained_allocator)
}

invalid_fallback :: proc() {
    selected_allocator := heap_allocator()
    selected_allocator = context.allocator
}

field_storage :: proc() {
    state := struct {
        allocator: int,
    }{
        allocator = context.allocator,
    }
    state.allocator = context.allocator
}

indirect_alias :: proc() {
    opaque := heap_allocator()
    opaque = context.allocator
    external_allocator_api(opaque)
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

// Verify valid instrumentation, aliases, call forms, defaults, and API boundaries.
verify_context_allocator_relay_findings :: proc(
    t: ^testing.T, summary: ^File_Summary) {
    default_finding, default_found := find_context_allocator_finding(
        summary, "allocator-default", "value")
    testing.expect(t, default_found)
    if default_found {
        testing.expect_value(t, default_finding.allocator_source, "context.allocator")
        testing.expect_value(t, default_finding.line, 3)
        testing.expect_value(t, default_finding.column, 34)
    }
    _, tracking_alias_found := find_context_allocator_finding(
        summary, "allocator-alias", "saved_allocator")
    testing.expect(t, !tracking_alias_found)
    _, custom_alias_found := find_context_allocator_finding(
        summary, "allocator-alias", "owner_allocator")
    testing.expect(t, !custom_alias_found)
    _, retained_alias_found := find_context_allocator_finding(
        summary, "allocator-alias", "retained_allocator")
    testing.expect(t, retained_alias_found)
    positional, positional_found := find_context_allocator_finding(
        summary, "allocator-pass", "external_allocator_api", 19)
    testing.expect(t, positional_found)
    if positional_found {
        testing.expect_value(t, positional.column, 28)
    }
    named, named_found := find_context_allocator_finding(
        summary, "allocator-pass", "external_allocator_api", 24)
    testing.expect(t, named_found)
    if named_found {
        testing.expect_value(t, named.column, 21)
    }
    third_party, third_party_site_found := find_context_allocator_finding(
        summary, "allocator-pass", "filepath.join", 29)
    testing.expect(t, third_party_site_found)
    if third_party_site_found {
        testing.expect_value(t, third_party.column, 50)
    }
}

// Verify fallback, struct storage, and indirect-alias findings.
verify_context_allocator_storage_findings :: proc(
    t: ^testing.T, summary: ^File_Summary) {
    fallback, fallback_site_found := find_context_allocator_finding(
        summary, "allocator-fallback", "selected_allocator", 39)
    testing.expect(t, fallback_site_found)
    if fallback_site_found {
        testing.expect_value(t, fallback.column, 26)
    }
    _, compound_store_found := find_context_allocator_finding(
        summary, "allocator-store", "allocator", 46)
    testing.expect(t, compound_store_found)
    _, field_store_found := find_context_allocator_finding(
        summary, "allocator-store", "state.allocator", 48)
    testing.expect(t, field_store_found)
    indirect_alias, indirect_alias_found := find_context_allocator_finding(
        summary, "allocator-alias", "", 53)
    testing.expect(t, indirect_alias_found)
    if indirect_alias_found {
        testing.expect_value(t, indirect_alias.column, 14)
        testing.expect_value(t, indirect_alias.target, "opaque")
    }
}

// Verify forbidden ambient allocator forms and accepted ownership instrumentation.
@(test)
odin_engine_test_context_allocator_policy :: proc(t: ^testing.T) {
    arena: vmem.Arena
    arena_error := vmem.arena_init_static(&arena)
    testing.expect(t, arena_error == nil)
    if arena_error != nil {
        return
    }
    defer vmem.arena_destroy(&arena)
    allocator := vmem.arena_allocator(&arena)
    context.allocator = allocator
    fixture := write_analysis_test_fixture(t, CONTEXT_ALLOCATOR_FIXTURE, allocator)
    defer if fixture.directory != "" {
        _ = os.remove_all(fixture.directory)
    }

    summary := analyze_file(fixture.path, allocator)
    testing.expect(t, summary.parsed)
    testing.expect_value(t, summary.syntax_errors, 0)
    context_findings := 0
    for finding in summary.findings {
        if finding.rule_id == "ODIN-ALLOCATION-CONTEXT" {
            context_findings += 1
        }
    }
    testing.expect_value(t, context_findings, 9)
    verify_context_allocator_relay_findings(t, &summary)
    verify_context_allocator_storage_findings(t, &summary)
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

// Return a context-allocator finding matching its operation and target.
find_context_allocator_finding :: proc(
    summary: ^File_Summary,
    operation: string,
    target: string,
    expected_line := 0) -> (^Finding, bool) {
    for &finding in summary.findings {
        if finding.rule_id == "ODIN-ALLOCATION-CONTEXT" &&
            finding.operation == operation &&
            (target == "" || finding.target == target) &&
            (expected_line == 0 || finding.line == expected_line) {
            return &finding, true
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
    static_arena, static_found := find_test_finding(
        summary, "ODIN-ALLOCATION-ARENA", "arena_init_static")
    testing.expect(t, static_found)
    if static_found {
        testing.expect_value(t, static_arena.procedure, "allocate")
        testing.expect_value(t, static_arena.target, "static_arena")
    }
    growing_arena, growing_found := find_test_finding(
        summary, "ODIN-ALLOCATION-ARENA", "arena_init_growing")
    testing.expect(t, growing_found)
    if growing_found {
        testing.expect_value(t, growing_arena.procedure, "allocate")
        testing.expect_value(t, growing_arena.target, "growing_arena")
    }
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
    context_alloc, context_alloc_found := find_test_finding(
        summary, "ODIN-ALLOCATION-CONTEXT", "new")
    testing.expect(t, context_alloc_found)
    if context_alloc_found {
        testing.expect_value(t, context_alloc.allocator_source, "context.allocator")
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
