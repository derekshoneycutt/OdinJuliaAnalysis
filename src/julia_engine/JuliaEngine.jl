module JuliaEngine

using CodeComplexity
using JuliaSyntax

using ..OdinJuliaAnalysis: Diagnostic
using ..OdinJuliaAnalysis: EffectiveSettings
using ..OdinJuliaAnalysis: FunctionAnalysis
using ..OdinJuliaAnalysis: Ignore
using ..OdinJuliaAnalysis: NamingConvention
using ..OdinJuliaAnalysis: configured_diagnostic
using ..OdinJuliaAnalysis: executable_source_lines
using ..OdinJuliaAnalysis: load_settings
using ..OdinJuliaAnalysis: valid_identifier_name

export check_syntax
export check
export analyze_functions
export documentation_comment_lines
export struct_count

include("ClosingParentheses.jl")

const CYCLOMATIC = CyclomaticComplexity()
const COGNITIVE = CognitiveComplexity()

"""Run configured syntax, layout, and documentation checks on Julia source."""
function check(
    path::String,
    source::String,
    configuration::EffectiveSettings=load_settings())
    diagnostics = check_syntax(path, source, configuration)
    isempty(diagnostics) || return diagnostics
    append!(diagnostics, check_closing_parentheses(path, source, configuration))
    append!(diagnostics, check_documentation(path, source, configuration))
    append!(diagnostics, check_naming(path, source, configuration))
    append!(diagnostics, check_nonconst_globals(path, source, configuration))
    append!(diagnostics, check_return_tuples(path, source, configuration))
    append!(diagnostics, check_parameter_counts(path, source, configuration))
    append!(diagnostics, check_declaration_order(path, source, configuration))
    return diagnostics
end

"""Report top-level constants and structs declared after ordinary functions."""
function check_declaration_order(path, source, configuration)
    tree = JuliaSyntax.parseall(JuliaSyntax.SyntaxNode, source; filename=path)
    offsets = line_start_offsets(split(source, '\n'; keepempty=true))
    diagnostics = Diagnostic[]
    collect_declaration_order!(diagnostics, tree, path, offsets, configuration)
    return diagnostics
end

"""Check each top-level or module statement list independently."""
function collect_declaration_order!(diagnostics, node, path, offsets, configuration)
    kind = Symbol(JuliaSyntax.kind(node))
    children = something(JuliaSyntax.children(node), ())
    if kind == :toplevel
        check_statement_order!(diagnostics, children, path, offsets, configuration)
    elseif kind == :module && length(children) >= 2
        body = children[end]
        statements = something(JuliaSyntax.children(body), ())
        check_statement_order!(diagnostics, statements, path, offsets, configuration)
    end
    for child in children
        collect_declaration_order!(diagnostics, child, path, offsets, configuration)
    end
end

"""Enforce the declaration section before the ordinary-function section."""
function check_statement_order!(diagnostics, statements, path, offsets, configuration)
    struct_names = Set{String}()
    function_section = false
    for statement in statements
        kind = Symbol(JuliaSyntax.kind(statement))
        if kind == :struct
            append_declaration_order_diagnostic!(
                diagnostics,
                statement,
                function_section,
                "struct",
                path,
                offsets,
                configuration)
            name = declaration_name(statement)
            isempty(name) || push!(struct_names, name)
        elseif kind == :const
            append_declaration_order_diagnostic!(
                diagnostics,
                statement,
                function_section,
                "constant",
                path,
                offsets,
                configuration)
        elseif kind == :function
            name = declaration_name(statement)
            name in struct_names || (function_section = true)
        end
    end
end

"""Return the declared struct or function name represented by a syntax node."""
function declaration_name(node)
    children = something(JuliaSyntax.children(node), ())
    isempty(children) && return ""
    signature = children[1]
    while true
        kind = Symbol(JuliaSyntax.kind(signature))
        kind == :Identifier && return String(JuliaSyntax.sourcetext(signature))
        kind in (:where, :(::), :curly, :(=), :call) || return ""
        nested = something(JuliaSyntax.children(signature), ())
        isempty(nested) && return ""
        signature = nested[1]
    end
end

