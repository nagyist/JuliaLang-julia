# This file is a part of Julia. License is MIT: https://julialang.org/license

"""
    Random

Support for generating random numbers. Provides [`rand`](@ref), [`randn`](@ref),
[`AbstractRNG`](@ref), [`Xoshiro`](@ref), [`MersenneTwister`](@ref), and [`RandomDevice`](@ref).
"""
module Random

include("DSFMT.jl")

using .DSFMT
using Base.GMP.MPZ
using Base.GMP: Limb
using SHA: SHA, SHA2_256_CTX, SHA2_512_CTX, SHA_CTX

using Base: BitInteger, BitInteger_types, BitUnsigned, require_one_based_indexing
import Base: copymutable, copy, copy!, ==, hash, convert,
             rand, randn, show

export rand!, randn!,
       randexp, randexp!,
       bitrand,
       randstring,
       randsubseq, randsubseq!,
       shuffle, shuffle!,
       randperm, randperm!,
       randcycle, randcycle!,
       AbstractRNG, MersenneTwister, RandomDevice, TaskLocalRNG, Xoshiro

public seed!, default_rng, Sampler, SamplerType, SamplerTrivial, SamplerSimple

## general definitions

"""
    AbstractRNG

Supertype for random number generators such as [`MersenneTwister`](@ref) and [`RandomDevice`](@ref).
"""
abstract type AbstractRNG end

Base.broadcastable(x::AbstractRNG) = Ref(x)

gentype(::Type{X}) where {X} = eltype(X)
gentype(x) = gentype(typeof(x))


### integers

# we define types which encode the generation of a specific number of bits
# the "raw" version means that the unused bits are not zeroed

abstract type UniformBits{T<:BitInteger} end

struct UInt10{T}    <: UniformBits{T} end
struct UInt10Raw{T} <: UniformBits{T} end

struct UInt23{T}    <: UniformBits{T} end
struct UInt23Raw{T} <: UniformBits{T} end

struct UInt52{T}    <: UniformBits{T} end
struct UInt52Raw{T} <: UniformBits{T} end

struct UInt104{T}    <: UniformBits{T} end
struct UInt104Raw{T} <: UniformBits{T} end

struct UInt2x52{T}    <: UniformBits{T} end
struct UInt2x52Raw{T} <: UniformBits{T} end

uint_sup(::Type{<:Union{UInt10,UInt10Raw}}) = UInt16
uint_sup(::Type{<:Union{UInt23,UInt23Raw}}) = UInt32
uint_sup(::Type{<:Union{UInt52,UInt52Raw}}) = UInt64
uint_sup(::Type{<:Union{UInt104,UInt104Raw}}) = UInt128
uint_sup(::Type{<:Union{UInt2x52,UInt2x52Raw}}) = UInt128

for UI = (:UInt10, :UInt10Raw, :UInt23, :UInt23Raw, :UInt52, :UInt52Raw,
          :UInt104, :UInt104Raw, :UInt2x52, :UInt2x52Raw)
    @eval begin
        $UI(::Type{T}=uint_sup($UI)) where {T} = $UI{T}()
        # useful for defining rand generically:
        uint_default(::$UI) = $UI{uint_sup($UI)}()
    end
end

gentype(::Type{<:UniformBits{T}}) where {T} = T

### floats

abstract type FloatInterval{T<:AbstractFloat} end

struct CloseOpen01{T<:AbstractFloat} <: FloatInterval{T} end # interval [0,1)
struct CloseOpen12{T<:AbstractFloat} <: FloatInterval{T} end # interval [1,2)

const FloatInterval_64 = FloatInterval{Float64}
const CloseOpen01_64   = CloseOpen01{Float64}
const CloseOpen12_64   = CloseOpen12{Float64}

CloseOpen01(::Type{T}=Float64) where {T<:AbstractFloat} = CloseOpen01{T}()
CloseOpen12(::Type{T}=Float64) where {T<:AbstractFloat} = CloseOpen12{T}()

gentype(::Type{<:FloatInterval{T}}) where {T<:AbstractFloat} = T

