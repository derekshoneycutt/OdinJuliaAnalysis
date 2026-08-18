@testset "dependency graph inventory" begin
    mktempdir() do root
        julia_path = joinpath(root, "app.jl")
        odin_path = joinpath(root, "main.odin")
        odin_package = joinpath(root, "lib", "math")
        mkpath(odin_package)
        write(julia_path, """
            module App
            using JSON3
            module Local
            import ..Local: value
            end
            import .Missing
            end
            """)
        write(odin_path, """
            package fixture
            import "core:fmt"
            import "lib/math"
            """)
        write(joinpath(odin_package, "math.odin"), """
            package math
            import "../.."
            """)
        base_configuration = with_odin_build_targets(
            with_jet_entries(
                OdinJuliaAnalysis.load_settings(),
                JetEntryPoint[]),
            OdinBuildTarget[])
        architecture = ArchitectureSettings(
            [
                ArchitectureLayer("application", ["."]),
                ArchitectureLayer("library", ["lib"]),
            ],
            [ArchitectureDependency("application", "library")])
        architecture_rules = Dict(
            rule_id => RuleSetting(rule_id, true, Warn)
            for rule_id in (
                "ARCHITECTURE-FORBIDDEN-DEPENDENCY",
                "ARCHITECTURE-DEPENDENCY-CYCLE",
                "ARCHITECTURE-UNRESOLVED-INTERNAL-IMPORT"))
        configuration = with_architecture(
            with_rules(base_configuration, architecture_rules),
            architecture)

        report = OdinJuliaAnalysis.check_repository(
            root; configuration)
        @test [
            (
                edge.source_path,
                edge.target,
                edge.target_path,
                edge.resolution,
                edge.language,
                edge.kind)
            for edge in report.dependencies
        ] == [
            ("app.jl", "JSON3", nothing, "external", "julia", "using"),
            (
                "app.jl",
                "..Local",
                "app.jl",
                "repository",
                "julia",
                "import"),
            (
                "app.jl",
                ".Missing",
                nothing,
                "unresolved",
                "julia",
                "import"),
            (
                "lib/math/math.odin",
                "../..",
                ".",
                "repository",
                "odin",
                "import"),
            (
                "main.odin",
                "core:fmt",
                nothing,
                "external",
                "odin",
                "import"),
            (
                "main.odin",
                "lib/math",
                "lib/math",
                "repository",
                "odin",
                "import"),
        ]
        @test [
            (item.qualified_name, item.kind, item.scope)
            for item in report.declarations
        ] == [
            ("App", "module", nothing),
            ("App.Local", "module", "App"),
        ]
        architecture_diagnostics = filter(
            diagnostic -> startswith(diagnostic.rule_id, "ARCHITECTURE-"),
            report.diagnostics)
        @test sort!([
            diagnostic.rule_id for diagnostic in architecture_diagnostics]) == [
            "ARCHITECTURE-DEPENDENCY-CYCLE",
            "ARCHITECTURE-FORBIDDEN-DEPENDENCY",
            "ARCHITECTURE-UNRESOLVED-INTERNAL-IMPORT",
        ]
        @test all(diagnostic -> diagnostic.response == Warn, architecture_diagnostics)
        @test isempty(report.extensions)
        @test any(
            engine -> engine.name == "architecture" &&
                engine.status == "complete",
            report.engines)
        @test all(
            summary -> summary.status == "evaluated" && summary.findings == 1,
            filter(
                summary -> startswith(summary.rule_id, "ARCHITECTURE-"),
                report.rules))

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
                ArchitectureSettings(
                    [ArchitectureLayer("duplicate", ["src", "src"])],
                    ArchitectureDependency[]),
                base_configuration.allocations,
                base_configuration.report,
                AnalysisExtension[]))

        json_output = IOBuffer()
        OdinJuliaAnalysis.write_report(json_output, report, "json")
        json = String(take!(json_output))
        @test occursin("\"dependencies\"", json)
        @test occursin("\"declarations\"", json)

        markdown_output = IOBuffer()
        OdinJuliaAnalysis.write_markdown_report(markdown_output, report)
        markdown = String(take!(markdown_output))
        @test !occursin("## Dependency Graph", markdown)
        @test !occursin("## Declaration Inventory", markdown)
        @test occursin("## Repository Statistics", markdown)
    end
end

@testset "declaration inventory" begin
    mktempdir() do root
        write(joinpath(root, "app.jl"), """
            module App
            const LIMIT = 2
            struct Item
                value::Int
            end
            helper(value) = value
            end
            """)
        odin_path = joinpath(root, "main.odin")
        write(odin_path, """
            package fixture
            VALUE :: 1
            run :: proc(item: int) {
                local := item
            }
            """)
        configuration = with_odin_build_targets(
            with_jet_entries(
                OdinJuliaAnalysis.load_settings(),
                JetEntryPoint[]),
            OdinBuildTarget[])

        report = OdinJuliaAnalysis.check_repository(root; configuration)

        @test [
            (
                item.path,
                item.qualified_name,
                item.kind,
                item.scope)
            for item in report.declarations
        ] == [
            ("app.jl", "App", "module", nothing),
            ("app.jl", "App.LIMIT", "constant", "App"),
            ("app.jl", "App.Item", "type", "App"),
            ("app.jl", "App.helper", "function", "App"),
            ("main.odin", "VALUE", "constant", nothing),
            ("main.odin", "run", "procedure", nothing),
            ("main.odin", "run.item", "parameter", "run"),
            ("main.odin", "run.local", "variable", "run"),
        ]
        @test report.schema_version == "3.19.0"
    end
end

