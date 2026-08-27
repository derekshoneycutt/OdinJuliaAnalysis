const COCOMO_ANNUAL_WAGE = 56_286
const COCOMO_OVERHEAD = 2.4
const LOCOMO_INPUT_PRICE_PER_MILLION = 3.0
const LOCOMO_OUTPUT_PRICE_PER_MILLION = 15.0
const LOCOMO_OUTPUT_TOKENS_PER_SECOND = 50.0

"""Calculate SCC-compatible organic Basic COCOMO estimates from code lines."""
function calculate_cocomo(code_lines::Int)
    effort = 2.4 * (code_lines / 1_000)^1.05
    schedule = 2.5 * effort^0.38
    people = schedule == 0 ? 0.0 : effort / schedule
    cost = effort * COCOMO_ANNUAL_WAGE / 12 * COCOMO_OVERHEAD
    return CocomoEstimate(
        "organic",
        effort,
        schedule,
        people,
        cost,
        COCOMO_ANNUAL_WAGE,
        COCOMO_OVERHEAD)
end

"""Calculate SCC-compatible medium-preset LOCOMO regeneration estimates."""
function calculate_locomo(code_lines::Int, complexity::Int)
    density = code_lines == 0 ? 0.0 : complexity / code_lines
    complexity_factor = 1 + sqrt(density) * 5
    cycles = 1.5 + sqrt(density) * 2
    output_tokens = code_lines * 10 * cycles
    input_tokens = code_lines * 20 * complexity_factor * cycles
    cost = input_tokens / 1_000_000 * LOCOMO_INPUT_PRICE_PER_MILLION +
        output_tokens / 1_000_000 * LOCOMO_OUTPUT_PRICE_PER_MILLION
    generation_seconds = output_tokens / LOCOMO_OUTPUT_TOKENS_PER_SECOND
    review_hours = code_lines * 0.01 / 60
    return LocomoEstimate(
        "medium",
        input_tokens,
        output_tokens,
        cycles,
        cost,
        generation_seconds,
        review_hours)
end

"""Aggregate file and parser-backed function metrics for one code scope."""
function calculate_code_statistics(
    files::Vector{FileAnalysis},
    functions::Vector{FunctionAnalysis})
    file_count = length(files)
    function_count = length(functions)
    struct_count = sum(file -> file.struct_count, files; init=0)
    lines = sum(file -> file.physical_lines, files; init=0)
    blank_lines = sum(file -> file.blank_lines, files; init=0)
    comment_lines = sum(file -> file.comment_lines, files; init=0)
    code_lines = sum(file -> file.code_lines, files; init=0)
    complexity = sum(item -> item.cyclomatic_complexity, functions; init=0)
    density = code_lines == 0 ? 0.0 : complexity / code_lines
    return CodeStatistics(
        file_count,
        function_count,
        struct_count,
        lines,
        blank_lines,
        comment_lines,
        code_lines,
        complexity,
        density)
end

"""Aggregate canonical Julia, Odin, and combined programming-language metrics."""
function calculate_repository_statistics(
    files::Vector{FileAnalysis},
    functions::Vector{FunctionAnalysis})
    languages = ("julia", "odin")
    code_by_language = Dict(language => calculate_code_statistics(
        filter(file -> file.language == language, files),
        filter(item -> item.language == language, functions)) for language in languages)
    code_files = filter(file -> file.language in languages, files)
    code_functions = filter(item -> item.language in languages, functions)
    code = calculate_code_statistics(code_files, code_functions)
    return RepositoryStatistics(
        code,
        code_by_language,
        calculate_cocomo(code.code_lines),
        calculate_locomo(code.code_lines, code.complexity))
end

