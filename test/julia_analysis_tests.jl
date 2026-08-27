@testset "Julia syntax" begin
    diagnostics = OdinJuliaAnalysis.JuliaEngine.check_syntax(
        "fixture.jl",
        "function broken(\n")
    @test only(diagnostics).rule_id == "JULIA-SYNTAX"
    @test only(diagnostics).response == Fail
    @test OdinJuliaAnalysis.JuliaEngine.struct_count(
        "struct One end\nmutable struct Two end\nabstract type Three end\n") == 2
end

@testset "Julia documentation" begin
    source = """
        \"\"\"Return one.\"\"\"
        documented() = 1

        documented(value::Int) = value

        undocumented(value::Int) = value
        undocumented(value::String) = length(value)
        map(value -> value + 1, [1])
        """
    diagnostics = OdinJuliaAnalysis.JuliaEngine.check("fixture.jl", source)
    missing = filter(
        item -> item.rule_id == "JULIA-DOC-MISSING",
        diagnostics)

    @test length(missing) == 1
    @test only(missing).response == Fail
    @test only(missing).line == 6
    @test occursin("undocumented", only(missing).message)
    @test occursin("at least one docstring", only(missing).message)

    template_configuration = with_documentation(
        OdinJuliaAnalysis.load_settings(),
        DocumentationSettings(r"(?m)^# Parameters$", r"\S"))
    template_configuration = with_rules(template_configuration, Dict(
        "JULIA-DOC-MISSING" => RuleSetting(
            "JULIA-DOC-MISSING", true, Warn)))
    template_source = """
        \"\"\"Summary only.\"\"\"
        missing_parameters(value) = value

        \"\"\"Summary.\n\n# Parameters\n- `value`: Returned value.\"\"\"
        documented_parameters(value) = value
        """
    template_diagnostics = OdinJuliaAnalysis.JuliaEngine.check(
        "template.jl", template_source, template_configuration)
    template_findings = filter(
        item -> item.rule_id == "JULIA-DOC-MISSING", template_diagnostics)
    @test [item.subject for item in template_findings] == ["missing_parameters"]
    @test only(template_findings).response == Warn

    empty_source = "\"\"\"\"\"\"\nempty_documentation() = nothing\n"
    empty_diagnostics = OdinJuliaAnalysis.JuliaEngine.check(
        "empty.jl", empty_source, OdinJuliaAnalysis.load_settings())
    @test only(filter(
        item -> item.rule_id == "JULIA-DOC-MISSING", empty_diagnostics)).subject ==
        "empty_documentation"

    documentation_source = join([
        "\"\"\"Single-line documentation.\"\"\"",
        "documented_one() = 1",
        "",
        "\"\"\"",
        "Multiline documentation.",
        "",
        "With a blank line.",
        "\"\"\"",
        "documented_two() = 2",
        "\"\"\"Shared line.\"\"\" documented_three() = 3",
    ], "\n") * "\n"
    @test OdinJuliaAnalysis.JuliaEngine.documentation_comment_lines(
        documentation_source) == Set([1, 4, 5, 7, 8])
    nested_documentation_source = join([
        "\"\"\"Module documentation.\"\"\"",
        "module Fixture",
        "\"\"\"Function documentation.\"\"\"",
        "documented() = 1",
        "end",
    ], "\n")
    @test OdinJuliaAnalysis.JuliaEngine.documentation_comment_lines(
        nested_documentation_source) == Set([1, 3])

    mktempdir() do root
        path = joinpath(root, "documented.jl")
        write(path, documentation_source)
        analysis = only(OdinJuliaAnalysis.analyze_files(
            root,
            [path],
            Dict{String, Int}(),
            OdinJuliaAnalysis.Diagnostic[]))
        @test analysis.physical_lines == 10
        @test analysis.comment_lines == 5
        @test analysis.blank_lines == 2
        @test analysis.code_lines == 3

        invalid_source = "function broken(\n"
        write(path, invalid_source)
        invalid_diagnostics = OdinJuliaAnalysis.JuliaEngine.check_syntax(
            "documented.jl", invalid_source)
        invalid_analysis = only(OdinJuliaAnalysis.analyze_files(
            root,
            [path],
            Dict{String, Int}(),
            invalid_diagnostics))
        @test !invalid_analysis.parsed
    end
end