const BitFloatType = Union{Type{Float16},Type{Float32},Type{Float64}}

### Sampler

abstract type Sampler{E} end

gentype(::Type{<:Sampler{E}}) where {E} = E

# temporarily for BaseBenchmarks
RangeGenerator(x) = Sampler(default_rng(), x)

# In some cases, when only 1 random value is to be generated,
# the optimal sampler can be different than if multiple values
# have to be generated. Hence a `Repetition` parameter is used
# to choose the best one depending on the need.
const Repetition = Union{Val{1},Val{Inf}}

# these default fall-back for all RNGs would be nice,
# but generate difficult-to-solve ambiguities
# Sampler(::AbstractRNG, X, ::Val{Inf}) = Sampler(X)
# Sampler(::AbstractRNG, ::Type{X}, ::Val{Inf}) where {X} = Sampler(X)

"""
    Sampler(rng, x, repetition = Val(Inf))

Return a sampler object that can be used to generate random values from `rng` for `x`.

When `sp = Sampler(rng, x, repetition)`, `rand(rng, sp)` will be used to draw random values,
and should be defined accordingly.

`repetition` can be `Val(1)` or `Val(Inf)`, and should be used as a suggestion for deciding
the amount of precomputation, if applicable.

[`Random.SamplerType`](@ref) and [`Random.SamplerTrivial`](@ref) are default fallbacks for
*types* and *values*, respectively. [`Random.SamplerSimple`](@ref) can be used to store
pre-computed values without defining extra types for only this purpose.
"""
Sampler(rng::AbstractRNG, x, r::Repetition=Val(Inf)) = Sampler(typeof(rng), x, r)
Sampler(rng::AbstractRNG, ::Type{X}, r::Repetition=Val(Inf)) where {X} =
    Sampler(typeof(rng), X, r)

# this method is necessary to prevent rand(rng::AbstractRNG, X) from
# recursively constructing nested Sampler types.
Sampler(T::Type{<:AbstractRNG}, sp::Sampler, r::Repetition) =
    throw(MethodError(Sampler, (T, sp, r)))

# default shortcut for the general case
Sampler(::Type{RNG}, X) where {RNG<:AbstractRNG} = Sampler(RNG, X, Val(Inf))
Sampler(::Type{RNG}, ::Type{X}) where {RNG<:AbstractRNG,X} = Sampler(RNG, X, Val(Inf))

#### pre-defined useful Sampler types

"""
    SamplerType{T}()

A sampler for types, containing no other information. The default fallback for `Sampler`
when called with types.
"""
struct SamplerType{T} <: Sampler{T} end

Sampler(::Type{<:AbstractRNG}, ::Type{T}, ::Repetition) where {T} = SamplerType{T}()

Base.getindex(::SamplerType{T}) where {T} = T

# SamplerUnion(X, Y, ...}) == Union{SamplerType{X}, SamplerType{Y}, ...}
SamplerUnion(U...) = Union{Any[SamplerType{T} for T in U]...}
const SamplerBoolBitInteger = SamplerUnion(Bool, BitInteger_types...)


struct SamplerTrivial{T,E} <: Sampler{E}
    self::T
end

"""
    SamplerTrivial(x)

Create a sampler that just wraps the given value `x`. This is the default fall-back for
values.
The `eltype` of this sampler is equal to `eltype(x)`.

The recommended use case is sampling from values without precomputed data.
"""
SamplerTrivial(x::T) where {T} = SamplerTrivial{T,gentype(T)}(x)

Sampler(::Type{<:AbstractRNG}, x, ::Repetition) = SamplerTrivial(x)

Base.getindex(sp::SamplerTrivial) = sp.self

# simple sampler carrying data (which can be anything)
struct SamplerSimple{T,S,E} <: Sampler{E}
    self::T
    data::S
end

"""
    SamplerSimple(x, data)

Create a sampler that wraps the given value `x` and the `data`.
The `eltype` of this sampler is equal to `eltype(x)`.

The recommended use case is sampling from values with precomputed data.
"""
SamplerSimple(x::T, data::S) where {T,S} = SamplerSimple{T,S,gentype(T)}(x, data)

