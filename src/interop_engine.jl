"""Pair repository bridge signatures and classify external or unmatched declarations."""
function pair_interop_signatures(signatures)
    pairs = InteropBridgePair[]
    julia_imports = filter(item ->
        item.language == "julia" && item.direction == "import" &&
            item.library === nothing,
        signatures)
    odin_exports = filter(item ->
        item.language == "odin" && item.direction == "export",
        signatures)
    matched_odin = Set{Int}()
    append_repository_interop_pairs!(pairs, matched_odin, julia_imports, odin_exports)
    append_unmatched_odin_pairs!(pairs, matched_odin, odin_exports)
    append_external_interop_pairs!(pairs, signatures)
    sort!(pairs; by=item -> (item.symbol, item.status))
    return pairs
end

"""Pair repository Julia imports with Odin exports by symbol."""
function append_repository_interop_pairs!(
    pairs, matched_odin, julia_imports, odin_exports)
    for julia_signature in julia_imports
        index = findfirst(item ->
            item.symbol == julia_signature.symbol,
            odin_exports)
        if index === nothing
            push!(pairs, InteropBridgePair(
                julia_signature.symbol,
                "missing-odin",
                julia_signature.path,
                nothing,
                nothing))
            continue
        end
        push!(matched_odin, index)
        odin_signature = odin_exports[index]
        mismatch = interop_signature_mismatch(julia_signature, odin_signature)
        push!(pairs, InteropBridgePair(
            julia_signature.symbol,
            mismatch === nothing ? "matched" : "signature-mismatch",
            julia_signature.path,
            odin_signature.path,
            mismatch))
    end
end

"""Append Odin exports without a repository Julia caller."""
function append_unmatched_odin_pairs!(pairs, matched_odin, odin_exports)
    for (index, signature) in enumerate(odin_exports)
        index in matched_odin && continue
        push!(pairs, InteropBridgePair(
            signature.symbol, "missing-julia", nothing, signature.path, nothing))
    end
end

"""Append signatures whose counterpart is intentionally external."""
function append_external_interop_pairs!(pairs, signatures)
    for signature in signatures
        external = signature.direction == "import" &&
            (signature.language == "odin" || signature.library !== nothing) ||
            signature.language == "julia" && signature.direction == "export"
        external || continue
        push!(pairs, InteropBridgePair(
            signature.symbol,
            "external",
            signature.language == "julia" ? signature.path : nothing,
            signature.language == "odin" ? signature.path : nothing,
            nothing))
    end
end

"""Return a stable description of the first ABI mismatch between two signatures."""
function interop_signature_mismatch(julia_signature, odin_signature)
    julia_signature.calling_convention == odin_signature.calling_convention ||
        return "calling convention $(julia_signature.calling_convention) != " *
            odin_signature.calling_convention
    julia_signature.parameter_types == odin_signature.parameter_types ||
        return "parameter types $(join(julia_signature.parameter_types, ", ")) != " *
            join(odin_signature.parameter_types, ", ")
    julia_signature.return_types == odin_signature.return_types ||
        return "return types $(join(julia_signature.return_types, ", ")) != " *
            join(odin_signature.return_types, ", ")
    return nothing
end