using Pkg
using Test

@testset "Test that dependencies have been precompiled" begin
    package_name = "StaticArrays"
    sa = Base.identify_package(package_name)
    package_path = Base.locate_package(sa)
    @debug "Package {$package_name} at {$package_path}"
    @test Base.isprecompiled(sa)
end
