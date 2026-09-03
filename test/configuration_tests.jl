@testset "common rules" begin
    source = "valid = true\n" * repeat("x", 91) * "\n\tbad = true\n"
    diagnostics = OdinJuliaAnalysis.check_common_rules("fixture.jl", source)
    @test [item.rule_id for item in diagnostics] == [
        "COMMON-LINE-90",
        "COMMON-NO-TABS",
    ]

    @testset "excludes CRLF carriage returns from line width" begin
        boundary_source = repeat("x", 90) * "\r\n" * repeat("x", 91) * "\r\n"
        diagnostics = OdinJuliaAnalysis.check_common_rules(
            "fixture.md", boundary_source)

        @test length(diagnostics) == 1
        @test only(diagnostics).line == 2
        @test only(diagnostics).measured == 91
    end

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

    @testset "ignores string content for line length" begin
        long_text = repeat("x", 121)
        source = join([
            "value = wrapper(\"$long_text\")",
            "text = \"\"\"",
            long_text,
            "\"\"\"",
            repeat("x", 91) * " * \"ignored\"",
        ], '\n')
        diagnostics = OdinJuliaAnalysis.check_common_rules("fixture.jl", source)

        @test [item.line for item in diagnostics] == [5]
        @test only(diagnostics).measured == 94

        odin_source = join([
            "value := wrapper(\"$long_text\")",
            "text := `first",
            long_text,
            "last`",
        ], '\n')
        @test isempty(OdinJuliaAnalysis.check_common_rules(
            "fixture.odin", odin_source))
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
        @test [item.line for item in markdown_diagnostics] == [8]
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

    @testset "caps staging path responses" begin
        for maximum in instances(FindingResponse)
            report = ReportSettings(
                :auto, 50, 50; staging_maximum_response=maximum)
            @test OdinJuliaAnalysis.staging_response(
                report, "staging_notes.md", Fail) == maximum
            @test OdinJuliaAnalysis.staging_response(
                report, "docs/staging_plans/notes.md", Fail) == maximum
            @test OdinJuliaAnalysis.staging_response(
                report, "docs/not_staging_notes.md", Fail) == Fail
        end

        rules = copy(configuration.rules)
        rules["COMMON-LINE-120"] = RuleSetting("COMMON-LINE-120", true, Fail)
        staging_configuration = OdinJuliaAnalysis.EffectiveSettings(
            configuration.profile,
            configuration.failure_threshold,
            configuration.thresholds,
            configuration.enforcement_excludes,
            rules,
            configuration.naming,
            configuration.jet,
            configuration.odin_build,
            configuration.return_tuples,
            configuration.parameter_counts,
            configuration.function_metrics,
            configuration.architecture,
            configuration.allocations,
            ReportSettings(:auto, 50, 50; staging_maximum_response=Report),
            configuration.extensions,
            configuration.rule_registry,
            configuration.extension_rule_owners,
            configuration.duplicate_code,
            configuration.resource_lifetime,
            configuration.security,
            configuration.coverage,
            configuration.documentation,
            configuration.call_roots)
        source = repeat("x", 121)

        for path in ("staging_notes.md", "docs/staging_plans/notes.md")
            diagnostics = OdinJuliaAnalysis.check_common_rules(
                path, source, staging_configuration)
            @test all(item -> item.response == Report, diagnostics)
        end
        diagnostics = OdinJuliaAnalysis.check_common_rules(
            "docs/not_staging_notes.md", source, staging_configuration)
        @test any(item -> item.response == Fail, diagnostics)

        reviewed = Diagnostic(
            "COMMON-LINE-120",
            Fail,
            "staging_notes.md",
            1,
            1,
            "reviewed staging finding",
            121,
            120,
            "fixture",
            nothing,
            nothing,
            nothing,
            nothing,
            nothing,
            nothing,
            "reviewed-staging",
            "fixture review")
        reviewed_diagnostics = [reviewed]
        OdinJuliaAnalysis.cap_staging_responses!(
            reviewed_diagnostics, staging_configuration.report)
        @test only(reviewed_diagnostics).response == Report
        @test only(reviewed_diagnostics).reviewed_policy_id == "reviewed-staging"
    end
end