@testset "Julia naming" begin
    configuration = OdinJuliaAnalysis.load_settings()
    source = """
        module bad_module
        struct bad_type
            Bad_Field::Int
        end
        const bad_constant = 1
        function Bad_Function(BadParameter)
            Bad_Local = BadParameter
        end
        good_function!(good_parameter) = good_parameter
        end
        """
    diagnostics = filter(
        item -> item.rule_id == "JULIA-NAMING",
        OdinJuliaAnalysis.JuliaEngine.check(
            "fixture.jl", source, configuration))

    @test [item.subject for item in diagnostics] == [
        "bad_module",
        "bad_type",
        "Bad_Field",
        "bad_constant",
        "Bad_Function",
        "BadParameter",
        "Bad_Local",
    ]
    @test all(item -> item.response == Warn, diagnostics)
    @test [item.operation for item in diagnostics] == [
        "module", "type", "field", "constant", "function", "parameter",
        "variable"]

    for response in (Ignore, Report, Warn, Fail)
        configured = with_rules(configuration, Dict(
            "JULIA-NAMING" => RuleSetting(
                "JULIA-NAMING", true, response)))
        response_diagnostics = filter(
            item -> item.rule_id == "JULIA-NAMING",
            OdinJuliaAnalysis.JuliaEngine.check(
                "fixture.jl", source, configured))
        @test all(item -> item.response == response, response_diagnostics)
    end

    disabled = with_rules(configuration, Dict(
        "JULIA-NAMING" => RuleSetting("JULIA-NAMING", false, Fail)))
    @test isempty(filter(
        item -> item.rule_id == "JULIA-NAMING",
        OdinJuliaAnalysis.JuliaEngine.check(
            "fixture.jl", source, disabled)))

    constructor_source = """
        struct Example
            value::Int
        end
        Example(value::Int) = Example(value)
        function UtilityFunction()
            return nothing
        end
        """
    function_conventions = [
        convention.kind == :function ?
            NamingConvention(
                :julia,
                :function,
                convention.casing;
                allow_leading_underscore=convention.allow_leading_underscore,
                allow_trailing_bang=convention.allow_trailing_bang,
                allow_constructor_names=true,
                ignored_names=convention.ignored_names,
                ignored_patterns=convention.ignored_patterns) : convention
        for convention in configuration.naming.conventions]
    constructor_configuration = OdinJuliaAnalysis.EffectiveSettings(
        configuration.profile,
        configuration.failure_threshold,
        configuration.thresholds,
        configuration.enforcement_excludes,
        configuration.rules,
        NamingSettings(function_conventions),
        configuration.jet,
        configuration.odin_build,
        configuration.return_tuples,
        configuration.parameter_counts,
        configuration.function_metrics,
        configuration.architecture,
        configuration.allocations,
        configuration.report,
        configuration.extensions,
        configuration.rule_registry,
        configuration.extension_rule_owners)
    constructor_diagnostics = filter(
        item -> item.rule_id == "JULIA-NAMING",
        OdinJuliaAnalysis.JuliaEngine.check(
            "constructors.jl", constructor_source, constructor_configuration))
    @test [item.subject for item in constructor_diagnostics] == [
        "UtilityFunction"]

    disabled_function_conventions = [
        convention.kind == :function ?
            NamingConvention(
                :julia,
                :function,
                convention.casing;
                allow_leading_underscore=convention.allow_leading_underscore,
                allow_trailing_bang=convention.allow_trailing_bang,
                ignored_names=convention.ignored_names,
                ignored_patterns=convention.ignored_patterns) : convention
        for convention in configuration.naming.conventions]
    disabled_constructor_configuration = OdinJuliaAnalysis.EffectiveSettings(
        configuration.profile,
        configuration.failure_threshold,
        configuration.thresholds,
        configuration.enforcement_excludes,
        configuration.rules,
        NamingSettings(disabled_function_conventions),
        configuration.jet,
        configuration.odin_build,
        configuration.return_tuples,
        configuration.parameter_counts,
        configuration.function_metrics,
        configuration.architecture,
        configuration.allocations,
        configuration.report,
        configuration.extensions,
        configuration.rule_registry,
        configuration.extension_rule_owners)
    disabled_constructor_diagnostics = filter(
        item -> item.rule_id == "JULIA-NAMING",
        OdinJuliaAnalysis.JuliaEngine.check(
            "constructors.jl",
            constructor_source,
            disabled_constructor_configuration))
    @test [item.subject for item in disabled_constructor_diagnostics] == [
        "Example", "UtilityFunction"]

    cross_file_diagnostics = filter(
        item -> item.rule_id == "JULIA-NAMING",
        OdinJuliaAnalysis.JuliaEngine.check(
            "constructor.jl",
            "Example(value::Int) = Example(value)",
            constructor_configuration))
    type_declarations = OdinJuliaAnalysis.JuliaEngine.analyze_declarations(
        "type.jl",
        "struct Example\nvalue::Int\nend")
    OdinJuliaAnalysis.apply_constructor_naming_convention!(
        cross_file_diagnostics,
        type_declarations,
        constructor_configuration)
    @test isempty(cross_file_diagnostics)
