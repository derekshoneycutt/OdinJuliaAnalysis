"""Collect deterministic production, test, init, callback, and bridge call roots."""
function collect_call_roots(declarations, signatures, configuration)
    roots = vcat(
        jet_call_roots(configuration),
        declaration_call_roots(declarations),
        signature_call_roots(signatures),
        configured_call_roots(declarations, configuration))
    unique!(root -> join(
        (root.path, root.language, root.declaration, root.category), '\0'), roots)
    sort!(roots; by=root -> join(
        (root.language, root.path, root.declaration, root.category), '\0'))
    return roots
end

"""Collect production roots declared for JET analysis."""
function jet_call_roots(configuration)
    return [CallRoot(
        entry.id, entry.path, "julia", string(nameof(entry.callable)), "production")
        for entry in configuration.jet.entry_points]
end

"""Collect test and conventional production roots from callable declarations."""
function declaration_call_roots(declarations)
    roots = CallRoot[]
    for declaration in declarations
        declaration.kind in ("function", "procedure") || continue
        if declaration.language == "odin" && declaration.is_init
            push!(roots, CallRoot(
                "init:$(declaration.qualified_name)", declaration.path,
                declaration.language, declaration.name, "init"))
            continue
        end
        if is_test_path(declaration.path)
            push!(roots, CallRoot(
                "test:$(declaration.qualified_name)", declaration.path,
                declaration.language, declaration.name, "test"))
        elseif declaration.name == "main"
            push!(roots, CallRoot(
                "main:$(declaration.language):$(declaration.path)", declaration.path,
                declaration.language, declaration.name, "production"))
        end
    end
    return roots
end

"""Return whether a source path follows a recognized test-file convention."""
function is_test_path(path)
    normalized = replace(path, '\\' => '/')
    return startswith(normalized, "test/") || occursin("/test/", normalized) ||
        endswith(normalized, "_test.jl") || endswith(normalized, "_test.odin") ||
        endswith(normalized, "_tests.odin")
end

"""Collect callback and exported bridge roots from interop signatures."""
function signature_call_roots(signatures)
    roots = CallRoot[]
    for signature in signatures
        category = signature.direction == "callback" ? "callback" :
            signature.direction == "export" ? "bridge" : nothing
        category === nothing && continue
        push!(roots, CallRoot(
            "$category:$(signature.symbol):$(signature.path)", signature.path,
            signature.language, signature.symbol, category))
    end
    return roots
end

"""Collect bridge roots selected by configured callable entry points."""
function configured_call_roots(declarations, configuration)
    roots = CallRoot[]
    for entry in configuration.call_roots.entry_points
        for declaration in matching_call_root_declarations(declarations, entry)
            push!(roots, CallRoot(
                "$(entry.id):$(declaration.path)", declaration.path,
                declaration.language, declaration.name, "bridge"))
        end
    end
    return roots
end

"""Return the callable declarations named by one configured call root."""
function matching_call_root_declarations(declarations, entry)
    language = string(entry.language)
    callable_kind = language == "julia" ? "function" : "procedure"
    return filter(declarations) do declaration
        declaration.language == language &&
            declaration.kind == callable_kind &&
            (declaration.name == entry.name ||
                declaration.qualified_name == entry.name)
    end
end

"""Analyze explicit call reachability and unresolved dynamic calls."""
function analyze_reachability(declarations, call_edges, references, roots, configuration)
    diagnostics = unresolved_call_diagnostics(call_edges)
    append!(diagnostics, call_root_drift_diagnostics(declarations, configuration))
    edges = vcat(call_edges, callable_value_edges(declarations, references))
    for language in ("julia", "odin")
        append!(diagnostics, language_reachability_diagnostics(
            language, declarations, edges, roots))
    end
    configured = Diagnostic[]
    for diagnostic in diagnostics
        item = configured_diagnostic(configuration, diagnostic)
        item === nothing || push!(configured, item)
    end
    return configured
end

"""Report configured call roots that no longer name a declared callable."""
function call_root_drift_diagnostics(declarations, configuration)
    return [Diagnostic(
        "CALL-ROOT-POLICY-DRIFT", Fail, ".", 1, 1,
        "Call root entry point `$(entry.id)` matches no declared " *
            "$(entry.language) callable named `$(entry.name)`.",
        nothing, nothing, "call-root-policy", entry.name, "call-root", nothing,
        "definite")
        for entry in configuration.call_roots.entry_points
        if isempty(matching_call_root_declarations(declarations, entry))]
end

"""Report explicit call expressions whose target syntax is dynamic."""
function unresolved_call_diagnostics(call_edges)
    return [Diagnostic(
        "CALL-GRAPH-UNRESOLVED-EDGE", Ignore, edge.source_path, edge.line,
        edge.column, "Dynamic call `$(edge.callee)` could not be resolved.",
        nothing, nothing, "call-graph", edge.callee, "dynamic-call", nothing,
        "potential") for edge in call_edges if edge.kind == "dynamic"]
end

"""Return reachability edges for callables named as values, not called.

Task submission, callback registration, dispatch tables, and `export` statements
hand a callable to another site instead of calling it, so the call graph alone
reports the whole downstream tree as unreachable."""
function callable_value_edges(declarations, references)
    callables = Set((declaration.language, declaration.name)
        for declaration in declarations
        if declaration.kind in ("procedure", "function"))
    declaration_sites = Set(
        (declaration.path, declaration.name, declaration.line)
        for declaration in declarations)
    edges = CallEdge[]
    for reference in references
        (reference.language, reference.name) in callables || continue
        site = (reference.path, reference.name, reference.line)
        site in declaration_sites && continue
        push!(edges, CallEdge(
            reference.path, reference.language,
            enclosing_callable_scope(reference, callables), reference.name,
            "value", reference.line, reference.column))
    end
    return edges
end

"""Return the callable owning a reference, or `nothing` at declaration-body scope.

Julia scopes nest through modules, so a reference directly inside a module runs
whenever the module loads and is not gated by any caller's reachability."""
function enclosing_callable_scope(reference, callables)
    terminal = terminal_call_name(reference.scope)
    isempty(terminal) && return nothing
    return (reference.language, terminal) in callables ? reference.scope : nothing
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
            caller = terminal_call_name(edge.caller)
            isempty(caller) || caller in reachable || continue
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