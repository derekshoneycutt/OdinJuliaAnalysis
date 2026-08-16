using Test
using OdinJuliaAnalysis
using JET

const TEST_VERBOSE = get(ENV, "ODIN_JULIA_ANALYSIS_TEST_VERBOSE", "false") == "true"

struct FixtureExtension <: AnalysisExtension
    id::String
    dependencies::Vector{String}
    phases::Set{AnalysisPhase}
    status::String
    should_throw::Bool
end

"""Return the fixture extension's stable identity."""
OdinJuliaAnalysis.extension_id(extension::FixtureExtension) = extension.id

"""Return the fixture extension's registered rule."""
function OdinJuliaAnalysis.extension_rules(extension::FixtureExtension)
    rule_id = uppercase(extension.id) * "-FIXTURE"
    return [RuleDefinition(
        rule_id,
        "common",
        "Test extension",
        "experimental",
        "stable",
        "report",
        false)]
end

"""Return fixture extension lifecycle phases."""
OdinJuliaAnalysis.extension_phases(extension::FixtureExtension) = extension.phases

"""Return fixture extension dependencies."""
function OdinJuliaAnalysis.extension_dependencies(extension::FixtureExtension)
    return extension.dependencies
end

"""Emit one repository-phase fixture finding and one artifact per phase."""
function OdinJuliaAnalysis.analyze_extension(
    extension::FixtureExtension,
    context,
    prior_results)
    extension.should_throw && error("fixture extension failed")
    diagnostics = Diagnostic[]
    if context.phase == AfterRepositoryAnalysis
        push!(diagnostics, Diagnostic(
            uppercase(extension.id) * "-FIXTURE",
            Ignore,
            first(context.paths),
            1,
            1,
            "Fixture extension finding.",
            nothing,
            nothing,
            "fixture-extension"))
    end
    artifacts = Dict{String, Any}(
        "path_count" => length(context.paths),
        "prior_count" => length(prior_results))
    return ExtensionResult(
        extension.id,
        context.phase;
        status=extension.status,
        diagnostics,
        artifacts)
end

"""Return validated settings with trusted fixture extensions and their rules."""
function with_extensions(configuration, extensions)
    rules = collect(values(configuration.rules))
    for extension in extensions, definition in extension_rules(extension)
        push!(rules, RuleSetting(definition.rule_id, true, Warn))
    end
    settings = AnalysisSettings(
        configuration.profile,
        configuration.failure_threshold,
        configuration.thresholds,
        [ScanProfile(configuration.profile, configuration.enforcement_excludes)],
        rules,
        configuration.naming,
        JetSettings(JetEntryPoint[]),
        OdinBuildSettings(OdinBuildTarget[]),
        configuration.return_tuples,
        configuration.parameter_counts,
        configuration.function_metrics,
        configuration.allocations,
        configuration.report,
        AnalysisExtension[extensions...])
    return OdinJuliaAnalysis.validate_settings(settings)
end

"""Exercise JET detection of an undefined global from a configured call root."""
jet_fixture_bad(value::Int) = value + jet_fixture_missing

"""Return effective settings with selected rule overrides."""
function with_rules(
    configuration,
    replacements;
    failure_threshold=configuration.failure_threshold)
    rules = copy(configuration.rules)
    merge!(rules, replacements)
    return OdinJuliaAnalysis.EffectiveSettings(
        configuration.profile,
        failure_threshold,
        configuration.thresholds,
        configuration.enforcement_excludes,
        rules,
        configuration.naming,
        configuration.jet,
        configuration.odin_build,
        configuration.return_tuples,
        configuration.parameter_counts,
        configuration.function_metrics,
        configuration.allocations,
        configuration.report)
end

"""Return effective settings with replacement allocation policies."""
function with_allocation_policies(configuration, policies)
    allocations = AllocationSettings(
        configuration.allocations.known_procedures,
        configuration.allocations.source_patterns,
        policies)
    return OdinJuliaAnalysis.EffectiveSettings(
        configuration.profile,
        configuration.failure_threshold,
        configuration.thresholds,
        configuration.enforcement_excludes,
        configuration.rules,
        configuration.naming,
        configuration.jet,
        configuration.odin_build,
        configuration.return_tuples,
        configuration.parameter_counts,
        configuration.function_metrics,
        allocations,
        configuration.report)
end

"""Return effective settings with replacement JET entry points."""
function with_jet_entries(configuration, entry_points)
    return OdinJuliaAnalysis.EffectiveSettings(
        configuration.profile,
        configuration.failure_threshold,
        configuration.thresholds,
        configuration.enforcement_excludes,
        configuration.rules,
        configuration.naming,
        JetSettings(entry_points),
        configuration.odin_build,
        configuration.return_tuples,
        configuration.parameter_counts,
        configuration.function_metrics,
        configuration.allocations,
        configuration.report)
end

"""Return effective settings with replacement analytical Odin build targets."""
function with_odin_build_targets(configuration, targets)
    return OdinJuliaAnalysis.EffectiveSettings(
        configuration.profile,
        configuration.failure_threshold,
        configuration.thresholds,
        configuration.enforcement_excludes,
        configuration.rules,
        configuration.naming,
        configuration.jet,
        OdinBuildSettings(targets),
        configuration.return_tuples,
        configuration.parameter_counts,
        configuration.function_metrics,
        configuration.allocations,
        configuration.report)
end

"""Return effective settings with independently replaced return tuple maxima."""
function with_return_tuples(configuration, return_tuples)
    return OdinJuliaAnalysis.EffectiveSettings(
        configuration.profile,
        configuration.failure_threshold,
        configuration.thresholds,
        configuration.enforcement_excludes,
        configuration.rules,
        configuration.naming,
        configuration.jet,
        configuration.odin_build,
        return_tuples,
        configuration.parameter_counts,
        configuration.function_metrics,
        configuration.allocations,
        configuration.report)
end

    """Return effective settings with replacement parameter count thresholds."""
    function with_parameter_counts(configuration, parameter_counts)
        return OdinJuliaAnalysis.EffectiveSettings(
        configuration.profile,
        configuration.failure_threshold,
        configuration.thresholds,
        configuration.enforcement_excludes,
        configuration.rules,
        configuration.naming,
        configuration.jet,
        configuration.odin_build,
        configuration.return_tuples,
        parameter_counts,
        configuration.function_metrics,
        configuration.allocations,
        configuration.report)
    end

    """Return effective settings with replacement function metric thresholds."""
    function with_function_metrics(configuration, function_metrics)
        return OdinJuliaAnalysis.EffectiveSettings(
        configuration.profile,
        configuration.failure_threshold,
        configuration.thresholds,
        configuration.enforcement_excludes,
        configuration.rules,
        configuration.naming,
        configuration.jet,
        configuration.odin_build,
        configuration.return_tuples,
        configuration.parameter_counts,
        function_metrics,
        configuration.allocations,
        configuration.report)
    end

"""Write package settings with replacement JET entry points for CLI fixtures."""
function write_jet_settings(path, entry_points_expression)
    default_path = repr(OdinJuliaAnalysis.DEFAULT_SETTINGS_PATH)
    write(path, """
        using OdinJuliaAnalysis

        base = Base.include(@__MODULE__, $default_path)
        AnalysisSettings(
            base.profile,
            base.failure_threshold,
            base.thresholds,
            base.profiles,
            base.rules,
            base.naming,
            JetSettings($entry_points_expression),
            OdinBuildSettings(OdinBuildTarget[]),
            base.allocations,
            base.report)
        """)
    return path
end

