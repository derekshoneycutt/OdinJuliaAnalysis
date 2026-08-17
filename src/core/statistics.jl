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