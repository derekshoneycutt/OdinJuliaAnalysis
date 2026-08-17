package main

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import vmem "core:mem/virtual"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:os"
import "core:strings"

SCHEMA_VERSION :: "3.9.0"
ENGINE_VERSION :: "0.12.0"
CLOSING_PAREN_MESSAGE :: "Closing `)` must share the final argument or parameter line."

Finding :: struct {
    rule_id: string,
    line: int,
    column: int,
    message: string,
    subject: string,
    operation: string,
    procedure: string,
    target: string,
    allocator_source: string,
    certainty: string,
}

Procedure_Metric :: struct {
    name: string,
    start_line: int,
    end_line: int,
    parameter_count: int,
    return_count: int,
    cyclomatic_complexity: int,
    documented: bool,
    start_offset: int,
    end_offset: int,
}

Declaration_Symbol :: struct {
    name: string,
    kind: string,
    line: int,
    column: int,
    is_struct: bool,
}

Import_Edge :: struct {
    target: string,
    binding: string,
    is_using: bool,
    line: int,
    column: int,
}

Reference_Record :: struct {
    name: string,
    scope: string,
    line: int,
    column: int,
}

Call_Edge :: struct {
    caller: string,
    callee: string,
    kind: string,
    line: int,
    column: int,
}

Procedure_Body :: struct {
    name: string,
    tokens: [dynamic]string,
    start_line: int,
    end_line: int,
}

Interop_Signature :: struct {
    symbol: string,
    direction: string,
    library: string,
    calling_convention: string,
    parameter_types: [dynamic]string,
    return_types: [dynamic]string,
    line: int,
    column: int,
}

File_Summary :: struct {
    path: string,
    parsed: bool,
    syntax_errors: int,
    syntax_warnings: int,
    struct_count: int,
    findings: [dynamic]Finding,
    procedures: [dynamic]Procedure_Metric,
    symbols: [dynamic]Declaration_Symbol,
    imports: [dynamic]Import_Edge,
    references: [dynamic]Reference_Record,
    call_edges: [dynamic]Call_Edge,
    procedure_bodies: [dynamic]Procedure_Body,
    interop_signatures: [dynamic]Interop_Signature,
}

Engine_Response :: struct {
    schema_version: string,
    engine_version: string,
    files: []File_Summary,
}

Parenthesis_Frame :: struct {
    last_interior_line: int,
}

Procedure_Scope :: struct {
    name: string,
    start_offset: int,
    end_offset: int,
}

Analysis_Visitor_Data :: struct {
    source: string,
    findings: ^[dynamic]Finding,
    procedure_scopes: ^[dynamic]Procedure_Scope,
    procedures: ^[dynamic]Procedure_Metric,
    symbols: ^[dynamic]Declaration_Symbol,
    imports: ^[dynamic]Import_Edge,
    references: ^[dynamic]Reference_Record,
    call_edges: ^[dynamic]Call_Edge,
    procedure_bodies: ^[dynamic]Procedure_Body,
    interop_signatures: ^[dynamic]Interop_Signature,
    allocator: runtime.Allocator,
}

// Configure optional metadata for one allocation finding.
Allocation_Finding_Options :: struct {
    allocator: ^ast.Expr,
    certainty: string,
    target: string,
}

// Initialize Odin's global tokenizer table before parallel test workers run.
@(init)
initialize_tokenizer :: proc "contextless" () {
    context = runtime.default_context()
    warmup_tokenizer: tokenizer.Tokenizer
    tokenizer.init(&warmup_tokenizer, "", "")
}

// Record one identifier declaration for policy evaluation by the Julia adapter.
append_symbol :: proc(
    data: ^Analysis_Visitor_Data,
    expression: ^ast.Expr,
    kind: string,
    is_struct := false) {
    name, named := identifier_name(expression)
    if !named || name == "_" {
        return
    }
    append(data.symbols, Declaration_Symbol {
        name = name,
        kind = kind,
        line = expression.pos.line,
        column = expression.pos.column,
        is_struct = is_struct,
    })
}

// Record every named field in a parameter or struct field list.
append_field_symbols :: proc(
    data: ^Analysis_Visitor_Data,
    fields: ^ast.Field_List,
    kind: string) {
    if fields == nil {
        return
    }
    for field in fields.list {
        for name in field.names {
            append_symbol(data, name, kind)
        }
    }
}

