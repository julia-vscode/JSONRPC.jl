using Test
using JSON
using JSONRPC
using JSONRPC: typed_res, @dict_readable, Outbound
using Sockets

@dict_readable struct Foo <: Outbound
    fieldA::Int
    fieldB::String
    fieldC::Union{Missing,String}
    fieldD::Union{String,Missing}
end

@dict_readable struct Foo2 <: Outbound
    fieldA::Union{Nothing,Int}
    fieldB::Vector{Int}
end

Base.:(==)(a::Foo2,b::Foo2) = a.fieldA == b.fieldA && a.fieldB == b.fieldB

@testset "JSONRPC" begin
    @info "test_core START"
    include("test_core.jl")
    @info "test_core END"

    @info "test_interface_def START"
    include("test_interface_def.jl")
    @info "test_interface_def END"

    @info "test_typed START"
    include("test_typed.jl")
    @info "test_typed END"

    @info "check response type START"
    @testset "check response type" begin
        @test typed_res(nothing, Nothing) isa Nothing
        @test typed_res([1,"2",3], Vector{Any}) isa Vector{Any}
        @test typed_res([1,2,3], Vector{Int}) isa Vector{Int}
        @test typed_res([1,2,3], Vector{Float64}) isa Vector{Float64}
        @test typed_res(['f','o','o'], String) isa String
        @test typed_res("foo", String) isa String
    end
    @info "check response type END"
end