"""Append one configured Julia declaration-order finding."""
function append_declaration_order_diagnostic!(
    diagnostics,
    node,
    misplaced,
    declaration_kind,
    path,
    offsets,
    configuration)
    misplaced || return
    byte_offset = JuliaSyntax.first_byte(node)
    line = metric_line_for_offset(offsets, byte_offset)
    diagnostic = Diagnostic(
        "JULIA-DECLARATION-ORDER",
        Ignore,
        path,
        line,
        byte_offset - offsets[line] + 1,
        "Julia $(declaration_kind) declarations must appear before ordinary functions.",
        nothing,
        nothing,
        "julia-syntax",
        declaration_name(node),
        "declaration-order",
        nothing,
        "stable")
    configured = configured_diagnostic(configuration, diagnostic)
    configured === nothing || push!(diagnostics, configured)
end

"""Report Julia functions above the configured positional parameter maximum."""
function check_parameter_counts(path, source, configuration)
    diagnostics = Diagnostic[]
    maximum = configuration.parameter_counts.julia_maximum
    for item in analyze_functions(path, source)
        item.parameter_count <= maximum && continue
        diagnostic = Diagnostic(
            "JULIA-PARAMETERS-FAIL",
            Ignore,
            path,
            item.start_line,
            1,
            "Julia function `$(item.name)` has $(item.parameter_count) " *
                "non-keyword parameters; maximum is $(maximum).",
            item.parameter_count,
            maximum,
            "julia-syntax",
            item.name,
            "parameters",
            nothing,
            "stable")
        configured = configured_diagnostic(configuration, diagnostic)
        configured === nothing || push!(diagnostics, configured)
    end
    return diagnostics
end

"""Report Julia function return tuples above the configured maximum."""
function check_return_tuples(path, source, configuration)
    tree = JuliaSyntax.parseall(JuliaSyntax.SyntaxNode, source; filename=path)
    offsets = line_start_offsets(split(source, '\n'; keepempty=true))
    diagnostics = Diagnostic[]
    collect_function_return_tuples!(
        diagnostics, tree, path, offsets, configuration)
    return diagnostics
end

"""Find return sites only within each function's own lexical body."""
function collect_function_return_tuples!(diagnostics, node, path, offsets, configuration)
    kind = Symbol(JuliaSyntax.kind(node))
    children = something(JuliaSyntax.children(node), ())
    if kind in (:function, :macro, :(->)) && !isempty(children)
        name = first_measure(
            CYCLOMATIC, String(JuliaSyntax.sourcetext(node))).name
        body = children[end]
        collect_explicit_return_tuples!(
            diagnostics, body, path, offsets, configuration, name)
        append_return_tuple_diagnostic!(
            diagnostics, terminal_expression(body), path, offsets, configuration, name)
        for child in children
            collect_function_return_tuples!(
                diagnostics, child, path, offsets, configuration)
        end
    else
        for child in children
            collect_function_return_tuples!(
                diagnostics, child, path, offsets, configuration)
        end
    end
end

"""Collect explicit tuple returns while excluding nested function bodies."""
function collect_explicit_return_tuples!(
    diagnostics, node, path, offsets, configuration, name)
    kind = Symbol(JuliaSyntax.kind(node))
    children = something(JuliaSyntax.children(node), ())
    if kind in (:function, :macro, :(->))
        return
    elseif kind == :return
        isempty(children) || append_return_tuple_diagnostic!(
            diagnostics, children[end], path, offsets, configuration, name)
        return
    end
    for child in children
        collect_explicit_return_tuples!(
            diagnostics, child, path, offsets, configuration, name)
    end
end

"""Return the final expression that determines an implicit function result."""
function terminal_expression(node)
    Symbol(JuliaSyntax.kind(node)) == :block || return node
    children = something(JuliaSyntax.children(node), ())
    return isempty(children) ? node : children[end]
end

"""Append one configured oversized-return diagnostic for a tuple expression."""
function append_return_tuple_diagnostic!(
    diagnostics, node, path, offsets, configuration, name)
    Symbol(JuliaSyntax.kind(node)) == :tuple || return
    children = something(JuliaSyntax.children(node), ())
    any(child -> Symbol(JuliaSyntax.kind(child)) in (:(=), :kw), children) && return
    arity = length(children)
    maximum = configuration.return_tuples.julia_maximum
    arity <= maximum && return
    byte_offset = JuliaSyntax.first_byte(node)
    line = metric_line_for_offset(offsets, byte_offset)
    column = byte_offset - offsets[line] + 1
    diagnostic = Diagnostic(
        "JULIA-RETURN-TUPLE",
        Ignore,
        path,
        line,
        column,
        "Julia function `$(name)` returns $(arity) tuple elements; " *
            "maximum is $(maximum).",
        arity,
        maximum,
        "julia-syntax",
        name,
        "return",
        nothing,
        "stable")
    configured = configured_diagnostic(configuration, diagnostic)
    configured === nothing || push!(diagnostics, configured)
