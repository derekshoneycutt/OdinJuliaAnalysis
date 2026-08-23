mutable struct AnalysisEvidence
    declarations::Vector{DeclarationRecord}
    import_bindings::Vector{ImportBinding}
    references::Vector{ReferenceRecord}
    call_edges::Vector{CallEdge}
    clone_candidates::Vector{CloneCandidate}
    clone_groups::Vector{CloneGroup}
    resource_lifetimes::Vector{ResourceLifetimeSummary}
    security_paths::Vector{SecurityBoundaryPath}
    test_coverage::Vector{TestCoverageEvidence}
    interop_signatures::Vector{InteropSignature}
    interop_pairs::Vector{InteropBridgePair}
end

"""Create empty evidence collections for one file or function."""
function AnalysisEvidence()
    return AnalysisEvidence(
        DeclarationRecord[],
        ImportBinding[],
        ReferenceRecord[],
        CallEdge[],
        CloneCandidate[],
        CloneGroup[],
        ResourceLifetimeSummary[],
        SecurityBoundaryPath[],
        TestCoverageEvidence[],
        InteropSignature[],
        InteropBridgePair[])
end

"""Build the canonical file/function hierarchy from flat engine inventories."""
function nest_analysis_files(
    files,
    functions;
    declarations=DeclarationRecord[],
    import_bindings=ImportBinding[],
    references=ReferenceRecord[],
    call_edges=CallEdge[],
    clone_candidates=CloneCandidate[],
    clone_groups=CloneGroup[],
    resource_lifetimes=ResourceLifetimeSummary[],
    security_paths=SecurityBoundaryPath[],
    test_coverage=TestCoverageEvidence[],
    interop_signatures=InteropSignature[],
    interop_pairs=InteropBridgePair[])
    function_evidence = [AnalysisEvidence() for _ in functions]
    file_evidence = [AnalysisEvidence() for _ in files]
    file_indices = Dict(file.path => index for (index, file) in enumerate(files))

    assign_records!(function_evidence, file_evidence, file_indices, functions,
        declarations, :declarations, item -> (item.path, item.line))
    assign_records!(function_evidence, file_evidence, file_indices, functions,
        import_bindings, :import_bindings, item -> (item.path, item.line))
    assign_records!(function_evidence, file_evidence, file_indices, functions,
        references, :references, item -> (item.path, item.line))
    assign_records!(function_evidence, file_evidence, file_indices, functions,
        call_edges, :call_edges, item -> (item.source_path, item.line))
    assign_records!(function_evidence, file_evidence, file_indices, functions,
        clone_candidates, :clone_candidates,
        item -> (item.occurrence.path, item.occurrence.start_line))
    assign_records!(function_evidence, file_evidence, file_indices, functions,
        clone_groups, :clone_groups, clone_group_location)
    assign_records!(function_evidence, file_evidence, file_indices, functions,
        resource_lifetimes, :resource_lifetimes, item -> (item.path, item.line))
    assign_records!(function_evidence, file_evidence, file_indices, functions,
        security_paths, :security_paths, item -> (item.path, item.source_line))
    assign_records!(function_evidence, file_evidence, file_indices, functions,
        test_coverage, :test_coverage, item -> (item.path, item.start_line))
    assign_records!(function_evidence, file_evidence, file_indices, functions,
        interop_signatures, :interop_signatures, item -> (item.path, item.line))
    assign_interop_pairs!(
        function_evidence,
        file_evidence,
        file_indices,
        functions,
        interop_signatures,
        interop_pairs)

    nested_functions = [nested_function(item, function_evidence[index])
        for (index, item) in enumerate(functions)]
    return [nested_file(
        file,
        file_evidence[index],
        filter(item -> item.path == file.path, nested_functions))
        for (index, file) in enumerate(files)]
end

"""Assign source-located records to their innermost function or containing file."""
function assign_records!(
    function_evidence,
    file_evidence,
    file_indices,
    functions,
    records,
    field,
    location)
    for record in records
        path, line = location(record)
        function_index = owning_function_index(functions, path, line)
        target = function_index === nothing ? file_evidence[file_indices[path]] :
            function_evidence[function_index]
        push!(getproperty(target, field), record)
    end
end

"""Return the innermost function containing one source location."""
function owning_function_index(functions, path, line)
    matches = findall(functions) do item
        item.path == path && item.start_line <= line <= item.end_line
    end
    isempty(matches) && return nothing
    return argmin(
        index -> functions[index].end_line - functions[index].start_line,
        matches)
end