"""Measure one Julia or Odin source file without running repository policy."""
function analyze_source_statistics(
    path::String;
    function_name::Union{Nothing, String}=nothing,
    line::Union{Nothing, Int}=nothing)
    function_name === nothing || line === nothing || throw(ArgumentError(
        "function and line selectors are mutually exclusive"))
    isfile(path) || throw(ArgumentError("source path is not a file: $path"))
    language = source_language(path)
    language in ("julia", "odin") || throw(ArgumentError(
        "source path must have a .jl or .odin extension: $path"))

    normalized_path = replace(normpath(path), '\\' => '/')
    source = read(path, String)
    functions, struct_count = language == "julia" ?
        julia_source_metrics(normalized_path, source) :
        odin_source_metrics(path)
    sort!(functions; by=function_statistics_sort_key)
    file = analyze_file(
        normalized_path, path, source, language, true, struct_count)
    compact_functions = function_statistics.(functions)
    selected, selection = select_function_statistics(
        compact_functions, function_name, line)
    code = calculate_code_statistics([file], functions)
    return SourceStatisticsReport(
        "1.0.0",
        string(VERSION),
        normalized_path,
        language,
        file_statistics(file, functions, code),
        selected,
        selection)
end

"""Return a deterministic scalar source-order key for one function."""
function function_statistics_sort_key(item)
    return join((
        lpad(item.start_line, 12, '0'),
        lpad(item.end_line, 12, '0'),
        item.name), '\0')
end

"""Collect parser-backed Julia function and struct measurements."""
function julia_source_metrics(path, source)
    try
        functions = JuliaEngine.analyze_functions(path, source)
        return functions, JuliaEngine.struct_count(source)
    catch error
        error isa JuliaSyntax.ParseError || rethrow()
        throw(ArgumentError("Julia source could not be parsed: $(sprint(showerror, error))"))
    end
end

"""Collect parser-backed Odin procedure and struct measurements."""
function odin_source_metrics(path)
    root = dirname(abspath(path))
    analysis = OdinEngine.analyze_metrics(root, [abspath(path)])
    analysis.parsed || throw(ArgumentError("Odin source could not be parsed: $path"))
    relative_path = relpath(abspath(path), root)
    return analysis.functions, get(analysis.struct_counts, relative_path, 0)
end

"""Project one canonical function record into the compact statistics schema."""
function function_statistics(item)
    physical_lines = item.end_line - item.start_line + 1
    density = item.executable_lines == 0 ? 0.0 :
        item.cyclomatic_complexity / item.executable_lines
    return FunctionStatistics(
        item.name,
        item.start_line,
        item.end_line,
        physical_lines,
        item.executable_lines,
        item.parameter_count,
        item.cyclomatic_complexity,
        item.cognitive_complexity,
        item.documented,
        density)
end

"""Build compact file statistics and derived function aggregates."""
function file_statistics(file, functions, code)
    count = length(functions)
    complexities = [item.cyclomatic_complexity for item in functions]
    executable_lines = [item.executable_lines for item in functions]
    return FileStatistics(
        file.parsed,
        file.physical_lines,
        file.source_lines,
        file.code_lines,
        file.comment_lines,
        file.blank_lines,
        count,
        file.struct_count,
        code.complexity,
        code.complexity_per_code_line,
        count == 0 ? 0.0 : sum(complexities) / count,
        maximum(complexities; init=0),
        count == 0 ? 0.0 : sum(executable_lines) / count,
        maximum(executable_lines; init=0))
end

"""Select compact function statistics by exact name or containing line."""
function select_function_statistics(functions, function_name, line)
    if function_name !== nothing
        matches = filter(item -> item.name == function_name, functions)
        isempty(matches) && throw(ArgumentError(
            "no function named `$function_name` was found"))
        return matches, StatisticsSelection(
            "function", function_name, length(matches))
    elseif line !== nothing
        line > 0 || throw(ArgumentError("line selector must be positive"))
        matches = filter(item -> item.start_line <= line <= item.end_line, functions)
        isempty(matches) && throw(ArgumentError(
            "no function contains line $line"))
        selected = argmin(item -> item.physical_lines, matches)
        return [selected], StatisticsSelection("line", string(line), 1)
    end
    return functions, nothing
end