// Record symbols declared by one value declaration.
append_value_declaration_symbols :: proc(
    data: ^Analysis_Visitor_Data,
    declaration: ^ast.Value_Decl) {
    for name, index in declaration.names {
        if index >= len(declaration.values) {
            kind := "constant" if !declaration.is_mutable else "variable"
            append_symbol(data, name, kind)
            continue
        }
        value := ast.unparen_expr(declaration.values[index])
        #partial switch typed_value in value.derived {
        case ^ast.Proc_Lit:
            append_symbol(data, name, "procedure")
            append_field_symbols(data, typed_value.type.params, "parameter")
        case ^ast.Proc_Group:
            append_symbol(data, name, "procedure")
        case ^ast.Struct_Type:
            append_symbol(data, name, "type", true)
            append_field_symbols(data, typed_value.fields, "field")
        case ^ast.Enum_Type:
            append_symbol(data, name, "type")
            for enum_field in typed_value.fields {
                normalized_field := ast.unparen_expr(enum_field)
                if field_value, ok := normalized_field.derived.(^ast.Field_Value); ok {
                    append_symbol(data, field_value.field, "enum_value")
                } else {
                    append_symbol(data, enum_field, "enum_value")
                }
            }
        case ^ast.Union_Type, ^ast.Distinct_Type, ^ast.Bit_Set_Type:
            append_symbol(data, name, "type")
        case:
            append_symbol(data, name, value_declaration_kind(declaration, value))
        }
    }
}

// Classify a value declaration after structural type forms have been handled.
value_declaration_kind :: proc(
    declaration: ^ast.Value_Decl,
    value: ^ast.Expr) -> string {
    if declaration.is_mutable {
        return "variable"
    }
    return "type" if is_clear_type_forward(value) else "constant"
}

// Return whether an immutable identifier or selector clearly names an Odin type.
is_clear_type_forward :: proc(expression: ^ast.Expr) -> bool {
    name, named := identifier_name(expression)
    if !named || len(name) < 2 || name[0] < 'A' || name[0] > 'Z' {
        return false
    }
    segment_start := false
    has_lowercase := false
    for character in name[1:] {
        if character == '_' {
            if segment_start {
                return false
            }
            segment_start = true
        } else if segment_start {
            if character < 'A' || character > 'Z' {
                return false
            }
            segment_start = false
        } else if character >= 'a' && character <= 'z' {
            has_lowercase = true
        } else if character < '0' || character > '9' {
            return false
        }
    }
    return !segment_start && has_lowercase
}

// Return whether a declaration has one identifier attribute.
has_attribute :: proc(declaration: ^ast.Value_Decl, expected: string) -> bool {
    for attribute in declaration.attributes {
        for element in attribute.elems {
            name, named := identifier_name(element)
            if named && name == expected {
                return true
            }
        }
    }
    return false
}

// Return one string-valued declaration attribute or an empty string.
attribute_string :: proc(
    declaration: ^ast.Value_Decl,
    expected: string,
    source: string) -> string {
    for attribute in declaration.attributes {
        for element in attribute.elems {
            field_value, valued := ast.unparen_expr(element).derived.(^ast.Field_Value)
            if !valued {
                continue
            }
            name, named := identifier_name(field_value.field)
            if named && name == expected {
                return strings.trim(expression_source(source, field_value.value), "\"")
            }
        }
    }
    return ""
}

// Append one type for every ABI slot represented by a field list.
append_abi_types :: proc(
    result: ^[dynamic]string,
    fields: ^ast.Field_List,
    source: string) {
    if fields == nil {
        return
    }
    for field in fields.list {
        type_name := expression_source(source, field.type)
        count := max(len(field.names), 1)
        for _ in 0 ..< count {
            append(result, type_name)
        }
    }
}

// Return the normalized source-level calling convention of a procedure.
procedure_calling_convention :: proc(procedure: ^ast.Proc_Lit) -> string {
    #partial switch convention in procedure.type.calling_convention {
    case string:
        return strings.trim(convention, "\"")
    case ast.Proc_Calling_Convention_Extra:
        return "c"
    }
    return "odin"
}