end

@testset "Julia non-const globals" begin
    configuration = OdinJuliaAnalysis.load_settings()
    source = """
        mutable_global = 1
        const FIXED_GLOBAL = 2
        first_global, second_global = 3, 4

        \"\"\"Exercise local and explicit global declarations.\"\"\"
        function sample()
            local_value = 5
            global explicit_global = 6
            return local_value
        end
        """
    diagnostics = filter(
        item -> item.rule_id == "JULIA-NONCONST-GLOBAL",
        OdinJuliaAnalysis.JuliaEngine.check(
            "fixture.jl", source, configuration))

    @test [item.subject for item in diagnostics] == [
        "mutable_global",
        "first_global",
        "second_global",
        "explicit_global",
    ]
    @test all(item -> item.response == Warn, diagnostics)
    @test "local_value" ∉ [item.subject for item in diagnostics]
    @test "FIXED_GLOBAL" ∉ [item.subject for item in diagnostics]

    for response in (Ignore, Report, Warn, Fail)
        configured = with_rules(configuration, Dict(
            "JULIA-NONCONST-GLOBAL" => RuleSetting(
                "JULIA-NONCONST-GLOBAL", true, response)))
        response_diagnostics = filter(
            item -> item.rule_id == "JULIA-NONCONST-GLOBAL",
            OdinJuliaAnalysis.JuliaEngine.check(
                "fixture.jl", source, configured))
        @test all(item -> item.response == response, response_diagnostics)
    end

    disabled = with_rules(configuration, Dict(
        "JULIA-NONCONST-GLOBAL" => RuleSetting(
            "JULIA-NONCONST-GLOBAL", false, Fail)))
    @test isempty(filter(
        item -> item.rule_id == "JULIA-NONCONST-GLOBAL",
        OdinJuliaAnalysis.JuliaEngine.check(
            "fixture.jl", source, disabled)))
end

@testset "Julia const mutable references" begin
    configuration = OdinJuliaAnalysis.load_settings()
    source = """
        const PLAIN_REF = Ref(1)
        const TYPED_REF::Ref{Int} = Ref{Int}(2)
        const BASE_REF = Base.RefValue(3)
        const CORE_REF = Core.Ref(4)
        const ORDINARY_CONSTANT = 5
        NONCONST_REF = Ref(6)

        module Nested
        const NESTED_REF = Ref(7)
        end

        \"\"\"Return local mutable state.\"\"\"
        function local_reference()
            local_ref = Ref(8)
            return local_ref[]
        end
        """
    diagnostics = filter(
        item -> item.rule_id == "JULIA-CONST-MUTABLE-REF",
        OdinJuliaAnalysis.JuliaEngine.check(
            "fixture.jl", source, configuration))

    @test [item.subject for item in diagnostics] == [
        "PLAIN_REF",
        "TYPED_REF",
        "BASE_REF",
        "CORE_REF",
        "NESTED_REF",
    ]
    @test all(item -> item.response == Warn, diagnostics)
    @test all(item -> item.operation == "const-ref-global", diagnostics)
    @test all(item -> item.certainty == "probable", diagnostics)

    for response in (Ignore, Report, Warn, Fail)
        configured = with_rules(configuration, Dict(
            "JULIA-CONST-MUTABLE-REF" => RuleSetting(
                "JULIA-CONST-MUTABLE-REF", true, response)))
        response_diagnostics = filter(
            item -> item.rule_id == "JULIA-CONST-MUTABLE-REF",
            OdinJuliaAnalysis.JuliaEngine.check(
                "fixture.jl", source, configured))
        @test all(item -> item.response == response, response_diagnostics)
    end

    disabled = with_rules(configuration, Dict(
        "JULIA-CONST-MUTABLE-REF" => RuleSetting(
            "JULIA-CONST-MUTABLE-REF", false, Fail)))
    @test isempty(filter(
        item -> item.rule_id == "JULIA-CONST-MUTABLE-REF",
        OdinJuliaAnalysis.JuliaEngine.check(
            "fixture.jl", source, disabled)))