@testset verbose=TEST_VERBOSE "OdinJuliaAnalysis" begin
    @test OdinJuliaAnalysis.main(["unknown"]) == 2

    @testset "common rules" begin
        source = "valid = true\n" * repeat("x", 91) * "\n\tbad = true\n"
        diagnostics = OdinJuliaAnalysis.check_common_rules("fixture.jl", source)
        @test [item.rule_id for item in diagnostics] == [
            "COMMON-LINE-90",
            "COMMON-NO-TABS",
        ]

        @testset "exempts Julia and Odin comment-only lines" begin
            long_text = repeat("x", 121)
            julia_source = "# $long_text\n#=\n$long_text\n=#\nvalue = 1 # $long_text\n"
            julia_diagnostics = OdinJuliaAnalysis.check_common_rules(
                "fixture.jl",
                julia_source)
            @test [item.line for item in julia_diagnostics] == [5]

            odin_source = "// $long_text\n/*\n$long_text\n*/\nvalue := 1 // $long_text\n"
            odin_diagnostics = OdinJuliaAnalysis.check_common_rules(
                "fixture.odin",
                odin_source)
            @test [item.line for item in odin_diagnostics] == [5]
        end

        @testset "exempts Markdown links and table rows" begin
            long_text = repeat("x", 121)
            markdown_source = """
                [reference](https://example.com/$long_text)
                | Column | Description |
                | --- | --- |
                | Value | $long_text |
                ```text
                https://example.com/$long_text
                ```
                $long_text
                """
            markdown_diagnostics = OdinJuliaAnalysis.check_common_rules(
                "fixture.md",
                markdown_source)
            @test [item.line for item in markdown_diagnostics] == [6, 8]
        end
    end

    @testset "configured rules" begin
        configuration = OdinJuliaAnalysis.load_settings()
        thresholds = AnalysisThresholds(10, 20, 30, 20, 30, 5, 10, 15, 15)
        rules = copy(configuration.rules)
        rules["COMMON-LINE-90"] = RuleSetting("COMMON-LINE-90", false, Warn)
        rules["COMMON-LINE-100"] = RuleSetting("COMMON-LINE-100", true, Report)
        rules["COMMON-LINE-120"] = RuleSetting("COMMON-LINE-120", true, Warn)
        configured = OdinJuliaAnalysis.EffectiveSettings(
            configuration.profile,
            configuration.failure_threshold,
            thresholds,
            configuration.enforcement_excludes,
            rules,
            configuration.naming,
            configuration.jet,
            configuration.odin_build,
            configuration.return_tuples,
            configuration.parameter_counts,
            configuration.function_metrics,
            configuration.allocations,
            configuration.report)
        diagnostics = OdinJuliaAnalysis.check_common_rules(
            "fixture.jl",
            repeat("x", 31),
            configured)
        @test only(diagnostics).rule_id == "COMMON-LINE-120"
        @test only(diagnostics).response == Warn
        @test only(diagnostics).allowed == 30
    end

    @testset "settings validation" begin
        configuration = OdinJuliaAnalysis.load_settings()
        @test Set(keys(configuration.rules)) == Set(keys(OdinJuliaAnalysis.RULE_REGISTRY))
        @test configuration.rules["JULIA-DOC-MISSING"].enabled == true
        @test configuration.rules["JULIA-DOC-MISSING"].response == Fail
        @test OdinJuliaAnalysis.RULE_REGISTRY[
            "JULIA-DOC-MISSING"].capability == "mature"
        @test configuration.rules["ODIN-DOC-MISSING"].enabled == true
        @test configuration.rules["ODIN-DOC-MISSING"].response == Fail
        @test configuration.rules["JULIA-NAMING"].response == Warn
        @test configuration.rules["ODIN-NAMING"].response == Warn
        @test configuration.rules["JULIA-NONCONST-GLOBAL"].response == Warn
        @test configuration.rules["ODIN-NONCONST-GLOBAL"].response == Warn
        @test configuration.rules["JULIA-RETURN-TUPLE"].response == Fail
        @test configuration.rules["ODIN-RETURN-TUPLE"].response == Fail
        @test configuration.return_tuples == ReturnTupleSettings(2, 2)
        @test configuration.rules["JULIA-PARAMETERS-FAIL"].response == Fail
        @test configuration.rules["ODIN-PARAMETERS-WARN"].response == Warn
        @test configuration.rules["ODIN-PARAMETERS-FAIL"].response == Fail
        @test configuration.parameter_counts == ParameterCountSettings(8, 5, 8)
        @test configuration.function_metrics.julia_lines ==
            ResponseThresholds(20, 35, 65)
        @test configuration.function_metrics.odin_lines ==
            ResponseThresholds(20, 35, 65)
        @test configuration.function_metrics.julia_cyclomatic ==
            ResponseThresholds(10, 13, 16)
        @test configuration.function_metrics.odin_cyclomatic ==
            ResponseThresholds(10, 15, 18)
        @test [policy.id for policy in configuration.function_metrics.reviewed] == [
            "odin-closing-parenthesis-scanner",
            "julia-declaration-naming-visitor",
        ]
        @test configuration.rules["FUNCTION-METRIC-POLICY-DRIFT"].response == Fail
        for language in ("JULIA", "ODIN"), metric in (
            "FUNCTION-LINES", "CYCLOMATIC")
            @test configuration.rules["$language-$metric-REPORT"].response == Report
            @test configuration.rules["$language-$metric-WARN"].response == Warn
            @test configuration.rules["$language-$metric-FAIL"].response == Fail
        end
        @test length(configuration.naming.conventions) == 15
        @test [entry.id for entry in configuration.jet.entry_points] == [
            "analyzer-cli"]
        @test Dict(
            rule_id => configuration.rules[rule_id].response
            for rule_id in (
                "ODIN-ALLOCATION-IMPLICIT",
                "ODIN-ALLOCATION-UNKNOWN",
                "ODIN-ALLOCATION-CONTEXT",
                "ODIN-ALLOCATION-HEAP",
                "ODIN-ALLOCATION-TEMPORARY",
                "ODIN-ALLOCATION-CUSTOM",
                "ODIN-ALLOCATION-DYNAMIC-GROWTH",
                "ODIN-ALLOCATION-ARENA",
                "ODIN-ALLOCATION-HIDDEN")) == Dict(
                    "ODIN-ALLOCATION-IMPLICIT" => Warn,
                    "ODIN-ALLOCATION-UNKNOWN" => Fail,
                    "ODIN-ALLOCATION-CONTEXT" => Warn,
                    "ODIN-ALLOCATION-HEAP" => Warn,
                    "ODIN-ALLOCATION-TEMPORARY" => Report,
                    "ODIN-ALLOCATION-CUSTOM" => Report,
                    "ODIN-ALLOCATION-DYNAMIC-GROWTH" => Report,
                    "ODIN-ALLOCATION-ARENA" => Warn,
                    "ODIN-ALLOCATION-HIDDEN" => Warn)
        @test [pattern.category
            for pattern in configuration.allocations.source_patterns] == [
            :context,
            :temporary,
            :heap,
        ]
        @test [policy.id
            for policy in configuration.allocations.reviewed_policies] == [
            "analysis-test-metrics-arena",
            "analysis-test-allocation-arena",
            "analysis-test-syntax-arena",
            "analysis-arena-backing",
        ]
        invalid_response = ReviewedAllocationPolicy(
            "invalid-response",
            "src/example.odin",
            "example",
            :implicit,
            "Ignore is not a reviewed decision.";
            response=Ignore)
        invalid_range = ReviewedAllocationPolicy(
            "invalid-range",
            "src/example.odin",
            "example",
            :implicit,
            "The range is invalid.";
            minimum_matches=2,
            maximum_matches=1)
        for policy in (invalid_response, invalid_range)
            allocations = AllocationSettings(
                KnownAllocatingProcedure[],
                AllocatorSourcePattern[],
                [policy])
            @test_throws ArgumentError OdinJuliaAnalysis.validate_allocation_settings(
                allocations)
        end

        invalid_thresholds = AnalysisThresholds(
            120, 100, 90, 20, 30, 5, 10, 15, 15)
        @test_throws ArgumentError OdinJuliaAnalysis.validate_thresholds(
            invalid_thresholds)
        @test_throws ArgumentError OdinJuliaAnalysis.validate_return_tuple_settings(
            ReturnTupleSettings(0, 2))
        @test_throws ArgumentError OdinJuliaAnalysis.validate_return_tuple_settings(
            ReturnTupleSettings(2, 0))
        @test_throws ArgumentError OdinJuliaAnalysis.validate_parameter_count_settings(
            ParameterCountSettings(0, 5, 8))
        @test_throws ArgumentError OdinJuliaAnalysis.validate_parameter_count_settings(
            ParameterCountSettings(8, 8, 8))
        @test_throws ArgumentError OdinJuliaAnalysis.validate_function_metric_settings(
            FunctionMetricSettings(
                ResponseThresholds(20, 20, 30),
                ResponseThresholds(20, 30, 40),
                ResponseThresholds(10, 15, 20),
                ResponseThresholds(10, 15, 20)))
        invalid_complexity = ReviewedComplexity(
            "invalid-response",
            "src/example.jl",
            :julia,
            "example",
            :cyclomatic_complexity,
            "Ignore would hide the reviewed decision.";
            response=Ignore)
        @test_throws ArgumentError OdinJuliaAnalysis.validate_reviewed_complexity(
            [invalid_complexity])

        function_convention = NamingConvention(
            :julia,
            :function,
            :snake_case;
            allow_leading_underscore=true,
            allow_trailing_bang=true,
            ignored_names=["Base.show"],
            ignored_patterns=[r"^ccall_"])
        @test OdinJuliaAnalysis.valid_identifier_name(
            "_parse_value!", function_convention)
        @test OdinJuliaAnalysis.valid_identifier_name(
            "Base.show", function_convention)
        @test OdinJuliaAnalysis.valid_identifier_name(
            "ccall_ABI", function_convention)
        @test !OdinJuliaAnalysis.valid_identifier_name(
            "ParseValue", function_convention)
        @test_throws ArgumentError OdinJuliaAnalysis.validate_naming_settings(
            NamingSettings([
                NamingConvention(:julia, :function, :snake_case),
                NamingConvention(:julia, :function, :lowercase),
            ]))
        invalid_naming_policy = ReviewedNamingPolicy(
            "invalid-response",
            "src/example.jl",
            :julia,
            :function,
            "Example",
            "Ignore would hide the reviewed decision.";
            response=Ignore)
        @test_throws ArgumentError OdinJuliaAnalysis.validate_naming_settings(
            NamingSettings(
                configuration.naming.conventions,
                [invalid_naming_policy]))
        @test_throws ArgumentError OdinJuliaAnalysis.validate_jet_settings(
            JetSettings([
                JetEntryPoint("invalid-path", "../main.jl", identity, (Int,)),
            ]))
        @test_throws ArgumentError OdinJuliaAnalysis.validate_odin_build_settings(
            OdinBuildSettings([
                OdinBuildTarget("invalid", "../src", "fixture", ["-vet"]),
            ]))
        @test_throws ArgumentError OdinJuliaAnalysis.validate_odin_build_settings(
            OdinBuildSettings([
                OdinBuildTarget("invalid", "src", "../fixture", ["-vet"]),
            ]))
        @test_throws ArgumentError OdinJuliaAnalysis.validate_odin_build_settings(
            OdinBuildSettings([
                OdinBuildTarget("invalid", "src", "fixture", ["vet"]),
            ]))
        @test_throws ArgumentError OdinJuliaAnalysis.validate_jet_settings(
            JetSettings([
                JetEntryPoint("invalid-types", "main.jl", identity, (1,)),
            ]))

        rules = collect(values(configuration.rules))
        syntax_index = findfirst(rule -> rule.rule_id == "JULIA-SYNTAX", rules)
        rules[syntax_index] = RuleSetting("JULIA-SYNTAX", true, Warn)
        settings = AnalysisSettings(
            :default,
            Fail,
            configuration.thresholds,
            [ScanProfile(:default, String[])],
            rules,
            configuration.naming,
            configuration.jet,
            configuration.allocations,
            configuration.report)
        @test_throws ArgumentError OdinJuliaAnalysis.validate_settings(settings)

        mktempdir() do root
            custom_path = joinpath(root, "settings.jl")
            default_source = read(OdinJuliaAnalysis.DEFAULT_SETTINGS_PATH, String)
            custom_source = replace(
                default_source,
                "AnalysisThresholds(90, 100, 120" =>
                    "AnalysisThresholds(80, 100, 120")
            write(custom_path, custom_source)
            custom = OdinJuliaAnalysis.load_settings(custom_path)
            options = OdinJuliaAnalysis.parse_check_options([
                "--settings=$custom_path"])

            @test custom.thresholds.line_warning == 80
            @test options.settings_path == custom_path
            @test options.progress == :auto
            @test OdinJuliaAnalysis.parse_check_options([
                "--progress=always"]).progress == :always
            @test OdinJuliaAnalysis.parse_check_options([
                "--progress=loud"]) === nothing
        end
    end

    @testset "trusted Julia extensions" begin
        configuration = OdinJuliaAnalysis.load_settings()
        all_phases = Set((
            AfterDiscovery,
            AfterLanguageAnalysis,
            AfterRepositoryAnalysis))
        dependency = FixtureExtension(
            "dependency", String[], all_phases, "complete", false)
        extension = FixtureExtension(
            "project", ["dependency"], all_phases, "complete", false)
        configured = with_extensions(configuration, [extension, dependency])

        @test extension_id.(configured.extensions) == ["dependency", "project"]
        @test configured.rules["PROJECT-FIXTURE"].response == Warn
        @test configured.extension_rule_owners["PROJECT-FIXTURE"] == "project"
        @test_throws ArgumentError OdinJuliaAnalysis.validate_extensions(
            AnalysisExtension[extension])
        cycle_a = FixtureExtension(
            "cycle-a", ["cycle-b"], all_phases, "complete", false)
        cycle_b = FixtureExtension(
            "cycle-b", ["cycle-a"], all_phases, "complete", false)
        @test_throws ArgumentError OdinJuliaAnalysis.validate_extensions(
            AnalysisExtension[cycle_a, cycle_b])

        mktempdir() do root
            write(joinpath(root, "README.md"), "# Fixture\n")
            report = OdinJuliaAnalysis.check_repository(root; configuration=configured)
            @test report.exit_code == 0
            @test length(report.extensions) == 6
            @test [result.phase for result in report.extensions[1:2]] ==
                [AfterDiscovery, AfterDiscovery]
            @test all(result -> result.status == "complete", report.extensions)
            @test only(filter(
                item -> item.rule_id == "PROJECT-FIXTURE",
                report.diagnostics)).response == Warn
            @test report.extensions[end].artifacts["prior_count"] == 1
            @test only(filter(
                engine -> engine.name == "extension:project",
                report.engines)).status == "complete"
            @test only(filter(
                rule -> rule.rule_id == "PROJECT-FIXTURE",
                report.rules)).status == "evaluated"
            output = IOBuffer()
            OdinJuliaAnalysis.write_markdown_report(output, report)
            report_text = String(take!(output))
            @test occursin("## Extension Results", report_text)
            @test occursin("`project`", report_text)
            @test occursin("prior_count", report_text)

            failing = FixtureExtension(
                "failing", String[], all_phases, "complete", true)
            failed_report = OdinJuliaAnalysis.check_repository(
                root;
                configuration=with_extensions(configuration, [failing]))
            @test failed_report.exit_code == 2
            failed_engine = only(filter(
                engine -> engine.name == "extension:failing",
                failed_report.engines))
            @test failed_engine.status == "failed"
            @test occursin("fixture extension failed", failed_engine.message)
        end

        mktempdir() do root
            extension_path = joinpath(root, "dynamic_extension.jl")
            write(extension_path, """
                using OdinJuliaAnalysis
                import OdinJuliaAnalysis: analyze_extension, extension_id
                import OdinJuliaAnalysis: extension_rules

                struct DynamicExtension <: AnalysisExtension end

                extension_id(_extension::DynamicExtension) = "dynamic"
                extension_rules(_extension::DynamicExtension) = RuleDefinition[
                    RuleDefinition(
                        "DYNAMIC-FIXTURE", "common", "Tests", "fixture",
                        "high", "default", false),
                ]
                analyze_extension(extension::DynamicExtension, context, prior) =
                    ExtensionResult(extension_id(extension), context.phase)

                DynamicExtension()
                """)
            extension_module = Module(gensym(:DynamicExtensionFixture))
            dynamic = Base.include(extension_module, extension_path)
            ordered = OdinJuliaAnalysis.validate_extensions(
                AnalysisExtension[dynamic])
            @test OdinJuliaAnalysis.invoke_extension_id(only(ordered)) == "dynamic"
            registry, owners = OdinJuliaAnalysis.merged_rule_registry(ordered)
            @test registry["DYNAMIC-FIXTURE"].language == "common"
            @test owners["DYNAMIC-FIXTURE"] == "dynamic"
        end
    end

    @testset "reviewed naming policies" begin
        configuration = OdinJuliaAnalysis.load_settings()
        mktempdir() do root
            path = joinpath(root, "src", "fixture.jl")
            mkpath(dirname(path))
            write(path, "")
            policy = ReviewedNamingPolicy(
                "accepted-constructor",
                "src/fixture.jl",
                :julia,
                :function,
                "Fixture",
                "Outer constructors use the constructed type name.";
                minimum_matches=2,
                maximum_matches=2)
            naming = NamingSettings(configuration.naming.conventions, [policy])
            configured = OdinJuliaAnalysis.EffectiveSettings(
                configuration.profile,
                configuration.failure_threshold,
                configuration.thresholds,
                configuration.enforcement_excludes,
                configuration.rules,
                naming,
                configuration.jet,
                configuration.odin_build,
                configuration.allocations,
                configuration.report)
            finding = OdinJuliaAnalysis.Diagnostic(
                "JULIA-NAMING",
                Warn,
                "src/fixture.jl",
                1,
                1,
                "Fixture must use snake_case.",
                nothing,
                nothing,
                "julia-syntax",
                "Fixture",
                "function",
                nothing,
                "stable")
            diagnostics = [finding, finding]
            OdinJuliaAnalysis.apply_reviewed_naming_policies!(
                diagnostics, root, [path], configured)

            @test all(item -> item.response == Report, diagnostics)
            @test all(
                item -> item.reviewed_policy_id == "accepted-constructor",
                diagnostics)
            @test all(
                item -> item.reviewed_policy_reason == policy.reason,
                diagnostics)

            drift = [finding]
            OdinJuliaAnalysis.apply_reviewed_naming_policies!(
                drift, root, [path], configured)
            @test only(filter(
                item -> item.rule_id == "NAMING-POLICY-DRIFT",
                drift)).response == Fail
        end
    end

    @testset "discovery exclusions" begin
        mktempdir() do root
            mkpath(joinpath(root, "vendor"))
            write(joinpath(root, "main.odin"), "package main\n")
            write(joinpath(root, "vendor", "binding.odin"), "package vendor\n")
            files = OdinJuliaAnalysis.discover_sources(root, ["vendor"])
            @test files == [joinpath(root, "main.odin")]
        end

        source_root = joinpath(mktempdir(), "src")
        excludes = OdinJuliaAnalysis.exclusions_for_root(source_root, ["src/julialib"])
        @test excludes == ["julialib"]
    end

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
                OdinJuliaAnalysis.FunctionAnalysis[],
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
                OdinJuliaAnalysis.FunctionAnalysis[],
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
                "fixture.jl", "julia", "report", 1, 3, 3, 0, 2, 0, true),
            OdinJuliaAnalysis.FunctionAnalysis(
                "fixture.jl", "julia", "warn", 4, 8, 5, 0, 4, 0, true),
            OdinJuliaAnalysis.FunctionAnalysis(
                "fixture.jl", "julia", "fail", 9, 15, 7, 0, 6, 0, true),
            OdinJuliaAnalysis.FunctionAnalysis(
                "fixture.odin", "odin", "warn", 1, 6, 6, 0, 5, nothing, true),
            OdinJuliaAnalysis.FunctionAnalysis(
                "boundary.odin", "odin", "boundary", 1, 3, 3, 0, 2,
                nothing, true),
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
                "fixture.jl", "julia", "reviewed", 1, 8, 5, 0, 4, 0, true),
            OdinJuliaAnalysis.FunctionAnalysis(
                "fixture.odin", "odin", "reviewed", 1, 8, 5, 0, 1,
                nothing, true),
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
                "one.jl", "julia", 10, 8, 6, 2, 2, 1, 2, true),
            OdinJuliaAnalysis.FileAnalysis(
                "two.odin", "odin", 20, 17, 15, 2, 3, 1, 3, true),
            OdinJuliaAnalysis.FileAnalysis(
                "notes.md", "markdown", 100, 90, 90, 0, 10, 0, 0, true),
        ]
        functions = [
            OdinJuliaAnalysis.FunctionAnalysis(
                "one.jl", "julia", "one", 1, 4, 3, 1, 4, 2, true),
            OdinJuliaAnalysis.FunctionAnalysis(
                "two.odin", "odin", "two", 1, 8, 6, 1, 3, nothing, true),
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

    @testset "Odin naming" begin
        mktempdir() do root
            path = joinpath(root, "fixture.odin")
            write(path, """
                package fixture
                import Bad_Import "core:fmt"
                bad_type :: struct {
                    Bad_Field: int,
                }
                bad_enum :: enum {
                    bad_value,
                }
                bad_constant :: 1
                Bad_Procedure :: proc(Bad_Parameter: int) {
                    _ = Bad_Parameter
                    Bad_Local := Bad_Parameter
                }
                """)
            configuration = OdinJuliaAnalysis.load_settings()
            diagnostics = filter(
                item -> item.rule_id == "ODIN-NAMING",
                OdinJuliaAnalysis.OdinEngine.analyze(
                    root, [path], configuration).diagnostics)

            @test [item.subject for item in diagnostics] == [
                "Bad_Import",
                "bad_type",
                "Bad_Field",
                "bad_enum",
                "bad_value",
                "bad_constant",
                "Bad_Procedure",
                "Bad_Parameter",
                "Bad_Local",
            ]
            @test [item.operation for item in diagnostics] == [
                "import", "type", "field", "type", "enum_value", "constant",
                "procedure", "parameter", "variable"]
            @test all(item -> item.response == Warn, diagnostics)
            @test "_" ∉ [item.subject for item in diagnostics]

            disabled = with_rules(configuration, Dict(
                "ODIN-NAMING" => RuleSetting("ODIN-NAMING", false, Fail)))
            @test isempty(filter(
                item -> item.rule_id == "ODIN-NAMING",
                OdinJuliaAnalysis.OdinEngine.analyze(
                    root, [path], disabled).diagnostics))
        end
    end

    @testset "Odin non-const globals" begin
        mktempdir() do root
            path = joinpath(root, "fixture.odin")
            write(path, """
                package fixture

                PACKAGE_GLOBAL := 1
                PACKAGE_CONSTANT :: 2

                // Exercise a procedure-local value.
                sample :: proc() {
                    local_value := 3
                }
                """)
            configuration = OdinJuliaAnalysis.load_settings()
            diagnostics = filter(
                item -> item.rule_id == "ODIN-NONCONST-GLOBAL",
                OdinJuliaAnalysis.OdinEngine.analyze(
                    root, [path], configuration).diagnostics)

            @test [item.subject for item in diagnostics] == ["PACKAGE_GLOBAL"]
            @test only(diagnostics).response == Warn
            @test only(diagnostics).operation == "global"

            for response in (Ignore, Report, Warn, Fail)
                configured = with_rules(configuration, Dict(
                    "ODIN-NONCONST-GLOBAL" => RuleSetting(
                        "ODIN-NONCONST-GLOBAL", true, response)))
                response_diagnostics = filter(
                    item -> item.rule_id == "ODIN-NONCONST-GLOBAL",
                    OdinJuliaAnalysis.OdinEngine.analyze(
                        root, [path], configured).diagnostics)
                @test all(item -> item.response == response, response_diagnostics)
            end

            disabled = with_rules(configuration, Dict(
                "ODIN-NONCONST-GLOBAL" => RuleSetting(
                    "ODIN-NONCONST-GLOBAL", false, Fail)))
            @test isempty(filter(
                item -> item.rule_id == "ODIN-NONCONST-GLOBAL",
                OdinJuliaAnalysis.OdinEngine.analyze(
                    root, [path], disabled).diagnostics))
        end
    end

    @testset "Odin return tuples" begin
        mktempdir() do root
            path = joinpath(root, "fixture.odin")
            write(path, """
                package fixture

                // Return three values.
                triple :: proc() -> (first, second: int, flag: bool) {
                    return 1, 2, true
                }

                // Return two values.
                pair :: proc() -> (int, bool) {
                    return 1, true
                }
                """)
            configuration = OdinJuliaAnalysis.load_settings()
            diagnostics = filter(
                item -> item.rule_id == "ODIN-RETURN-TUPLE",
                OdinJuliaAnalysis.OdinEngine.analyze(
                    root, [path], configuration).diagnostics)
            @test [item.subject for item in diagnostics] == ["triple"]
            @test only(diagnostics).measured == 3
            @test only(diagnostics).allowed == 2
            @test only(diagnostics).response == Fail

            odin_relaxed = with_return_tuples(
                configuration, ReturnTupleSettings(1, 3))
            @test isempty(filter(
                item -> item.rule_id == "ODIN-RETURN-TUPLE",
                OdinJuliaAnalysis.OdinEngine.analyze(
                    root, [path], odin_relaxed).diagnostics))

            for response in (Report, Warn, Fail)
                configured = with_rules(configuration, Dict(
                    "ODIN-RETURN-TUPLE" => RuleSetting(
                        "ODIN-RETURN-TUPLE", true, response)))
                response_diagnostics = filter(
                    item -> item.rule_id == "ODIN-RETURN-TUPLE",
                    OdinJuliaAnalysis.OdinEngine.analyze(
                        root, [path], configured).diagnostics)
                @test all(item -> item.response == response, response_diagnostics)
            end

            disabled = with_rules(configuration, Dict(
                "ODIN-RETURN-TUPLE" => RuleSetting(
                    "ODIN-RETURN-TUPLE", false, Fail)))
            @test isempty(filter(
                item -> item.rule_id == "ODIN-RETURN-TUPLE",
                OdinJuliaAnalysis.OdinEngine.analyze(
                    root, [path], disabled).diagnostics))
        end
    end

    @testset "Odin parameter counts" begin
        mktempdir() do root
            path = joinpath(root, "fixture.odin")
            write(path, """
                package fixture

                // Stay at the warning boundary.
                accepted :: proc(a, b, c, d, e: int) {}

                // Cross the warning boundary.
                warning :: proc(a, b, c, d, e, f: int) {}

                // Stay below the failure boundary.
                warning_eight :: proc(a, b, c, d, e, f, g, h: int) {}

                // Cross the failure boundary.
                failure :: proc(a, b, c, d, e, f, g, h, i: int) {}
                """)
            configuration = OdinJuliaAnalysis.load_settings()
            diagnostics = filter(
                item -> startswith(item.rule_id, "ODIN-PARAMETERS-"),
                OdinJuliaAnalysis.OdinEngine.analyze(
                    root, [path], configuration).diagnostics)
            @test [item.rule_id for item in diagnostics] == [
                "ODIN-PARAMETERS-WARN",
                "ODIN-PARAMETERS-WARN",
                "ODIN-PARAMETERS-FAIL",
            ]
            @test [item.subject for item in diagnostics] == [
                "warning", "warning_eight", "failure"]
            @test [item.measured for item in diagnostics] == [6, 8, 9]
            @test [item.allowed for item in diagnostics] == [5, 5, 8]
            @test [item.response for item in diagnostics] == [Warn, Warn, Fail]

            relaxed = with_parameter_counts(
                configuration, ParameterCountSettings(1, 9, 10))
            @test isempty(filter(
                item -> startswith(item.rule_id, "ODIN-PARAMETERS-"),
                OdinJuliaAnalysis.OdinEngine.analyze(
                    root, [path], relaxed).diagnostics))

            configured = with_rules(configuration, Dict(
                "ODIN-PARAMETERS-WARN" => RuleSetting(
                    "ODIN-PARAMETERS-WARN", true, Report),
                "ODIN-PARAMETERS-FAIL" => RuleSetting(
                    "ODIN-PARAMETERS-FAIL", true, Warn)))
            configured_diagnostics = filter(
                item -> startswith(item.rule_id, "ODIN-PARAMETERS-"),
                OdinJuliaAnalysis.OdinEngine.analyze(
                    root, [path], configured).diagnostics)
            @test [item.response for item in configured_diagnostics] == [
                Report, Report, Warn]

            disabled = with_rules(configuration, Dict(
                "ODIN-PARAMETERS-WARN" => RuleSetting(
                    "ODIN-PARAMETERS-WARN", false, Warn),
                "ODIN-PARAMETERS-FAIL" => RuleSetting(
                    "ODIN-PARAMETERS-FAIL", false, Fail)))
            @test isempty(filter(
                item -> startswith(item.rule_id, "ODIN-PARAMETERS-"),
                OdinJuliaAnalysis.OdinEngine.analyze(
                    root, [path], disabled).diagnostics))
        end
    end

    @testset verbose=TEST_VERBOSE "Julia closing parenthesis placement" begin
        configuration = OdinJuliaAnalysis.load_settings()
        @testset "accepts close beside final argument" begin
            source = "f(\n    first,\n    second)\n"
            @test isempty(OdinJuliaAnalysis.JuliaEngine.check(
                "valid.jl",
                source,
                configuration))
        end

        @testset "rejects isolated close" begin
            source = "f(\n    first,\n    second\n)\n"
            diagnostics = OdinJuliaAnalysis.JuliaEngine.check(
                "invalid.jl",
                source,
                configuration)
            @test only(diagnostics).rule_id == "JULIA-CLOSING-PAREN-PLACEMENT"
            @test only(diagnostics).line == 4
            @test only(diagnostics).response == Fail
        end

        @testset "ignores strings comments and empty calls" begin
            source = "let\n    text = \"value )\"\nend\n# )\nf()\n"
            @test isempty(OdinJuliaAnalysis.JuliaEngine.check(
                "trivia.jl",
                source,
                configuration))
        end
    end

    @testset "Markdown structure" begin
        configuration = OdinJuliaAnalysis.load_settings()
        source = """
            # Title

            ### Skipped Level

            ```text
            # Not A Heading
            ```

            ```
            missing language
            ```
            """
        diagnostics = OdinJuliaAnalysis.MarkdownEngine.check(
            "fixture.md",
            source,
            configuration)
        @test Set(item.rule_id for item in diagnostics) == Set([
            "MARKDOWN-HEADING-LEVELS",
            "MARKDOWN-CODE-FENCE-LANGUAGE",
        ])

        missing_h1 = OdinJuliaAnalysis.MarkdownEngine.check(
            "missing.md",
            "## Section\n",
            configuration)
        @test any(item -> item.rule_id == "MARKDOWN-SINGLE-H1", missing_h1)
    end

    @testset "repository check" begin
        mktempdir() do root
            write(
                joinpath(root, "valid.jl"),
                "\"\"\"Return the selected value.\"\"\"\n" *
                "function choose(a, b)\n" *
                "    return a > 0 ? a : b\n" *
                "end\n")
            write(
                joinpath(root, "valid.odin"),
                "package fixture\n\n" *
                "// Return the selected value.\n" *
                "choose :: proc(a, b: int) -> int {\n" *
                "    if a > 0 {\n" *
                "        return a\n" *
                "    }\n" *
                "    return b\n" *
                "}\n")
            progress = String[]
            configuration = with_odin_build_targets(
                with_jet_entries(
                    OdinJuliaAnalysis.load_settings(), JetEntryPoint[]),
                OdinBuildTarget[])
            report = OdinJuliaAnalysis.check_repository(
                root;
                configuration,
                progress=message -> push!(progress, message))
            @test report.files_analyzed == 2
            @test isempty(report.diagnostics)
            @test length(report.files) == 2
            @test length(report.functions) == 2
            julia_function = only(filter(
                item -> item.language == "julia", report.functions))
            odin_function = only(filter(
                item -> item.language == "odin", report.functions))
            @test julia_function.name == "choose"
            @test julia_function.parameter_count == 2
            @test julia_function.cyclomatic_complexity == 2
            @test julia_function.cognitive_complexity == 2
            @test julia_function.documented
            @test odin_function.name == "choose"
            @test progress == [
                "Discovering source files",
                "Checking 2 source files",
                "Running JET on 0 configured entry points",
                "Running Odin analysis on 1 files",
                "Running 0 analytical Odin builds",
                "Assembling the canonical report",
            ]
            @test odin_function.parameter_count == 2
            @test odin_function.cyclomatic_complexity == 2
            @test odin_function.cognitive_complexity === nothing
            @test odin_function.documented
            @test any(
                engine -> engine.name == "jet" && engine.status == "complete",
                report.engines)
            jet_rule = only(filter(
                rule -> rule.rule_id == "JULIA-JET-POSSIBLE-ERROR",
                report.rules))
            @test jet_rule.status == "not-applicable"

            output = IOBuffer()
            OdinJuliaAnalysis.write_report(output, report, "json")
            @test occursin("\"schema_version\": \"3.8.0\"", String(take!(output)))

            settings_path = write_jet_settings(
                tempname(),
                "JetEntryPoint[]")
            report_path = joinpath(root, "report.md")
            @test OdinJuliaAnalysis.main([
                "check", root, "--format=text", "--report=$report_path",
                "--settings=$settings_path"]) == 0
            report_text = read(report_path, String)
            @test occursin("## File Inventory", report_text)
            @test occursin("## Repository Statistics", report_text)
            @test occursin("| Odin |", report_text)
            @test occursin("| Julia |", report_text)
            @test occursin("| Total |", report_text)
            @test occursin("### COCOMO Development Estimate", report_text)
            @test occursin("### LOCOMO Regeneration Estimate", report_text)
            @test occursin("## Function And Procedure Inventory", report_text)
            @test occursin("## Analytical Odin Builds", report_text)
            @test occursin("No analytical Odin builds were configured.", report_text)
            @test occursin("## Allocation Ledger", report_text)
            @test occursin("## Rule Coverage", report_text)
            @test occursin("## Extension Results", report_text)
            @test occursin("No extensions were configured.", report_text)
            @test occursin("Functions within thresholds", report_text)
            @test occursin("`choose`", report_text)
            @test OdinJuliaAnalysis.main([
                "check", root, "--format=text", "--settings=$settings_path"]) == 0
            @test OdinJuliaAnalysis.main(["check", "--help"]) == 0
        end
    end

    @testset "analytical Odin build" begin
        base = with_jet_entries(
            OdinJuliaAnalysis.load_settings(), JetEntryPoint[])
        strict_flags = [
            "-vet",
            "-strict-style",
            "-disallow-do",
            "-warnings-as-errors",
        ]

        mktempdir() do root
            package = joinpath(root, "fixture")
            mkpath(package)
            write(
                joinpath(package, "main.odin"),
                "package fixture\n\n// Run the fixture.\nmain :: proc() {}\n")
            target = OdinBuildTarget(
                "fixture", "fixture", "fixture-analysis", strict_flags)
            configuration = with_odin_build_targets(base, [target])
            report = OdinJuliaAnalysis.check_repository(root; configuration)

            @test report.exit_code == 0
            build = only(report.odin_builds)
            @test build.status == "passed"
            @test build.exit_code == 0
            @test build.input == "fixture"
            @test build.output == joinpath(
                ".build", "analysis", "odin", "fixture-analysis")
            @test isfile(joinpath(root, build.output))
            @test build.flags == strict_flags
            @test build.command[1:3] == ["odin", "build", "fixture"]
        end

        mktempdir() do root
            target = OdinBuildTarget(
                "missing", "missing", "missing-analysis", strict_flags)
            configuration = with_odin_build_targets(base, [target])
            report = OdinJuliaAnalysis.check_repository(root; configuration)

            @test report.exit_code == 1
            build = only(report.odin_builds)
            @test build.status == "failed"
            @test build.exit_code != 0
            @test !isempty(build.stdout) || !isempty(build.stderr)
            failure = only(filter(
                item -> item.rule_id == "ODIN-BUILD-FAILED",
                report.diagnostics))
            @test failure.response == Fail
            rule = only(filter(
                item -> item.rule_id == "ODIN-BUILD-FAILED",
                report.rules))
            @test rule.status == "evaluated"
            @test rule.files_checked == 1
            @test rule.findings == 1

            output = IOBuffer()
            OdinJuliaAnalysis.write_markdown_report(output, report)
            report_text = String(take!(output))
            @test occursin("## Analytical Odin Builds", report_text)
            @test occursin("### `missing`", report_text)
            @test occursin("| Status | FAILED |", report_text)
            @test occursin("#### Standard Error", report_text)

            rules = Dict(
                "ODIN-BUILD-FAILED" => RuleSetting(
                    "ODIN-BUILD-FAILED", true, Warn))
            warning_configuration = with_rules(configuration, rules)
            warning_report = OdinJuliaAnalysis.check_repository(
                root; configuration=warning_configuration)
            @test warning_report.exit_code == 0
            @test only(filter(
                item -> item.rule_id == "ODIN-BUILD-FAILED",
                warning_report.diagnostics)).response == Warn
        end
    end

    @testset "report status and color" begin
        mktempdir() do root
            write(joinpath(root, "long.jl"), repeat("x", 91))
            configuration = OdinJuliaAnalysis.load_settings()
            blocking = with_rules(configuration, Dict(
                "JULIA-JET-POSSIBLE-ERROR" => RuleSetting(
                    "JULIA-JET-POSSIBLE-ERROR", false, Report));
                failure_threshold=Warn)
            blocking = with_odin_build_targets(blocking, OdinBuildTarget[])
            report = OdinJuliaAnalysis.check_repository(root; configuration=blocking)
            @test report.exit_code == 1

            plain = IOBuffer()
            OdinJuliaAnalysis.write_report(plain, report, "text"; color=:never)
            plain_text = String(take!(plain))
            @test occursin("Target:", plain_text)
            @test occursin("$(joinpath(root, "long.jl")):1:91:", plain_text)
            @test occursin("ENGINES", plain_text)
            @test occursin("RULES", plain_text)
            @test occursin("EVALUATED  COMMON-LINE-90 [WARN]", plain_text)
            @test occursin("EVALUATED  JULIA-DOC-MISSING [FAIL]", plain_text)
            @test occursin("WARN (1)", plain_text)
            @test endswith(plain_text, "POLICY FAILURE (exit 1)\n")
            @test !occursin('\e', plain_text)

            colored = IOBuffer()
            OdinJuliaAnalysis.write_report(colored, report, "text"; color=:always)
            colored_text = String(take!(colored))
            @test occursin('\e', colored_text)
            @test occursin(
                "\e[1;33m[\e[0m\e[1;33mCOMMON-LINE-90\e[0m" *
                    "\e[1;33m]\e[0m \e[1;33mLine exceeds",
                colored_text)
            @test occursin(
                "Report            |        0      0      0\n" *
                "\e[1;33mWarn             \e[0m |        1      1      1\n" *
                "Fail              |        0      0      0",
                colored_text)

            json = IOBuffer()
            OdinJuliaAnalysis.write_report(json, report, "json"; color=:always)
            json_text = String(take!(json))
            @test occursin("\"response\": \"warn\"", json_text)
            @test !occursin('\e', json_text)

            reviewed = OdinJuliaAnalysis.Diagnostic(
                "ODIN-ALLOCATION-IMPLICIT",
                Report,
                "reviewed.odin",
                1,
                1,
                "new may allocate memory.",
                nothing,
                nothing,
                "odin-ast",
                "new",
                "new",
                nothing,
                "definite",
                "reviewed",
                "int",
                "reviewed-new",
                "Fixture decision.")
            @test OdinJuliaAnalysis.reviewed_policy_label(reviewed, false) ==
                " [REVIEWED: reviewed-new]"
            reviewed_summary = IOBuffer()
            OdinJuliaAnalysis.write_analysis_summary(
                reviewed_summary,
                [reviewed],
                false)
            @test occursin(
                "Reviewed allocations: 1 findings, 1 policies",
                String(take!(reviewed_summary)))
        end
    end

    @testset "report always shows allocations" begin
        mktempdir() do root
            line_path = joinpath(root, "a_long.jl")
            allocation_path = joinpath(root, "z_allocation.odin")
            write(
                line_path,
                repeat("x", 121) * "\n" *
                repeat("y", 101) * "\n" *
                repeat("z", 101))
            write(
                allocation_path,
                "package fixture\n\n" *
                "value := new(int, context.allocator)\n" *
                "temporary := new(int, context.temp_allocator)\n")
            configuration = with_rules(OdinJuliaAnalysis.load_settings(), Dict(
                "JULIA-JET-POSSIBLE-ERROR" => RuleSetting(
                    "JULIA-JET-POSSIBLE-ERROR", false, Report),
                "ODIN-NONCONST-GLOBAL" => RuleSetting(
                    "ODIN-NONCONST-GLOBAL", false, Warn)))
            configuration = with_odin_build_targets(
                configuration, OdinBuildTarget[])
            report = OdinJuliaAnalysis.check_repository(
                root; configuration=configuration)

            output = IOBuffer()
            OdinJuliaAnalysis.write_report(
                output,
                report,
                "text";
                color=:never,
                warning_limit=1)
            report_text = String(take!(output))
            @test occursin("[COMMON-LINE-100]", report_text)
            @test occursin("[COMMON-LINE-120]", report_text)
            @test occursin("[ODIN-ALLOCATION-CONTEXT]", report_text)
            @test occursin("$allocation_path:3:10:", report_text)
            report_position = findfirst("\nREPORT (1)\n", report_text)
            warning_position = findfirst("\nWARN (3)\n", report_text)
            failure_position = findfirst("\nFAIL (1)\n", report_text)
            summary_position = findfirst("\nAnalysis Summary:", report_text)
            status_position = findfirst("\nPOLICY FAILURE (exit 1)\n", report_text)
            @test first(report_position) < first(warning_position) <
                first(failure_position)
            @test first(failure_position) < first(summary_position) <
                first(status_position)
            @test occursin(
                "Analysis Summary: | Findings  Files  Rules\n" *
                "Report            |        1      1      1\n" *
                "Warn              |        3      2      2\n" *
                "Fail              |        1      1      1",
                report_text)

            colored = IOBuffer()
            OdinJuliaAnalysis.write_report(
                colored,
                report,
                "text";
                color=:always,
                warning_limit=1)
            colored_text = String(take!(colored))
            @test occursin(
                "\e[1;33m[\e[0m\e[1;31mCOMMON-LINE-100\e[0m" *
                    "\e[1;33m]\e[0m \e[1;31mLine exceeds",
                colored_text)
            @test occursin(
                "\e[1;33m[\e[0m\e[1;31mODIN-ALLOCATION-CONTEXT\e[0m" *
                    "\e[1;33m]\e[0m \e[1;31mnew may allocate",
                colored_text)
            @test occursin(
                "\e[32m[\e[0m\e[33mODIN-ALLOCATION-TEMPORARY\e[0m" *
                    "\e[32m]\e[0m \e[33mnew may allocate memory.\e[0m",
                colored_text)
            @test occursin(
                "\e[36mReport           \e[0m |        1      1      1\n" *
                "\e[1;33mWarn             \e[0m |        3      2      2\n" *
                "\e[1;31mFail             \e[0m |        1      1      1",
                colored_text)
            @test occursin("\nREPORT (1)\n", colored_text)
            @test occursin(
                "1 more non-allocation WARN findings omitted",
                colored_text)
        end
    end


    @testset "Odin syntax" begin
        mktempdir() do root
            path = joinpath(root, "broken.odin")
            write(path, "package fixture\n\nbroken :: proc( {\n")
            diagnostics = OdinJuliaAnalysis.OdinEngine.check_syntax(root, [path])
            @test only(diagnostics).rule_id == "ODIN-SYNTAX"
            @test only(diagnostics).source == "odin-ast"
        end
    end

    @testset "Odin procedure documentation" begin
        mktempdir() do root
            path = joinpath(root, "documentation.odin")
            write(path, """
                package fixture

                // Return without performing work.
                documented :: proc() {}

                undocumented :: proc() {}

                // Exercise local procedure declarations.
                container :: proc() {
                    // Return from the local helper.
                    local_documented := proc() {}
                    local_undocumented := proc() {}
                }
                """)
            diagnostics = OdinJuliaAnalysis.OdinEngine.check_syntax(root, [path])
            missing_docs = filter(
                item -> item.rule_id == "ODIN-DOC-MISSING",
                diagnostics)
            @test [item.line for item in missing_docs] == [6, 12]
            @test [item.subject for item in missing_docs] == [
                "undocumented",
                "local_undocumented",
            ]
            @test all(item -> item.response == Fail, missing_docs)
        end
    end

    @testset verbose=TEST_VERBOSE "Odin allocation analysis" begin
        mktempdir() do root
            path = joinpath(root, "allocations.odin")
            write(path, """
                package fixture

                import "core:mem/heap"
                import vmem "core:mem/virtual"

                allocations :: proc(custom_allocator: runtime.Allocator) {
                    arena: vmem.Arena
                    _ = vmem.arena_init_static(&arena)
                    _ = new(int)
                    _ = new(int, context.allocator)
                    _ = new(int, context.temp_allocator)
                    _ = new(int, heap.allocator())
                    _ = new(int, custom_allocator)
                    _ = new(int, select_allocator())
                    _ = new(int, allocator = context.temp_allocator)
                    values := make([dynamic]int)
                    values = make([dynamic]int, 0, context.allocator)
                    append(&values, 1)
                }
                """)
            diagnostics = OdinJuliaAnalysis.OdinEngine.check_syntax(root, [path])
            allocations = filter(
                item -> startswith(item.rule_id, "ODIN-ALLOCATION-"),
                diagnostics)
            @test [item.rule_id for item in allocations] == [
                "ODIN-ALLOCATION-ARENA",
                "ODIN-ALLOCATION-IMPLICIT",
                "ODIN-ALLOCATION-CONTEXT",
                "ODIN-ALLOCATION-TEMPORARY",
                "ODIN-ALLOCATION-HEAP",
                "ODIN-ALLOCATION-CUSTOM",
                "ODIN-ALLOCATION-UNKNOWN",
                "ODIN-ALLOCATION-TEMPORARY",
                "ODIN-ALLOCATION-IMPLICIT",
                "ODIN-ALLOCATION-CONTEXT",
                "ODIN-ALLOCATION-DYNAMIC-GROWTH",
            ]
            @test [item.response for item in allocations] == [
                Warn,
                Warn,
                Warn,
                Report,
                Warn,
                Report,
                Fail,
                Report,
                Warn,
                Warn,
                Report,
            ]
            @test allocations[6].allocator_source == "custom_allocator"
            @test allocations[7].allocator_source == "select_allocator()"
            @test allocations[11].certainty == "potential"
            @test all(item -> item.procedure == "allocations", allocations)
            @test allocations[1].allocation_target == "arena"
            @test allocations[2].allocation_target == "int"
            @test allocations[11].allocation_target == "values"
            @test all(item -> item.source == "odin-ast", allocations)
        end
    end

    @testset verbose=TEST_VERBOSE "reviewed allocation policies" begin
        configuration = OdinJuliaAnalysis.load_settings()
        mktempdir() do root
            path = joinpath(root, "reviewed.odin")
            write(path, """
                package fixture

                // Allocate reviewed values.
                reviewed :: proc() {
                    _ = new(int)
                    _ = new(int)
                }
                """)
            policy_path = relpath(path, root)
            policy = ReviewedAllocationPolicy(
                "reviewed-new",
                policy_path,
                "reviewed",
                :implicit,
                "Fixture allocation is reviewed.";
                operation="new",
                target="int",
                response=Report,
                minimum_matches=2,
                maximum_matches=2)
            reviewed_configuration = with_allocation_policies(
                configuration,
                [policy])
            diagnostics = OdinJuliaAnalysis.OdinEngine.check_syntax(
                root,
                [path],
                reviewed_configuration)
            allocations = filter(
                item -> item.rule_id == "ODIN-ALLOCATION-IMPLICIT",
                diagnostics)
            @test length(allocations) == 2
            @test all(item -> item.response == Report, allocations)
            @test all(item -> item.reviewed_policy_id == "reviewed-new", allocations)
            @test all(
                item -> item.reviewed_policy_reason == policy.reason,
                allocations)
            @test !any(
                item -> item.rule_id == "ODIN-ALLOCATION-POLICY-DRIFT",
                diagnostics)

            missing = ReviewedAllocationPolicy(
                "missing-new",
                policy_path,
                "reviewed",
                :implicit,
                "Selector intentionally misses.";
                operation="new",
                target="string")
            missing_diagnostics = OdinJuliaAnalysis.OdinEngine.check_syntax(
                root,
                [path],
                with_allocation_policies(configuration, [missing]))
            missing_drift = filter(
                item -> item.rule_id == "ODIN-ALLOCATION-POLICY-DRIFT",
                missing_diagnostics)
            @test length(missing_drift) == 1
            @test only(missing_drift).response == Fail
            @test occursin("found 0", only(missing_drift).message)

            excess = ReviewedAllocationPolicy(
                "excess-new",
                policy_path,
                "reviewed",
                :implicit,
                "Only one allocation was expected.";
                operation="new",
                target="int")
            excess_diagnostics = OdinJuliaAnalysis.OdinEngine.check_syntax(
                root,
                [path],
                with_allocation_policies(configuration, [excess]))
            excess_drift = filter(
                item -> item.rule_id == "ODIN-ALLOCATION-POLICY-DRIFT",
                excess_diagnostics)
            @test length(excess_drift) == 1
            @test occursin("found 2", only(excess_drift).message)

            ambiguous = ReviewedAllocationPolicy(
                "ambiguous-new",
                policy_path,
                "reviewed",
                :implicit,
                "Overlapping selector.";
                operation="new",
                target="int",
                minimum_matches=2,
                maximum_matches=2)
            ambiguous_diagnostics = OdinJuliaAnalysis.OdinEngine.check_syntax(
                root,
                [path],
                with_allocation_policies(configuration, [policy, ambiguous]))
            ambiguous_drift = filter(
                item -> item.rule_id == "ODIN-ALLOCATION-POLICY-DRIFT",
                ambiguous_diagnostics)
            @test length(ambiguous_drift) == 2
            @test all(
                item -> occursin("multiple reviewed policies", item.message),
                ambiguous_drift)
        end

    end

    @testset verbose=TEST_VERBOSE "Odin closing parenthesis placement" begin
        mktempdir() do root
            @testset "accepts close beside final parameter" begin
                path = joinpath(root, "valid.odin")
                write(
                    path,
                    "package fixture\n\n" *
                    "// Return the input value.\n" *
                    "value :: proc(\n    input: int) {}\n")
                @test isempty(OdinJuliaAnalysis.OdinEngine.check_syntax(root, [path]))
            end

            @testset "rejects isolated close" begin
                path = joinpath(root, "invalid.odin")
                write(
                    path,
                    "package fixture\n\nvalue :: proc(\n    input: int\n) {}\n")
                diagnostics = OdinJuliaAnalysis.OdinEngine.check_syntax(root, [path])
                closing = filter(
                    item -> item.rule_id == "ODIN-CLOSING-PAREN-PLACEMENT",
                    diagnostics)
                @test only(closing).line == 5
                @test only(closing).response == Fail
            end
        end
    end

    @testset "native Odin engine" begin
        build_directory = joinpath(
            OdinJuliaAnalysis.ANALYSIS_ROOT,
            ".build")
        mkpath(build_directory)
        flags = [
            "-vet",
            "-strict-style",
            "-disallow-do",
            "-warnings-as-errors",
            "-error-pos-style:unix",
            "-define:ODIN_TEST_THREADS=1",
            "-out:" * joinpath(build_directory, "odin-engine-tests"),
        ]
        command = Cmd(
            Cmd(vcat(["odin", "test", joinpath(
                OdinJuliaAnalysis.ANALYSIS_ROOT, "odin_engine")], flags));
            dir=build_directory)
        output = IOBuffer()
        process = run(pipeline(ignorestatus(command), stdout=output, stderr=output))
        text = String(take!(output))
        @test process.exitcode == 0
        @test occursin("Finished 3 tests", text)
    end

    @testset "self analysis" begin
        report = OdinJuliaAnalysis.check_repository(
            OdinJuliaAnalysis.ANALYSIS_ROOT)
        @test report.exit_code == 0
        @test all(engine -> engine.status == "complete", report.engines)
        @test report.files_analyzed > 0
    end
end