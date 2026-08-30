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
            Vector2 :: rl.Vector2
            bad_forward :: rl.Vector2
            FORWARDED_CONSTANT :: rl.FORWARDED_CONSTANT
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
            "bad_forward",
            "bad_constant",
            "Bad_Procedure",
            "Bad_Parameter",
            "Bad_Local",
        ]
        @test [item.operation for item in diagnostics] == [
            "import", "type", "field", "type", "enum_value", "type",
            "constant", "procedure", "parameter", "variable"]
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

@testset "Odin foreign procedures are interop-only" begin
    mktempdir() do root
        path = joinpath(root, "fixture.odin")
        write(path, """
            package fixture

            foreign import fixture_library "system:fixture.lib"

            foreign fixture_library {
                Bad_Foreign :: proc(
                    Bad_A, Bad_B, Bad_C, Bad_D, Bad_E, Bad_F: int) ->
                    (first, second: int, flag: bool) ---
            }

            AFTER_FOREIGN :: 1
            """)
        configuration = OdinJuliaAnalysis.load_settings()
        analysis = OdinJuliaAnalysis.OdinEngine.analyze(
            root, [path], configuration)

        @test isempty(analysis.functions)
        @test !any(item -> item.name == "Bad_Foreign", analysis.declarations)
        @test isempty(analysis.diagnostics)
        signature = only(analysis.interop_signatures)
        @test signature.symbol == "Bad_Foreign"
        @test signature.direction == "import"
        @test length(signature.parameter_types) == 6
        @test length(signature.return_types) == 3
    end
end

@testset "Odin init procedures are implicit call roots" begin
    mktempdir() do root
        path = joinpath(root, "fixture.odin")
        write(path, """
            package fixture

            // Initialize package state before main.
            @(init)
            initialize :: proc() {}

            // Remain unreachable from package entry points.
            unused :: proc() {}
            """)
        configuration = OdinJuliaAnalysis.load_settings()
        analysis = OdinJuliaAnalysis.OdinEngine.analyze(
            root, [path], configuration)
        initialize = only(filter(
            item -> item.name == "initialize",
            analysis.declarations))
        unused = only(filter(
            item -> item.name == "unused",
            analysis.declarations))

        @test initialize.is_init
        @test !unused.is_init
        roots = OdinJuliaAnalysis.collect_call_roots(
            analysis.declarations,
            analysis.interop_signatures,
            configuration)
        @test any(root -> root.declaration == "initialize" && root.category == "init",
            roots)
        diagnostics = OdinJuliaAnalysis.analyze_reachability(
            analysis.declarations,
            analysis.call_edges,
            analysis.references,
            roots,
            configuration)
        unreachable = filter(
            item -> item.rule_id == "ODIN-UNREACHABLE-PROCEDURE",
            diagnostics)
        @test [item.subject for item in unreachable] == ["unused"]
    end
end

@testset "Odin test files are implicit call roots" begin
    mktempdir() do root
        path = joinpath(root, "fixture_test.odin")
        write(path, """
            package fixture
            import "core:testing"

            test_helper :: proc() {}

            @(test)
            fixture_test :: proc(t: ^testing.T) {
                test_helper()
            }
            """)
        configuration = OdinJuliaAnalysis.load_settings()
        analysis = OdinJuliaAnalysis.OdinEngine.analyze(
            root, [path], configuration)
        roots = OdinJuliaAnalysis.collect_call_roots(
            analysis.declarations,
            analysis.interop_signatures,
            configuration)

        @test Set(root.declaration for root in roots if root.category == "test") ==
            Set(["fixture_test", "test_helper"])
        diagnostics = OdinJuliaAnalysis.analyze_reachability(
            analysis.declarations,
            analysis.call_edges,
            analysis.references,
            roots,
            configuration)
        @test !any(
            item -> item.rule_id == "ODIN-UNREACHABLE-PROCEDURE",
            diagnostics)
    end
end

@testset "Odin non-const globals" begin
    mktempdir() do root
        path = joinpath(root, "fixture.odin")
        write(path, """
            package fixture

            PACKAGE_GLOBAL := 1
            PACKAGE_CONSTANT :: 2
            @(rodata)
            RODATA_GLOBAL := [?]Int{3, 4}
            @(rodata)
            RODATA_FIRST, RODATA_SECOND := 5, 6

            // Exercise a procedure-local value.
            sample :: proc() {
                local_value := 3
            }
            """)
        configuration = OdinJuliaAnalysis.load_settings()
        analysis = OdinJuliaAnalysis.OdinEngine.analyze(
            root, [path], configuration)
        diagnostics = filter(
            item -> item.rule_id == "ODIN-NONCONST-GLOBAL",
            analysis.diagnostics)

        @test [item.subject for item in diagnostics] == ["PACKAGE_GLOBAL"]
        @test only(diagnostics).response == Warn
        @test only(diagnostics).operation == "global"
        declarations = Dict(item.name => item for item in analysis.declarations)
        @test declarations["PACKAGE_GLOBAL"].kind == "variable"
        @test !declarations["PACKAGE_GLOBAL"].is_rodata
        for name in ("RODATA_GLOBAL", "RODATA_FIRST", "RODATA_SECOND")
            @test declarations[name].kind == "variable"
            @test declarations[name].is_rodata
        end

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

@testset "Odin declaration order" begin
    mktempdir() do root
        path = joinpath(root, "fixture.odin")
        write(path, """
            package fixture

            first :: proc() {
                LOCAL_CONSTANT :: 1
            }

            Later :: struct {
                value: int,
            }
            AFTER :: 2
            """)
        configuration = OdinJuliaAnalysis.load_settings()
        diagnostics = filter(
            item -> item.rule_id == "ODIN-DECLARATION-ORDER",
            OdinJuliaAnalysis.OdinEngine.analyze(
                root, [path], configuration).diagnostics)

        @test [item.subject for item in diagnostics] == ["Later", "AFTER"]
        @test all(item -> item.response == Warn, diagnostics)

        disabled = with_rules(configuration, Dict(
            "ODIN-DECLARATION-ORDER" => RuleSetting(
                "ODIN-DECLARATION-ORDER", false, Warn)))
        @test isempty(filter(
            item -> item.rule_id == "ODIN-DECLARATION-ORDER",
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

