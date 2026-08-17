"""Report explicit import bindings with no parser-visible same-file reference."""
function analyze_unused_imports(import_bindings, references, configuration)
    diagnostics = Diagnostic[]
    references_by_file = Dict{Tuple{String, String}, Set{String}}()
    for reference in references
        key = (reference.path, reference.language)
        push!(get!(references_by_file, key, Set{String}()), reference.name)
    end
    for binding in import_bindings
        names = get(
            references_by_file,
            (binding.path, binding.language),
            Set{String}())
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
    return diagnostics
end