// Record foreign imports and exported procedures as normalized ABI signatures.
append_interop_signature :: proc(
    data: ^Analysis_Visitor_Data,
    declaration: ^ast.Value_Decl) {
    for value, index in declaration.values {
        procedure, is_procedure := ast.unparen_expr(value).derived.(^ast.Proc_Lit)
        if !is_procedure || index >= len(declaration.names) {
            continue
        }
        direction := "import" if procedure.body == nil else
            "export" if has_attribute(declaration, "export") else ""
        if direction == "" {
            continue
        }
        name, named := identifier_name(declaration.names[index])
        if !named {
            continue
        }
        symbol := attribute_string(declaration, "link_name", data.source)
        if symbol == "" {
            symbol = name
        }
        parameters := make([dynamic]string, 0, data.allocator)
        returns := make([dynamic]string, 0, data.allocator)
        append_abi_types(&parameters, procedure.type.params, data.source)
        append_abi_types(&returns, procedure.type.results, data.source)
        append(data.interop_signatures, Interop_Signature {
            symbol = symbol,
            direction = direction,
            calling_convention = procedure_calling_convention(procedure),
            parameter_types = parameters,
            return_types = returns,
            line = declaration.names[index].pos.line,
            column = declaration.names[index].pos.column,
        })
    }
}

// Report mutable package-scope values while excluding procedure-local declarations.
check_nonconst_global :: proc(
    data: ^Analysis_Visitor_Data,
    declaration: ^ast.Value_Decl) {
    if !declaration.is_mutable ||
        containing_procedure(data, declaration.pos.offset) != "" {
        return
    }
    for name_expression in declaration.names {
        name, named := identifier_name(name_expression)
        if !named || name == "_" {
            continue
        }
        append(data.findings, Finding {
            rule_id = "ODIN-NONCONST-GLOBAL",
            line = name_expression.pos.line,
            column = name_expression.pos.column,
            message = fmt.aprintf(
                "Odin package global `%s` is mutable; use a constant or local.",
                name),
            subject = name,
            operation = "global",
            certainty = "definite",
        })
    }
}

// Return the number of declared inputs represented by an Odin parameter list.
parameter_count :: proc(parameters: ^ast.Field_List) -> int {
    if parameters == nil {
        return 0
    }
    count := 0
    for field in parameters.list {
        count += max(len(field.names), 1)
    }
    return count
}

// Return the number of declared results represented by an Odin result list.
return_count :: proc(results: ^ast.Field_List) -> int {
    if results == nil {
        return 0
    }
    count := 0
    for field in results.list {
        count += max(len(field.names), 1)
    }
    return count
}

// Increment complexity for the narrowest procedure containing a decision node.
record_decision :: proc(data: ^Analysis_Visitor_Data, node: ^ast.Node) {
    metric_index := -1
    metric_width := max(int)
    for metric, index in data.procedures {
        if node.pos.offset < metric.start_offset || node.end.offset > metric.end_offset {
            continue
        }
        width := metric.end_offset - metric.start_offset
        if width < metric_width {
            metric_index = index
            metric_width = width
        }
    }
    if metric_index >= 0 {
        data.procedures[metric_index].cyclomatic_complexity += 1
    }
}

// Return source text normalized for use as an allocation-policy target.
allocation_target :: proc(expression: ^ast.Expr, source: string) -> string {
    if expression == nil {
        return ""
    }
    target := expression_source(source, expression)
    if len(target) > 0 && target[0] == '&' {
        return strings.trim_space(target[1:])
    }
    return target
}

// Return the narrowest named procedure scope containing a source offset.
containing_procedure :: proc(data: ^Analysis_Visitor_Data, offset: int) -> string {
    result := ""
    result_width := max(int)
    for scope in data.procedure_scopes {
        if offset < scope.start_offset || offset > scope.end_offset {
            continue
        }
        width := scope.end_offset - scope.start_offset
        if width < result_width {
            result = scope.name
            result_width = width
        }
    }
    return result
}

// Return the exact source text covered by an AST expression.
expression_source :: proc(source: string, expression: ^ast.Expr) -> string {
    start := clamp(expression.pos.offset, 0, len(source))
    end := clamp(expression.end.offset, start, len(source))
    return strings.trim_space(source[start:end])
}

// Return the exact source text covered by an AST statement.
statement_source :: proc(source: string, statement: ^ast.Stmt) -> string {
    start := clamp(statement.pos.offset, 0, len(source))
    end := clamp(statement.end.offset, start, len(source))
    return strings.trim_space(source[start:end])
}

