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