end

@testset "Julia declaration order" begin
    configuration = OdinJuliaAnalysis.load_settings()
    valid_source = """
        struct Widget
            value::Int
        end
        Widget(value) = Widget(value)
        const LIMIT = 1
        struct Box{T}
            value::T
        end
        Box{T}(value) where {T} = Box{T}(value)
        run() = LIMIT
        """
    @test isempty(filter(
        item -> item.rule_id == "JULIA-DECLARATION-ORDER",
        OdinJuliaAnalysis.JuliaEngine.check(
            "valid.jl", valid_source, configuration)))

    invalid_source = """
        run() = 1
        struct Widget
            value::Int
        end
        const LIMIT = 1
        """
    diagnostics = filter(
        item -> item.rule_id == "JULIA-DECLARATION-ORDER",
        OdinJuliaAnalysis.JuliaEngine.check(
            "invalid.jl", invalid_source, configuration))
    @test [item.subject for item in diagnostics] == ["Widget", "LIMIT"]
    @test all(item -> item.response == Warn, diagnostics)

    disabled = with_rules(configuration, Dict(
        "JULIA-DECLARATION-ORDER" => RuleSetting(
            "JULIA-DECLARATION-ORDER", false, Warn)))
    @test isempty(filter(
        item -> item.rule_id == "JULIA-DECLARATION-ORDER",
        OdinJuliaAnalysis.JuliaEngine.check(
            "invalid.jl", invalid_source, disabled)))
end

@testset "Julia return tuples" begin
    configuration = OdinJuliaAnalysis.load_settings()
    source = """
        \"\"\"Return an explicit tuple.\"\"\"
        function explicit_tuple(value)
            value > 0 && return value, value + 1, value + 2
            return value, value + 1
        end

        \"\"\"Return an implicit tuple.\"\"\"
        implicit_tuple(value) = (value, value + 1, value + 2)

        \"\"\"Contain a nested tuple-returning function.\"\"\"
        function outer(value)
            inner(item) = (item, item + 1, item + 2)
            return value
        end
        """
    diagnostics = filter(
        item -> item.rule_id == "JULIA-RETURN-TUPLE",
        OdinJuliaAnalysis.JuliaEngine.check(
            "fixture.jl", source, configuration))
    @test [item.subject for item in diagnostics] == [
        "explicit_tuple", "implicit_tuple", "inner"]
    @test all(item -> item.measured == 3, diagnostics)
    @test all(item -> item.allowed == 2, diagnostics)
    @test all(item -> item.response == Fail, diagnostics)

    julia_relaxed = with_return_tuples(
        configuration, ReturnTupleSettings(3, 1))
    @test isempty(filter(
        item -> item.rule_id == "JULIA-RETURN-TUPLE",
        OdinJuliaAnalysis.JuliaEngine.check(
            "fixture.jl", source, julia_relaxed)))

    for response in (Report, Warn, Fail)
        configured = with_rules(configuration, Dict(
            "JULIA-RETURN-TUPLE" => RuleSetting(
                "JULIA-RETURN-TUPLE", true, response)))
        response_diagnostics = filter(
            item -> item.rule_id == "JULIA-RETURN-TUPLE",
            OdinJuliaAnalysis.JuliaEngine.check(
                "fixture.jl", source, configured))
        @test all(item -> item.response == response, response_diagnostics)
    end

    disabled = with_rules(configuration, Dict(
        "JULIA-RETURN-TUPLE" => RuleSetting(
            "JULIA-RETURN-TUPLE", false, Fail)))
    @test isempty(filter(
        item -> item.rule_id == "JULIA-RETURN-TUPLE",
        OdinJuliaAnalysis.JuliaEngine.check(
            "fixture.jl", source, disabled)))
end