// Return the terminal identifier represented by an identifier or selector.
identifier_name :: proc(expression: ^ast.Expr) -> (string, bool) {
    normalized_expression := ast.unparen_expr(expression)
    if identifier, ok := normalized_expression.derived.(^ast.Ident); ok {
        return identifier.name, true
    }
    if selector, ok := normalized_expression.derived.(^ast.Selector_Expr); ok {
        return selector.field.name, true
    }
    return "", false
}

// Find a named argument in a call expression.
named_argument :: proc(call: ^ast.Call_Expr, name: string) -> ^ast.Expr {
    for argument in call.args {
        field_value, ok := argument.derived.(^ast.Field_Value)
        if !ok {
            continue
        }
        field_name, named := identifier_name(field_value.field)
        if named && field_name == name {
            return field_value.value
        }
    }
    return nil
}

// Classify an explicit allocator expression into its allocation policy rule.
known_allocator_category :: proc(expression: ^ast.Expr) -> string {
    if identifier, ok := ast.unparen_expr(expression).derived.(^ast.Ident); ok {
        if strings.contains(identifier.name, "allocator") {
            return "ODIN-ALLOCATION-CUSTOM"
        }
    }
    if selector, ok := ast.unparen_expr(expression).derived.(^ast.Selector_Expr); ok {
        owner, owner_ok := identifier_name(selector.expr)
        if owner_ok && owner == "context" && selector.field.name == "allocator" {
            return "ODIN-ALLOCATION-CONTEXT"
        }
        if owner_ok && owner == "context" && selector.field.name == "temp_allocator" {
            return "ODIN-ALLOCATION-TEMPORARY"
        }
    }
    if call, ok := ast.unparen_expr(expression).derived.(^ast.Call_Expr); ok {
        if selector, selector_ok :=
            ast.unparen_expr(call.expr).derived.(^ast.Selector_Expr);
            selector_ok {
            owner, owner_ok := identifier_name(selector.expr)
            if owner_ok && owner == "heap" && selector.field.name == "allocator" {
                return "ODIN-ALLOCATION-HEAP"
            }
        }
    }
    return "ODIN-ALLOCATION-UNKNOWN"
}

// Find an allocator passed positionally to a make or new call.
positional_allocator :: proc(call: ^ast.Call_Expr, operation: string) -> ^ast.Expr {
    if operation == "new" {
        if len(call.args) >= 2 {
            return call.args[1]
        }
        return nil
    }
    if operation != "make" {
        return nil
    }
    for index := len(call.args) - 1; index >= 1; index -= 1 {
        candidate := call.args[index]
        if known_allocator_category(candidate) != "ODIN-ALLOCATION-UNKNOWN" {
            return candidate
        }
        candidate_name, named := identifier_name(candidate)
        if named && strings.contains(candidate_name, "allocator") {
            return candidate
        }
    }
    return nil
}

// Record an allocation finding for the current call expression.
append_allocation_finding :: proc(
    data: ^Analysis_Visitor_Data,
    call: ^ast.Call_Expr,
    operation: string,
    rule_id: string,
    options: Allocation_Finding_Options = {}) {
    allocator_source := ""
    if options.allocator != nil {
        allocator_source = expression_source(data.source, options.allocator)
    }
    certainty := options.certainty if options.certainty != "" else "definite"
    append(data.findings, Finding {
        rule_id = rule_id,
        line = call.pos.line,
        column = call.pos.column,
        message = fmt.aprintf("%s may allocate memory.", operation),
        subject = operation,
        operation = operation,
        procedure = containing_procedure(data, call.pos.offset),
        target = options.target,
        allocator_source = allocator_source,
        certainty = certainty,
    })
}

// Report a recognized allocator initialization call.
check_allocator_initialization :: proc(
    data: ^Analysis_Visitor_Data,
    call: ^ast.Call_Expr) -> bool {
    selector, ok := ast.unparen_expr(call.expr).derived.(^ast.Selector_Expr)
    if !ok {
        return false
    }
    owner, named := identifier_name(selector.expr)
    if !named || owner != "vmem" || selector.field.name != "arena_init_static" {
        return false
    }
    append_allocation_finding(
        data,
        call,
        "arena_init_static",
        "ODIN-ALLOCATION-ARENA",
        {
            target = allocation_target(
                call.args[0] if len(call.args) > 0 else nil,
                data.source),
        })
    return true
}

