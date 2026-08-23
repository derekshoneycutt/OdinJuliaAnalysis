@testset "exact duplicate code" begin
    base_configuration = OdinJuliaAnalysis.load_settings()
    """Return validated settings for one duplicate-code test configuration."""
    function duplicate_code_configuration(duplicate_code)
        settings = AnalysisSettings(
            base_configuration.profile,
            base_configuration.failure_threshold,
            base_configuration.thresholds,
            [ScanProfile(base_configuration.profile, String[])],
            collect(values(base_configuration.rules)),
            base_configuration.naming,
            JetSettings(JetEntryPoint[]),
            OdinBuildSettings(OdinBuildTarget[]),
            base_configuration.return_tuples,
            base_configuration.parameter_counts,
            base_configuration.function_metrics,
            base_configuration.architecture,
            base_configuration.allocations,
            base_configuration.report,
            AnalysisExtension[],
            duplicate_code)
        return OdinJuliaAnalysis.validate_settings(settings)
    end

    enabled = DuplicateCodeSettings(
        true, 1, 1, 2, String[], ReviewedClonePolicy[])
    report = mktempdir() do root
        write(joinpath(root, "clones.jl"), """
        function first_clone(value)
            result = value + 1
            return result * 2
        end

        function second_clone(value)
            result = value + 1
            return result * 2
        end

        function different(value)
            return value - 1
        end
        """)
        write(joinpath(root, "clones.odin"), """
        package fixture

        first_clone :: proc(value: int) -> int {
            result := value + 1
            return result * 2
        }

        second_clone :: proc(value: int) -> int {
            result := value + 1
            return result * 2
        }

        different :: proc(value: int) -> int {
            return value - 1
        }
        """)
        OdinJuliaAnalysis.check_repository(
            root; configuration=duplicate_code_configuration(enabled))
    end
    clone_groups = OdinJuliaAnalysis.analysis_clone_groups(report.files)
    @test report.schema_version == "4.0.0"
    @test [group.language for group in clone_groups] == ["julia", "odin"]
    @test all(group -> length(group.occurrences) == 2, clone_groups)
    @test all(group -> group.token_count > 0, clone_groups)
    @test all(group -> group.executable_lines > 0, clone_groups)
    @test !any(occurrence -> occurrence.declaration == "different",
        Iterators.flatten(group.occurrences for group in clone_groups))
    @test count(diagnostic -> endswith(diagnostic.rule_id, "-DUPLICATE-CODE"),
        report.diagnostics) == 2
    @test any(engine -> engine.name == "duplicate-code" &&
        engine.status == "complete", report.engines)

    json_output = IOBuffer()
    OdinJuliaAnalysis.write_report(json_output, report, "json")
    @test occursin("\"clone_groups\"", String(take!(json_output)))
    markdown_output = IOBuffer()
    OdinJuliaAnalysis.write_markdown_report(markdown_output, report)
    markdown = String(take!(markdown_output))
    @test !occursin("## Exact Clone Groups", markdown)
    @test occursin("ODIN-DUPLICATE-CODE", markdown)

    julia_group = only(filter(group -> group.language == "julia", clone_groups))
    candidates = [
        CloneCandidate(
            CloneOccurrence(
                occurrence.path,
                occurrence.language,
                occurrence.declaration,
                occurrence.start_line,
                occurrence.end_line),
            "shared-body",
            10,
            3)
        for occurrence in julia_group.occurrences
    ]
    reviewed_fingerprint = OdinJuliaAnalysis.exact_clone_groups(candidates)[1].fingerprint
    reviewed = DuplicateCodeSettings(true, 1, 1, 2, String[], [
        ReviewedClonePolicy(
            "shared-julia-body",
            :julia,
            reviewed_fingerprint,
            "The fixture intentionally verifies reviewed exact clones.";
            response=Warn),
    ])
    groups, diagnostics = OdinJuliaAnalysis.analyze_duplicate_code(
        candidates, duplicate_code_configuration(reviewed))
    @test length(groups) == 1
    @test only(diagnostics).response == Warn
    @test only(diagnostics).reviewed_policy_id == "shared-julia-body"

    excluded = DuplicateCodeSettings(
        true, 1, 1, 2, ["clones.jl"], ReviewedClonePolicy[])
    groups, diagnostics = OdinJuliaAnalysis.analyze_duplicate_code(
        candidates, duplicate_code_configuration(excluded))
    @test isempty(groups)
    @test isempty(diagnostics)

    high_threshold = DuplicateCodeSettings(
        true, 11, 4, 2, String[], ReviewedClonePolicy[])
    groups, diagnostics = OdinJuliaAnalysis.analyze_duplicate_code(
        candidates, duplicate_code_configuration(high_threshold))
    @test isempty(groups)
    @test isempty(diagnostics)

    stale = DuplicateCodeSettings(true, 1, 1, 2, String[], [
        ReviewedClonePolicy(
            "stale", :julia, repeat("0", 64), "Must match one clone."),
    ])
    _, diagnostics = OdinJuliaAnalysis.analyze_duplicate_code(
        candidates, duplicate_code_configuration(stale))
    @test any(diagnostic -> diagnostic.rule_id == "DUPLICATE-CODE-POLICY-DRIFT" &&
        diagnostic.response == Fail, diagnostics)

    ambiguous = DuplicateCodeSettings(true, 1, 1, 2, String[], [
        ReviewedClonePolicy("first", :julia, reviewed_fingerprint, "First review."),
        ReviewedClonePolicy("second", :julia, reviewed_fingerprint, "Second review."),
    ])
    _, diagnostics = OdinJuliaAnalysis.analyze_duplicate_code(
        candidates, duplicate_code_configuration(ambiguous))
    @test any(diagnostic -> diagnostic.rule_id == "DUPLICATE-CODE-POLICY-DRIFT" &&
        occursin("multiple reviewed policies", diagnostic.message), diagnostics)
