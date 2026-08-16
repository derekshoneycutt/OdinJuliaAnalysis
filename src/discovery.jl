const SUPPORTED_EXTENSIONS = Set([".jl", ".md", ".odin"])
const EXCLUDED_DIRECTORIES = Set([".git", ".build", "bin"])

"""Discover supported source files below a root directory."""
function discover_sources(root::String, excludes::Vector{String}=String[])
    isdir(root) || throw(ArgumentError("analysis root is not a directory: $root"))
    files = String[]

    for (directory, directories, names) in walkdir(root)
        filter!(name -> name ∉ EXCLUDED_DIRECTORIES, directories)
        for name in names
            extension = splitext(name)[2]
            extension in SUPPORTED_EXTENSIONS || continue
            path = joinpath(directory, name)
            is_excluded(relpath(path, root), excludes) && continue
            push!(files, path)
        end
    end

    sort!(files)
    return files
end


"""Return whether a normalized source path matches an exclusion."""
function is_excluded(path::String, excludes::Vector{String})
    normalized = replace(normpath(path), '\\' => '/')
    return any(excludes) do excluded
        prefix = rstrip(replace(normpath(excluded), '\\' => '/'), '/')
        normalized == prefix || startswith(normalized, prefix * "/")
    end
end