// Register source ranges for named procedure declarations.
register_procedure_scopes :: proc(
    data: ^Analysis_Visitor_Data,
    declaration: ^ast.Value_Decl) {
    for value, index in declaration.values {
        #partial switch procedure in value.derived {
        case ^ast.Proc_Lit:
            if index >= len(declaration.names) {
                continue
            }
            name, named := identifier_name(declaration.names[index])
            if !named {
                continue
            }
            append(data.procedure_scopes, Procedure_Scope {
                name = name,
                start_offset = value.pos.offset,
                end_offset = value.end.offset,
            })
            append(data.procedures, Procedure_Metric {
                name = name,
                start_line = value.pos.line,
                end_line = value.end.line,
                parameter_count = parameter_count(procedure.type.params),
                return_count = return_count(procedure.type.results),
                cyclomatic_complexity = 1,
                documented = declaration.docs != nil,
                start_offset = value.pos.offset,
                end_offset = value.end.offset,
            })
            if procedure.body != nil {
                append(data.procedure_bodies, Procedure_Body {
                    name = name,
                    tokens = canonical_body_tokens(
                        statement_source(data.source, procedure.body),
                        data.allocator),
                    start_line = procedure.body.pos.line,
                    end_line = procedure.body.end.line,
                })
            }
        }
    }
}

// Return parser-tokenized procedure body text without comments or formatting.
canonical_body_tokens :: proc(
    source: string,
    allocator: runtime.Allocator) -> [dynamic]string {
    tokens := make([dynamic]string, 0, allocator)
    body_tokenizer: tokenizer.Tokenizer
    tokenizer.init(&body_tokenizer, source, "")
    for {
        token := tokenizer.scan(&body_tokenizer)
        #partial switch token.kind {
        case .Comment:
            continue
        case .EOF:
            return tokens
        case:
            append(&tokens, token.text)
        }
    }
}

// Report each named procedure declaration that lacks attached documentation.
check_procedure_documentation :: proc(
    data: ^Analysis_Visitor_Data,
    declaration: ^ast.Value_Decl) {
    if declaration.docs != nil {
        return
    }
    for value, index in declaration.values {
        #partial switch _ in value.derived {
        case ^ast.Proc_Lit, ^ast.Proc_Group:
            if index >= len(declaration.names) {
                continue
            }
            name, named := identifier_name(declaration.names[index])
            if !named {
                continue
            }
            append(data.findings, Finding {
                rule_id = "ODIN-DOC-MISSING",
                line = declaration.names[index].pos.line,
                column = declaration.names[index].pos.column,
                message = fmt.aprintf(
                    "Named Odin procedure `%s` requires a doc comment.",
                    name),
                subject = name,
                operation = "documentation",
                certainty = "definite",
            })
        }
    }
}

// Record a named import declaration for naming policy evaluation.
append_import_symbol :: proc(
    data: ^Analysis_Visitor_Data,
    declaration: ^ast.Import_Decl) {
    if len(declaration.name.text) == 0 {
        return
    }
    append(data.symbols, Declaration_Symbol {
        name = declaration.name.text,
        kind = "import",
        line = declaration.name.pos.line,
        column = declaration.name.pos.column,
    })
}

// Record one parser-backed Odin package import.
append_import_edge :: proc(
    data: ^Analysis_Visitor_Data,
    declaration: ^ast.Import_Decl) {
    append(data.imports, Import_Edge {
        target = strings.trim(declaration.relpath.text, "\""),
        binding = declaration.name.text,
        is_using = declaration.is_using,
        line = declaration.relpath.pos.line,
        column = declaration.relpath.pos.column,
    })
}

// Record one parser-visible Odin identifier reference.
append_reference :: proc(data: ^Analysis_Visitor_Data, identifier: ^ast.Ident) {
    if identifier.name == "_" {
        return
    }
    append(data.references, Reference_Record {
        name = identifier.name,
        scope = containing_procedure(data, identifier.pos.offset),
        line = identifier.pos.line,
        column = identifier.pos.column,
    })
}