end

@testset "resource lifetime summaries" begin
    base_configuration = OdinJuliaAnalysis.load_settings()
    """Return validated settings for one resource lifetime configuration."""
    function lifetime_configuration(resource_lifetime)
        settings = AnalysisSettings(
            base_configuration.profile,
            base_configuration.failure_threshold,
            base_configuration.thresholds,
            [ScanProfile(base_configuration.profile, String[])],
            collect(values(base_configuration.rules)),
            base_configuration.naming,
            JetSettings(JetEntryPoint[]),
            OdinBuildSettings(OdinBuildTarget[]),
            base_configuration.return_tuples,
            base_configuration.parameter_counts,
            base_configuration.function_metrics,
            base_configuration.architecture,
            base_configuration.allocations,
            base_configuration.report,
            AnalysisExtension[],
            base_configuration.duplicate_code,
            resource_lifetime)
        return OdinJuliaAnalysis.validate_settings(settings)
    end

    contract = ResourceLifetimeContract(
        "temporary-slice",
        :temporary,
        :borrowed,
        :temporary,
        "The context temporary allocator owns storage until the temporary scope ends.";
        operation="make",
        allocator_source="context.temp_allocator",
        allows_escape=false)
    configured = ResourceLifetimeSettings(true, [contract])
    report = mktempdir() do root
        write(joinpath(root, "lifetime.odin"), """
        package fixture

        // Build temporary values for one operation.
        build_values :: proc() {
            values := make([]int, 0, context.temp_allocator)
            _ = values
        }
        """)
        OdinJuliaAnalysis.check_repository(
            root; configuration=lifetime_configuration(configured))
    end
    resource_lifetimes = OdinJuliaAnalysis.analysis_resource_lifetimes(report.files)
    @test length(resource_lifetimes) == 1
    summary = only(resource_lifetimes)
    @test summary.status == "complete"
    @test summary.contract_id == "temporary-slice"
    @test summary.ownership == "borrowed"
    @test summary.lifetime == "temporary"
    @test summary.allows_escape == false
    @test any(engine -> engine.name == "resource-lifetime" &&
        engine.status == "complete", report.engines)

    json_output = IOBuffer()
    OdinJuliaAnalysis.write_report(json_output, report, "json")
    @test occursin("\"resource_lifetimes\"", String(take!(json_output)))
    markdown_output = IOBuffer()
    OdinJuliaAnalysis.write_markdown_report(markdown_output, report)
    markdown = String(take!(markdown_output))
    @test occursin("## Resource Lifetime Summaries", markdown)
    @test occursin("ODIN-ALLOCATION-TEMPORARY", markdown)

    event = Diagnostic(
        "ODIN-ALLOCATION-TEMPORARY",
        Ignore,
        "fixture.odin",
        3,
        1,
        "make may allocate memory.",
        nothing,
        nothing,
        "odin-ast",
        "make",
        "make",
        "context.temp_allocator",
        "definite",
        "build_values",
        "[]int",
        nothing,
        nothing)
    summaries, status = OdinJuliaAnalysis.analyze_resource_lifetimes(
        [event], lifetime_configuration(ResourceLifetimeSettings(
            true, ResourceLifetimeContract[])))
    @test status == "incomplete"
    @test only(summaries).status == "unresolved"

    broad = ResourceLifetimeContract(
        "all-temporary", :temporary, :borrowed, :temporary,
        "All temporary allocations use scoped storage.")
    summaries, status = OdinJuliaAnalysis.analyze_resource_lifetimes(
        [event], lifetime_configuration(ResourceLifetimeSettings(
            true, [broad, contract])))
    @test status == "incomplete"
    @test only(summaries).status == "ambiguous"

    @test_throws ArgumentError OdinJuliaAnalysis.validate_settings(
        AnalysisSettings(
            base_configuration.profile,
            base_configuration.failure_threshold,
            base_configuration.thresholds,
            [ScanProfile(base_configuration.profile, String[])],
            collect(values(base_configuration.rules)),
            base_configuration.naming,
            base_configuration.jet,
            base_configuration.odin_build,
            base_configuration.return_tuples,
            base_configuration.parameter_counts,
            base_configuration.function_metrics,
            base_configuration.architecture,
            base_configuration.allocations,
            base_configuration.report,
            AnalysisExtension[],
            base_configuration.duplicate_code,
            ResourceLifetimeSettings(true, [
                ResourceLifetimeContract(
                    "invalid", :temporary, :unknown, :temporary,
                    "Invalid ownership fixture."),
            ])))
