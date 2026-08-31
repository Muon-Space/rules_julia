using Test
using TestImages

@testset begin
    @test !isnothing(testimage("cameraman.tif"))
end