// Record one explicit Odin call with its narrowest lexical procedure scope.
append_call_edge :: proc(data: ^Analysis_Visitor_Data, call: ^ast.Call_Expr) {
    callee := expression_source(data.source, call.expr)
    if callee == "" {
        return
    }
    _, direct := ast.unparen_expr(call.expr).derived.(^ast.Ident)
    _, qualified := ast.unparen_expr(call.expr).derived.(^ast.Selector_Expr)
    kind := "direct" if direct else "qualified" if qualified else "dynamic"
    append(data.call_edges, Call_Edge {
        caller = containing_procedure(data, call.pos.offset),
        callee = callee,
        kind = kind,
        line = call.pos.line,
        column = call.pos.column,
    })
}

// Classify one allocation-producing call and append its finding.
check_allocation_call :: proc(
    data: ^Analysis_Visitor_Data,
    call: ^ast.Call_Expr) {
    if check_allocator_initialization(data, call) {
        return
    }
    operation, named := identifier_name(call.expr)
    if !named {
        return
    }
    _, unqualified := ast.unparen_expr(call.expr).derived.(^ast.Ident)
    if !unqualified {
        return
    }
    if operation == "append" || operation == "reserve" || operation == "resize" {
        append_dynamic_growth_finding(data, call, operation)
        return
    }
    if operation != "make" && operation != "new" {
        return
    }

    append_constructing_allocation_finding(data, call, operation)
}

// Record a dynamic-container growth operation as a potential allocation.
append_dynamic_growth_finding :: proc(
    data: ^Analysis_Visitor_Data,
    call: ^ast.Call_Expr,
    operation: string) {
    append_allocation_finding(
        data,
        call,
        operation,
        "ODIN-ALLOCATION-DYNAMIC-GROWTH",
        {
            certainty = "potential",
            target = allocation_target(
                call.args[0] if len(call.args) > 0 else nil,
                data.source),
        })
}

// Record a make or new call using its explicit or implicit allocator.
append_constructing_allocation_finding :: proc(
    data: ^Analysis_Visitor_Data,
    call: ^ast.Call_Expr,
    operation: string) {
    allocator := named_argument(call, "allocator")
    if allocator == nil {
        allocator = positional_allocator(call, operation)
    }
    if allocator == nil {
        append_allocation_finding(
            data,
            call,
            operation,
            "ODIN-ALLOCATION-IMPLICIT",
            {
                target = allocation_target(
                    call.args[0] if len(call.args) > 0 else nil,
                    data.source),
            })
        return
    }
    append_allocation_finding(
        data,
        call,
        operation,
        known_allocator_category(allocator),
        {
            allocator = allocator,
            target = allocation_target(
                call.args[0] if len(call.args) > 0 else nil,
                data.source),
        })
}

// Inspect declarations, decisions, and calls during an analysis AST walk.
visit_allocations :: proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
    if node == nil {
        return visitor
    }
    data := (^Analysis_Visitor_Data)(visitor.data)
    if declaration, is_declaration := node.derived.(^ast.Value_Decl); is_declaration {
        register_procedure_scopes(data, declaration)
        check_procedure_documentation(data, declaration)
        check_nonconst_global(data, declaration)
        append_value_declaration_symbols(data, declaration)
            append_interop_signature(data, declaration)
        return visitor
    }
    if import_declaration, is_import := node.derived.(^ast.Import_Decl); is_import {
        append_import_symbol(data, import_declaration)
        append_import_edge(data, import_declaration)
        return visitor
    }
    if identifier, is_identifier := node.derived.(^ast.Ident); is_identifier {
        append_reference(data, identifier)
        return visitor
    }
    #partial switch _ in node.derived {
    case ^ast.If_Stmt, ^ast.For_Stmt, ^ast.Range_Stmt, ^ast.Case_Clause:
        record_decision(data, node)
    }
    if call, is_call := node.derived.(^ast.Call_Expr); is_call {
        append_call_edge(data, call)
        check_allocation_call(data, call)
    }
    return visitor
}

// Walk a parsed file to collect documentation and allocation findings.
check_allocations :: proc(
    file: ^ast.File,
    summary: ^File_Summary,
    allocator: runtime.Allocator) {
    procedure_scopes := make([dynamic]Procedure_Scope, 0, allocator)
    data := Analysis_Visitor_Data {
        source = file.src,
        findings = &summary.findings,
        procedure_scopes = &procedure_scopes,
        procedures = &summary.procedures,
        symbols = &summary.symbols,
        imports = &summary.imports,
        references = &summary.references,
        call_edges = &summary.call_edges,
        procedure_bodies = &summary.procedure_bodies,
        interop_signatures = &summary.interop_signatures,
        allocator = allocator,
    }
    visitor := ast.Visitor {
        visit = visit_allocations,
        data = rawptr(&data),
    }
    ast.walk(&visitor, file)
}

