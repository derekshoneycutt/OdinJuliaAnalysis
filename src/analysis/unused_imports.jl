"""Report explicit import bindings with no parser-visible same-module reference."""
function analyze_unused_imports(
    import_bindings, references, include_edges, declarations,
    root, files, configuration)
    diagnostics = Diagnostic[]
    references_by_file = index_references_by_file(references)
    include_components = same_module_include_components(include_edges, declarations)
    for binding in import_bindings
        paths = get(include_components, binding.path, Set([binding.path]))
        names = Set{String}()
        for path in paths
            union!(names, get(
                references_by_file, (path, binding.language), Set{String}()))
        end
        binding.name in names && continue
        rule_id = binding.language == "julia" ?
            "JULIA-UNUSED-IMPORT" : "ODIN-UNUSED-IMPORT"
        diagnostic = Diagnostic(
            rule_id,
            Ignore,
            binding.path,
            binding.line,
            binding.column,
            "Imported binding `$(binding.name)` is not referenced in this file.",
            nothing,
            nothing,
            "$(binding.language)-syntax",
            binding.name,
            "unused-import",
            nothing,
            "definite")
        configured = configured_diagnostic(configuration, diagnostic)
        configured === nothing || push!(diagnostics, configured)
    end
    apply_reviewed_import_policies!(diagnostics, root, files, configuration)
    return diagnostics
end


"""Index parser-visible reference names by source path and language."""
function index_references_by_file(references)
    result = Dict{Tuple{String, String}, Set{String}}()
    for reference in references
        key = (reference.path, reference.language)
        push!(get!(result, key, Set{String}()), reference.name)
    end
    return result
end


"""Group files evaluated into one Julia module through literal include calls."""
function same_module_include_components(include_edges, declarations)
    module_files = Set(declaration.path for declaration in declarations
        if declaration.language == "julia" && declaration.kind == "module" &&
            declaration.scope === nothing)
    adjacency = Dict{String, Set{String}}()
    for edge in include_edges
        edge.target_path in module_files && continue
        push!(get!(adjacency, edge.source_path, Set{String}()), edge.target_path)
        push!(get!(adjacency, edge.target_path, Set{String}()), edge.source_path)
    end
    components = Dict{String, Set{String}}()
    for path in keys(adjacency)
        haskey(components, path) && continue
        component = Set{String}()
        pending = [path]
        while !isempty(pending)
            current = pop!(pending)
            current in component && continue
            push!(component, current)
            append!(pending, get(adjacency, current, Set{String}()))
        end
        for member in component
            components[member] = component
        end
    end
    return components
end


"""Apply reviewed external-binding decisions and report policy drift."""
function apply_reviewed_import_policies!(diagnostics, root, files, configuration)
    scanned_paths = Set(relpath(abspath(path), abspath(root)) for path in files)
    policies = filter(
        policy -> policy.path in scanned_paths,
        configuration.call_roots.reviewed_imports)
    match_counts = zeros(Int, length(policies))
    drift = Diagnostic[]
    for index in eachindex(diagnostics)
        diagnostic = diagnostics[index]
        endswith(diagnostic.rule_id, "-UNUSED-IMPORT") || continue
        matches = findall(
            policy -> reviewed_import_matches(policy, diagnostic), policies)
        for policy_index in matches
            match_counts[policy_index] += 1
        end
        if length(matches) == 1
            diagnostics[index] = apply_reviewed_import(
                diagnostic, policies[only(matches)])
        elseif length(matches) > 1
            ids = join((policies[item].id for item in matches), ", ")
            push!(drift, import_policy_drift(
                diagnostic.path, diagnostic.line, diagnostic.column,
                "Unused import matches multiple reviewed policies: $ids."))
        end
    end
    for (policy, count) in zip(policies, match_counts)
        if count < policy.minimum_matches || count > policy.maximum_matches
            push!(drift, import_policy_drift(
                policy.path, 1, 1,
                "Reviewed import $(policy.id) expected " *
                    "$(policy.minimum_matches)-$(policy.maximum_matches) " *
                    "matches, found $count."))
        end
    end
    append!(diagnostics, drift)
end

"""Return whether one unused-import finding satisfies an exact policy selector."""
function reviewed_import_matches(policy, diagnostic)
    return diagnostic.path == policy.path &&
        diagnostic.rule_id == "$(uppercase(string(policy.language)))-UNUSED-IMPORT" &&
        diagnostic.subject == policy.binding
end

"""Attach one reviewed import decision to its diagnostic."""
function apply_reviewed_import(diagnostic, policy)
    return Diagnostic(
        diagnostic.rule_id, policy.response, diagnostic.path,
        diagnostic.line, diagnostic.column, diagnostic.message,
        diagnostic.measured, diagnostic.allowed, diagnostic.source,
        diagnostic.subject, diagnostic.operation, diagnostic.allocator_source,
        diagnostic.certainty, diagnostic.procedure, diagnostic.allocation_target,
        policy.id, policy.reason)
end

"""Construct one blocking reviewed-import drift diagnostic."""
function import_policy_drift(path, line, column, message)
    return Diagnostic(
        "IMPORT-POLICY-DRIFT", Fail, path, line, column, message,
        nothing, nothing, "import-policy", nothing, "reviewed-import",
        nothing, "definite")
end