end

"""Report mutable Julia bindings declared in module or explicit global scope."""
function check_nonconst_globals(path, source, configuration)
    tree = JuliaSyntax.parseall(JuliaSyntax.SyntaxNode, source; filename=path)
    offsets = line_start_offsets(split(source, '\n'; keepempty=true))
    diagnostics = Diagnostic[]
    collect_nonconst_globals!(diagnostics, tree, path, offsets, :module)
    configured = Diagnostic[]
    for diagnostic in diagnostics
        item = configured_diagnostic(configuration, diagnostic)
        item === nothing || push!(configured, item)
    end
    return configured
end

"""Collect non-const bindings while respecting Julia lexical scopes."""
function collect_nonconst_globals!(diagnostics, node, path, offsets, scope)
    kind = Symbol(JuliaSyntax.kind(node))
    children = something(JuliaSyntax.children(node), ())
    if kind == :module && length(children) >= 2
        collect_nonconst_globals!(diagnostics, children[end], path, offsets, :module)
        return
    elseif kind == :global
        for child in children
            collect_global_bindings!(diagnostics, child, path, offsets)
        end
        return
    elseif kind in (:const, :local, :struct, :quote, :call, :macrocall)
        return
    elseif kind in (
        :function, :macro, :(->), :let, :for, :while, :generator,
        :comprehension, :do)
        for child in children
            collect_nonconst_globals!(diagnostics, child, path, offsets, :local)
        end
        return
    elseif kind == :(=) && scope == :module && !isempty(children)
        collect_module_assignment!(diagnostics, children, path, offsets)
        return
    end
    for child in children
        collect_nonconst_globals!(diagnostics, child, path, offsets, scope)
    end
end

"""Collect a module assignment or descend into a short-form function body."""
function collect_module_assignment!(diagnostics, children, path, offsets)
    if is_call_signature(children[1])
        length(children) >= 2 && collect_nonconst_globals!(
            diagnostics, children[end], path, offsets, :local)
        return
    end
    collect_global_bindings!(diagnostics, children[1], path, offsets)
end

"""Append diagnostics for identifiers in one global binding pattern."""
function collect_global_bindings!(diagnostics, node, path, offsets)
    kind = Symbol(JuliaSyntax.kind(node))
    children = something(JuliaSyntax.children(node), ())
    if kind == :Identifier
        name = String(JuliaSyntax.sourcetext(node))
        name == "_" && return
        byte_offset = JuliaSyntax.first_byte(node)
        line = metric_line_for_offset(offsets, byte_offset)
        column = byte_offset - offsets[line] + 1
        push!(diagnostics, Diagnostic(
            "JULIA-NONCONST-GLOBAL",
            Ignore,
            path,
            line,
            column,
            "Julia global `$(name)` is mutable; declare it `const` or keep it local.",
            nothing,
            nothing,
            "julia-syntax",
            name,
            "global",
            nothing,
            "stable"))
    elseif kind == :(=) && !isempty(children)
        collect_global_bindings!(diagnostics, children[1], path, offsets)
    elseif kind in (:(::), :kw, :(...)) && !isempty(children)
        collect_global_bindings!(diagnostics, children[1], path, offsets)
    elseif kind in (:tuple, :parameters)
        for child in children
            collect_global_bindings!(diagnostics, child, path, offsets)
        end
    end
end

"""Report Julia declarations that violate configured naming conventions."""
function check_naming(path, source, configuration)
    tree = JuliaSyntax.parseall(JuliaSyntax.SyntaxNode, source; filename=path)
    conventions = Dict(
        convention.kind => convention
        for convention in configuration.naming.conventions
        if convention.language == :julia)
    diagnostics = Diagnostic[]
    offsets = line_start_offsets(split(source, '\n'; keepempty=true))
    collect_naming!(diagnostics, tree, path, offsets, conventions, :top_level)
    configured = Diagnostic[]
    for diagnostic in diagnostics
        item = configured_diagnostic(configuration, diagnostic)
        item === nothing || push!(configured, item)
    end
    return configured
end