@testset "Julia parameter counts" begin
    configuration = OdinJuliaAnalysis.load_settings()
    source = """
        \"\"\"Accept eight positional parameters and many keywords.\"\"\"
        accepted(a, b, c, d, e, f, g, h;
            first=1, second=2, third=3, fourth=4, fifth=5,
            sixth=6, seventh=7, eighth=8, ninth=9) = a

        \"\"\"Reject nine positional parameters.\"\"\"
        rejected(a, b, c, d, e, f, g, h, i; keyword=1) = a

        \"\"\"Accept arbitrary keyword parameters.\"\"\"
        keywords(; a=1, b=2, c=3, d=4, e=5, f=6, g=7, h=8, i=9) = a
        """
    diagnostics = filter(
        item -> item.rule_id == "JULIA-PARAMETERS-FAIL",
        OdinJuliaAnalysis.JuliaEngine.check(
            "fixture.jl", source, configuration))
    @test [item.subject for item in diagnostics] == ["rejected"]
    @test only(diagnostics).measured == 9
    @test only(diagnostics).allowed == 8
    @test only(diagnostics).response == Fail

    relaxed = with_parameter_counts(
        configuration, ParameterCountSettings(9, 1, 2))
    @test isempty(filter(
        item -> item.rule_id == "JULIA-PARAMETERS-FAIL",
        OdinJuliaAnalysis.JuliaEngine.check(
            "fixture.jl", source, relaxed)))

    for response in (Report, Warn, Fail)
        configured = with_rules(configuration, Dict(
            "JULIA-PARAMETERS-FAIL" => RuleSetting(
                "JULIA-PARAMETERS-FAIL", true, response)))
        response_diagnostics = filter(
            item -> item.rule_id == "JULIA-PARAMETERS-FAIL",
            OdinJuliaAnalysis.JuliaEngine.check(
                "fixture.jl", source, configured))
        @test all(item -> item.response == response, response_diagnostics)
    end

    disabled = with_rules(configuration, Dict(
        "JULIA-PARAMETERS-FAIL" => RuleSetting(
            "JULIA-PARAMETERS-FAIL", false, Fail)))
    @test isempty(filter(
        item -> item.rule_id == "JULIA-PARAMETERS-FAIL",
        OdinJuliaAnalysis.JuliaEngine.check(
            "fixture.jl", source, disabled)))
end

@testset "CodeComplexity metrics" begin
    source = """
        \"\"\"Document the short function.\"\"\"
        short(x::T, args...; flag=true) where T =
            flag && x > 0 ? x : short(x, args...; flag=false)
        macro guarded(x)
            try
                x || return nothing
            catch
                @goto done
            end
            @label done
        end
        value = (a, b; c=1) -> a && b || c
        Thing(x) = x
        (::Thing)(x, y) = x > y ? x : y
        """
    functions = OdinJuliaAnalysis.JuliaEngine.analyze_functions(
        "fixture.jl", source)

    @test [item.name for item in functions] == [
        "short", "@guarded", "<anonymous>", "Thing", "Thing"]
    @test [item.parameter_count for item in functions] == [2, 1, 2, 1, 2]
    @test [item.cyclomatic_complexity for item in functions] == [3, 4, 3, 1, 2]
    @test [item.cognitive_complexity for item in functions] == [4, 3, 2, 0, 2]
    @test functions[1].documented
    @test all(item -> item.start_line <= item.end_line, functions)

    token_source = "kinds = (:function, :macro, :(->))\n"
    @test isempty(OdinJuliaAnalysis.JuliaEngine.analyze_functions(
        "tokens.jl", token_source))
end

@testset "source statistics result contract" begin
    function_stats = FunctionStatistics(
        "sample", 2, 5, 4, 3, 1, 2, 1, true, 2 / 3)
    file_stats = FileStatistics(
        true, 6, 5, 4, 1, 1, 1, 0, 2, 0.5, 2.0, 2, 3.0, 3)
    report = SourceStatisticsReport(
        "1.0.0", "0.1.0", "sample.jl", "julia", file_stats,
        [function_stats], StatisticsSelection("line", "3", 1))

    encoded = JSON3.read(JSON3.write(report))
    @test encoded.schema_version == "1.0.0"
    @test encoded.path == "sample.jl"
    @test encoded.file.total_cyclomatic_complexity == 2
    @test encoded.functions[1].physical_lines == 4
    @test encoded.functions[1].complexity_per_executable_line ≈ 2 / 3
    @test encoded.selection.kind == "line"
    @test encoded.selection.matches == 1
