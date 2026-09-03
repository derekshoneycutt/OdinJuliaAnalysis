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

        template_configuration = with_documentation(
            OdinJuliaAnalysis.load_settings(),
            DocumentationSettings(r"\S", r"(?m)^Parameters:$"))
        template_configuration = with_rules(template_configuration, Dict(
            "ODIN-DOC-MISSING" => RuleSetting(
                "ODIN-DOC-MISSING", true, Report)))
        write(path, """
            package fixture

            // Summary only.
            missing_parameters :: proc(value: int) {}

            // Summary.
            // Parameters:
            // - value: Ignored value.
            documented_parameters :: proc(value: int) {}

            //
            empty_documentation :: proc() {}
            """)
        template_diagnostics = OdinJuliaAnalysis.OdinEngine.check_syntax(
            root, [path], template_configuration)
        template_findings = filter(
            item -> item.rule_id == "ODIN-DOC-MISSING", template_diagnostics)
        @test [item.subject for item in template_findings] == [
            "missing_parameters",
            "empty_documentation",
        ]
        @test all(item -> item.response == Report, template_findings)
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
        "-out:" * joinpath(build_directory,
            Sys.iswindows() ? "odin-engine-tests.exe" : "odin-engine-tests"),
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

