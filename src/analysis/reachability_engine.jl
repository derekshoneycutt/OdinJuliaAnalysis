"""Collect deterministic production, test, callback, and bridge call roots."""
function collect_call_roots(declarations, signatures, configuration)
    roots = CallRoot[]
    for entry in configuration.jet.entry_points
        push!(roots, CallRoot(
            entry.id, entry.path, "julia", string(nameof(entry.callable)), "production"))
    end
    for declaration in declarations
        declaration.kind in ("function", "procedure") || continue
        normalized = replace(declaration.path, '\\' => '/')
        test_path = startswith(normalized, "test/") || occursin("/test/", normalized) ||
            endswith(normalized, "_test.jl") || endswith(normalized, "_tests.odin")
        if test_path
            push!(roots, CallRoot(
                "test:$(declaration.qualified_name)", declaration.path,
                declaration.language, declaration.name, "test"))
        elseif declaration.name == "main"
            push!(roots, CallRoot(
                "main:$(declaration.language):$(declaration.path)", declaration.path,
                declaration.language, declaration.name, "production"))
        end
    end
    for signature in signatures
        category = signature.direction == "callback" ? "callback" :
            signature.direction == "export" ? "bridge" : nothing
        category === nothing && continue
        push!(roots, CallRoot(
            "$category:$(signature.symbol):$(signature.path)", signature.path,
            signature.language, signature.symbol, category))
    end
    unique!(root -> join(
        (root.path, root.language, root.declaration, root.category), '\0'), roots)
    sort!(roots; by=root -> join(
        (root.language, root.path, root.declaration, root.category), '\0'))
    return roots
end

"""Analyze explicit call reachability and unresolved dynamic calls."""
function analyze_reachability(declarations, call_edges, roots, configuration)
    diagnostics = unresolved_call_diagnostics(call_edges)
    for language in ("julia", "odin")
        append!(diagnostics, language_reachability_diagnostics(
            language, declarations, call_edges, roots))
    end
    configured = Diagnostic[]
    for diagnostic in diagnostics
        item = configured_diagnostic(configuration, diagnostic)
        item === nothing || push!(configured, item)
    end
    return configured
end

"""Report explicit call expressions whose target syntax is dynamic."""
function unresolved_call_diagnostics(call_edges)
    return [Diagnostic(
        "CALL-GRAPH-UNRESOLVED-EDGE", Ignore, edge.source_path, edge.line,
        edge.column, "Dynamic call `$(edge.callee)` could not be resolved.",
        nothing, nothing, "call-graph", edge.callee, "dynamic-call", nothing,
        "potential") for edge in call_edges if edge.kind == "dynamic"]
end

"""Report callable declarations outside one language's root closure."""
function language_reachability_diagnostics(language, declarations, call_edges, roots)
    language_roots = filter(root -> root.language == language, roots)
    isempty(language_roots) && return Diagnostic[]
    callable_kind = language == "julia" ? "function" : "procedure"
    callable_declarations = filter(
        declaration -> declaration.language == language &&
            declaration.kind == callable_kind,
        declarations)
    reachable = reachable_call_names(
        language, callable_declarations, call_edges, language_roots)
    rule_id = language == "julia" ?
        "JULIA-UNREACHABLE-FUNCTION" : "ODIN-UNREACHABLE-PROCEDURE"
    return [Diagnostic(
        rule_id, Ignore, declaration.path, declaration.line, declaration.column,
        "$(uppercasefirst(language)) $(callable_kind) " *
            "`$(declaration.qualified_name)` is not reachable from a configured root.",
        nothing, nothing, "call-graph", declaration.qualified_name,
        "reachability", nothing, "probable")
        for declaration in callable_declarations if !(declaration.name in reachable)]
end

"""Return the fixed-point closure of explicit calls from one language's roots."""
function reachable_call_names(language, declarations, call_edges, roots)
    names = Set(declaration.name for declaration in declarations)
    reachable = Set(root.declaration for root in roots)
    changed = true
    while changed
        changed = false
        for edge in call_edges
            edge.language == language || continue
            terminal_call_name(edge.caller) in reachable || continue
            callee = terminal_call_name(edge.callee)
            callee in names || continue
            callee in reachable && continue
            push!(reachable, callee)
            changed = true
        end
    end
    return reachable
end

"""Return the terminal declaration segment from a call or lexical scope."""
function terminal_call_name(name)
    name === nothing && return ""
    segments = split(String(name), '.')
    return isempty(segments) ? "" : last(segments)
end