end

@testset "function metric response tiers" begin
    configuration = OdinJuliaAnalysis.load_settings()
    metrics = FunctionMetricSettings(
        ResponseThresholds(2, 4, 6),
        ResponseThresholds(3, 5, 7),
        ResponseThresholds(1, 3, 5),
        ResponseThresholds(2, 4, 6))
    configured = with_function_metrics(configuration, metrics)
    functions = [
        OdinJuliaAnalysis.FunctionAnalysis(
            "fixture.jl", "julia", "report"; start_line=1, end_line=3,
            executable_lines=3, parameter_count=0, cyclomatic_complexity=2,
            cognitive_complexity=0, documented=true),
        OdinJuliaAnalysis.FunctionAnalysis(
            "fixture.jl", "julia", "warn"; start_line=4, end_line=8,
            executable_lines=5, parameter_count=0, cyclomatic_complexity=4,
            cognitive_complexity=0, documented=true),
        OdinJuliaAnalysis.FunctionAnalysis(
            "fixture.jl", "julia", "fail"; start_line=9, end_line=15,
            executable_lines=7, parameter_count=0, cyclomatic_complexity=6,
            cognitive_complexity=0, documented=true),
        OdinJuliaAnalysis.FunctionAnalysis(
            "fixture.odin", "odin", "warn"; start_line=1, end_line=6,
            executable_lines=6, parameter_count=0, cyclomatic_complexity=5,
            cognitive_complexity=nothing, documented=true),
        OdinJuliaAnalysis.FunctionAnalysis(
            "boundary.odin", "odin", "boundary"; start_line=1, end_line=3,
            executable_lines=3, parameter_count=0, cyclomatic_complexity=2,
            cognitive_complexity=nothing, documented=true),
    ]
    diagnostics = OdinJuliaAnalysis.function_metric_diagnostics(
        functions, configured)
    @test [item.rule_id for item in diagnostics] == [
        "JULIA-FUNCTION-LINES-REPORT",
        "JULIA-CYCLOMATIC-REPORT",
        "JULIA-FUNCTION-LINES-WARN",
        "JULIA-CYCLOMATIC-WARN",
        "JULIA-FUNCTION-LINES-FAIL",
        "JULIA-CYCLOMATIC-FAIL",
        "ODIN-FUNCTION-LINES-WARN",
        "ODIN-CYCLOMATIC-WARN",
    ]
    @test [item.response for item in diagnostics] == [
        Report, Report, Warn, Warn, Fail, Fail, Warn, Warn]
    @test [item.allowed for item in diagnostics] == [2, 1, 4, 3, 6, 5, 5, 4]
    @test all(item -> item.subject != "boundary", diagnostics)

    odin_relaxed = with_function_metrics(
        configured,
        FunctionMetricSettings(
            metrics.julia_lines,
            ResponseThresholds(10, 20, 30),
            metrics.julia_cyclomatic,
            ResponseThresholds(10, 20, 30)))
    relaxed_diagnostics = OdinJuliaAnalysis.function_metric_diagnostics(
        functions, odin_relaxed)
    @test all(item -> startswith(item.rule_id, "JULIA-"), relaxed_diagnostics)

    overridden = with_rules(configured, Dict(
        "JULIA-FUNCTION-LINES-REPORT" => RuleSetting(
            "JULIA-FUNCTION-LINES-REPORT", true, Warn)))
    overridden_diagnostics = OdinJuliaAnalysis.function_metric_diagnostics(
        functions[1:1], overridden)
    @test first(overridden_diagnostics).response == Warn

    disabled = with_rules(configured, Dict(
        "JULIA-FUNCTION-LINES-FAIL" => RuleSetting(
            "JULIA-FUNCTION-LINES-FAIL", false, Fail),
        "JULIA-CYCLOMATIC-FAIL" => RuleSetting(
            "JULIA-CYCLOMATIC-FAIL", false, Fail)))
    @test isempty(OdinJuliaAnalysis.function_metric_diagnostics(
        functions[3:3], disabled))
end

