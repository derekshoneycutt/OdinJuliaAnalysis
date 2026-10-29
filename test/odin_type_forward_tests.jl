@testset "Odin distinct array type forwards" begin
    mktempdir() do root
        color_directory = mkdir(joinpath(root, "color"))
        color_path = joinpath(color_directory, "color.odin")
        write(color_path, """
            package color
            Color_RGBA8 :: distinct [4]u8
            ARRAY_VALUES :: [4]u8{1, 2, 3, 4}
            """)
        path = joinpath(root, "fixture.odin")
        write(path, """
            package fixture
            import color "color"
            Particle_Color :: color.Color_RGBA8
            Local_RGBA8 :: distinct [4]u8
            Local_Color :: Local_RGBA8
            Alias_Color :: Particle_Color
            bad_forward :: color.Color_RGBA8
            ARRAY_VALUES :: [4]u8{1, 2, 3, 4}
            FORWARDED_CONSTANT :: color.ARRAY_VALUES
            mutable_color := color.Color_RGBA8
            """)
        analysis = OdinJuliaAnalysis.OdinEngine.analyze(
            root, [path, color_path], OdinJuliaAnalysis.load_settings())
        declarations = Dict(
            item.name => item.kind
            for item in analysis.declarations if item.path == "fixture.odin")
        for name in ("Particle_Color", "Local_RGBA8", "Local_Color", "Alias_Color")
            @test declarations[name] == "type"
        end
        @test declarations["ARRAY_VALUES"] == "constant"
        @test declarations["FORWARDED_CONSTANT"] == "constant"
        @test declarations["mutable_color"] == "variable"
        diagnostics = filter(
            item -> item.rule_id == "ODIN-NAMING" && item.path == "fixture.odin",
            analysis.diagnostics)
        @test [(item.subject, item.operation) for item in diagnostics] ==
            [("Local_RGBA8", "type"), ("bad_forward", "type")]
    end
end
