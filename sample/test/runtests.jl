using HelloWorldSample
using Test

@testset "HelloWorldSample" begin
    @test greeting() == "Hello from Julia!"

    output = IOBuffer()
    main(output)
    @test String(take!(output)) == "Hello from Julia!\n"
end