@testset "reviewed function metrics" begin
    configuration = OdinJuliaAnalysis.load_settings()
    policies = ReviewedComplexity[
        ReviewedComplexity(
            "julia-lines",
            "fixture.jl",
            :julia,
            "reviewed",
            :executable_lines,
            "The cohesive fixture is intentionally long.";
            response=Report),
        ReviewedComplexity(
            "julia-cyclomatic",
            "fixture.jl",
            :julia,
            "reviewed",
            :cyclomatic_complexity,
            "The branching is an intentional dispatcher.";
            response=Warn),
        ReviewedComplexity(
            "odin-lines",
            "fixture.odin",
            :odin,
            "reviewed",
            :executable_lines,
            "The fixture verifies Fail remapping.";
            response=Fail),
    ]
    metrics = FunctionMetricSettings(
        ResponseThresholds(2, 4, 6),
        ResponseThresholds(2, 4, 6),
        ResponseThresholds(1, 3, 5),
        ResponseThresholds(1, 3, 5),
        policies)
    configured = with_function_metrics(configuration, metrics)
    functions = [
        OdinJuliaAnalysis.FunctionAnalysis(
            "fixture.jl", "julia", "reviewed"; start_line=1, end_line=8,
            executable_lines=5, parameter_count=0, cyclomatic_complexity=4,
            cognitive_complexity=0, documented=true),
        OdinJuliaAnalysis.FunctionAnalysis(
            "fixture.odin", "odin", "reviewed"; start_line=1, end_line=8,
            executable_lines=5, parameter_count=0, cyclomatic_complexity=1,
            cognitive_complexity=nothing, documented=true),
    ]
    diagnostics = OdinJuliaAnalysis.function_metric_diagnostics(
        functions, configured)
    mktempdir() do root
        files = [joinpath(root, "fixture.jl"), joinpath(root, "fixture.odin")]
        foreach(path -> write(path, ""), files)
        OdinJuliaAnalysis.apply_reviewed_complexity!(
            diagnostics, root, files, configured)
    end
    @test [item.response for item in diagnostics] == [Report, Warn, Fail]
    @test [item.reviewed_policy_id for item in diagnostics] == [
        "julia-lines", "julia-cyclomatic", "odin-lines"]
    @test all(item -> item.reviewed_policy_reason !== nothing, diagnostics)

    stale = with_function_metrics(
        configuration,
        FunctionMetricSettings(
            metrics.julia_lines,
            metrics.odin_lines,
            metrics.julia_cyclomatic,
            metrics.odin_cyclomatic,
            policies[1:1]))
    drift = OdinJuliaAnalysis.Diagnostic[]
    mktempdir() do root
        path = joinpath(root, "fixture.jl")
        write(path, "")
        OdinJuliaAnalysis.apply_reviewed_complexity!(
            drift, root, [path], stale)
    end
    @test only(drift).rule_id == "FUNCTION-METRIC-POLICY-DRIFT"
    @test occursin("found 0", only(drift).message)

    duplicate = ReviewedComplexity(
        "duplicate",
        "fixture.jl",
        :julia,
        "reviewed",
        :executable_lines,
        "Duplicate selector.")
    @test_throws ArgumentError OdinJuliaAnalysis.validate_reviewed_complexity(
        [policies[1], duplicate])
end