Base.getindex(sp::SamplerSimple) = sp.self

# simple sampler carrying a (type) tag T and data
struct SamplerTag{T,S,E} <: Sampler{E}
    data::S
    SamplerTag{T}(s::S) where {T,S} = new{T,S,gentype(T)}(s)
end


#### helper samplers

# TODO: make constraining constructors to enforce that those
# types are <: Sampler{T}

##### Adapter to generate a random value in [0, n]

struct LessThan{T<:Integer,S} <: Sampler{T}
    sup::T
    s::S    # the scalar specification/sampler to feed to rand
end

function rand(rng::AbstractRNG, sp::LessThan)
    while true
        x = rand(rng, sp.s)
        x <= sp.sup && return x
    end
end

struct Masked{T<:Integer,S} <: Sampler{T}
    mask::T
    s::S
end

rand(rng::AbstractRNG, sp::Masked) = rand(rng, sp.s) & sp.mask

##### Uniform

struct UniformT{T} <: Sampler{T} end

uniform(::Type{T}) where {T} = UniformT{T}()

rand(rng::AbstractRNG, ::UniformT{T}) where {T} = rand(rng, T)


### machinery for generation with Sampler

# This describes how to generate random scalars or arrays, by generating a Sampler
# and calling rand on it (which should be defined in "generation.jl").
# NOTE: this section could be moved into a separate file when more containers are supported.

#### scalars

rand(rng::AbstractRNG, X)                                           = rand(rng, Sampler(rng, X, Val(1)))
# this is needed to disambiguate
rand(rng::AbstractRNG, X::Dims)                                     = rand(rng, Sampler(rng, X, Val(1)))
rand(rng::AbstractRNG=default_rng(), ::Type{X}=Float64) where {X}   = rand(rng, Sampler(rng, X, Val(1)))::X

rand(X)                   = rand(default_rng(), X)
rand(::Type{X}) where {X} = rand(default_rng(), X)

#### arrays

rand!(A::AbstractArray{T}, X) where {T}             = rand!(default_rng(), A, X)
rand!(A::AbstractArray{T}, ::Type{X}=T) where {T,X} = rand!(default_rng(), A, X)

rand!(rng::AbstractRNG, A::AbstractArray{T}, X) where {T}             = rand!(rng, A, Sampler(rng, X))
rand!(rng::AbstractRNG, A::AbstractArray{T}, ::Type{X}=T) where {T,X} = rand!(rng, A, Sampler(rng, X))

function rand!(rng::AbstractRNG, A::AbstractArray{T}, sp::Sampler) where T
    for i in eachindex(A)
        @inbounds A[i] = rand(rng, sp)
    end
    A
end

rand(r::AbstractRNG, dims::Integer...) = rand(r, Float64, Dims(dims))
rand(                dims::Integer...) = rand(Float64, Dims(dims))

rand(r::AbstractRNG, X, dims::Dims)  = rand!(r, Array{gentype(X)}(undef, dims), X)
rand(                X, dims::Dims)  = rand(default_rng(), X, dims)

rand(r::AbstractRNG, X, d::Integer, dims::Integer...) = rand(r, X, Dims((d, dims...)))
rand(                X, d::Integer, dims::Integer...) = rand(X, Dims((d, dims...)))
# note: the above methods would trigger an ambiguity warning if d was not separated out:
# rand(r, ()) would match both this method and rand(r, dims::Dims)
# moreover, a call like rand(r, NotImplementedType()) would be an infinite loop

rand(r::AbstractRNG, ::Type{X}, dims::Dims) where {X} = rand!(r, Array{X}(undef, dims), X)
rand(                ::Type{X}, dims::Dims) where {X} = rand(default_rng(), X, dims)

rand(r::AbstractRNG, ::Type{X}, d::Integer, dims::Integer...) where {X} = rand(r, X, Dims((d, dims...)))
rand(                ::Type{X}, d::Integer, dims::Integer...) where {X} = rand(X, Dims((d, dims...)))


### UnsafeView
# internal array-like type to circumvent the lack of flexibility with reinterpret