"""Collect names only from syntax positions that declare identifiers."""
function collect_naming!(diagnostics, node, path, offsets, conventions, scope)
    kind = Symbol(JuliaSyntax.kind(node))
    children = something(JuliaSyntax.children(node), ())
    if kind == :module && length(children) >= 2
        check_name!(diagnostics, children[1], :module, path, offsets, conventions)
        collect_naming!(diagnostics, children[end], path, offsets, conventions, :module)
        return
    elseif kind in (:struct, :abstract, :primitive) && !isempty(children)
        collect_type_names!(diagnostics, kind, children, path, offsets, conventions)
        kind == :struct && return
    elseif kind in (:function, :macro) && length(children) >= 2
        collect_signature_names!(diagnostics, children[1], path, offsets, conventions)
        collect_naming!(diagnostics, children[end], path, offsets, conventions, :function)
        return
    elseif kind == :const && !isempty(children)
        collect_binding_names!(
            diagnostics, children[1], :constant, path, offsets, conventions)
        return
    elseif kind == :(=) && !isempty(children)
        collect_assignment_names!(
            diagnostics, children, path, offsets, conventions, scope) && return
    end
    for child in children
        collect_naming!(diagnostics, child, path, offsets, conventions, scope)
    end
end

"""Collect a declared type name and any struct fields."""
function collect_type_names!(diagnostics, kind, children, path, offsets, conventions)
    check_name!(diagnostics, children[1], :type, path, offsets, conventions)
    kind == :struct && length(children) >= 2 && collect_struct_fields!(
        diagnostics, children[end], path, offsets, conventions)
end

"""Collect names introduced by long-form and short-form assignments."""
function collect_assignment_names!(
    diagnostics,
    children,
    path,
    offsets,
    conventions,
    scope)
    if is_call_signature(children[1])
        collect_signature_names!(diagnostics, children[1], path, offsets, conventions)
        length(children) >= 2 && collect_naming!(
            diagnostics, children[end], path, offsets, conventions, :function)
        return true
    end
    scope == :function && collect_binding_names!(
        diagnostics, children[1], :variable, path, offsets, conventions)
    return false
end

"""Collect struct field declarations without inspecting referenced type names."""
function collect_struct_fields!(diagnostics, block, path, offsets, conventions)
    for field in something(JuliaSyntax.children(block), ())
        field_kind = Symbol(JuliaSyntax.kind(field))
        children = something(JuliaSyntax.children(field), ())
        if field_kind in (:(::), :(=)) && !isempty(children)
            collect_binding_names!(
                diagnostics, children[1], :field, path, offsets, conventions)
        elseif field_kind == :Identifier
            check_name!(diagnostics, field, :field, path, offsets, conventions)
        elseif field_kind in (:function, :macro)
            collect_naming!(
                diagnostics, field, path, offsets, conventions, :function)
        end
    end
end

"""Collect a function name and its declared parameters from a signature."""
function collect_signature_names!(diagnostics, signature, path, offsets, conventions)
    kind = Symbol(JuliaSyntax.kind(signature))
    children = something(JuliaSyntax.children(signature), ())
    if kind in (:where, :(::)) && !isempty(children)
        collect_signature_names!(diagnostics, children[1], path, offsets, conventions)
    elseif kind == :call && !isempty(children)
        check_name!(diagnostics, children[1], :function, path, offsets, conventions)
        for parameter in Iterators.drop(children, 1)
            collect_binding_names!(
                diagnostics, parameter, :parameter, path, offsets, conventions)
        end
    elseif kind == :Identifier
        check_name!(diagnostics, signature, :function, path, offsets, conventions)
    end
end

"""Return whether a syntax node is a call-shaped method signature."""
function is_call_signature(node)
    kind = Symbol(JuliaSyntax.kind(node))
    children = something(JuliaSyntax.children(node), ())
    return kind == :call ||
        (kind in (:where, :(::)) && !isempty(children) && is_call_signature(children[1]))
end

"""Collect identifiers from a binding pattern while ignoring type expressions."""
function collect_binding_names!(diagnostics, node, kind, path, offsets, conventions)
    node_kind = Symbol(JuliaSyntax.kind(node))
    children = something(JuliaSyntax.children(node), ())
    if node_kind == :Identifier
        check_name!(diagnostics, node, kind, path, offsets, conventions)
    elseif node_kind in (:(::), :kw, :(...), :(=)) && !isempty(children)
        collect_binding_names!(diagnostics, children[1], kind, path, offsets, conventions)
    elseif node_kind in (:tuple, :parameters)
        for child in children
            collect_binding_names!(diagnostics, child, kind, path, offsets, conventions)
        end
    end