@testset "unused imports and interop bridges" begin
    mktempdir() do root
        write(joinpath(root, "bridge.jl"), """
            import Dates
            import Random: rand as random_value
            Dates.now()
            bridge(a::Cint, b::Cint) =
                @ccall bridge_add(a::Cint, b::Cint)::Cint
            invoke_bridge() = bridge(1, 2)
            """)
        write(joinpath(root, "bridge.odin"), """
            package library
            import fmt "core:fmt"
            import path "core:path"
            @(export, link_name="bridge_add")
            add :: proc "c" (a, b: i32) -> i32 {
                fmt.println("bridge")
                return a + b
            }
            """)
        configuration = with_odin_build_targets(
            with_jet_entries(
                OdinJuliaAnalysis.load_settings(),
                JetEntryPoint[]),
            OdinBuildTarget[])

        report = OdinJuliaAnalysis.check_repository(root; configuration)

        findings = filter(
            item -> endswith(item.rule_id, "UNUSED-IMPORT"),
            report.diagnostics)
        @test sort([(item.rule_id, item.subject) for item in findings]) == [
            ("JULIA-UNUSED-IMPORT", "random_value"),
            ("ODIN-UNUSED-IMPORT", "path"),
        ]
        @test all(item -> item.certainty == "definite", findings)
        @test length(report.import_bindings) == 4
        @test !isempty(report.references)
        @test [(item.caller, item.callee, item.kind) for item in report.call_edges] == [
            (nothing, "Dates.now", "qualified"),
            ("bridge", "bridge_add", "direct"),
            ("invoke_bridge", "bridge", "direct"),
            ("add", "fmt.println", "qualified"),
        ]
        @test [(item.symbol, item.status) for item in report.interop_pairs] ==
            [("bridge_add", "matched")]
        pair = only(report.interop_pairs)
        @test pair.mismatch === nothing
        @test report.schema_version == "3.19.0"

        signatures = InteropSignature[
            InteropSignature(
                "caller.jl", "julia", "mismatch", "import", nothing,
                "c", ["i32"], ["i32"], 1, 1),
            InteropSignature(
                "exports.odin", "odin", "mismatch", "export", nothing,
                "c", ["i64"], ["i32"], 1, 1),
            InteropSignature(
                "caller.jl", "julia", "julia_only", "import", nothing,
                "c", String[], String[], 2, 1),
            InteropSignature(
                "exports.odin", "odin", "odin_only", "export", nothing,
                "c", String[], String[], 2, 1),
            InteropSignature(
                "external.jl", "julia", "puts", "import", "libc",
                "c", ["cstring"], ["i32"], 1, 1),
        ]
        pairs = OdinJuliaAnalysis.pair_interop_signatures(signatures)
        @test Dict(item.symbol => item.status for item in pairs) == Dict(
            "julia_only" => "missing-odin",
            "mismatch" => "signature-mismatch",
            "odin_only" => "missing-julia",
            "puts" => "external")
        @test only(filter(item -> item.symbol == "mismatch", pairs)).mismatch ==
            "parameter types i32 != i64"

        output = IOBuffer()
        OdinJuliaAnalysis.write_markdown_report(output, report)
        markdown = String(take!(output))
        @test !occursin("## Import Bindings", markdown)
        @test !occursin("## Reference Inventory", markdown)
        @test !occursin("## Call Graph", markdown)
        @test !occursin("## Interop Bridge Pairs", markdown)
        @test occursin("JULIA-UNUSED-IMPORT", markdown)
    end
end

@testset "call graph reachability and behavior" begin
    configuration = OdinJuliaAnalysis.load_settings()
    declarations = DeclarationRecord[
        DeclarationRecord("app.jl", "julia", "main", "App.main",
            "function", "App", 1, 1),
        DeclarationRecord("app.jl", "julia", "helper", "App.helper",
            "function", "App", 5, 1),
        DeclarationRecord("app.jl", "julia", "unused", "App.unused",
            "function", "App", 9, 1),
    ]
    edges = CallEdge[
        CallEdge("app.jl", "julia", "App.main", "helper", "direct", 2, 5),
        CallEdge("app.jl", "julia", "App.helper", "factory()", "dynamic", 6, 5),
    ]
    roots = CallRoot[
        CallRoot("app", "app.jl", "julia", "main", "production"),
    ]
    diagnostics = OdinJuliaAnalysis.analyze_reachability(
        declarations, edges, roots, configuration)
    @test sort([item.rule_id for item in diagnostics]) == [
        "CALL-GRAPH-UNRESOLVED-EDGE",
        "JULIA-UNREACHABLE-FUNCTION",
    ]
    @test only(filter(
        item -> item.rule_id == "JULIA-UNREACHABLE-FUNCTION",
        diagnostics)).subject == "App.unused"

    source = """
        function mutate(value::Vector{Int})
            value[1] = 2
            global STATE = 1
            try
                error("failure")
            catch error_value
                println("ignored")
            end
            try
                error("failure")
            catch
            end
        end

        function mutate!(value::Vector{Int})
            value[1] = 3
        end
        """
    behavior = filter(
        item -> item.rule_id in (
            "JULIA-EMPTY-CATCH",
            "JULIA-BROAD-CATCH",
            "JULIA-UNSIGNALED-ARGUMENT-MUTATION",
            "JULIA-GLOBAL-WRITE"),
        OdinJuliaAnalysis.JuliaEngine.check("behavior.jl", source, configuration))
    @test sort([item.rule_id for item in behavior]) == [
        "JULIA-BROAD-CATCH",
        "JULIA-EMPTY-CATCH",
        "JULIA-GLOBAL-WRITE",
        "JULIA-UNSIGNALED-ARGUMENT-MUTATION",
    ]
    @test count(
        item -> item.rule_id == "JULIA-UNSIGNALED-ARGUMENT-MUTATION",
        behavior) == 1
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