end

@testset "configured security boundaries" begin
    base_configuration = OdinJuliaAnalysis.load_settings()
    """Return validated settings for one configured security analysis."""
    function security_configuration(security)
        settings = AnalysisSettings(
            base_configuration.profile,
            base_configuration.failure_threshold,
            base_configuration.thresholds,
            [ScanProfile(base_configuration.profile, String[])],
            collect(values(base_configuration.rules)),
            base_configuration.naming,
            JetSettings(JetEntryPoint[]),
            OdinBuildSettings(OdinBuildTarget[]),
            base_configuration.return_tuples,
            base_configuration.parameter_counts,
            base_configuration.function_metrics,
            base_configuration.architecture,
            base_configuration.allocations,
            base_configuration.report,
            AnalysisExtension[],
            base_configuration.duplicate_code,
            base_configuration.resource_lifetime,
            security)
        return OdinJuliaAnalysis.validate_settings(settings)
    end

    security = SecuritySettings(
        true,
        [
            SecurityCallContract(
                "julia-input", :julia, "readline", :user_input,
                "Interactive input is untrusted."),
            SecurityCallContract(
                "odin-input", :odin, "read_external", :interop,
                "Interop input crosses a trust boundary."),
        ],
        [
            SecurityCallContract(
                "julia-process", :julia, "run", :command_execution,
                "The call executes a process."),
            SecurityCallContract(
                "odin-write", :odin, "write_external", :external_write,
                "The call writes across a trust boundary."),
        ],
        [
            SecurityCallContract(
                "julia-allowlist", :julia, "validate_input", :allowlist,
                "The call validates input against an allowlist."),
        ])
    report = mktempdir() do root
        write(joinpath(root, "boundary.jl"), """
        function main()
            value = readline()
            checked = validate_input(value)
            run(checked)
        end
        """)
        write(joinpath(root, "boundary.odin"), """
        package fixture

        // Forward external data to a configured boundary.
        forward :: proc() {
            value := read_external()
            write_external(value)
        }
        """)
        OdinJuliaAnalysis.check_repository(
            root; configuration=security_configuration(security))
    end
    security_paths = OdinJuliaAnalysis.analysis_security_paths(report.files)
    @test report.schema_version == "4.0.0"
    @test length(security_paths) == 2
    @test Set(path.language for path in security_paths) == Set(("julia", "odin"))
    julia_path = only(filter(path -> path.language == "julia", security_paths))
    @test julia_path.sanitizer_contract_ids == ["julia-allowlist"]
    @test julia_path.certainty == "potential"
    @test occursin("Argument flow is not yet proven", julia_path.explanation)
    @test count(diagnostic -> diagnostic.rule_id == "SECURITY-UNSAFE-BOUNDARY",
        report.diagnostics) == 2
    @test any(engine -> engine.name == "security" &&
        engine.status == "complete", report.engines)

    json_output = IOBuffer()
    OdinJuliaAnalysis.write_report(json_output, report, "json")
    @test occursin("\"security_paths\"", String(take!(json_output)))
    markdown_output = IOBuffer()
    OdinJuliaAnalysis.write_markdown_report(markdown_output, report)
    markdown = String(take!(markdown_output))
    @test occursin("## Security Boundary Paths", markdown)
    @test occursin("SECURITY-UNSAFE-BOUNDARY", markdown)

    reversed = [
        CallEdge("x.jl", "julia", "main", "run", "direct", 2, 1),
        CallEdge("x.jl", "julia", "main", "readline", "direct", 3, 1),
    ]
    analysis = OdinJuliaAnalysis.analyze_security_boundaries(
        reversed, security_configuration(security))
    @test isempty(analysis.paths)
    @test isempty(analysis.diagnostics)
    @test analysis.status == "complete"

    dynamic = [
        CallEdge("x.jl", "julia", "main", "readline", "direct", 2, 1),
        CallEdge("x.jl", "julia", "main", "callable", "dynamic", 3, 1),
        CallEdge("x.jl", "julia", "main", "run", "direct", 4, 1),
    ]
    analysis = OdinJuliaAnalysis.analyze_security_boundaries(
        dynamic, security_configuration(security))
    @test length(analysis.paths) == 1
    @test analysis.status == "incomplete"

    invalid = SecuritySettings(true, [
        SecurityCallContract(
            "bad", :python, "input", :user_input, "Unsupported language."),
    ], SecurityCallContract[], SecurityCallContract[])
    @test_throws ArgumentError security_configuration(invalid)