end

"""Append one configured naming diagnostic when a declaration name is invalid."""
function check_name!(diagnostics, node, kind, path, offsets, conventions)
    convention = get(conventions, kind, nothing)
    convention === nothing && return
    Symbol(JuliaSyntax.kind(node)) == :Identifier || return
    name = String(JuliaSyntax.sourcetext(node))
    valid_identifier_name(name, convention) && return
    byte_offset = JuliaSyntax.first_byte(node)
    line = metric_line_for_offset(offsets, byte_offset)
    column = byte_offset - offsets[line] + 1
    kind_name = replace(string(kind), '_' => ' ')
    diagnostic = Diagnostic(
        "JULIA-NAMING",
        Ignore,
        path,
        line,
        column,
        "Julia $(kind_name) `$(name)` must use $(convention.casing).",
        nothing,
        nothing,
        "julia-syntax",
        name,
        string(kind),
        nothing,
        "stable")
    push!(diagnostics, diagnostic)
end

"""Report same-name Julia function families without any attached docstring."""
function check_documentation(path, source, configuration)
    diagnostics = Diagnostic[]
    functions = analyze_functions(path, source)
    documented_names = Set(
        item.name for item in functions
        if item.documented && item.name != "<anonymous>")
    reported_names = Set{String}()
    for item in functions
        (item.name == "<anonymous>" || item.name in documented_names ||
            item.name in reported_names) && continue
        push!(reported_names, item.name)
        diagnostic = Diagnostic(
            "JULIA-DOC-MISSING",
            Ignore,
            path,
            item.start_line,
            1,
            "Julia function family `$(item.name)` requires at least one docstring.",
            nothing,
            nothing,
            "julia-syntax")
        configured = configured_diagnostic(configuration, diagnostic)
        configured === nothing || push!(diagnostics, configured)
    end
    return diagnostics
end

"""Return a configured diagnostic when Julia source cannot be parsed."""
function check_syntax(
    path::String,
    source::String,
    configuration::EffectiveSettings=load_settings())
    try
        JuliaSyntax.parseall(JuliaSyntax.SyntaxNode, source; filename=path)
        return Diagnostic[]
    catch error
        error isa JuliaSyntax.ParseError || rethrow()
        diagnostic = Diagnostic(
            "JULIA-SYNTAX",
            Ignore,
            path,
            1,
            1,
            sprint(showerror, error),
            nothing,
            nothing,
            "julia-syntax")
        configured = configured_diagnostic(configuration, diagnostic)
        return configured === nothing ? Diagnostic[] : [configured]
    end
end

"""Return parser-backed measurements for every Julia function-like definition."""
function analyze_functions(path::String, source::String)
    tree = JuliaSyntax.parseall(JuliaSyntax.SyntaxNode, source; filename=path)
    lines = split(source, '\n'; keepempty=true)
    offsets = line_start_offsets(lines)
    functions = FunctionAnalysis[]
    collect_functions!(functions, tree, path, source, lines, offsets, false)
    return functions
end

"""Return nonblank source lines occupied only by attached Julia docstrings."""
function documentation_comment_lines(source::String)
    tree = JuliaSyntax.parseall(JuliaSyntax.SyntaxNode, source)
    lines = split(source, '\n'; keepempty=true)
    offsets = line_start_offsets(lines)
    comment_lines = Set{Int}()
    collect_documentation_comment_lines!(comment_lines, tree, lines, offsets)
    return comment_lines
end

"""Return the number of parser-backed Julia struct declarations."""
function struct_count(source::String)
    tree = JuliaSyntax.parseall(JuliaSyntax.SyntaxNode, source)
    return count_structs(tree)
end

"""Count struct nodes recursively, including mutable struct declarations."""
function count_structs(node)
    count = Symbol(JuliaSyntax.kind(node)) == :struct ? 1 : 0
    for child in something(JuliaSyntax.children(node), ())
        count += count_structs(child)
    end
    return count
end