struct UnsafeView{T} <: DenseArray{T,1}
    ptr::Ptr{T}
    len::Int
end

Base.length(a::UnsafeView) = a.len
Base.getindex(a::UnsafeView, i::Int) = unsafe_load(a.ptr, i)
Base.setindex!(a::UnsafeView, x, i::Int) = unsafe_store!(a.ptr, x, i)
Base.pointer(a::UnsafeView) = a.ptr
Base.size(a::UnsafeView) = (a.len,)
Base.elsize(::Type{UnsafeView{T}}) where {T} = sizeof(T)


## rand & rand! docstrings

"""
    rand([rng=default_rng()], [S], [dims...])

Pick a random element or array of random elements from the set of values specified by `S`;
`S` can be

* an indexable collection (for example `1:9` or `('x', "y", :z)`)

* an `AbstractDict` or `AbstractSet` object

* a string (considered as a collection of characters), or

* a type from the list below, corresponding to the specified set of values

  + concrete integer types sample from `typemin(S):typemax(S)` (excepting [`BigInt`](@ref) which is not supported)

  + concrete floating point types sample from `[0, 1)`

  + concrete complex types `Complex{T}` if `T` is a sampleable type take their real and imaginary components
    independently from the set of values corresponding to `T`, but are not supported if `T` is not sampleable.

  + all `<:AbstractChar` types sample from the set of valid Unicode scalars

  + a user-defined type and set of values; for implementation guidance please see [Hooking into the `Random` API](@ref rand-api-hook)

  + a tuple type of known size and where each parameter of `S` is itself a sampleable type; return a value of type `S`.
    Note that tuple types such as `Tuple{Vararg{T}}` (unknown size) and `Tuple{1:2}` (parameterized with a value) are not supported

  + a `Pair` type, e.g. `Pair{X, Y}` such that `rand` is defined for `X` and `Y`,
    in which case random pairs are produced.


`S` defaults to [`Float64`](@ref).
When only one argument is passed besides the optional `rng` and is a `Tuple`, it is interpreted
as a collection of values (`S`) and not as `dims`.


See also [`randn`](@ref) for normally distributed numbers, and [`rand!`](@ref) and [`randn!`](@ref) for the in-place equivalents.

!!! compat "Julia 1.1"
    Support for `S` as a tuple requires at least Julia 1.1.

!!! compat "Julia 1.11"
    Support for `S` as a `Tuple` type requires at least Julia 1.11.

# Examples
```julia-repl
julia> rand(Int, 2)
2-element Vector{Int64}:
 1339893410598768192
 1575814717733606317

julia> using Random

julia> rand(Xoshiro(0), Dict(1=>2, 3=>4))
3 => 4

julia> rand((2, 3))
3

julia> rand(Float64, (2, 3))
2×3 Matrix{Float64}:
 0.999717  0.0143835  0.540787
 0.696556  0.783855   0.938235
```

!!! note
    The complexity of `rand(rng, s::Union{AbstractDict,AbstractSet})`
    is linear in the length of `s`, unless an optimized method with
    constant complexity is available, which is the case for `Dict`,
    `Set` and dense `BitSet`s. For more than a few calls, use `rand(rng,
    collect(s))` instead, or either `rand(rng, Dict(s))` or `rand(rng,
    Set(s))` as appropriate.
"""
rand

"""
    rand!([rng=default_rng()], A, [S=eltype(A)])

Populate the array `A` with random values. If `S` is specified
(`S` can be a type or a collection, cf. [`rand`](@ref) for details),
the values are picked randomly from `S`.
This is equivalent to `copyto!(A, rand(rng, S, size(A)))`
but without allocating a new array.

# Examples
```jldoctest
julia> rand!(Xoshiro(123), zeros(5))
5-element Vector{Float64}:
 0.521213795535383
 0.5868067574533484
 0.8908786980927811
 0.19090669902576285
 0.5256623915420473
```
"""
rand!


include("Xoshiro.jl")
include("RNGs.jl")
include("MersenneTwister.jl")
include("generation.jl")
include("normal.jl")
include("misc.jl")
include("XoshiroSimd.jl")

end # module
