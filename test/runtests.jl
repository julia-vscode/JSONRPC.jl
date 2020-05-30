using Test
using JSONRPC
using JSONRPC: typed_res

@testset "JSONRPC" begin
    @testset "check response type" begin
        @test typed_res(nothing, Nothing) isa Nothing
        @test typed_res([1,"2",3], Vector{Any}) isa Vector{Any}
        @test typed_res([1,2,3], Vector{Int}) isa Vector{Int}
        @test typed_res([1,2,3], Vector{Float64}) isa Vector{Float64}
        @test typed_res(['f','o','o'], String) isa String
        @test typed_res("foo", String) isa String
    end
end