"""Collect line spans for doc expressions without consuming their declarations."""
function collect_documentation_comment_lines!(results, node, lines, offsets)
    children = something(JuliaSyntax.children(node), ())
    if Symbol(JuliaSyntax.kind(node)) == :doc && length(children) >= 2
        documentation = first(children)
        declaration = last(children)
        first_line = metric_line_for_offset(
            offsets, JuliaSyntax.first_byte(documentation))
        last_line = metric_line_for_offset(
            offsets, JuliaSyntax.last_byte(documentation))
        declaration_line = metric_line_for_offset(
            offsets, JuliaSyntax.first_byte(declaration))
        for line_number in first_line:last_line
            line_number == declaration_line && continue
            isempty(strip(lines[line_number])) || push!(results, line_number)
        end
        collect_documentation_comment_lines!(results, declaration, lines, offsets)
        return
    end
    for child in children
        collect_documentation_comment_lines!(results, child, lines, offsets)
    end
end

"""Return one-based byte offsets for the beginning of each source line."""
function line_start_offsets(lines)
    offsets = Int[]
    offset = 1
    for line in lines
        push!(offsets, offset)
        offset += ncodeunits(line) + 1
    end
    return offsets
end

"""Return the metric source line containing a one-based byte offset."""
function metric_line_for_offset(offsets, byte_offset)
    return searchsortedlast(offsets, byte_offset)
end

"""Collect named function metrics while preserving docstring attachment state."""
function collect_functions!(results, node, path, source, lines, offsets, documented)
    node_kind = Symbol(JuliaSyntax.kind(node))
    node_children = JuliaSyntax.children(node)
    children = something(node_children, ())
    if node_kind == :doc
        length(children) >= 2 && collect_functions!(
            results, children[end], path, source, lines, offsets, true)
        return
    elseif node_kind in (:function, :macro, :(->)) && node_children !== nothing
        push!(results, function_analysis(
            node, path, source, lines, offsets, documented))
    end
    for child in children
        collect_functions!(results, child, path, source, lines, offsets, false)
    end
end

"""Build one metric record using CodeComplexity as the scoring authority."""
function function_analysis(node, path, source, lines, offsets, documented)
    children = JuliaSyntax.children(node)
    body = last(children)
    start_line = metric_line_for_offset(offsets, JuliaSyntax.first_byte(node))
    end_line = metric_line_for_offset(offsets, JuliaSyntax.last_byte(node))
    definition_source = String(JuliaSyntax.sourcetext(node))
    cyclomatic = first_measure(CYCLOMATIC, definition_source)
    cognitive = first_measure(COGNITIVE, definition_source)
    parameter_count = positional_parameter_count(node)
    executable = body_executable_lines(body, path, lines, offsets)
    return FunctionAnalysis(
        path, "julia", cyclomatic.name, start_line, end_line, executable,
        parameter_count, cyclomatic.value, cognitive.value, documented)
end

"""Count a Julia function's positional parameters, excluding all keywords."""
function positional_parameter_count(node)
    children = something(JuliaSyntax.children(node), ())
    isempty(children) && return 0
    signature = children[1]
    if Symbol(JuliaSyntax.kind(node)) == :(->)
        signature_children = something(JuliaSyntax.children(signature), ())
        return Symbol(JuliaSyntax.kind(signature)) == :tuple ?
            count(
                child -> Symbol(JuliaSyntax.kind(child)) != :parameters,
                signature_children) : 1
    end
    return named_signature_parameter_count(signature)
end

"""Count positional entries in a named Julia method signature."""
function named_signature_parameter_count(signature)
    kind = Symbol(JuliaSyntax.kind(signature))
    children = something(JuliaSyntax.children(signature), ())
    if kind in (:where, :(::)) && !isempty(children)
        return named_signature_parameter_count(children[1])
    elseif kind != :call || isempty(children)
        return 0
    end
    return count(
        child -> Symbol(JuliaSyntax.kind(child)) != :parameters,
        Iterators.drop(children, 1))
end

"""Return the outer definition measurement from a function-like source span."""
function first_measure(metric, source)
    measurements = measure_report(metric, source)
    isempty(measurements) && error(
        "CodeComplexity did not recognize a Julia function-like definition")
    return first(measurements)
end

"""Count nonblank, non-comment-only lines covered by a function body."""
function body_executable_lines(body, path, lines, offsets)
    start_line = metric_line_for_offset(offsets, JuliaSyntax.first_byte(body))
    end_line = metric_line_for_offset(offsets, JuliaSyntax.last_byte(body))
    Symbol(JuliaSyntax.kind(body)) == :block && (start_line += 1)
    start_line > end_line && return 0
    return executable_source_lines(path, lines, start_line, end_line)
end

end