"""Return the primary occurrence location for one cross-function clone group."""
function clone_group_location(group)
    occurrence = first(group.occurrences)
    return occurrence.path, occurrence.start_line
end

"""Assign each bridge pair once using its primary matching signature."""
function assign_interop_pairs!(
    function_evidence,
    file_evidence,
    file_indices,
    functions,
    signatures,
    pairs)
    for pair in pairs
        signature = interop_pair_signature(pair, signatures)
        path = signature === nothing ? something(pair.julia_path, pair.odin_path) :
            signature.path
        line = signature === nothing ? 1 : signature.line
        function_index = owning_function_index(functions, path, line)
        target = function_index === nothing ? file_evidence[file_indices[path]] :
            function_evidence[function_index]
        push!(target.interop_pairs, pair)
    end
end

"""Return the preferred source signature anchoring one bridge pair."""
function interop_pair_signature(pair, signatures)
    paths = filter(!isnothing, (pair.julia_path, pair.odin_path))
    index = findfirst(signature ->
        signature.symbol == pair.symbol && signature.path in paths, signatures)
    return index === nothing ? nothing : signatures[index]
end

"""Attach nested evidence to one function metric record."""
function nested_function(item, evidence)
    return FunctionAnalysis(
        item.path,
        item.language,
        item.name,
        item.start_line,
        item.end_line,
        item.executable_lines,
        item.parameter_count,
        item.cyclomatic_complexity,
        item.cognitive_complexity,
        item.documented,
        evidence.declarations,
        evidence.import_bindings,
        evidence.references,
        evidence.call_edges,
        evidence.clone_candidates,
        evidence.clone_groups,
        evidence.resource_lifetimes,
        evidence.security_paths,
        evidence.test_coverage,
        evidence.interop_signatures,
        evidence.interop_pairs)
end

"""Attach nested functions and unowned evidence to one file metric record."""
function nested_file(file, evidence, functions)
    return FileAnalysis(
        file.path,
        file.language,
        file.physical_lines,
        file.source_lines,
        file.code_lines,
        file.comment_lines,
        file.blank_lines,
        file.struct_count,
        file.parsed,
        functions,
        evidence.declarations,
        evidence.import_bindings,
        evidence.references,
        evidence.call_edges,
        evidence.clone_candidates,
        evidence.clone_groups,
        evidence.resource_lifetimes,
        evidence.security_paths,
        evidence.test_coverage,
        evidence.interop_signatures,
        evidence.interop_pairs)
end

"""Return every function nested under analyzed files."""
analysis_functions(files) = [item for file in files for item in file.functions]

"""Return one evidence collection flattened from files and nested functions."""
function analysis_evidence(files, field)
    records = Any[]
    for file in files
        append!(records, getproperty(file, field))
        for item in file.functions
            append!(records, getproperty(item, field))
        end
    end
    return records
end

"""Return every declaration nested under analyzed files and functions."""
analysis_declarations(files) = DeclarationRecord[
    analysis_evidence(files, :declarations)...]

"""Return every import binding nested under analyzed files and functions."""
analysis_import_bindings(files) = ImportBinding[
    analysis_evidence(files, :import_bindings)...]

"""Return every reference nested under analyzed files and functions."""
analysis_references(files) = ReferenceRecord[analysis_evidence(files, :references)...]

"""Return every call edge nested under analyzed files and functions."""
analysis_call_edges(files) = CallEdge[analysis_evidence(files, :call_edges)...]

"""Return every clone candidate nested under analyzed files and functions."""
analysis_clone_candidates(files) = CloneCandidate[
    analysis_evidence(files, :clone_candidates)...]

"""Return every clone group nested under analyzed files and functions."""
analysis_clone_groups(files) = CloneGroup[analysis_evidence(files, :clone_groups)...]

"""Return every resource lifetime nested under analyzed files and functions."""
analysis_resource_lifetimes(files) = ResourceLifetimeSummary[
    analysis_evidence(files, :resource_lifetimes)...]

"""Return every security path nested under analyzed files and functions."""
analysis_security_paths(files) = SecurityBoundaryPath[
    analysis_evidence(files, :security_paths)...]

"""Return every coverage record nested under analyzed files and functions."""
analysis_test_coverage(files) = TestCoverageEvidence[
    analysis_evidence(files, :test_coverage)...]

"""Return every interop signature nested under analyzed files and functions."""
analysis_interop_signatures(files) = InteropSignature[
    analysis_evidence(files, :interop_signatures)...]

"""Return every interop pair nested under analyzed files and functions."""
analysis_interop_pairs(files) = InteropBridgePair[
    analysis_evidence(files, :interop_pairs)...]