@testset "repository statistics" begin
    files = [
        OdinJuliaAnalysis.FileAnalysis(
            "one.jl", "julia"; physical_lines=10, source_lines=8,
            code_lines=6, comment_lines=2, blank_lines=2,
            struct_count=2, parsed=true),
        OdinJuliaAnalysis.FileAnalysis(
            "two.odin", "odin"; physical_lines=20, source_lines=17,
            code_lines=15, comment_lines=2, blank_lines=3,
            struct_count=3, parsed=true),
        OdinJuliaAnalysis.FileAnalysis(
            "notes.md", "markdown"; physical_lines=100, source_lines=90,
            code_lines=90, comment_lines=0, blank_lines=10,
            struct_count=0, parsed=true),
    ]
    functions = [
        OdinJuliaAnalysis.FunctionAnalysis(
            "one.jl", "julia", "one"; start_line=1, end_line=4,
            executable_lines=3, parameter_count=1, cyclomatic_complexity=4,
            cognitive_complexity=2, documented=true),
        OdinJuliaAnalysis.FunctionAnalysis(
            "two.odin", "odin", "two"; start_line=1, end_line=8,
            executable_lines=6, parameter_count=1, cyclomatic_complexity=3,
            cognitive_complexity=nothing, documented=true),
    ]
    statistics = OdinJuliaAnalysis.calculate_repository_statistics(
        files, functions)

    @test statistics.code.files == 2
    @test statistics.code.functions == 2
    @test statistics.code.structs == 5
    @test statistics.code.lines == 30
    @test statistics.code.blank_lines == 5
    @test statistics.code.comment_lines == 4
    @test statistics.code.code_lines == 21
    @test statistics.code.complexity == 7
    @test statistics.code.complexity_per_code_line ≈ 1 / 3
    @test statistics.code_by_language["julia"].files == 1
    @test statistics.code_by_language["julia"].functions == 1
    @test statistics.code_by_language["julia"].structs == 2
    @test statistics.code_by_language["julia"].code_lines == 6
    @test statistics.code_by_language["julia"].complexity == 4
    @test statistics.code_by_language["odin"].files == 1
    @test statistics.code_by_language["odin"].functions == 1
    @test statistics.code_by_language["odin"].structs == 3
    @test statistics.code_by_language["odin"].code_lines == 15
    @test statistics.code_by_language["odin"].complexity == 3

    cocomo = statistics.cocomo
    expected_effort = 2.4 * (21 / 1_000)^1.05
    @test cocomo.effort_person_months ≈ expected_effort
    @test cocomo.schedule_months ≈ 2.5 * expected_effort^0.38
    @test cocomo.people ≈ expected_effort / cocomo.schedule_months
    @test cocomo.estimated_cost ≈ expected_effort * 56_286 / 12 * 2.4

    locomo = statistics.locomo
    expected_cycles = 1.5 + sqrt(1 / 3) * 2
    expected_output = 21 * 10 * expected_cycles
    expected_input = 21 * 20 * (1 + sqrt(1 / 3) * 5) * expected_cycles
    @test locomo.estimated_cycles ≈ expected_cycles
    @test locomo.output_tokens ≈ expected_output
    @test locomo.input_tokens ≈ expected_input
    @test locomo.estimated_cost ≈
        expected_input / 1_000_000 * 3 + expected_output / 1_000_000 * 15
    @test locomo.generation_seconds ≈ expected_output / 50
    @test locomo.review_hours ≈ 21 * 0.01 / 60

    empty_statistics = OdinJuliaAnalysis.calculate_repository_statistics(
        OdinJuliaAnalysis.FileAnalysis[], OdinJuliaAnalysis.FunctionAnalysis[])
    @test empty_statistics.code.complexity_per_code_line == 0.0
    @test empty_statistics.cocomo.people == 0.0
    @test empty_statistics.locomo.estimated_cost == 0.0
end

@testset "JET static inference" begin
    @test JET.JET_AVAILABLE
    mktempdir() do root
        path = joinpath(root, "fixture.jl")
        write(path, "")
        configuration = OdinJuliaAnalysis.load_settings()
        entry = JetEntryPoint(
            "bad-call",
            "fixture.jl",
            jet_fixture_bad,
            (Int,))
        configured = with_jet_entries(configuration, [entry])
        diagnostics = OdinJuliaAnalysis.JetEngine.analyze(
            root, configured)
        diagnostic = only(diagnostics)

        @test diagnostic.rule_id == "JULIA-JET-POSSIBLE-ERROR"
        @test diagnostic.response == Fail
        @test diagnostic.path == "fixture.jl"
        @test diagnostic.line > 0
        @test occursin("jet_fixture_missing", diagnostic.message)
        @test !occursin("JETVirtualModule", diagnostic.message)

        disabled = with_rules(configured, Dict(
            "JULIA-JET-POSSIBLE-ERROR" => RuleSetting(
                "JULIA-JET-POSSIBLE-ERROR", false, Fail)))
        @test isempty(OdinJuliaAnalysis.JetEngine.analyze(
            root, disabled))

        wrapped = JET.ActualErrorWrapped(
            ErrorException("fixture failure"),
            Base.StackTraces.StackFrame[],
            path,
            1)
        wrapped_diagnostic = OdinJuliaAnalysis.JetEngine.jet_diagnostic(
            root, path, wrapped)
        @test occursin("fixture failure", wrapped_diagnostic.message)
    end
end