@testset "reviewed diagnostic policies" begin
    policy = ReviewedDiagnosticPolicy(
        "accepted-platform-cache",
        "JULIA-NONCONST-GLOBAL",
        "src/cache.jl",
        "PLATFORM_CACHE",
        "The platform-specific cache has process lifetime.")
    report = ReportSettings(:auto, 50, 50; reviewed_diagnostics=[policy])
    reviewed = Diagnostic(
        "JULIA-NONCONST-GLOBAL", Warn, "src/cache.jl", 2, 1,
        "Mutable global.", nothing, nothing, "julia-syntax",
        "PLATFORM_CACHE", "global", nothing, "stable")

    @test OdinJuliaAnalysis.reviewed_diagnostic_matches(policy, reviewed)
    accepted = OdinJuliaAnalysis.apply_reviewed_diagnostic_policy(reviewed, policy)
    @test accepted.response == Ignore
    @test accepted.reviewed_policy_id == policy.id
    @test accepted.reviewed_policy_reason == policy.reason

    drift = Diagnostic[]
    OdinJuliaAnalysis.append_reviewed_diagnostic_drift!(drift, [policy], [0])
    @test only(drift).rule_id == "REVIEWED-DIAGNOSTIC-POLICY-DRIFT"
    @test only(drift).response == Fail

    duplicate = ReviewedDiagnosticPolicy(
        "duplicate-platform-cache",
        policy.rule_id,
        policy.path,
        policy.subject,
        "Duplicate selector fixture.")
    @test_throws ArgumentError begin
        OdinJuliaAnalysis.validate_reviewed_diagnostic_policies(
            [policy, duplicate], OdinJuliaAnalysis.RULE_REGISTRY)
    end
    OdinJuliaAnalysis.validate_report_settings(
        report, OdinJuliaAnalysis.RULE_REGISTRY)
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
    @test configuration.rules["JULIA-CONST-MUTABLE-REF"].response == Warn
    @test configuration.rules["ODIN-NONCONST-GLOBAL"].response == Warn
    @test configuration.rules["JULIA-RETURN-TUPLE"].response == Fail
    @test configuration.rules["ODIN-RETURN-TUPLE"].response == Fail
    @test configuration.return_tuples == ReturnTupleSettings(2, 2)
    @test configuration.rules["JULIA-PARAMETERS-FAIL"].response == Fail
    @test configuration.rules["ODIN-PARAMETERS-WARN"].response == Warn
    @test configuration.rules["ODIN-PARAMETERS-FAIL"].response == Fail
    @test configuration.parameter_counts == ParameterCountSettings(8, 5, 8)
    @test configuration.documentation.julia_template.pattern == raw"\S"
    @test configuration.documentation.odin_template.pattern == raw"\S"
    @test configuration.report.staging_maximum_response == Fail
    @test_throws ArgumentError OdinJuliaAnalysis.validate_documentation_settings(
        DocumentationSettings(r"", r"\S"))
    @test_throws ArgumentError OdinJuliaAnalysis.validate_documentation_settings(
        DocumentationSettings(r"\S", r"(?:)"))
    @test configuration.function_metrics.julia_lines ==
        ResponseThresholds(35, 45, 65)
    @test configuration.function_metrics.odin_lines ==
        ResponseThresholds(35, 45, 65)
    @test configuration.function_metrics.julia_cyclomatic ==
        ResponseThresholds(10, 13, 16)
    @test configuration.function_metrics.odin_cyclomatic ==
        ResponseThresholds(10, 15, 18)
    @test [policy.id for policy in configuration.function_metrics.reviewed] == [
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
        :custom,
    ]
    @test [policy.id
        for policy in configuration.allocations.reviewed_policies] == [
        "analysis-test-metrics-arena",
        "analysis-test-allocation-arena",
        "analysis-test-syntax-arena",
        "analysis-arena-backing",
        "analysis-symbol-inventory-growth",
        "analysis-abi-type-growth",
        "analysis-interop-type-storage",
        "analysis-interop-inventory-growth",
        "analysis-global-finding-growth",
        "analysis-allocation-finding-growth",
        "analysis-procedure-inventory-growth",
        "analysis-body-token-storage",
        "analysis-body-token-growth",
        "analysis-documentation-finding-growth",
        "analysis-import-symbol-growth",
        "analysis-import-edge-growth",
        "analysis-reference-growth",
        "analysis-call-edge-growth",
        "analysis-procedure-scope-storage",
        "analysis-parenthesis-finding-growth",
        "analysis-parenthesis-frame-storage",
        "analysis-parenthesis-frame-growth",
        "analysis-file-inventory-storage",
        "analysis-summary-storage",
    ]
    ignored_response = ReviewedAllocationPolicy(
        "ignored-response",
        "src/example.odin",
        "example",
        :implicit,
        "The reviewed allocation findings are intentionally ignored.";
        response=Ignore)
    ignored_allocations = AllocationSettings(
        KnownAllocatingProcedure[],
        AllocatorSourcePattern[],
        [ignored_response])
    @test OdinJuliaAnalysis.validate_allocation_settings(
        ignored_allocations) === nothing
    invalid_range = ReviewedAllocationPolicy(
        "invalid-range",
        "src/example.odin",
        "example",
        :implicit,
        "The range is invalid.";
        minimum_matches=2,
        maximum_matches=1)
    allocations = AllocationSettings(
        KnownAllocatingProcedure[],
        AllocatorSourcePattern[],
        [invalid_range])
    @test_throws ArgumentError OdinJuliaAnalysis.validate_allocation_settings(
        allocations)

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
    ignored_complexity = ReviewedComplexity(
        "ignored-response",
        "src/example.jl",
        :julia,
        "example",
        :cyclomatic_complexity,
        "The reviewed complexity findings are intentionally ignored.";
        response=Ignore)
    @test OdinJuliaAnalysis.validate_reviewed_complexity(
        [ignored_complexity]) === nothing

    function_convention = NamingConvention(
        :julia,
        :function,
        :snake_case;
        allow_leading_underscore=true,
        allow_trailing_bang=true,
        allow_constructor_names=true,
        ignored_names=["Base.show"],
        ignored_patterns=[r"^ccall_"])
    @test function_convention.allow_constructor_names
    @test OdinJuliaAnalysis.valid_identifier_name(
        "_parse_value!", function_convention)
    @test OdinJuliaAnalysis.valid_identifier_name(
        "Base.show", function_convention)
    @test OdinJuliaAnalysis.valid_identifier_name(
        "ccall_ABI", function_convention)
    @test !OdinJuliaAnalysis.valid_identifier_name(
        "ParseValue", function_convention)

    greek_convention = NamingConvention(:julia, :parameter, :snake_case)
    @test OdinJuliaAnalysis.valid_identifier_name("start_θ", greek_convention)
    @test OdinJuliaAnalysis.valid_identifier_name("ω_0", greek_convention)
    @test !OdinJuliaAnalysis.valid_identifier_name("penFloorθ", greek_convention)
    @test OdinJuliaAnalysis.valid_identifier_name(
        "MAX_Θ", NamingConvention(:julia, :constant, :screaming_snake_case))
    @test_throws ArgumentError OdinJuliaAnalysis.validate_naming_settings(
        NamingSettings([
            NamingConvention(:julia, :function, :snake_case),
            NamingConvention(:julia, :function, :lowercase),
        ]))
    @test_throws ArgumentError OdinJuliaAnalysis.validate_naming_settings(
        NamingSettings([
            NamingConvention(
                :odin,
                :procedure,
                :snake_case;
                allow_constructor_names=true),
        ]))
    ignored_naming_policy = ReviewedNamingPolicy(
        "ignored-response",
        "src/example.jl",
        :julia,
        :function,
        "Example",
        "The reviewed naming findings are intentionally ignored.";
        response=Ignore)
    @test OdinJuliaAnalysis.validate_naming_settings(
        NamingSettings(
            configuration.naming.conventions,
            [ignored_naming_policy])) === nothing
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
    default_target = OdinBuildTarget("defaulted", "src", "fixture", ["-vet"])
    @test default_target.include_julia_linker_flags === false
    linked_target = OdinBuildTarget(
        "linked", "src", "fixture", ["-vet"]; include_julia_linker_flags=true)
    @test linked_target.include_julia_linker_flags === true
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
        stats = OdinJuliaAnalysis.parse_stats_options([
            custom_path, "--format=json", "--function=sample"])
        @test stats.path == custom_path
        @test stats.format == "json"
        @test stats.function_name == "sample"
        @test stats.line === nothing
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
        @test occursin("extension:project", report_text)

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