end

@testset "coverage evidence" begin
    base_configuration = OdinJuliaAnalysis.load_settings()
    """Return validated settings for one runtime coverage configuration."""
    function coverage_configuration(coverage)
        settings = AnalysisSettings(
            base_configuration.profile,
            base_configuration.failure_threshold,
            base_configuration.thresholds,
            [ScanProfile(base_configuration.profile, String[])],
            collect(values(base_configuration.rules)),
            base_configuration.naming,
            JetSettings(JetEntryPoint[]),
            OdinBuildSettings(OdinBuildTarget[]),
            base_configuration.return_tuples,
            base_configuration.parameter_counts,
            base_configuration.function_metrics,
            base_configuration.architecture,
            base_configuration.allocations,
            base_configuration.report,
            AnalysisExtension[],
            base_configuration.duplicate_code,
            base_configuration.resource_lifetime,
            base_configuration.security,
            coverage)
        return OdinJuliaAnalysis.validate_settings(settings)
    end

    parsed = OdinJuliaAnalysis.parse_lcov("""
    SF:src/example.jl
    DA:2,1
    DA:3,0,checksum
    end_of_record
    SF:src/example.jl
    DA:2,2
    end_of_record
    SF:/tmp/external.jl
    DA:1,4
    end_of_record
    """, pwd())
    @test parsed["src/example.jl"] == Dict(2 => 3, 3 => 0)
    @test_throws ArgumentError OdinJuliaAnalysis.parse_lcov(
        "DA:1,1\nend_of_record\n", pwd())
    @test_throws ArgumentError OdinJuliaAnalysis.parse_lcov(
        "SF:src/example.jl\nDA:bad,1\nend_of_record\n", pwd())

    merged = mktempdir() do root
        write(joinpath(root, "first.info"),
            "SF:src/example.jl\nDA:2,1\nend_of_record\n")
        write(joinpath(root, "second.info"),
            "SF:src/example.jl\nDA:2,3\nDA:4,0\nend_of_record\n")
        OdinJuliaAnalysis.load_lcov_data(
            root, ["first.info", "second.info"])
    end
    @test merged.lines["src/example.jl"] == Dict(2 => 4, 4 => 0)

    evidence_classes = Dict(
        (true, true) => "corroborated",
        (true, false) => "static-only",
        (false, true) => "runtime-only",
        (false, false) => "uncovered",
        (true, nothing) => "runtime-unavailable",
        (nothing, true) => "static-unavailable",
        (nothing, nothing) => "unavailable")
    for ((static_reachable, runtime_covered), expected) in evidence_classes
        @test OdinJuliaAnalysis.coverage_evidence_class(
            static_reachable, runtime_covered) == expected
    end

    closure = OdinJuliaAnalysis.test_reachable_names(
        "julia",
        [(name="test_entry",), (name="helper",), (name="target",)],
        [
            CallEdge("test/runtests.jl", "julia", "test_entry", "helper",
                "direct", 2, 1),
            CallEdge("src/app.jl", "julia", "helper", "target",
                "direct", 3, 1),
        ],
        [CallRoot("test:test_entry", "test/runtests.jl", "julia",
            "test_entry", "test")])
    @test closure == Set(("test_entry", "helper", "target"))
    risk_item = (cyclomatic_complexity=4, executable_lines=11)
    @test OdinJuliaAnalysis.coverage_risk_score(risk_item, ["callback"]) == 11
    @test OdinJuliaAnalysis.coverage_risk_score(risk_item, String[]) == 6

    coverage = CoverageSettings(true, ["coverage.info"], 1)
    report = mktempdir() do root
        mkpath(joinpath(root, "src"))
        mkpath(joinpath(root, "test"))
        write(joinpath(root, "src", "app.jl"), """
        function covered_julia()
            return 1
        end

        function uncovered_julia(value)
            value > 0 && return value
            return 0
        end
        """)
        write(joinpath(root, "test", "runtests.jl"), """
        function julia_test_entry()
            return covered_julia()
        end
        """)
        write(joinpath(root, "src", "app.odin"), """
        package fixture

        // Return one covered value.
        covered_odin :: proc() -> int {
            return 1
        }

        // Return a value with one decision.
        uncovered_odin :: proc(value: int) -> int {
            if value > 0 {
                return value
            }
            return 0
        }
        """)
        write(joinpath(root, "test", "main_tests.odin"), """
        package fixture

        // Exercise the covered procedure.
        odin_test_entry :: proc() {
            _ = covered_odin()
        }
        """)
        write(joinpath(root, "coverage.info"), """
        SF:src/app.jl
        DA:2,1
        DA:6,0
        end_of_record
        SF:src/app.odin
        DA:5,1
        DA:10,0
        end_of_record
        """)
        OdinJuliaAnalysis.check_repository(
            root; configuration=coverage_configuration(coverage))
    end
    @test report.schema_version == "4.0.0"
    @test report.test_coverage_statistics !== nothing
    @test report.test_coverage_statistics.overall.declarations == 6
    @test report.test_coverage_statistics.overall.corroborated == 2
    @test report.test_coverage_statistics.overall.uncovered == 2
    @test report.test_coverage_statistics.overall.runtime_unavailable == 2
    test_coverage = OdinJuliaAnalysis.analysis_test_coverage(report.files)
    @test Set(item.evidence_class for item in test_coverage) ==
        Set(("corroborated", "uncovered", "runtime-unavailable"))
    gaps = filter(OdinJuliaAnalysis.coverage_is_gap, test_coverage)
    @test Set(item.declaration for item in gaps) ==
        Set(("uncovered_julia", "uncovered_odin"))
    @test any(engine -> engine.name == "test-coverage" &&
        engine.status == "complete", report.engines)

    json_output = IOBuffer()
    OdinJuliaAnalysis.write_report(json_output, report, "json")
    json = String(take!(json_output))
    @test occursin("\"test_coverage\"", json)
    @test occursin("\"test_coverage_statistics\"", json)
    markdown_output = IOBuffer()
    OdinJuliaAnalysis.write_markdown_report(markdown_output, report)
    markdown = String(take!(markdown_output))
    @test occursin("## Test Coverage Evidence", markdown)
    @test occursin("### High-Risk Coverage Gaps", markdown)
    coverage_section = first(split(markdown, "\n## Analytical Odin Builds"))
    coverage_section = last(split(coverage_section, "## Test Coverage Evidence"))
    @test length(collect(eachmatch(
        r"(?m)^\| \d+ \| `uncovered_", coverage_section))) == 1

    failed = mktempdir() do root
        write(joinpath(root, "main.jl"), "main() = 1\n")
        OdinJuliaAnalysis.check_repository(
            root; configuration=coverage_configuration(coverage))
    end
    @test failed.exit_code == 2
    @test any(engine -> engine.name == "test-coverage" &&
        engine.status == "failed" && occursin("does not exist", engine.message),
        failed.engines)

    @test_throws ArgumentError coverage_configuration(
        CoverageSettings(true, String[], 20))
    @test_throws ArgumentError coverage_configuration(
        CoverageSettings(false, String[], 0))
    @test_throws ArgumentError coverage_configuration(
        CoverageSettings(false, ["coverage.info", "coverage.info"], 20))
end

@testset "self analysis" begin
    report = OdinJuliaAnalysis.check_repository(
        OdinJuliaAnalysis.ANALYSIS_ROOT)
    @test report.exit_code == 0
    @test all(
        engine -> engine.status == "complete" ||
            (engine.name in (
                "architecture", "duplicate-code", "resource-lifetime",
                "security", "test-coverage") &&
                engine.status == "not-applicable"),
        report.engines)
    @test report.files_analyzed > 0
end