// Report closing parentheses placed apart from the final interior token.
check_closing_parentheses :: proc(
    source: string,
    path: string,
    findings: ^[dynamic]Finding,
    allocator: runtime.Allocator) {
    odin_tokenizer: tokenizer.Tokenizer
    tokenizer.init(&odin_tokenizer, source, path)
    frames := make([dynamic]Parenthesis_Frame, 0, allocator)

    for {
        token := tokenizer.scan(&odin_tokenizer)
        #partial switch token.kind {
        case .Open_Paren:
            if len(frames) > 0 {
                frames[len(frames) - 1].last_interior_line = token.pos.line
            }
            append(&frames, Parenthesis_Frame{})
        case .Close_Paren:
            if len(frames) == 0 {
                continue
            }
            frame := pop(&frames)
            if frame.last_interior_line > 0 &&
                frame.last_interior_line != token.pos.line {
                append(findings, Finding {
                    rule_id = "ODIN-CLOSING-PAREN-PLACEMENT",
                    line = token.pos.line,
                    column = token.pos.column,
                    message = CLOSING_PAREN_MESSAGE,
                })
            }
            if len(frames) > 0 {
                frames[len(frames) - 1].last_interior_line = token.pos.line
            }
        case .Comment:
        case .EOF:
            return
        case:
            if len(frames) > 0 {
                frames[len(frames) - 1].last_interior_line = token.pos.line
            }
        }
    }
}

// Parse and analyze one Odin source file.
analyze_file :: proc(path: string, allocator: runtime.Allocator) -> File_Summary {
    summary := File_Summary {
        path = path,
        findings = make([dynamic]Finding, 0, allocator),
        procedures = make([dynamic]Procedure_Metric, 0, allocator),
        symbols = make([dynamic]Declaration_Symbol, 0, allocator),
        imports = make([dynamic]Import_Edge, 0, allocator),
        references = make([dynamic]Reference_Record, 0, allocator),
        interop_signatures = make([dynamic]Interop_Signature, 0, allocator),
    }
    source, read_error := os.read_entire_file(path, allocator)
    if read_error != nil {
        summary.syntax_errors = 1
        return summary
    }
    check_closing_parentheses(string(source), path, &summary.findings, allocator)

    no_position := tokenizer.Pos{}
    file := ast.new(ast.File, no_position, no_position)
    file.fullpath = path
    file.src = string(source)

    odin_parser := parser.default_parser()
    summary.parsed = parser.parse_file(&odin_parser, file)
    summary.syntax_errors = file.syntax_error_count
    summary.syntax_warnings = file.syntax_warning_count
    if summary.parsed && summary.syntax_errors == 0 {
        check_allocations(file, &summary, allocator)
        for symbol in summary.symbols {
            if symbol.is_struct {
                summary.struct_count += 1
            }
        }
    }
    return summary
}

// Analyze command-line paths and emit the schema-versioned JSON response.
main :: proc() {
    if len(os.args) < 2 {
        fmt.eprintln("Usage: odin_engine <file.odin> [file.odin ...]")
        os.exit(2)
    }

    analysis_arena: vmem.Arena
    if arena_error := vmem.arena_init_static(&analysis_arena); arena_error != nil {
        fmt.eprintln("Odin analysis engine could not initialize its memory arena.")
        os.exit(2)
    }
    defer vmem.arena_destroy(&analysis_arena)
    analysis_allocator := vmem.arena_allocator(&analysis_arena)
    context.allocator = analysis_allocator

    summaries := make([]File_Summary, len(os.args) - 1, analysis_allocator)
    for path, index in os.args[1:] {
        summaries[index] = analyze_file(path, analysis_allocator)
    }

    response := Engine_Response{
        schema_version = SCHEMA_VERSION,
        engine_version = ENGINE_VERSION,
        files = summaries,
    }
    encoded, marshal_error := json.marshal(response)
    if marshal_error != nil {
        fmt.eprintln("Odin analysis engine could not serialize its response.")
        os.exit(2)
    }
    fmt.println(string(encoded))
}