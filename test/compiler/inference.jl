# This file is a part of Julia. License is MIT: https://julialang.org/license

# tests for Core.Compiler correctness and precision
import Core.Compiler: Const, Conditional, ⊑, ReturnNode, GotoIfNot
isdispatchelem(@nospecialize x) = !isa(x, Type) || Core.Compiler.isdispatchelem(x)

using Random, Core.IR
using InteractiveUtils: code_llvm

f39082(x::Vararg{T}) where {T <: Number} = x[1]
let ast = only(code_typed(f39082, Tuple{Vararg{Rational}}))[1]
    @test ast.slottypes == Any[Const(f39082), Tuple{Vararg{Rational}}]
end
let ast = only(code_typed(f39082, Tuple{Rational, Vararg{Rational}}))[1]
    @test ast.slottypes == Any[Const(f39082), Tuple{Rational, Vararg{Rational}}]
end

# demonstrate some of the type-size limits
@test Core.Compiler.limit_type_size(Ref{Complex{T} where T}, Ref, Ref, 100, 0) == Ref
@test Core.Compiler.limit_type_size(Ref{Complex{T} where T}, Ref{Complex{T} where T}, Ref, 100, 0) == Ref{Complex{T} where T}

let comparison = Tuple{X, X} where X<:Tuple
    sig = Tuple{X, X} where X<:comparison
    ref = Tuple{X, X} where X
    @test Core.Compiler.limit_type_size(sig, comparison, comparison, 100, 100) == Tuple{Tuple, Tuple}
    @test Core.Compiler.limit_type_size(sig, ref, comparison, 100, 100) == Tuple{Any, Any}
    @test Core.Compiler.limit_type_size(Tuple{sig}, Tuple{ref}, comparison, 100, 100) == Tuple{Tuple{Any, Any}}
    @test Core.Compiler.limit_type_size(sig, ref, Tuple{comparison}, 100,  100) == Tuple{Tuple{X, X} where X<:Tuple, Tuple{X, X} where X<:Tuple}
    @test Core.Compiler.limit_type_size(ref, sig, Union{}, 100, 100) == ref
end

let ref = Tuple{T, Val{T}} where T<:Val
    sig = Tuple{T, Val{T}} where T<:(Val{T} where T<:Val)
    @test Core.Compiler.limit_type_size(sig, ref, Union{}, 100, 100) == Tuple{Val, Val}
    @test Core.Compiler.limit_type_size(ref, sig, Union{}, 100, 100) == ref
end
let ref = Tuple{T, Val{T}} where T<:(Val{T} where T<:(Val{T} where T<:(Val{T} where T<:Val)))
    sig = Tuple{T, Val{T}} where T<:(Val{T} where T<:(Val{T} where T<:(Val{T} where T<:(Val{T} where T<:Val))))
    @test Core.Compiler.limit_type_size(sig, ref, Union{}, 100, 100) == Tuple{Val, Val}
    @test Core.Compiler.limit_type_size(ref, sig, Union{}, 100, 100) == ref
end

let t = Tuple{Ref{T},T,T} where T, c = Tuple{Ref, T, T} where T # #36407
    @test t <: Core.Compiler.limit_type_size(t, c, Union{}, 1, 100)
end

# obtain Vararg with 2 undefined fields
let va = ccall(:jl_type_intersection_with_env, Any, (Any, Any), Tuple{Tuple}, Tuple{Tuple{Vararg{Any, N}}} where N)[2][1]
    @test Core.Compiler.__limit_type_size(Tuple, va, Core.svec(va, Union{}), 2, 2) === Tuple
end

# issue #42835
@test !Core.Compiler.type_more_complex(Int, Any, Core.svec(), 1, 1, 1)
@test !Core.Compiler.type_more_complex(Int, Type{Int}, Core.svec(), 1, 1, 1)
@test !Core.Compiler.type_more_complex(Type{Int}, Any, Core.svec(), 1, 1, 1)
@test  Core.Compiler.type_more_complex(Type{Type{Int}}, Type{Int}, Core.svec(Type{Int}), 1, 1, 1)
@test  Core.Compiler.type_more_complex(Type{Type{Int}}, Int, Core.svec(Type{Int}), 1, 1, 1)
@test  Core.Compiler.type_more_complex(Type{Type{Int}}, Any, Core.svec(), 1, 1, 1)
@test  Core.Compiler.type_more_complex(Type{Type{Type{Int}}}, Type{Type{Int}}, Core.svec(Type{Type{Int}}), 1, 1, 1)

@test  Core.Compiler.type_more_complex(ComplexF32, Any, Core.svec(), 1, 1, 1)
@test !Core.Compiler.type_more_complex(ComplexF32, Any, Core.svec(Type{ComplexF32}), 1, 1, 1)
@test  Core.Compiler.type_more_complex(ComplexF32, Type{ComplexF32}, Core.svec(), 1, 1, 1)
@test !Core.Compiler.type_more_complex(Type{ComplexF32}, Any, Core.svec(Type{Type{ComplexF32}}), 1, 1, 1)
@test  Core.Compiler.type_more_complex(Type{ComplexF32}, Type{Type{ComplexF32}}, Core.svec(), 1, 1, 1)
@test !Core.Compiler.type_more_complex(Type{ComplexF32}, ComplexF32, Core.svec(), 1, 1, 1)
@test  Core.Compiler.type_more_complex(Type{ComplexF32}, Any, Core.svec(), 1, 1, 1)
@test  Core.Compiler.type_more_complex(Type{Type{ComplexF32}}, Type{ComplexF32}, Core.svec(Type{ComplexF32}), 1, 1, 1)
@test  Core.Compiler.type_more_complex(Type{Type{ComplexF32}}, ComplexF32, Core.svec(ComplexF32), 1, 1, 1)
@test  Core.Compiler.type_more_complex(Type{Type{Type{ComplexF32}}}, Type{Type{ComplexF32}}, Core.svec(Type{ComplexF32}), 1, 1, 1)

# n.b. Type{Type{Union{}} === Type{Core.TypeofBottom}
@test !Core.Compiler.type_more_complex(Type{Union{}}, Any, Core.svec(), 1, 1, 1)
@test !Core.Compiler.type_more_complex(Type{Type{Union{}}}, Any, Core.svec(), 1, 1, 1)
@test  Core.Compiler.type_more_complex(Type{Type{Type{Union{}}}}, Any, Core.svec(), 1, 1, 1)
@test  Core.Compiler.type_more_complex(Type{Type{Type{Union{}}}}, Type{Type{Union{}}}, Core.svec(Type{Type{Union{}}}), 1, 1, 1)
@test  Core.Compiler.type_more_complex(Type{Type{Type{Type{Union{}}}}}, Type{Type{Type{Union{}}}}, Core.svec(Type{Type{Type{Union{}}}}), 1, 1, 1)

@test !Core.Compiler.type_more_complex(Type{1}, Type{2}, Core.svec(), 1, 1, 1)
@test  Core.Compiler.type_more_complex(Type{Union{Float32,Float64}}, Union{Float32,Float64}, Core.svec(Union{Float32,Float64}), 1, 1, 1)
@test !Core.Compiler.type_more_complex(Type{Union{Float32,Float64}}, Union{Float32,Float64}, Core.svec(Union{Float32,Float64}), 0, 1, 1)
@test_broken Core.Compiler.type_more_complex(Type{<:Union{Float32,Float64}}, Type{Union{Float32,Float64}}, Core.svec(Union{Float32,Float64}), 1, 1, 1)
@test  Core.Compiler.type_more_complex(Type{<:Union{Float32,Float64}}, Any, Core.svec(Union{Float32,Float64}), 1, 1, 1)


let # 40336
    t = Type{Type{Int}}
    c = Type{Int}
    r = Core.Compiler.limit_type_size(t, c, c, 100, 100)
    @test t !== r && t <: r
end

@test Core.Compiler.unionlen(Union{}) == 1
@test Core.Compiler.unionlen(Int8) == 1
@test Core.Compiler.unionlen(Union{Int8, Int16}) == 2
@test Core.Compiler.unionlen(Union{Int8, Int16, Int32, Int64}) == 4
@test Core.Compiler.unionlen(Tuple{Union{Int8, Int16, Int32, Int64}}) == 1
@test Core.Compiler.unionlen(Union{Int8, Int16, Int32, T} where T) == 1

@test Core.Compiler.unioncomplexity(Union{}) == 0
@test Core.Compiler.unioncomplexity(Int8) == 0
@test Core.Compiler.unioncomplexity(Val{Union{Int8, Int16, Int32, Int64}}) == 0
@test Core.Compiler.unioncomplexity(Union{Int8, Int16}) == 1
@test Core.Compiler.unioncomplexity(Union{Int8, Int16, Int32, Int64}) == 3
@test Core.Compiler.unioncomplexity(Tuple{Union{Int8, Int16, Int32, Int64}}) == 3
@test Core.Compiler.unioncomplexity(Union{Int8, Int16, Int32, T} where T) == 3
@test Core.Compiler.unioncomplexity(Tuple{Val{T}, Union{Int8, Int16}, Int8} where T<:Union{Int8, Int16, Int32, Int64}) == 3
@test Core.Compiler.unioncomplexity(Tuple{Vararg{Tuple{Union{Int8, Int16}}}}) == 1
@test Core.Compiler.unioncomplexity(Tuple{Vararg{Symbol}}) == 0
@test Core.Compiler.unioncomplexity(Tuple{Vararg{Union{Symbol, Tuple{Vararg{Symbol}}}}}) == 1
@test Core.Compiler.unioncomplexity(Tuple{Vararg{Union{Symbol, Tuple{Vararg{Union{Symbol, Tuple{Vararg{Symbol}}}}}}}}) == 2
@test Core.Compiler.unioncomplexity(Tuple{Vararg{Union{Symbol, Tuple{Vararg{Union{Symbol, Tuple{Vararg{Union{Symbol, Tuple{Vararg{Symbol}}}}}}}}}}}) == 3


# PR 22120
function tmerge_test(a, b, r, commutative=true)
    @test r == Core.Compiler.tuplemerge(a, b)
    if commutative
        @test r == Core.Compiler.tuplemerge(b, a)
    else
        @test_broken r == Core.Compiler.tuplemerge(b, a)
    end
end
tmerge_test(Tuple{Int}, Tuple{String}, Tuple{Union{Int, String}})
tmerge_test(Tuple{Int}, Tuple{String, String}, Tuple)
tmerge_test(Tuple{Vararg{Int}}, Tuple{String}, Tuple)
tmerge_test(Tuple{Int}, Tuple{Int, Int},
    Tuple{Vararg{Int}})
tmerge_test(Tuple{Integer}, Tuple{Int, Int},
    Tuple{Vararg{Integer}})
tmerge_test(Tuple{}, Tuple{Int, Int},
    Tuple{Vararg{Int}})
tmerge_test(Tuple{}, Tuple{Complex},
    Tuple{Vararg{Complex}})
tmerge_test(Tuple{ComplexF32}, Tuple{ComplexF32, ComplexF64},
    Tuple{Vararg{Complex}})
tmerge_test(Tuple{Vararg{ComplexF32}}, Tuple{Vararg{ComplexF64}},
    Tuple{Vararg{Complex}})
tmerge_test(Tuple{}, Tuple{ComplexF32, Vararg{Union{ComplexF32, ComplexF64}}},
    Tuple{Vararg{Union{ComplexF32, ComplexF64}}})
tmerge_test(Tuple{ComplexF32}, Tuple{ComplexF32, Vararg{Union{ComplexF32, ComplexF64}}},
    Tuple{Vararg{Union{ComplexF32, ComplexF64}}})
tmerge_test(Tuple{ComplexF32, ComplexF32, ComplexF32}, Tuple{ComplexF32, Vararg{Union{ComplexF32, ComplexF64}}},
    Tuple{Vararg{Union{ComplexF32, ComplexF64}}})
tmerge_test(Tuple{}, Tuple{Union{ComplexF64, ComplexF32}, Vararg{Union{ComplexF32, ComplexF64}}},
    Tuple{Vararg{Union{ComplexF32, ComplexF64}}})
tmerge_test(Tuple{ComplexF64, ComplexF64, ComplexF32}, Tuple{Vararg{Union{ComplexF32, ComplexF64}}},
    Tuple{Vararg{Complex}}, false)
tmerge_test(Tuple{}, Tuple{Complex, Vararg{Union{ComplexF32, ComplexF64}}},
    Tuple{Vararg{Complex}})
@test Core.Compiler.tmerge(Tuple{}, Union{Nothing, Tuple{ComplexF32, ComplexF32}}) ==
    Union{Nothing, Tuple{}, Tuple{ComplexF32, ComplexF32}}
@test Core.Compiler.tmerge(Tuple{}, Union{Nothing, Tuple{ComplexF32}, Tuple{ComplexF32, ComplexF32}}) ==
    Union{Nothing, Tuple{Vararg{ComplexF32}}}
@test Core.Compiler.tmerge(Union{Nothing, Tuple{ComplexF32}}, Union{Nothing, Tuple{ComplexF32, ComplexF32}}) ==
    Union{Nothing, Tuple{ComplexF32}, Tuple{ComplexF32, ComplexF32}}
@test Core.Compiler.tmerge(Union{Nothing, Tuple{}, Tuple{ComplexF32}}, Union{Nothing, Tuple{ComplexF32, ComplexF32}}) ==
    Union{Nothing, Tuple{Vararg{ComplexF32}}}
@test Core.Compiler.tmerge(Vector{Int}, Core.Compiler.tmerge(Vector{String}, Vector{Bool})) ==
    Union{Vector{Bool}, Vector{Int}, Vector{String}}
@test Core.Compiler.tmerge(Vector{Int}, Core.Compiler.tmerge(Vector{String}, Union{Vector{Bool}, Vector{Symbol}})) == Vector
@test Core.Compiler.tmerge(Base.BitIntegerType, Union{}) === Base.BitIntegerType
@test Core.Compiler.tmerge(Union{}, Base.BitIntegerType) === Base.BitIntegerType
@test Core.Compiler.tmerge(Core.Compiler.InterConditional(1, Int, Union{}), Core.Compiler.InterConditional(2, String, Union{})) === Core.Compiler.Const(true)

struct SomethingBits
    x::Base.BitIntegerType
end
@test Base.return_types(getproperty, (SomethingBits, Symbol)) == Any[Base.BitIntegerType]


# issue 9770
@noinline x9770() = false
function f9770(x)
    return if x9770()
        g9770(:a, :foo)
    else
        x
    end
end
function g9770(x,y)
   return if isa(y, Symbol)
       f9770(x)
   else
       g9770(:a, :foo)
   end
end
@test g9770(:a, "c") === :a
@test g9770(:b, :c) === :b


# issue #1628
mutable struct I1628{X}
    x::X
end
let
    # here the potential problem is that the run-time value of static
    # parameter X in the I1628 constructor is (DataType,DataType),
    # but type inference will track it more accurately as
    # (Type{Integer}, Type{Int}).
    f1628() = I1628((Integer,Int))
    @test isa(f1628(), I1628{Tuple{DataType,DataType}})
end

let
    fT(x::T) where {T} = T
    @test fT(Any) === DataType
    @test fT(Int) === DataType
    @test fT(Type{Any}) === DataType
    @test fT(Type{Int}) === DataType

    ff(x::Type{T}) where {T} = T
    @test ff(Type{Any}) === Type{Any}
    @test ff(Type{Int}) === Type{Int}
    @test ff(Any) === Any
    @test ff(Int) === Int
end


# issue #3182
f3182(::Type{T}) where {T} = 0
f3182(x) = 1
function g3182(t::DataType)
    # tricky thing here is that DataType is a concrete type, and a
    # subtype of Type, but we cannot infer the T in Type{T} just
    # by knowing (at compile time) that the argument is a DataType.
    # however the ::Type{T} method should still match at run time.
    return f3182(t)
end
@test g3182(Complex.body) == 0


# issue #5906

abstract type Outer5906{T} end

struct Inner5906{T}
    a:: T
end

struct Empty5906{T} <: Outer5906{T}
end

struct Hanoi5906{T} <: Outer5906{T}
    a::T
    succ :: Outer5906{Inner5906{T}}
    Hanoi5906{T}(a) where T = new(a, Empty5906{Inner5906{T}}())
end

function f5906(h::Hanoi5906{T}) where T
    if isa(h.succ, Empty5906) return end
    f5906(h.succ)
end

# can cause infinite recursion in type inference via instantiation of
# the type of the `succ` field
@test f5906(Hanoi5906{Int}(1)) === nothing

# issue on the flight from DFW
# (type inference deducing Type{:x} rather than Symbol)
mutable struct FooBarDFW{s}; end
fooDFW(p::Type{FooBarDFW}) = string(p.parameters[1])
fooDFW(p) = string(p.parameters[1])
@test fooDFW(FooBarDFW{:x}) == "x" # not ":x"

# Type inference for tuple parameters
struct fooTuple{s}; end
barTuple1() = fooTuple{(:y,)}()
barTuple2() = fooTuple{tuple(:y)}()

@test Base.return_types(barTuple1,Tuple{})[1] == Base.return_types(barTuple2,Tuple{})[1] == fooTuple{(:y,)}

# issue #6050
@test Core.Compiler.getfield_tfunc(
          Dict{Int64,Tuple{UnitRange{Int64},UnitRange{Int64}}},
          Core.Compiler.Const(:vals)) == Array{Tuple{UnitRange{Int64},UnitRange{Int64}},1}

# assert robustness of `getfield_tfunc`
struct GetfieldRobustness
    field::String
end
@test Base.return_types((GetfieldRobustness,String,)) do obj, s
    t = (10, s) # to form `PartialStruct`
    getfield(obj, t)
end |> only === Union{}

# issue #12476
function f12476(a)
    (k, v) = a
    return v
end
@inferred f12476(1.0 => 1)


# issue #12551 (make sure these don't throw in inference)
Base.return_types(unsafe_load, (Ptr{nothing},))
Base.return_types(getindex, (Vector{nothing},))


# issue #12636
module MyColors

abstract type Paint{T} end
struct RGB{T<:AbstractFloat} <: Paint{T}
    r::T
    g::T
    b::T
end

myeltype(::Type{Paint{T}}) where {T} = T
myeltype(::Type{P}) where {P<:Paint} = myeltype(supertype(P))
myeltype(::Type{Any}) = Any

end

@test @inferred(MyColors.myeltype(MyColors.RGB{Float32})) == Float32
@test @inferred(MyColors.myeltype(MyColors.RGB)) == Any


# issue #12826
f12826(v::Vector{I}) where {I<:Integer} = v[1]
@test Base.return_types(f12826,Tuple{Array{I,1} where I<:Integer})[1] == Integer


# non-terminating inference, issue #14009
# non-terminating codegen, issue #16201
mutable struct A14009{T}; end
A14009(a::T) where {T} = A14009{T}()
f14009(a) = rand(Bool) ? f14009(A14009(a)) : a
code_typed(f14009, (Int,))
code_llvm(devnull, f14009, (Int,))

mutable struct B14009{T}; end
g14009(a) = g14009(B14009{a})
code_typed(g14009, (Type{Int},))
code_llvm(devnull, f14009, (Int,))


# issue #9232
arithtype9232(::Type{T},::Type{T}) where {T<:Real} = arithtype9232(T)
result_type9232(::Type{T1}, ::Type{T2}) where {T1<:Number,T2<:Number} = arithtype9232(T1, T2)
# this gave a "type too large", but not reliably
@test length(code_typed(result_type9232, Tuple{(Type{x} where x<:Union{Float32,Float64}), Type{T2} where T2<:Number})) == 1


# issue #10878
function g10878(x; kw...); end
invoke_g10878() = invoke(g10878, Tuple{Any}, 1)
code_typed(invoke_g10878, ())
code_llvm(devnull, invoke_g10878, ())


# issue #10930
@test isa(code_typed(promote,(Any,Any,Vararg{Any})), Array)
find_tvar10930(sig::Type{T}) where {T<:Tuple} = 1
function find_tvar10930(arg)
    if isa(arg, Type) && arg<:Tuple
        find_tvar10930(arg[random_var_name])
    end
    return 1
end
@test find_tvar10930(Vararg{Int}) === 1


# issue #12474
@generated function f12474(::Any)
    return :(for i in 1
        end)
end
let ast12474 = code_typed(f12474, Tuple{Float64})
    @test isdispatchelem(ast12474[1][2])
end


# pr #15259
struct A15259
    x
    y
end
# check that allocation was ellided
@eval f15259(x,y) = (a = $(Expr(:new, :A15259, :x, :y)); (a.x, a.y, getfield(a,1), getfield(a, 2)))
@test isempty(filter(x -> isa(x,Expr) && x.head === :(=) &&
                          isa(x.args[2], Expr) && x.args[2].head === :new,
                     code_typed(f15259, (Any,Int))[1][1].code))
@test f15259(1,2) == (1,2,1,2)
# check that error cases are still correct
@eval g15259(x,y) = (a = $(Expr(:new, :A15259, :x, :y)); a.z)
@test_throws ErrorException g15259(1,1)
@eval h15259(x,y) = (a = $(Expr(:new, :A15259, :x, :y)); getfield(a, 3))
@test_throws BoundsError h15259(1,1)


# issue #7810
mutable struct Foo7810{T<:AbstractVector}
    v::T
end
bar7810() = [Foo7810([(a,b) for a in 1:2]) for b in 3:4]
@test Base.return_types(bar7810,Tuple{})[1] == Array{Foo7810{Array{Tuple{Int,Int},1}},1}


# issue #11366
f11366(x::Type{Ref{T}}) where {T} = Ref{x}
@test !isconcretetype(Base.return_types(f11366, (Any,))[1])


let f(T) = Type{T}
    @test Base.return_types(f, Tuple{Type{Int}}) == [Type{Type{Int}}]
end

# issue #9222
function SimpleTest9222(pdedata, mu_actual::Vector{T1},
        nu_actual::Vector{T1}, v0::Vector{T1}, epsilon::T1, beta::Vector{T1},
        delta::T1, l::T1, R::T1, s0::T1, show_trace::Bool = true) where T1<:Real
    return 0.0
end
function SimpleTest9222(pdedata, mu_actual::Vector{T1},
        nu_actual::Vector{T1}, v0::Vector{T1}, epsilon::T1, beta::Vector{T1},
        delta::T1, l::T1, R::T1) where T1<:Real
    return SimpleTest9222(pdedata, mu_actual, nu_actual, v0, epsilon,
        beta, delta, l, R, v0[1])
end
function foo9222()
    v0 = rand(10)
    mu_actual = rand(10)
    nu_actual = rand(10)
    SimpleTest9222(0.0, mu_actual, nu_actual, v0, 0.0, [1.0,1.0], 0.5, 5.0, 20.0)
end
@test 0.0 == foo9222()

# branching based on inferrable conditions
let f(x) = isa(x,Int) ? 1 : ""
    @test Base.return_types(f, Tuple{Int}) == [Int]
end

let g() = Int <: Real ? 1 : ""
    @test Base.return_types(g, Tuple{}) == [Int]
end

const NInt{N} = Tuple{Vararg{Int, N}}
const NInt1{N} = Tuple{Int, Vararg{Int, N}}
@test Base.eltype(NInt) === Int
@test Base.eltype(NInt1) === Int
@test Base.eltype(NInt{0}) === Union{}
@test Base.eltype(NInt{1}) === Int
@test Base.eltype(NInt1{0}) === Int
@test Base.eltype(NInt1{1}) === Int
fNInt(x::NInt) = (x...,)
gNInt() = fNInt(x)
@test Base.return_types(gNInt, ()) == Any[NInt]
@test Base.return_types(eltype, (NInt,)) == Any[Union{Type{Int}, Type{Union{}}}] # issue 21763

# issue #17572
function f17572(::Type{Val{A}}) where A
    return Tuple{Int}(Tuple{A}((1,)))
end
# test that inference doesn't error
@test isa(code_typed(f17572, (Type{Val{0}},)), Array)

# === with singleton constants
let f(x) = (x===nothing) ? 1 : 1.0
    @test Base.return_types(f, (Nothing,)) == Any[Int]
end

# issue #16530
mutable struct Foo16530a{dim}
    c::Vector{NTuple{dim, Float64}}
    d::Vector
end
mutable struct Foo16530b{dim}
    c::Vector{NTuple{dim, Float64}}
end
f16530a() = fieldtype(Foo16530a, :c)
f16530a(c) = fieldtype(Foo16530a, c)
f16530b() = fieldtype(Foo16530b, :c)
f16530b(c) = fieldtype(Foo16530b, c)

let T = Vector{Tuple{Vararg{Float64,dim}}} where dim
    @test f16530a() == T
    @test f16530a(:c) == T
    @test Base.return_types(f16530a, ()) == Any[Type{T}]
    @test Base.return_types(f16530b, ()) == Any[Type{T}]
    @test Base.return_types(f16530b, (Symbol,)) == Any[Type{T}]
end
@test f16530a(:d) == Vector

let T1 = Tuple{Int, Float64},
    T2 = Tuple{Int, Float32},
    T = Tuple{T1, T2}

    global f18037
    f18037() = fieldtype(T, 1)
    f18037(i) = fieldtype(T, i)

    @test f18037() === T1
    @test f18037(1) === T1
    @test f18037(2) === T2

    @test Base.return_types(f18037, ()) == Any[Type{T1}]
    @test Base.return_types(f18037, (Int,)) == Any[Union{Type{T1},Type{T2}}]
end

# issue #18015
mutable struct Triple18015
    a::Int
    b::Int
    c::Int
end
a18015(tri) = tri.a
b18015(tri) = tri.b
c18015(tri) = tri.c
setabc18015!(tri, a, b, c) = (tri.a = a; tri.b = b; tri.c = c)
let tri = Triple18015(1, 2, 3)
    setabc18015!(tri, b18015(tri), c18015(tri), a18015(tri))
    @test tri.a === 2 && tri.b === 3 && tri.c === 1
end

# issue #18222
f18222(::Union{T, Int}) where {T<:AbstractFloat} = false
f18222(x) = true
g18222(x) = f18222(x)
@test f18222(1) == g18222(1) == false
@test f18222(1.0) == g18222(1.0) == false

# issue #18399
# TODO: this test is rather brittle
mutable struct TSlow18399{T}
    x::T
end
function hvcat18399(as)
    cb = ri->as[ri]
    g = Base.Generator(cb, 1)
    return g.f(1)
end
function cat_t18399(X...)
    for i = 2:1
        X[i]
        d->i
    end
end
C18399 = TSlow18399{Int}(1)
GB18399 = TSlow18399{Int}(1)
function test18399(C)
    B = GB18399::Union{TSlow18399{Int},TSlow18399{Any}}
    cat_t18399()
    cat_t18399(B, B, B)
    hvcat18399((C,))
    return hvcat18399(((2, 3),))
end
@test test18399(C18399) == (2, 3)

# issue #18450
f18450() = ifelse(true, Tuple{Vararg{Int}}, Tuple{Vararg})
@test f18450() == Tuple{Vararg{Int}}

# issue #18569
@test !Core.Compiler.isconstType(Type{Tuple})

# ensure pure attribute applies correctly to all signatures of fpure
Base.@pure function fpure(a=rand(); b=rand())
    # use the `rand` function since it is known to be `@inline`
    # but would be too big to inline
    return a + b + rand()
end
gpure() = fpure()
gpure(x::Irrational) = fpure(x)
@test which(fpure, ()).pure
@test which(fpure, (typeof(pi),)).pure
@test !which(gpure, ()).pure
@test !which(gpure, (typeof(pi),)).pure
@test code_typed(gpure, ())[1][1].pure
@test code_typed(gpure, (typeof(π),))[1][1].pure
@test gpure() == gpure() == gpure()
@test gpure(π) == gpure(π) == gpure(π)

# Make sure @pure works for functions using the new syntax
Base.@pure (fpure2(x::T) where T) = T
@test which(fpure2, (Int64,)).pure

# issue #10880
function cat10880(a, b)
    Tuple{a.parameters..., b.parameters...}
end
@inferred cat10880(Tuple{Int8,Int16}, Tuple{Int32})

# issue #19348
function is_typed_expr(e::Expr)
    if e.head === :call ||
       e.head === :invoke ||
       e.head === :new ||
       e.head === :copyast ||
       e.head === :inert
        return true
    end
    return false
end
is_typed_expr(@nospecialize other) = false
test_inferred_static(@nospecialize(other)) = true
test_inferred_static(slot::TypedSlot) = @test isdispatchelem(slot.typ)
function test_inferred_static(expr::Expr)
    for a in expr.args
        test_inferred_static(a)
    end
end
function test_inferred_static(arrow::Pair, all_ssa)
    code, rt = arrow
    @test isdispatchelem(rt)
    @test code.inferred
    for i = 1:length(code.code)
        e = code.code[i]
        test_inferred_static(e)
        if all_ssa && is_typed_expr(e)
            @test isdispatchelem(code.ssavaluetypes[i])
        end
    end
end

function f18679()
    local a
    for i = 1:2
        if i == 1
            a = ((),)
        else
            return a[1]
        end
    end
    error()
end
g18679(x::Tuple) = ()
g18679() = g18679(any_undef_global::Union{Int, Tuple{}})
function h18679()
    for i = 1:2
        local a
        if i == 1
            a = ((),)
        else
            @isdefined(a) && return "BAD"
        end
    end
end

function g19348(x)
    a, b = x
    g = 1
    g = 2
    c = Base.indexed_iterate(x, g, g)
    return a + b + c[1]
end

for (codetype, all_ssa) in Any[
        (code_typed(f18679, ())[1], true),
        (code_typed(g18679, ())[1], false),
        (code_typed(h18679, ())[1], true),
        (code_typed(g19348, (typeof((1, 2.0)),))[1], true)]
    code = codetype[1]
    local notconst(@nospecialize(other)) = true
    notconst(slot::TypedSlot) = @test isa(slot.typ, Type)
    function notconst(expr::Expr)
        for a in expr.args
            notconst(a)
        end
    end
    local i
    for i = 1:length(code.code)
        e = code.code[i]
        notconst(e)
        typ = code.ssavaluetypes[i]
        typ isa Core.Compiler.MaybeUndef && (typ = typ.typ)
        @test isa(typ, Type) || isa(typ, Const) || isa(typ, Conditional) || typ
    end
    test_inferred_static(codetype, all_ssa)
end
@test f18679() === ()
@test_throws UndefVarError(:any_undef_global) g18679()
@test h18679() === nothing


# issue #5575: inference with abstract types on a reasonably complex method tree
zeros5575(::Type{T}, dims::Tuple{Vararg{Any,N}}) where {T,N} = Array{T,N}(undef, dims)
zeros5575(dims::Tuple) = zeros5575(Float64, dims)
zeros5575(::Type{T}, dims...) where {T} = zeros5575(T, dims)
zeros5575(a::AbstractArray) = zeros5575(a, Float64)
zeros5575(a::AbstractArray, ::Type{T}) where {T} = zeros5575(a, T, size(a))
zeros5575(a::AbstractArray, ::Type{T}, dims::Tuple) where {T} = zeros5575(T, dims)
zeros5575(a::AbstractArray, ::Type{T}, dims...) where {T} = zeros5575(T, dims)
zeros5575(dims...) = zeros5575(dims)
f5575() = zeros5575(Type[Float64][1], 1)
@test Base.return_types(f5575, ())[1] == Vector

g5575() = zeros(Type[Float64][1], 1)
@test Base.return_types(g5575, ())[1] == Vector


# make sure Tuple{unknown} handles the possibility that `unknown` is a Vararg
function maybe_vararg_tuple_1()
    x = Any[Vararg{Int}][1]
    Tuple{x}
end
@test Type{Tuple{Vararg{Int}}} <: Base.return_types(maybe_vararg_tuple_1, ())[1]
function maybe_vararg_tuple_2()
    x = [Vararg{Int}][1]
    Tuple{x}
end
@test Type{Tuple{Vararg{Int}}} <: Base.return_types(maybe_vararg_tuple_2, ())[1]

# inference of `fieldtype`
mutable struct UndefField__
    x::Union{}
end
f_infer_undef_field() = fieldtype(UndefField__, :x)
@test Base.return_types(f_infer_undef_field, ()) == Any[Type{Union{}}]
@test f_infer_undef_field() === Union{}

mutable struct HasAbstractlyTypedField
    x::Union{Int,String}
end
f_infer_abstract_fieldtype() = fieldtype(HasAbstractlyTypedField, :x)
@test Base.return_types(f_infer_abstract_fieldtype, ()) == Any[Type{Union{Int,String}}]
let fieldtype_tfunc = Core.Compiler.fieldtype_tfunc,
    fieldtype_nothrow = Core.Compiler.fieldtype_nothrow
    @test fieldtype_tfunc(Union{}, :x) == Union{}
    @test fieldtype_tfunc(Union{Type{Int32}, Int32}, Const(:x)) == Union{}
    @test fieldtype_tfunc(Union{Type{Base.RefValue{T}}, Type{Int32}} where {T<:Array}, Const(:x)) == Type{<:Array}
    @test fieldtype_tfunc(Union{Type{Base.RefValue{T}}, Type{Int32}} where {T<:Real}, Const(:x)) == Type{<:Real}
    @test fieldtype_tfunc(Union{Type{Base.RefValue{<:Array}}, Type{Int32}}, Const(:x)) == Type{Array}
    @test fieldtype_tfunc(Union{Type{Base.RefValue{<:Real}}, Type{Int32}}, Const(:x)) == Const(Real)
    @test fieldtype_tfunc(Const(Union{Base.RefValue{<:Real}, Type{Int32}}), Const(:x)) == Const(Real)
    @test fieldtype_tfunc(Type{Union{Base.RefValue{T}, Type{Int32}}} where {T<:Real}, Const(:x)) == Type{<:Real}
    @test fieldtype_tfunc(Type{<:Tuple}, Const(1)) == Any
    @test fieldtype_tfunc(Type{<:Tuple}, Any) == Any
    @test fieldtype_nothrow(Type{Base.RefValue{<:Real}}, Const(:x))
    @test !fieldtype_nothrow(Type{Union{}}, Const(:x))
    @test !fieldtype_nothrow(Union{Type{Base.RefValue{T}}, Int32} where {T<:Real}, Const(:x))
    @test !fieldtype_nothrow(Union{Type{Base.RefValue{<:Real}}, Int32}, Const(:x))
    @test fieldtype_nothrow(Const(Union{Base.RefValue{<:Real}, Int32}), Const(:x))
    @test !fieldtype_nothrow(Type{Union{Base.RefValue{T}, Int32}} where {T<:Real}, Const(:x)) # improvable?
    @test fieldtype_nothrow(Union{Type{Base.RefValue{T}}, Type{Base.RefValue{Any}}} where {T<:Real}, Const(:x))
    @test fieldtype_nothrow(Union{Type{Base.RefValue{<:Real}}, Type{Base.RefValue{Any}}}, Const(:x))
    @test fieldtype_nothrow(Const(Union{Base.RefValue{<:Real}, Base.RefValue{Any}}), Const(:x))
    @test fieldtype_nothrow(Type{Union{Base.RefValue{T}, Base.RefValue{Any}}} where {T<:Real}, Const(:x))
    @test !fieldtype_nothrow(Type{Tuple{}}, Const(1))
    @test fieldtype_nothrow(Type{Tuple{Int}}, Const(1))
    @test fieldtype_nothrow(Type{Tuple{Vararg{Int}}}, Const(1))
    @test fieldtype_nothrow(Type{Tuple{Vararg{Int}}}, Const(2))
    @test fieldtype_nothrow(Type{Tuple{Vararg{Int}}}, Const(42))
    @test !fieldtype_nothrow(Type{<:Tuple{Vararg{Int}}}, Const(1))
    @test TypeVar <: fieldtype_tfunc(Any, Any)
end

# issue #11480
@noinline f11480(x,y) = x
let A = Ref
    function h11480(x::A{A{A{A{A{A{A{A{A{Int}}}}}}}}}) # enough for type_too_complex
        y :: Tuple{Vararg{typeof(x)}} = (x,) # apply_type(Vararg, too_complex) => TypeVar(_,Vararg)
        f(y[1], # fool getfield logic : Tuple{_<:Vararg}[1] => Vararg
          1) # make it crash by construction of the signature Tuple{Vararg,Int}
    end
    @test !Base.isvarargtype(Base.return_types(h11480, (Any,))[1])
end

# Issue 19641
foo19641() = let a = 1.0
    Core.Compiler.return_type(x -> x + a, Tuple{Float64})
end
@inferred foo19641()

test_fast_eq(a, b) = @fastmath a == b
test_fast_ne(a, b) = @fastmath a != b
test_fast_lt(a, b) = @fastmath a < b
test_fast_le(a, b) = @fastmath a <= b
@inferred test_fast_eq(1f0, 1f0)
@inferred test_fast_ne(1f0, 1f0)
@inferred test_fast_lt(1f0, 1f0)
@inferred test_fast_le(1f0, 1f0)
@inferred test_fast_eq(1.0, 1.0)
@inferred test_fast_ne(1.0, 1.0)
@inferred test_fast_lt(1.0, 1.0)
@inferred test_fast_le(1.0, 1.0)

abstract type AbstractMyType18457{T,F,G} end
struct MyType18457{T,F,G}<:AbstractMyType18457{T,F,G} end
tpara18457(::Type{AbstractMyType18457{I}}) where {I} = I
tpara18457(::Type{A}) where {A<:AbstractMyType18457} = tpara18457(supertype(A))
@test tpara18457(MyType18457{true}) === true

@testset "type inference error #19322" begin
    Y_19322 = reshape(round.(Int, abs.(randn(5*1000))) .+ 1, 1000, 5)

    function FOO_19322(Y::AbstractMatrix; frac::Float64=0.3, nbins::Int=100, n_sims::Int=100)
        num_iters, num_chains = size(Y)
        start_iters = unique([1; map(s->round(Int64, exp10(s)), range(log(10,100),
                                                                      stop=log(10,num_iters/2),
                                                                      length=nbins-1))])
        result = zeros(Float64, 10, length(start_iters) * num_chains)
        j=1
        for c in 1:num_chains
            for st in 1:length(start_iters)
                n = length(start_iters[st]:num_iters)
                idx1 = start_iters[st]:round(Int64, start_iters[st] + frac * n - 1)
                idx2 = round(Int64, num_iters - frac * n + 1):num_iters
                y1 = Y[idx1,c]
                y2 = Y[idx2,c]
                n_min = min(length(y1), length(y2))
                X = [y1[1:n_min] y2[(end - n_min + 1):end]]
            end
        end
    end

    @test_nowarn FOO_19322(Y_19322)
end

randT_inferred_union() = rand(Bool) ? rand(Bool) ? 1 : 2.0 : nothing
function f_inferred_union()
    b = randT_inferred_union()
    if !(nothing !== b) === true
        return f_inferred_union_nothing(b)
    elseif (isa(b, Float64) === true) !== false
        return f_inferred_union_float(b)
    else
        return f_inferred_union_int(b)
    end
end
f_inferred_union_nothing(::Nothing) = 1
f_inferred_union_nothing(::Any) = "broken"
f_inferred_union_float(::Float64) = 2
f_inferred_union_float(::Any) = "broken"
f_inferred_union_int(::Int) = 3
f_inferred_union_int(::Any) = "broken"
@test @inferred(f_inferred_union()) in (1, 2, 3)

# issue #11015
mutable struct AT11015
    f::Union{Bool,Function}
end

g11015(::Type{S}, ::S) where {S} = 1
f11015(a::AT11015) = g11015(Base.fieldtype(typeof(a), :f), true)
g11015(::Type{Bool}, ::Bool) = 2.0
@test Base.return_types(f11015, (AT11015,)) == Any[Int]
@test f11015(AT11015(true)) === 1

# better inference of apply (#20343)
f20343(::String, ::Int) = 1
f20343(::Int, ::String, ::Int, ::Int) = 2
f20343(::Int, ::Int, ::String, ::Int, ::Int, ::Int) = 3
f20343(::Int, ::Int, ::Int, ::String, ::Int, ::Int, ::Int, ::Int, ::Int, ::Int, ::Int, ::Int) = 4
f20343(::Union{Int,String}...) = Int8(5)
f20343(::Any...) = "no"
function g20343()
    n = rand(1:3)
    T = Union{Tuple{String, Int}, Tuple{Int, String, Int, Int}, Tuple{Int, Int, String, Int, Int, Int}}
    i = ntuple(i -> n == i ? "" : 0, 2n)::T
    f20343(i...)
end
@test Base.return_types(g20343, ()) == [Int]
function h20343()
    n = rand(1:3)
    T = Union{Tuple{String, Int, Int}, Tuple{Int, String, Int}, Tuple{Int, Int, String}}
    i = ntuple(i -> n == i ? "" : 0, 3)::T
    f20343(i..., i..., i..., i...)
end
@test Base.return_types(h20343, ()) == [Union{Int8, Int}]
function i20343()
    f20343([1,2,3]..., 4)
end
@test Base.return_types(i20343, ()) == [Int8]
struct Foo20518 <: AbstractVector{Int}; end # issue #20518; inference assumed AbstractArrays
Base.getindex(::Foo20518, ::Int) = "oops"      # not to lie about their element type
Base.axes(::Foo20518) = (Base.OneTo(4),)
foo20518(xs::Any...) = -1
foo20518(xs::Int...) = [0]
bar20518(xs) = sum(foo20518(xs...))
@test bar20518(Foo20518()) == -1
f19957(::Int) = Int8(1)            # issue #19957, inference failure when splatting a number
f19957(::Int...) = Int16(1)
f19957(::Any...) = "no"
g19957(x) = f19957(x...)
@test Base.return_types(g19957, (Int,)) == Any[Int8]

# Inference for some type-level computation
fUnionAll(::Type{T}) where {T} = Type{S} where S <: T
@inferred fUnionAll(Real) == Type{T} where T <: Real
@inferred fUnionAll(Rational{T} where T <: AbstractFloat) == Type{T} where T<:(Rational{S} where S <: AbstractFloat)

# issue #20733
# run this test in a separate process to avoid interfering with `getindex`
let def = "Base.getindex(t::NTuple{3,NTuple{2,Int}}, i::Int, j::Int, k::Int) = (t[1][i], t[2][j], t[3][k])"
    @test read(`$(Base.julia_cmd()) --startup-file=no -E "$def;test(t) = t[2,1,2];test(((3,4), (5,6), (7,8)))"`, String) ==
        "(4, 5, 8)\n"
end

# issue #20267
mutable struct T20267{T}
    inds::Vector{T}
end
# infinite type growth via lower bounds (formed by intersection)
f20267(x::T20267{T}, y::T) where (T) = f20267(Any[1][1], x.inds)
@test Base.return_types(f20267, (Any, Any)) == Any[Union{}]

# issue #20704
f20704(::Int) = 1
Base.@pure b20704(@nospecialize(x)) = f20704(x)
@test b20704(42) === 1
@test_throws MethodError b20704(42.0)

bb20704() = b20704(Any[1.0][1])
@test_throws MethodError bb20704()

v20704() = Val{b20704(Any[1.0][1])}
@test_throws MethodError v20704()
@test Base.return_types(v20704, ()) == Any[Type{Val{1}}]

Base.@pure g20704(::Int) = 1
h20704(@nospecialize(x)) = g20704(x)
@test g20704(1) === 1
@test_throws MethodError h20704(1.2)

Base.@pure c20704() = (f20704(1.0); 1)
d20704() = c20704()
@test_throws MethodError d20704()

Base.@pure function a20704(x)
    rand()
    42
end
aa20704(x) = x(nothing)
@test code_typed(aa20704, (typeof(a20704),))[1][1].pure

#issue #21065, elision of _apply_iterate when splatted expression is not effect_free
function f21065(x,y)
    println("x=$x, y=$y")
    return x, y
end
g21065(x,y) = +(f21065(x,y)...)
function test_no_apply(expr::Expr)
    return all(test_no_apply, expr.args)
end
function test_no_apply(ref::GlobalRef)
    return ref.mod != Core || ref.name !== :_apply_iterate
end
test_no_apply(::Any) = true
@test all(test_no_apply, code_typed(g21065, Tuple{Int,Int})[1].first.code)

# issue #20033
# check return_type_tfunc for calls where no method matches
bcast_eltype_20033(f, A) = Core.Compiler.return_type(f, Tuple{eltype(A)})
err20033(x::Float64...) = prod(x)
@test bcast_eltype_20033(err20033, [1]) === Union{}
@test Base.return_types(bcast_eltype_20033, (typeof(err20033), Vector{Int},)) == Any[Type{Union{}}]
# return_type on builtins
@test Core.Compiler.return_type(tuple, Tuple{Int,Int8,Int}) === Tuple{Int,Int8,Int}

# issue #21088
@test Core.Compiler.return_type(typeof, Tuple{Int}) == Type{Int}

# Inference of constant svecs
@eval fsvecinf() = $(QuoteNode(Core.svec(Tuple{Int,Int}, Int)))[1]
@test Core.Compiler.return_type(fsvecinf, Tuple{}) == Type{Tuple{Int,Int}}

# nfields tfunc on `DataType`
let f = ()->Val{nfields(DataType[Int][1])}
    @test f() == Val{length(DataType.types)}
end

# inference on invalid getfield call
@eval _getfield_with_string_() = getfield($(1=>2), "")
@test Base.return_types(_getfield_with_string_, ()) == Any[Union{}]

# inference AST of a constant return value
f21175() = 902221
@test code_typed(f21175, ())[1].second === Int
# call again, so that the AST is built on-demand
let e = code_typed(f21175, ())[1].first.code[1]::ReturnNode
    @test e.val ∈ (902221, Core.QuoteNode(902221))
end

# issue #10207
mutable struct T10207{A, B}
    a::A
    b::B
end
@test code_typed(T10207, (Int,Any))[1].second == T10207{Int,T} where T

# issue #21410
f21410(::V, ::Pair{V,E}) where {V, E} = E
@test code_typed(f21410, Tuple{Ref, Pair{Ref{T},Ref{T}} where T<:Number})[1].second ==
    Type{E} where E <: (Ref{T} where T<:Number)

# issue #21369
function inf_error_21369(arg)
    if arg
        # invalid instantiation, causing throw during inference
        Complex{String}
    end
end
function break_21369()
    try
        error("uhoh")
    catch
        eval(:(inf_error_21369(false)))
        bt = catch_backtrace()
        i = 1
        local fr
        while true
            fr = Base.StackTraces.lookup(bt[i])[end]
            if !fr.from_c && fr.func !== :error
                break
            end
            i += 1
        end
        @test fr.func === :break_21369
        rethrow()
    end
end
@test_throws ErrorException break_21369()  # not TypeError

# issue #17003
abstract type AArray_17003{T,N} end
AVector_17003{T} = AArray_17003{T,1}

struct Nable_17003{T}
end

struct NArray_17003{T,N} <: AArray_17003{Nable_17003{T},N}
end

NArray_17003(::Array{T,N}) where {T,N} = NArray_17003{T,N}()

gl_17003 = [1, 2, 3]

f2_17003(item::AVector_17003) = nothing
f2_17003(::Any) = f2_17003(NArray_17003(gl_17003))

@test f2_17003(1) == nothing

# issue #20847
function segfaultfunction_20847(A::Vector{NTuple{N, T}}) where {N, T}
    B = reshape(reinterpret(T, A), (N, length(A)))
    return nothing
end

tuplevec_20847 = Tuple{Float64, Float64}[(0.0,0.0), (1.0,0.0)]

for A in (1,)
    @test segfaultfunction_20847(tuplevec_20847) == nothing
end

# Issue #20902, check that this doesn't error.
@generated function test_20902()
    quote
        10 + 11
    end
end
@test length(code_typed(test_20902, (), optimize = false)) == 1
@test length(code_typed(test_20902, (), optimize = false)) == 1

# normalization of arguments with constant Types as parameters
g21771(T) = T
f21771(::Val{U}) where {U} = Tuple{g21771(U)}
@test @inferred(f21771(Val{Int}())) === Tuple{Int}
@test @inferred(f21771(Val{Union{}}())) === Tuple{Union{}}
@test @inferred(f21771(Val{Integer}())) === Tuple{Integer}

# PR #28284, check that constants propagate through calls to new
struct t28284
  x::Int
end
f28284() = Val(t28284(1))
@inferred f28284()

# ...even if we have a non-bitstype
struct NonBitstype
    a::NTuple{N, Int} where N
    b::NTuple{N, Int} where N
end
function fNonBitsTypeConstants()
    val = NonBitstype((1,2),(3,4))
    Val((val.a[1],val.b[2]))
end
@test @inferred(fNonBitsTypeConstants()) === Val((1,4))

# missing method should be inferred as Union{}, ref https://github.com/JuliaLang/julia/issues/20033#issuecomment-282228948
@test Base.return_types(f -> f(1), (typeof((x::String) -> x),)) == Any[Union{}]

# issue #21653
# ensure that we don't try to resolve cycles using uncached edges
# but which also means we should still be storing the inference result from inferring the cycle
f21653() = f21653()
@test code_typed(f21653, Tuple{}, optimize=false)[1] isa Pair{CodeInfo, typeof(Union{})}
let meth = which(f21653, ())
    tt = Tuple{typeof(f21653)}
    mi = ccall(:jl_specializations_lookup, Any, (Any, Any), meth, tt)::Core.MethodInstance
    @test mi.cache.rettype === Union{}
end

# issue #22290
f22290() = return 3
for i in 1:3
    ir = sprint(io -> code_llvm(io, f22290, Tuple{}))
    @test occursin("julia_f22290", ir)
end

# constant inference of isdefined
let f(x) = isdefined(x, 2) ? 1 : ""
    @test Base.return_types(f, (Tuple{Int,Int},)) == Any[Int]
    @test Base.return_types(f, (Tuple{Int,},)) == Any[String]
end
let f(x) = isdefined(x, :re) ? 1 : ""
    @test Base.return_types(f, (ComplexF32,)) == Any[Int]
    @test Base.return_types(f, (Complex,)) == Any[Int]
end
let f(x) = isdefined(x, :NonExistentField) ? 1 : ""
    @test Base.return_types(f, (ComplexF32,)) == Any[String]
    @test Union{Int,String} <: Base.return_types(f, (AbstractArray,))[1]
end
import Core.Compiler: isdefined_tfunc
@test isdefined_tfunc(ComplexF32, Const(())) === Union{}
@test isdefined_tfunc(ComplexF32, Const(1)) === Const(true)
@test isdefined_tfunc(ComplexF32, Const(2)) === Const(true)
@test isdefined_tfunc(ComplexF32, Const(3)) === Const(false)
@test isdefined_tfunc(ComplexF32, Const(0)) === Const(false)
mutable struct SometimesDefined
    x
    function SometimesDefined()
        v = new()
        if rand(Bool)
            v.x = 0
        end
        return v
    end
end
@test isdefined_tfunc(SometimesDefined, Const(:x)) == Bool
@test isdefined_tfunc(SometimesDefined, Const(:y)) === Const(false)
@test isdefined_tfunc(Const(Base), Const(:length)) === Const(true)
@test isdefined_tfunc(Const(Base), Symbol) == Bool
@test isdefined_tfunc(Const(Base), Const(:NotCurrentlyDefinedButWhoKnows)) == Bool
@test isdefined_tfunc(Core.SimpleVector, Const(1)) === Const(false)
@test Const(false) ⊑ isdefined_tfunc(Const(:x), Symbol)
@test Const(false) ⊑ isdefined_tfunc(Const(:x), Const(:y))
@test isdefined_tfunc(Vector{Int}, Const(1)) == Const(false)
@test isdefined_tfunc(Vector{Any}, Const(1)) == Const(false)
@test isdefined_tfunc(Module, Int) === Union{}
@test isdefined_tfunc(Tuple{Any,Vararg{Any}}, Const(0)) === Const(false)
@test isdefined_tfunc(Tuple{Any,Vararg{Any}}, Const(1)) === Const(true)
@test isdefined_tfunc(Tuple{Any,Vararg{Any}}, Const(2)) === Bool
@test isdefined_tfunc(Tuple{Any,Vararg{Any}}, Const(3)) === Bool
@testset "isdefined check for `NamedTuple`s" begin
    # concrete `NamedTuple`s
    @test isdefined_tfunc(NamedTuple{(:x,:y),Tuple{Int,Int}}, Const(:x)) === Const(true)
    @test isdefined_tfunc(NamedTuple{(:x,:y),Tuple{Int,Int}}, Const(:y)) === Const(true)
    @test isdefined_tfunc(NamedTuple{(:x,:y),Tuple{Int,Int}}, Const(:z)) === Const(false)
    # non-concrete `NamedTuple`s
    @test isdefined_tfunc(NamedTuple{(:x,:y),<:Tuple{Int,Any}}, Const(:x)) === Const(true)
    @test isdefined_tfunc(NamedTuple{(:x,:y),<:Tuple{Int,Any}}, Const(:y)) === Const(true)
    @test isdefined_tfunc(NamedTuple{(:x,:y),<:Tuple{Int,Any}}, Const(:z)) === Const(false)
end
struct UnionIsdefinedA; x; end
struct UnionIsdefinedB; x; end
@test isdefined_tfunc(Union{UnionIsdefinedA,UnionIsdefinedB}, Const(:x)) === Const(true)
@test isdefined_tfunc(Union{UnionIsdefinedA,UnionIsdefinedB}, Const(:y)) === Const(false)
@test isdefined_tfunc(Union{UnionIsdefinedA,Nothing}, Const(:x)) === Bool

@noinline map3_22347(f, t::Tuple{}) = ()
@noinline map3_22347(f, t::Tuple) = (f(t[1]), map3_22347(f, Base.tail(t))...)
# issue #22347
let niter = 0
    map3_22347((1, 2, 3, 4)) do y
        niter += 1
        nothing
    end
    @test niter == 4
end

# issue #22875

typeargs = Tuple{Type{Int},}
@test Base.Core.Compiler.return_type((args...) -> one(args...), typeargs) === Int

typeargs = Tuple{Type{Int},Type{Int},Type{Int},Type{Int},Type{Int},Type{Int}}
@test Base.Core.Compiler.return_type(promote_type, typeargs) === Type{Int}

# demonstrate that inference must converge
# while doing constant propagation
Base.@pure plus1(x) = x + 1
f21933(x::Val{T}) where {T} = f(Val(plus1(T)))
code_typed(f21933, (Val{1},))
Base.return_types(f21933, (Val{1},))

function count_specializations(method::Method)
    specs = method.specializations
    n = count(i -> isassigned(specs, i), 1:length(specs))
    return n
end

# demonstrate that inference can complete without waiting for MAX_TYPE_DEPTH
copy_dims_out(out) = ()
copy_dims_out(out, dim::Int, tail...) =  copy_dims_out((out..., dim), tail...)
copy_dims_out(out, dim::Colon, tail...) = copy_dims_out((out..., dim), tail...)
@test Base.return_types(copy_dims_out, (Tuple{}, Vararg{Union{Int,Colon}})) == Any[Tuple{}, Tuple{}, Tuple{}]
@test all(m -> 4 < count_specializations(m) < 15, methods(copy_dims_out)) # currently about 5

copy_dims_pair(out) = ()
copy_dims_pair(out, dim::Int, tail...) =  copy_dims_pair(out => dim, tail...)
copy_dims_pair(out, dim::Colon, tail...) = copy_dims_pair(out => dim, tail...)
@test Base.return_types(copy_dims_pair, (Tuple{}, Vararg{Union{Int,Colon}})) == Any[Tuple{}, Tuple{}, Tuple{}]
@test all(m -> 5 < count_specializations(m) < 15, methods(copy_dims_pair)) # currently about 7

@test isdefined_tfunc(typeof(NamedTuple()), Const(0)) === Const(false)
@test isdefined_tfunc(typeof(NamedTuple()), Const(1)) === Const(false)
@test isdefined_tfunc(typeof((a=1,b=2)), Const(:a)) === Const(true)
@test isdefined_tfunc(typeof((a=1,b=2)), Const(:b)) === Const(true)
@test isdefined_tfunc(typeof((a=1,b=2)), Const(:c)) === Const(false)
@test isdefined_tfunc(typeof((a=1,b=2)), Const(0)) === Const(false)
@test isdefined_tfunc(typeof((a=1,b=2)), Const(1)) === Const(true)
@test isdefined_tfunc(typeof((a=1,b=2)), Const(2)) === Const(true)
@test isdefined_tfunc(typeof((a=1,b=2)), Const(3)) === Const(false)
@test isdefined_tfunc(NamedTuple, Const(1)) == Bool
@test isdefined_tfunc(NamedTuple, Symbol) == Bool
@test Const(false) ⊑ isdefined_tfunc(NamedTuple{(:x,:y)}, Const(:z))
@test Const(true) ⊑ isdefined_tfunc(NamedTuple{(:x,:y)}, Const(1))
@test Const(false) ⊑ isdefined_tfunc(NamedTuple{(:x,:y)}, Const(3))
@test Const(true) ⊑ isdefined_tfunc(NamedTuple{(:x,:y)}, Const(:y))

# splatting an ::Any should still allow inference to use types of parameters preceding it
f22364(::Int, ::Any...) = 0
f22364(::String, ::Any...) = 0.0
g22364(x) = f22364(x, Any[[]][1]...)
@test @inferred(g22364(1)) === 0
@test @inferred(g22364("1")) === 0.0

function get_linfo(@nospecialize(f), @nospecialize(t))
    if isa(f, Core.Builtin)
        throw(ArgumentError("argument is not a generic function"))
    end
    # get the MethodInstance for the method match
    match = Base._which(Base.signature_type(f, t), Base.get_world_counter())
    precompile(match.spec_types)
    return Core.Compiler.specialize_method(match)
end

function test_const_return(@nospecialize(f), @nospecialize(t), @nospecialize(val))
    interp = Core.Compiler.NativeInterpreter()
    linfo = Core.Compiler.getindex(Core.Compiler.code_cache(interp), get_linfo(f, t))
    # If coverage is not enabled, make the check strict by requiring constant ABI
    # Otherwise, check the typed AST to make sure we return a constant.
    if Base.JLOptions().code_coverage == 0
        @test Core.Compiler.invoke_api(linfo) == 2
    end
    if Core.Compiler.invoke_api(linfo) == 2
        @test linfo.rettype_const == val
        return
    end
    ct = code_typed(f, t)
    @test length(ct) == 1
    ast = first(ct[1])
    ret_found = false
    for ex in ast.code::Vector{Any}
        if isa(ex, LineNumberNode)
            continue
        elseif isa(ex, ReturnNode)
            # multiple returns
            @test !ret_found
            ret_found = true
            ret = ex.val
            # return value mismatch
            @test ret === val || (isa(ret, QuoteNode) && (ret::QuoteNode).value === val)
            continue
        elseif isa(ex, Expr)
            if Core.Compiler.is_meta_expr_head(ex.head)
                continue
            end
        end
        @test false || "Side effect expressions found $ex"
        return
    end
end

function find_call(code::Core.CodeInfo, @nospecialize(func), narg)
    for ex in code.code
        Meta.isexpr(ex, :(=)) && (ex = ex.args[2])
        isa(ex, Expr) || continue
        if ex.head === :call && length(ex.args) == narg
            farg = ex.args[1]
            if isa(farg, GlobalRef)
                if isdefined(farg.mod, farg.name) && isconst(farg.mod, farg.name)
                    farg = typeof(getfield(farg.mod, farg.name))
                end
            elseif isa(farg, Core.SSAValue)
                farg = Core.Compiler.widenconst(code.ssavaluetypes[farg.id])
            else
                farg = typeof(farg)
            end
            if farg === typeof(func)
                return true
            end
        end
    end
    return false
end

test_const_return(()->1, Tuple{}, 1)
test_const_return(()->sizeof(Int), Tuple{}, sizeof(Int))
test_const_return(()->sizeof(1), Tuple{}, sizeof(Int))
test_const_return(()->sizeof(DataType), Tuple{}, sizeof(DataType))
test_const_return(()->sizeof(1 < 2), Tuple{}, 1)
test_const_return(()->fieldtype(Dict{Int64,Nothing}, :age), Tuple{}, UInt)
test_const_return(@eval(()->Core.sizeof($(Array{Int,0}(undef)))), Tuple{}, sizeof(Int))
test_const_return(@eval(()->Core.sizeof($(Matrix{Float32}(undef, 2, 2)))), Tuple{}, 4 * 2 * 2)

# Make sure Core.sizeof with a ::DataType as inferred input type is inferred but not constant.
function sizeof_typeref(typeref)
    return Core.sizeof(typeref[])
end
@test @inferred(sizeof_typeref(Ref{DataType}(Int))) == sizeof(Int)
@test find_call(first(code_typed(sizeof_typeref, (Ref{DataType},))[1]), Core.sizeof, 2)
# Constant `Vector` can be resized and shouldn't be optimized to a constant.
const constvec = [1, 2, 3]
@eval function sizeof_constvec()
    return Core.sizeof($constvec)
end
@test @inferred(sizeof_constvec()) == sizeof(Int) * 3
@test find_call(first(code_typed(sizeof_constvec, ())[1]), Core.sizeof, 2)
push!(constvec, 10)
@test @inferred(sizeof_constvec()) == sizeof(Int) * 4

test_const_return(x->isdefined(x, :re), Tuple{ComplexF64}, true)

isdefined_f3(x) = isdefined(x, 3)
@test @inferred(isdefined_f3(())) == false
@test find_call(first(code_typed(isdefined_f3, Tuple{Tuple{Vararg{Int}}})[1]), isdefined, 3)

let isa_tfunc = Core.Compiler.isa_tfunc
    @test isa_tfunc(Array, Const(AbstractArray)) === Const(true)
    @test isa_tfunc(Array, Type{AbstractArray}) === Const(true)
    @test isa_tfunc(Array, Type{AbstractArray{Int}}) == Bool
    @test isa_tfunc(Array{Real}, Type{AbstractArray{Int}}) === Const(false)
    @test isa_tfunc(Array{Real, 2}, Const(AbstractArray{Real, 2})) === Const(true)
    @test isa_tfunc(Array{Real, 2}, Const(AbstractArray{Int, 2})) === Const(false)
    @test isa_tfunc(DataType, Int) === Union{}
    @test isa_tfunc(DataType, Const(Type{Int})) === Bool
    @test isa_tfunc(DataType, Const(Type{Array})) === Bool
    @test isa_tfunc(UnionAll, Const(Type{Int})) === Bool # could be improved
    @test isa_tfunc(UnionAll, Const(Type{Array})) === Bool
    @test isa_tfunc(Union, Const(Union{Float32, Float64})) === Bool
    @test isa_tfunc(Union, Type{Union}) === Const(true)
    @test isa_tfunc(typeof(Union{}), Const(Int)) === Const(false)
    @test isa_tfunc(typeof(Union{}), Const(Union{})) === Const(false)
    @test isa_tfunc(typeof(Union{}), typeof(Union{})) === Const(false)
    @test isa_tfunc(typeof(Union{}), Union{}) === Union{} # any result is ok
    @test isa_tfunc(typeof(Union{}), Type{typeof(Union{})}) === Const(true)
    @test isa_tfunc(typeof(Union{}), Const(typeof(Union{}))) === Const(true)
    let c = Conditional(Core.SlotNumber(0), Const(Union{}), Const(Union{}))
        @test isa_tfunc(c, Const(Bool)) === Const(true)
        @test isa_tfunc(c, Type{Bool}) === Const(true)
        @test isa_tfunc(c, Const(Real)) === Const(true)
        @test isa_tfunc(c, Type{Real}) === Const(true)
        @test isa_tfunc(c, Const(Signed)) === Const(false)
        @test isa_tfunc(c, Type{Complex}) === Const(false)
        @test isa_tfunc(c, Type{Complex{T}} where T) === Const(false)
    end
    @test isa_tfunc(Val{1}, Type{Val{T}} where T) === Bool
    @test isa_tfunc(Val{1}, DataType) === Bool
    @test isa_tfunc(Any, Const(Any)) === Const(true)
    @test isa_tfunc(Any, Union{}) === Union{} # any result is ok
    @test isa_tfunc(Any, Type{Union{}}) === Const(false)
    @test isa_tfunc(Union{Int64, Float64}, Type{Real}) === Const(true)
    @test isa_tfunc(Union{Int64, Float64}, Type{Integer}) === Bool
    @test isa_tfunc(Union{Int64, Float64}, Type{AbstractArray}) === Const(false)
end

let subtype_tfunc = Core.Compiler.subtype_tfunc
    @test subtype_tfunc(Type{<:Array}, Const(AbstractArray)) === Const(true)
    @test subtype_tfunc(Type{<:Array}, Type{AbstractArray}) === Const(true)
    @test subtype_tfunc(Type{<:Array}, Type{AbstractArray{Int}}) == Bool
    @test subtype_tfunc(Type{<:Array{Real}}, Type{AbstractArray{Int}}) === Const(false)
    @test subtype_tfunc(Type{<:Array{Real, 2}}, Const(AbstractArray{Real, 2})) === Const(true)
    @test subtype_tfunc(Type{Array{Real, 2}}, Const(AbstractArray{Int, 2})) === Const(false)
    @test subtype_tfunc(DataType, Int) === Bool
    @test subtype_tfunc(DataType, Const(Type{Int})) === Bool
    @test subtype_tfunc(DataType, Const(Type{Array})) === Bool
    @test subtype_tfunc(UnionAll, Const(Type{Int})) === Bool
    @test subtype_tfunc(UnionAll, Const(Type{Array})) === Bool
    @test subtype_tfunc(Union, Const(Union{Float32, Float64})) === Bool
    @test subtype_tfunc(Union, Type{Union}) === Bool
    @test subtype_tfunc(Union{}, Const(Int)) === Const(true) # any result is ok
    @test subtype_tfunc(Union{}, Const(Union{})) === Const(true) # any result is ok
    @test subtype_tfunc(Union{}, typeof(Union{})) === Const(true) # any result is ok
    @test subtype_tfunc(Union{}, Union{}) === Const(true) # any result is ok
    @test subtype_tfunc(Union{}, Type{typeof(Union{})}) === Const(true) # any result is ok
    @test subtype_tfunc(Union{}, Const(typeof(Union{}))) === Const(true) # any result is ok
    @test subtype_tfunc(typeof(Union{}), Const(typeof(Union{}))) === Const(true) # Union{} <: typeof(Union{})
    @test subtype_tfunc(typeof(Union{}), Const(Int)) === Const(true) # Union{} <: Int
    @test subtype_tfunc(typeof(Union{}), Const(Union{})) === Const(true) # Union{} <: Union{}
    @test subtype_tfunc(typeof(Union{}), Type{typeof(Union{})}) === Const(true) # Union{} <: Union{}
    @test subtype_tfunc(typeof(Union{}), Type{typeof(Union{})}) === Const(true) # Union{} <: typeof(Union{})
    @test subtype_tfunc(typeof(Union{}), Type{Union{}}) === Const(true) # Union{} <: Union{}
    @test subtype_tfunc(Type{Union{}}, typeof(Union{})) === Const(true) # Union{} <: Union{}
    @test subtype_tfunc(Type{Union{}}, Const(typeof(Union{}))) === Const(true) # Union{} <: typeof(Union{})
    @test subtype_tfunc(Type{Union{}}, Const(Int)) === Const(true) # Union{} <: typeof(Union{})
    @test subtype_tfunc(Type{Union{}}, Any) === Const(true) # Union{} <: Any
    @test subtype_tfunc(Type{Union{}}, Union{Type{Int64}, Type{Float64}}) === Const(true)
    @test subtype_tfunc(Type{Union{}}, Union{Type{T}, Type{Float64}} where T) === Const(true)
    let c = Conditional(Core.SlotNumber(0), Const(Union{}), Const(Union{}))
        @test subtype_tfunc(c, Const(Bool)) === Const(true) # any result is ok
    end
    @test subtype_tfunc(Type{Val{1}}, Type{Val{T}} where T) === Bool
    @test subtype_tfunc(Type{Val{1}}, DataType) === Bool
    @test subtype_tfunc(Type, Type{Val{T}} where T) === Bool
    @test subtype_tfunc(Type{Val{T}} where T, Type) === Bool
    @test subtype_tfunc(Any, Const(Any)) === Const(true)
    @test subtype_tfunc(Type{Any}, Const(Any)) === Const(true)
    @test subtype_tfunc(Any, Union{}) === Bool # any result is ok
    @test subtype_tfunc(Type{Any}, Union{}) === Const(false) # any result is ok
    @test subtype_tfunc(Type, Union{}) === Bool # any result is ok
    @test subtype_tfunc(Type, Type{Union{}}) === Bool
    @test subtype_tfunc(Union{Type{Int64}, Type{Float64}}, Type{Real}) === Const(true)
    @test subtype_tfunc(Union{Type{Int64}, Type{Float64}}, Type{Integer}) === Bool
    @test subtype_tfunc(Union{Type{Int64}, Type{Float64}}, Type{AbstractArray}) === Const(false)
end

let egal_tfunc
    function egal_tfunc(a, b)
        r = Core.Compiler.egal_tfunc(a, b)
        @test r === Core.Compiler.egal_tfunc(b, a)
        return r
    end
    @test egal_tfunc(Const(12345.12345), Const(12344.12345 + 1)) == Const(true)
    @test egal_tfunc(Array, Const(Array)) === Const(false)
    @test egal_tfunc(Array, Type{Array}) === Const(false)
    @test egal_tfunc(Int, Int) == Bool
    @test egal_tfunc(Array, Array) == Bool
    @test egal_tfunc(Array, AbstractArray{Int}) == Bool
    @test egal_tfunc(Array{Real}, AbstractArray{Int}) === Const(false)
    @test egal_tfunc(Array{Real, 2}, AbstractArray{Real, 2}) === Bool
    @test egal_tfunc(Array{Real, 2}, AbstractArray{Int, 2}) === Const(false)
    @test egal_tfunc(DataType, Int) === Const(false)
    @test egal_tfunc(DataType, Const(Int)) === Bool
    @test egal_tfunc(DataType, Const(Array)) === Const(false)
    @test egal_tfunc(UnionAll, Const(Int)) === Const(false)
    @test egal_tfunc(UnionAll, Const(Array)) === Bool
    @test egal_tfunc(Union, Const(Union{Float32, Float64})) === Bool
    @test egal_tfunc(Const(Union{Float32, Float64}), Const(Union{Float32, Float64})) === Const(true)
    @test egal_tfunc(Type{Union{Float32, Float64}}, Type{Union{Float32, Float64}}) === Bool
    @test egal_tfunc(typeof(Union{}), typeof(Union{})) === Bool # could be improved
    @test egal_tfunc(Const(typeof(Union{})), Const(typeof(Union{}))) === Const(true)
    let c = Conditional(Core.SlotNumber(0), Const(Union{}), Const(Union{}))
        @test egal_tfunc(c, Const(Bool)) === Const(false)
        @test egal_tfunc(c, Type{Bool}) === Const(false)
        @test egal_tfunc(c, Const(Real)) === Const(false)
        @test egal_tfunc(c, Type{Real}) === Const(false)
        @test egal_tfunc(c, Const(Signed)) === Const(false)
        @test egal_tfunc(c, Type{Complex}) === Const(false)
        @test egal_tfunc(c, Type{Complex{T}} where T) === Const(false)
        @test egal_tfunc(c, Bool) === Bool
        @test egal_tfunc(c, Any) === Bool
    end
    let c = Conditional(Core.SlotNumber(0), Union{}, Const(Union{})) # === Const(false)
        @test egal_tfunc(c, Const(false)) === Conditional(c.var, c.elsetype, Union{})
        @test egal_tfunc(c, Const(true)) === Conditional(c.var, Union{}, c.elsetype)
        @test egal_tfunc(c, Const(nothing)) === Const(false)
        @test egal_tfunc(c, Int) === Const(false)
        @test egal_tfunc(c, Bool) === Bool
        @test egal_tfunc(c, Any) === Bool
    end
    let c = Conditional(Core.SlotNumber(0), Const(Union{}), Union{}) # === Const(true)
        @test egal_tfunc(c, Const(false)) === Conditional(c.var, Union{}, c.vtype)
        @test egal_tfunc(c, Const(true)) === Conditional(c.var, c.vtype, Union{})
        @test egal_tfunc(c, Const(nothing)) === Const(false)
        @test egal_tfunc(c, Int) === Const(false)
        @test egal_tfunc(c, Bool) === Bool
        @test egal_tfunc(c, Any) === Bool
    end
    @test egal_tfunc(Type{Val{1}}, Type{Val{T}} where T) === Bool
    @test egal_tfunc(Type{Val{1}}, DataType) === Bool
    @test egal_tfunc(Const(Any), Const(Any)) === Const(true)
    @test egal_tfunc(Any, Union{}) === Const(false) # any result is ok
    @test egal_tfunc(Type{Any}, Type{Union{}}) === Const(false)
    @test egal_tfunc(Union{Int64, Float64}, Real) === Bool
    @test egal_tfunc(Union{Int64, Float64}, Integer) === Bool
    @test egal_tfunc(Union{Int64, Float64}, AbstractArray) === Const(false)
end
egal_conditional_lattice1(x, y) = x === y ? "" : 1
egal_conditional_lattice2(x, y) = x + x === y ? "" : 1
egal_conditional_lattice3(x, y) = x === y + y ? "" : 1
@test Base.return_types(egal_conditional_lattice1, (Int64, Int64)) == Any[Union{Int, String}]
@test Base.return_types(egal_conditional_lattice1, (Int32, Int64)) == Any[Int]
@test Base.return_types(egal_conditional_lattice2, (Int64, Int64)) == Any[Union{Int, String}]
@test Base.return_types(egal_conditional_lattice2, (Int32, Int64)) == Any[Int]
@test Base.return_types(egal_conditional_lattice3, (Int64, Int64)) == Any[Union{Int, String}]
@test Base.return_types(egal_conditional_lattice3, (Int32, Int64)) == Any[Int]

using Core.Compiler: PartialStruct, nfields_tfunc, sizeof_tfunc, sizeof_nothrow
@test sizeof_tfunc(Const(Ptr)) === sizeof_tfunc(Union{Ptr, Int, Type{Ptr{Int8}}, Type{Int}}) === Const(Sys.WORD_SIZE ÷ 8)
@test sizeof_tfunc(Type{Ptr}) === Const(sizeof(Ptr))
@test sizeof_nothrow(Union{Ptr, Int, Type{Ptr{Int8}}, Type{Int}})
@test sizeof_nothrow(Const(Ptr))
@test sizeof_nothrow(Type{Ptr})
@test sizeof_nothrow(Type{Union{Ptr{Int}, Int}})
@test !sizeof_nothrow(Const(Tuple))
@test !sizeof_nothrow(Type{Vector{Int}})
@test !sizeof_nothrow(Type{Union{Int, String}})
@test sizeof_nothrow(String)
@test !sizeof_nothrow(Type{String})
@test sizeof_tfunc(Type{Union{Int64, Int32}}) == Const(Core.sizeof(Union{Int64, Int32}))
let PT = PartialStruct(Tuple{Int64,UInt64}, Any[Const(10), UInt64])
    @test sizeof_tfunc(PT) === Const(16)
    @test nfields_tfunc(PT) === Const(2)
    @test sizeof_nothrow(PT)
end
@test nfields_tfunc(Type) === Int
@test nfields_tfunc(Number) === Int
@test nfields_tfunc(Int) === Const(0)
@test nfields_tfunc(Complex) === Const(2)
@test nfields_tfunc(Type{Type{Int}}) === Const(nfields(DataType))
@test nfields_tfunc(UnionAll) === Const(2)
@test nfields_tfunc(DataType) === Const(nfields(DataType))
@test nfields_tfunc(Type{Int}) === Const(nfields(DataType))
@test nfields_tfunc(Type{Integer}) === Const(nfields(DataType))
@test nfields_tfunc(Type{Complex}) === Int
@test nfields_tfunc(typeof(Union{})) === Const(0)
@test nfields_tfunc(Type{Union{}}) === Const(0)
@test nfields_tfunc(Tuple{Int, Vararg{Int}}) === Int
@test nfields_tfunc(Tuple{Int, Integer}) === Const(2)
@test nfields_tfunc(Union{Tuple{Int, Float64}, Tuple{Int, Int}}) === Const(2)

using Core.Compiler: typeof_tfunc
@test typeof_tfunc(Tuple{Vararg{Int}}) == Type{Tuple{Vararg{Int,N}}} where N
@test typeof_tfunc(Tuple{Any}) == Type{<:Tuple{Any}}
@test typeof_tfunc(Type{Array}) === DataType
@test typeof_tfunc(Type{<:Array}) === DataType
@test typeof_tfunc(Array{Int}) == Type{Array{Int,N}} where N
@test typeof_tfunc(AbstractArray{Int}) == Type{<:AbstractArray{Int,N}} where N
@test typeof_tfunc(Union{<:T, <:Real} where T<:Complex) == Union{Type{Complex{T}} where T<:Real, Type{<:Real}}

f_typeof_tfunc(x) = typeof(x)
@test Base.return_types(f_typeof_tfunc, (Union{<:T, Int} where T<:Complex,)) == Any[Union{Type{Int}, Type{Complex{T}} where T<:Real}]

# arrayref / arrayset / arraysize
import Core.Compiler: Const, arrayref_tfunc, arrayset_tfunc, arraysize_tfunc
@test arrayref_tfunc(Const(true), Vector{Int}, Int) === Int
@test arrayref_tfunc(Const(true), Vector{<:Integer}, Int) === Integer
@test arrayref_tfunc(Const(true), Vector, Int) === Any
@test arrayref_tfunc(Const(true), Vector{Int}, Int, Vararg{Int}) === Int
@test arrayref_tfunc(Const(true), Vector{Int}, Vararg{Int}) === Int
@test arrayref_tfunc(Const(true), Vector{Int}) === Union{}
@test arrayref_tfunc(Const(true), String, Int) === Union{}
@test arrayref_tfunc(Const(true), Vector{Int}, Float64) === Union{}
@test arrayref_tfunc(Int, Vector{Int}, Int) === Union{}
@test arrayset_tfunc(Const(true), Vector{Int}, Int, Int) === Vector{Int}
let ua = Vector{<:Integer}
    @test arrayset_tfunc(Const(true), ua, Int, Int) === ua
end
@test arrayset_tfunc(Const(true), Vector, Int, Int) === Vector
@test arrayset_tfunc(Const(true), Any, Int, Int) === Any
@test arrayset_tfunc(Const(true), Vector{String}, String, Int, Vararg{Int}) === Vector{String}
@test arrayset_tfunc(Const(true), Vector{String}, String, Vararg{Int}) === Vector{String}
@test arrayset_tfunc(Const(true), Vector{String}, String) === Union{}
@test arrayset_tfunc(Const(true), String, Char, Int) === Union{}
@test arrayset_tfunc(Const(true), Vector{Int}, Int, Float64) === Union{}
@test arrayset_tfunc(Int, Vector{Int}, Int, Int) === Union{}
@test arrayset_tfunc(Const(true), Vector{Int}, Float64, Int) === Union{}
@test arraysize_tfunc(Vector, Int) === Int
@test arraysize_tfunc(Vector, Float64) === Union{}
@test arraysize_tfunc(String, Int) === Union{}

function f23024(::Type{T}, ::Int) where T
    1 + 1
end
v23024 = 0
g23024(TT::Tuple{DataType}) = f23024(TT[1], v23024)
@test Base.return_types(f23024, (DataType, Any)) == Any[Int]
@test Base.return_types(g23024, (Tuple{DataType},)) == Any[Int]
@test g23024((UInt8,)) === 2

@test !Core.Compiler.isconstType(Type{typeof(Union{})}) # could be Core.TypeofBottom or Type{Union{}} at runtime
@test Base.return_types(supertype, (Type{typeof(Union{})},)) == Any[Any]

# issue #23685
struct Node23685{T}
end
@inline function update23685!(::Node23685{T}) where T
    convert(Node23685{T}, Node23685{Float64}())
end
h23685 = Node23685{Float64}()
f23685() = update23685!(h23685)
@test f23685() === h23685

let c(::Type{T}, x) where {T<:Array} = T,
    f() = c(Vector{Any[Int][1]}, [1])
    @test f() === Vector{Int}
end

# issue #13183
_false13183 = false
gg13183(x::X...) where {X} = (_false13183 ? gg13183(x, x) : 0)
@test gg13183(5) == 0

# test the external OptimizationState constructor
let linfo = get_linfo(Base.convert, Tuple{Type{Int64}, Int32}),
    world = UInt(23) # some small-numbered world that should be valid
    interp = Core.Compiler.NativeInterpreter()
    opt = Core.Compiler.OptimizationState(linfo, Core.Compiler.OptimizationParams(interp), interp)
    # make sure the state of the properties look reasonable
    @test opt.src !== linfo.def.source
    @test length(opt.src.slotflags) == linfo.def.nargs <= length(opt.src.slotnames)
    @test opt.src.ssavaluetypes isa Vector{Any}
    @test !opt.src.inferred
    @test opt.mod === Base
end

# approximate static parameters due to unions
let T1 = Array{Float64}, T2 = Array{_1,2} where _1
    inference_test_copy(a::T) where {T<:Array} = ccall(:jl_array_copy, Ref{T}, (Any,), a)
    rt = Base.return_types(inference_test_copy, (Union{T1,T2},))[1]
    @test rt >: T1 && rt >: T2

    el(x::T) where {T} = eltype(T)
    rt = Base.return_types(el, (Union{T1,Array{Float32,2}},))[1]
    @test rt >: Union{Type{Float64}, Type{Float32}}

    g(x::Ref{T}) where {T} = T
    rt = Base.return_types(g, (Union{Ref{Array{Float64}}, Ref{Array{Float32}}},))[1]
    @test rt >: Union{Type{Array{Float64}}, Type{Array{Float32}}}
end

# Demonstrate IPO constant propagation (#24362)
f_constant(x) = convert(Int, x)
g_test_constant() = (f_constant(3) == 3 && f_constant(4) == 4 ? true : "BAD")
@test @inferred g_test_constant()

f_pure_add() = (1 + 1 == 2) ? true : "FAIL"
@test @inferred f_pure_add()

# inference of `T.mutable`
@test Core.Compiler.getfield_tfunc(Const(Int.name), Const(:flags)) == Const(0x4)
@test Core.Compiler.getfield_tfunc(Const(Vector{Int}.name), Const(:flags)) == Const(0x2)
@test Core.Compiler.getfield_tfunc(Core.TypeName, Const(:flags)) == UInt8

# getfield on abstract named tuples. issue #32698
import Core.Compiler: getfield_tfunc, Const
@test getfield_tfunc(NamedTuple{(:id, :y), T} where {T <: Tuple{Int, Union{Float64, Missing}}},
                     Const(:y)) == Union{Missing, Float64}
@test getfield_tfunc(NamedTuple{(:id, :y), T} where {T <: Tuple{Int, Union{Float64, Missing}}},
                     Const(2)) == Union{Missing, Float64}
@test getfield_tfunc(NamedTuple{(:id, :y), T} where {T <: Tuple{Int, Union{Float64, Missing}}},
                     Symbol) == Union{Missing, Float64, Int}
@test getfield_tfunc(NamedTuple{<:Any, T} where {T <: Tuple{Int, Union{Float64, Missing}}},
                     Symbol) == Union{Missing, Float64, Int}
@test getfield_tfunc(NamedTuple{<:Any, T} where {T <: Tuple{Int, Union{Float64, Missing}}},
                     Int) == Union{Missing, Float64, Int}
@test getfield_tfunc(NamedTuple{<:Any, T} where {T <: Tuple{Int, Union{Float64, Missing}}},
                     Const(:x)) == Union{Missing, Float64, Int}

mutable struct ARef{T}
    @atomic x::T
end
@test getfield_tfunc(ARef{Int},Const(:x),Symbol) === Int
@test getfield_tfunc(ARef{Int},Const(:x),Bool) === Int
@test getfield_tfunc(ARef{Int},Const(:x),Symbol,Bool) === Int
@test getfield_tfunc(ARef{Int},Const(:x),Symbol,Vararg{Symbol}) === Int # `Vararg{Symbol}` might be empty
@test getfield_tfunc(ARef{Int},Const(:x),Vararg{Symbol}) === Int
@test getfield_tfunc(ARef{Int},Const(:x),Any,) === Int
@test getfield_tfunc(ARef{Int},Const(:x),Any,Any) === Int
@test getfield_tfunc(ARef{Int},Const(:x),Any,Vararg{Any}) === Int
@test getfield_tfunc(ARef{Int},Const(:x),Vararg{Any}) === Int
@test getfield_tfunc(ARef{Int},Const(:x),Int) === Union{}
@test getfield_tfunc(ARef{Int},Const(:x),Bool,Symbol) === Union{}
@test getfield_tfunc(ARef{Int},Const(:x),Symbol,Symbol) === Union{}
@test getfield_tfunc(ARef{Int},Const(:x),Bool,Bool) === Union{}

import Core.Compiler: setfield!_tfunc, setfield!_nothrow, Const
mutable struct XY{X,Y}
    x::X
    y::Y
end
mutable struct ABCDconst
    const a
    const b::Int
    c
    const d::Union{Int,Nothing}
end
@test setfield!_tfunc(Base.RefValue{Int}, Const(:x), Int) === Int
@test setfield!_tfunc(Base.RefValue{Int}, Const(:x), Int, Symbol) === Int
@test setfield!_tfunc(Base.RefValue{Int}, Const(1), Int) === Int
@test setfield!_tfunc(Base.RefValue{Int}, Const(1), Int, Symbol) === Int
@test setfield!_tfunc(Base.RefValue{Int}, Int, Int) === Int
@test setfield!_tfunc(Base.RefValue{Any}, Const(:x), Int) === Int
@test setfield!_tfunc(Base.RefValue{Any}, Const(:x), Int, Symbol) === Int
@test setfield!_tfunc(Base.RefValue{Any}, Const(1), Int) === Int
@test setfield!_tfunc(Base.RefValue{Any}, Const(1), Int, Symbol) === Int
@test setfield!_tfunc(Base.RefValue{Any}, Int, Int) === Int
@test setfield!_tfunc(XY{Any,Any}, Const(1), Int) === Int
@test setfield!_tfunc(XY{Any,Any}, Const(2), Float64) === Float64
@test setfield!_tfunc(XY{Int,Float64}, Const(1), Int) === Int
@test setfield!_tfunc(XY{Int,Float64}, Const(2), Float64) === Float64
@test setfield!_tfunc(ABCDconst, Const(:c), Any) === Any
@test setfield!_tfunc(ABCDconst, Const(3), Any) === Any
@test setfield!_tfunc(ABCDconst, Symbol, Any) === Any
@test setfield!_tfunc(ABCDconst, Int, Any) === Any
@test setfield!_tfunc(Union{Base.RefValue{Any},Some{Any}}, Const(:x), Int) === Int
@test setfield!_tfunc(Union{Base.RefValue,Some{Any}}, Const(:x), Int) === Int
@test setfield!_tfunc(Union{Base.RefValue{Any},Some{Any}}, Const(1), Int) === Int
@test setfield!_tfunc(Union{Base.RefValue,Some{Any}}, Const(1), Int) === Int
@test setfield!_tfunc(Union{Base.RefValue{Any},Some{Any}}, Symbol, Int) === Int
@test setfield!_tfunc(Union{Base.RefValue,Some{Any}}, Symbol, Int) === Int
@test setfield!_tfunc(Union{Base.RefValue{Any},Some{Any}}, Int, Int) === Int
@test setfield!_tfunc(Union{Base.RefValue,Some{Any}}, Int, Int) === Int
@test setfield!_tfunc(Any, Symbol, Int) === Int
@test setfield!_tfunc(Any, Int, Int) === Int
@test setfield!_tfunc(Any, Any, Int) === Int
@test setfield!_tfunc(Base.RefValue{Int}, Const(:x), Float64) === Union{}
@test setfield!_tfunc(Base.RefValue{Int}, Const(:x), Float64, Symbol) === Union{}
@test setfield!_tfunc(Base.RefValue{Int}, Const(1), Float64) === Union{}
@test setfield!_tfunc(Base.RefValue{Int}, Const(1), Float64, Symbol) === Union{}
@test setfield!_tfunc(Base.RefValue{Int}, Int, Float64) === Union{}
@test setfield!_tfunc(Base.RefValue{Any}, Const(:y), Int) === Union{}
@test setfield!_tfunc(Base.RefValue{Any}, Const(:y), Int, Bool) === Union{}
@test setfield!_tfunc(Base.RefValue{Any}, Const(2), Int) === Union{}
@test setfield!_tfunc(Base.RefValue{Any}, Const(2), Int, Bool) === Union{}
@test setfield!_tfunc(Base.RefValue{Any}, String, Int) === Union{}
@test setfield!_tfunc(Some{Any}, Const(:value), Int) === Union{}
@test setfield!_tfunc(Some, Const(:value), Int) === Union{}
@test setfield!_tfunc(Some{Any}, Const(1), Int) === Union{}
@test setfield!_tfunc(Some, Const(1), Int) === Union{}
@test setfield!_tfunc(Some{Any}, Symbol, Int) === Union{}
@test setfield!_tfunc(Some, Symbol, Int) === Union{}
@test setfield!_tfunc(Some{Any}, Int, Int) === Union{}
@test setfield!_tfunc(Some, Int, Int) === Union{}
@test setfield!_tfunc(Const(@__MODULE__), Const(:v), Int) === Union{}
@test setfield!_tfunc(Const(@__MODULE__), Int, Int) === Union{}
@test setfield!_tfunc(Module, Const(:v), Int) === Union{}
@test setfield!_tfunc(Union{Module,Base.RefValue{Any}}, Const(:v), Int) === Union{}
@test setfield!_tfunc(ABCDconst, Const(:a), Any) === Union{}
@test setfield!_tfunc(ABCDconst, Const(:b), Any) === Union{}
@test setfield!_tfunc(ABCDconst, Const(:d), Any) === Union{}
@test setfield!_tfunc(ABCDconst, Const(1), Any) === Union{}
@test setfield!_tfunc(ABCDconst, Const(2), Any) === Union{}
@test setfield!_tfunc(ABCDconst, Const(4), Any) === Union{}
@test setfield!_nothrow(Base.RefValue{Int}, Const(:x), Int)
@test setfield!_nothrow(Base.RefValue{Int}, Const(1), Int)
@test setfield!_nothrow(Base.RefValue{Any}, Const(:x), Int)
@test setfield!_nothrow(Base.RefValue{Any}, Const(1), Int)
@test setfield!_nothrow(XY{Any,Any}, Const(:x), Int)
@test setfield!_nothrow(XY{Any,Any}, Const(:x), Any)
@test setfield!_nothrow(XY{Int,Float64}, Const(:x), Int)
@test setfield!_nothrow(ABCDconst, Const(:c), Any)
@test setfield!_nothrow(ABCDconst, Const(3), Any)
@test !setfield!_nothrow(XY{Int,Float64}, Symbol, Any)
@test !setfield!_nothrow(XY{Int,Float64}, Int, Any)
@test !setfield!_nothrow(Base.RefValue{Int}, Const(:x), Any)
@test !setfield!_nothrow(Base.RefValue{Int}, Const(1), Any)
@test !setfield!_nothrow(Any[Base.RefValue{Any}, Const(:x), Int, Symbol])
@test !setfield!_nothrow(Base.RefValue{Any}, Symbol, Int)
@test !setfield!_nothrow(Base.RefValue{Any}, Int, Int)
@test !setfield!_nothrow(XY{Int,Float64}, Const(:y), Int)
@test !setfield!_nothrow(XY{Int,Float64}, Symbol, Int)
@test !setfield!_nothrow(XY{Int,Float64}, Int, Int)
@test !setfield!_nothrow(ABCDconst, Const(:a), Any)
@test !setfield!_nothrow(ABCDconst, Const(:b), Any)
@test !setfield!_nothrow(ABCDconst, Const(:d), Any)
@test !setfield!_nothrow(ABCDconst, Symbol, Any)
@test !setfield!_nothrow(ABCDconst, Const(1), Any)
@test !setfield!_nothrow(ABCDconst, Const(2), Any)
@test !setfield!_nothrow(ABCDconst, Const(4), Any)
@test !setfield!_nothrow(ABCDconst, Int, Any)
@test !setfield!_nothrow(Union{Base.RefValue{Any},Some{Any}}, Const(:x), Int)
@test !setfield!_nothrow(Union{Base.RefValue,Some{Any}}, Const(:x), Int)
@test !setfield!_nothrow(Union{Base.RefValue{Any},Some{Any}}, Const(1), Int)
@test !setfield!_nothrow(Union{Base.RefValue,Some{Any}}, Const(1), Int)
@test !setfield!_nothrow(Union{Base.RefValue{Any},Some{Any}}, Symbol, Int)
@test !setfield!_nothrow(Union{Base.RefValue,Some{Any}}, Symbol, Int)
@test !setfield!_nothrow(Union{Base.RefValue{Any},Some{Any}}, Int, Int)
@test !setfield!_nothrow(Union{Base.RefValue,Some{Any}}, Int, Int)
@test !setfield!_nothrow(Any, Symbol, Int)
@test !setfield!_nothrow(Any, Int, Int)
@test !setfield!_nothrow(Any, Any, Int)

struct Foo_22708
    x::Ptr{Foo_22708}
end

f_22708(x::Int) = f_22708(Foo_22708, x)
f_22708(::Type{Foo_22708}, x) = bar_22708("x")
f_22708(x) = x
bar_22708(x) = f_22708(x)

@test bar_22708(1) == "x"

# mechanism for spoofing work-limiting heuristics and early generator expansion (#24852)
function _generated_stub(gen::Symbol, args::Vector{Any}, params::Vector{Any}, line, file, expand_early)
    stub = Expr(:new, Core.GeneratedFunctionStub, gen, args, params, line, file, expand_early)
    return Expr(:meta, :generated, stub)
end

f24852_kernel1(x, y::Tuple) = x * y[1][1][1]
f24852_kernel2(x, y::Tuple) = f24852_kernel1(x, (y,))
f24852_kernel3(x, y::Tuple) = f24852_kernel2(x, (y,))
f24852_kernel(x, y::Number) = f24852_kernel3(x, (y,))

function f24852_kernel_cinfo(fsig::Type)
    world = typemax(UInt) # FIXME
    match = Base._methods_by_ftype(fsig, -1, world)[1]
    isdefined(match.method, :source) || return (nothing, :(f(x, y)))
    code_info = Base.uncompressed_ir(match.method)
    Meta.partially_inline!(code_info.code, Any[], match.spec_types, Any[match.sparams...], 1, 0, :propagate)
    if startswith(String(match.method.name), "f24852")
        for a in code_info.code
            if a isa Expr && a.head == :(=)
                a = a.args[2]
            end
            if a isa Expr && length(a.args) === 3 && a.head === :call
                pushfirst!(a.args, Core.SlotNumber(1))
            end
        end
    end
    pushfirst!(code_info.slotnames, Symbol("#self#"))
    pushfirst!(code_info.slotflags, 0x00)
    return match.method, code_info
end

function f24852_gen_cinfo_uninflated(X, Y, _, f, x, y)
    _, code_info = f24852_kernel_cinfo(Tuple{f, x, y})
    return code_info
end

function f24852_gen_cinfo_inflated(X, Y, _, f, x, y)
    method, code_info = f24852_kernel_cinfo(Tuple{f, x, y})
    code_info.method_for_inference_limit_heuristics = method
    return code_info
end

function f24852_gen_expr(X, Y, _, f, x, y) # deparse f(x::X, y::Y) where {X, Y}
    if f === typeof(f24852_kernel)
        f2 = :f24852_kernel3
    elseif f === typeof(f24852_kernel3)
        f2 = :f24852_kernel2
    elseif f === typeof(f24852_kernel2)
        f2 = :f24852_kernel1
    elseif f === typeof(f24852_kernel1)
        return :((x::$X) * (y::$Y)[1][1][1])
    else
        return :(error(repr(f)))
    end
    return :(f24852_late_expr($f2, x::$X, (y::$Y,)))
end

@eval begin
    function f24852_late_expr(f, x::X, y::Y) where {X, Y}
        $(_generated_stub(:f24852_gen_expr, Any[:self, :f, :x, :y],
                          Any[:X, :Y], @__LINE__, QuoteNode(Symbol(@__FILE__)), false))
        $(Expr(:meta, :generated_only))
        #= no body =#
    end
    function f24852_late_inflated(f, x::X, y::Y) where {X, Y}
        $(_generated_stub(:f24852_gen_cinfo_inflated, Any[:self, :f, :x, :y],
                          Any[:X, :Y], @__LINE__, QuoteNode(Symbol(@__FILE__)), false))
        $(Expr(:meta, :generated_only))
        #= no body =#
    end
    function f24852_late_uninflated(f, x::X, y::Y) where {X, Y}
        $(_generated_stub(:f24852_gen_cinfo_uninflated, Any[:self, :f, :x, :y],
                          Any[:X, :Y], @__LINE__, QuoteNode(Symbol(@__FILE__)), false))
        $(Expr(:meta, :generated_only))
        #= no body =#
    end
end

@eval begin
    function f24852_early_expr(f, x::X, y::Y) where {X, Y}
        $(_generated_stub(:f24852_gen_expr, Any[:self, :f, :x, :y],
                          Any[:X, :Y], @__LINE__, QuoteNode(Symbol(@__FILE__)), true))
        $(Expr(:meta, :generated_only))
        #= no body =#
    end
    function f24852_early_inflated(f, x::X, y::Y) where {X, Y}
        $(_generated_stub(:f24852_gen_cinfo_inflated, Any[:self, :f, :x, :y],
                          Any[:X, :Y], @__LINE__, QuoteNode(Symbol(@__FILE__)), true))
        $(Expr(:meta, :generated_only))
        #= no body =#
    end
    function f24852_early_uninflated(f, x::X, y::Y) where {X, Y}
        $(_generated_stub(:f24852_gen_cinfo_uninflated, Any[:self, :f, :x, :y],
                          Any[:X, :Y], @__LINE__, QuoteNode(Symbol(@__FILE__)), true))
        $(Expr(:meta, :generated_only))
        #= no body =#
    end
end

x, y = rand(), rand()
result = f24852_kernel(x, y)

@test result === f24852_late_expr(f24852_kernel, x, y)
@test Base.return_types(f24852_late_expr, typeof((f24852_kernel, x, y))) == Any[Any]
@test result === f24852_late_uninflated(f24852_kernel, x, y)
@test Base.return_types(f24852_late_uninflated, typeof((f24852_kernel, x, y))) == Any[Any]
@test result === f24852_late_uninflated(f24852_kernel, x, y)
@test Base.return_types(f24852_late_uninflated, typeof((f24852_kernel, x, y))) == Any[Any]

@test result === f24852_early_expr(f24852_kernel, x, y)
@test Base.return_types(f24852_early_expr, typeof((f24852_kernel, x, y))) == Any[Any]
@test result === f24852_early_uninflated(f24852_kernel, x, y)
@test Base.return_types(f24852_early_uninflated, typeof((f24852_kernel, x, y))) == Any[Any]
@test result === @inferred f24852_early_inflated(f24852_kernel, x, y)
@test Base.return_types(f24852_early_inflated, typeof((f24852_kernel, x, y))) == Any[Float64]

# TODO: test that `expand_early = true` + inflated `method_for_inference_limit_heuristics`
# can be used to tighten up some inference result.

f26339(T) = T === Union{} ? 1 : ""
g26339(T) = T === Int ? 1 : ""
@test Base.return_types(f26339, (Int,)) == Any[String]
@test Base.return_types(g26339, (Int,)) == Any[String]
@test Base.return_types(f26339, (Type{Int},)) == Any[String]
@test Base.return_types(g26339, (Type{Int},)) == Any[Int]
@test Base.return_types(f26339, (Type{Union{}},)) == Any[Int]
@test Base.return_types(g26339, (Type{Union{}},)) == Any[String]
@test Base.return_types(f26339, (typeof(Union{}),)) == Any[Int]
@test Base.return_types(g26339, (typeof(Union{}),)) == Any[String]
@test Base.return_types(f26339, (Type,)) == Any[Union{Int, String}]
@test Base.return_types(g26339, (Type,)) == Any[Union{Int, String}]

# Test that Conditional doesn't get widened to Bool too quickly
f25261() = (1, 1)
f25261(s) = i == 1 ? (1, 2) : nothing
function foo25261()
    next = f25261()
    while next !== nothing
        next = f25261(Core.getfield(next, 2))
    end
end
opt25261 = code_typed(foo25261, Tuple{}, optimize=false)[1].first.code
i = 1
# Skip to after the branch
while !isa(opt25261[i], GotoIfNot); global i += 1; end
foundslot = false
for expr25261 in opt25261[i:end]
    if expr25261 isa TypedSlot && expr25261.typ === Tuple{Int, Int}
        # This should be the assignment to the SSAValue into the getfield
        # call - make sure it's a TypedSlot
        global foundslot = true
    end
end
@test foundslot

@testset "inter-procedural conditional constraint propagation" begin
    # simple cases
    isaint(a) = isa(a, Int)
    @test Base.return_types((Any,)) do a
        isaint(a) && return a # a::Int
        return 0
    end == Any[Int]
    eqnothing(a) = a === nothing
    @test Base.return_types((Union{Nothing,Int},)) do a
        eqnothing(a) && return 0
        return a # a::Int
    end == Any[Int]

    # more complicated cases
    ispositive(a) = isa(a, Int) && a > 0
    @test Base.return_types((Any,)) do a
        ispositive(a) && return a # a::Int
        return 0
    end == Any[Int]
    global isaint2
    isaint2(a::Int)           = true
    isaint2(@nospecialize(_)) = false
    @test Base.return_types((Any,)) do a
        isaint2(a) && return a # a::Int
        return 0
    end == Any[Int]
    global ispositive2
    ispositive2(a::Int)           = a > 0
    ispositive2(@nospecialize(_)) = false
    @test Base.return_types((Any,)) do a
        ispositive2(a) && return a # a::Int
        return 0
    end == Any[Int]

    # type constraints from multiple constant boolean return types
    function f(x)
        isa(x, Int) && return true
        isa(x, Symbol) && return true
        return false
    end
    @test Base.return_types((Any,)) do x
        f(x) && return x # x::Union{Int,Symbol}
        return nothing
    end == Any[Union{Int,Symbol,Nothing}]

    # constraint on non-vararg argument of `isva` method
    isaint_isvapositive(a, va...) = isa(a, Int) && sum(va) > 0
    @test Base.return_types((Any,Int,Int)) do a, b, c
        isaint_isvapositive(a, b, c) && return a # a::Int
        0
    end == Any[Int]

    # slot as SSA
    isaT(x, T) = isa(x, T)
    @test Base.return_types((Any,Int)) do a, b
        c = a
        if isaT(c, typeof(b))
            return c # c::Int
        end
        return 0
    end |> only === Int

    # with Base functions
    @test Base.return_types((Any,)) do a
        Base.Fix2(isa, Int)(a) && return a # a::Int
        return 0
    end == Any[Int]
    @test Base.return_types((Union{Nothing,Int},)) do a
        isnothing(a) && return 0
        return a # a::Int
    end == Any[Int]
    @test Base.return_types((Union{Missing,Int},)) do a
        ismissing(a) && return 0
        return a # a::Int
    end == Any[Int]
    @test Base.return_types((Any,)) do x
        Meta.isexpr(x, :call) && return x # x::Expr
        return nothing
    end == Any[Union{Nothing,Expr}]

    # handle the edge case
    let ts = @eval Module() begin
            edgecase(_) = $(Core.Compiler.InterConditional(2, Int, Any))
            # create cache
            Base.return_types(edgecase, (Any,))
            Base.return_types((Any,)) do x
                edgecase(x) ? x : nothing # ::Any
            end
        end
        @test ts == Any[Any]
    end

    # a tricky case: if constant inference derives `Const` while non-constant inference has
    # derived `InterConditional`, we should not discard that constant information
    iszero_simple(x) = x === 0
    @test Base.return_types() do
        iszero_simple(0) ? nothing : missing
    end |> only === Nothing
end

@testset "branching on conditional object" begin
    # simple
    @test Base.return_types((Union{Nothing,Int},)) do a
        b = a === nothing
        return b ? 0 : a # ::Int
    end == Any[Int]

    # can use multiple times (as far as the subject of condition hasn't changed)
    @test Base.return_types((Union{Nothing,Int},)) do a
        b = a === nothing
        c = b ? 0 : a # c::Int
        d = !b ? a : 0 # d::Int
        return c, d # ::Tuple{Int,Int}
    end == Any[Tuple{Int,Int}]

    # should invalidate old constraint when the subject of condition has changed
    @test Base.return_types((Union{Nothing,Int},)) do a
        cond = a === nothing
        r1 = cond ? 0 : a # r1::Int
        a = 0
        r2 = cond ? a : 1 # r2::Int, not r2::Union{Nothing,Int}
        return r1, r2 # ::Tuple{Int,Int}
    end == Any[Tuple{Int,Int}]
end

# https://github.com/JuliaLang/julia/issues/42090#issuecomment-911824851
# `PartialStruct` shoudln't wrap `Conditional`
let M = Module()
    @eval M begin
        struct BePartialStruct
            val::Int
            cond
        end
    end

    rt = @eval M begin
        Base.return_types((Union{Nothing,Int},)) do a
            cond = a === nothing
            obj = $(Expr(:new, M.BePartialStruct, 42, :cond))
            r1 = getfield(obj, :cond) ? 0 : a # r1::Union{Nothing,Int}, not r1::Int (because PartialStruct doesn't wrap Conditional)
            a = $(gensym(:anyvar))::Any
            r2 = getfield(obj, :cond) ? a : nothing # r2::Any, not r2::Const(nothing) (we don't need to worry about constrait invalidation here)
            return r1, r2 # ::Tuple{Union{Nothing,Int},Any}
        end |> only
    end
    @test rt == Tuple{Union{Nothing,Int},Any}
end

@testset "conditional constraint propagation from non-`Conditional` object" begin
    @test Base.return_types((Bool,)) do b
        if b
            return !b ? nothing : 1 # ::Int
        else
            return 0
        end
    end == Any[Int]

    @test Base.return_types((Any,)) do b
        if b
            return b # ::Bool
        else
            return nothing
        end
    end == Any[Union{Bool,Nothing}]
end

@testset "`from_interprocedural!`: translate inter-procedural information" begin
    # TODO come up with a test case to check the functionality of `collect_limitations!`
    # one heavy test case would be to use https://github.com/aviatesk/JET.jl and
    # check `julia /path/to/JET/jet /path/to/JET/src/JET.jl` doesn't result in errors
    # because of nested `LimitedAccuracy`es

    # `InterConditional` handling: `abstract_invoke`
    ispositive(a) = isa(a, Int) && a > 0
    @test Base.return_types((Any,)) do a
        if Base.@invoke ispositive(a::Any)
            return a
        end
        return 0
    end |> only == Int
    # the `fargs = nothing` edge case
    @test Base.return_types((Any,)) do a
        Core.Compiler.return_type(invoke, Tuple{typeof(ispositive), Type{Tuple{Any}}, Any})
    end |> only == Type{Bool}

    # `InterConditional` handling: `abstract_call_opaque_closure`
    @test Base.return_types((Any,)) do a
        f = Base.Experimental.@opaque a -> isa(a, Int) && a > 0
        if f(a)
            return a
        end
        return 0
    end |> only === Int
end

function f25579(g)
    h = g[]
    t = (h === nothing)
    h = 3.0
    return t ? typeof(h) : typeof(h)
end
@test @inferred f25579(Ref{Union{Nothing, Int}}(nothing)) == Float64
@test @inferred f25579(Ref{Union{Nothing, Int}}(1)) == Float64
function g25579(g)
    h = g[]
    h = (h === nothing)
    return h ? typeof(h) : typeof(h)
end
@test @inferred g25579(Ref{Union{Nothing, Int}}(nothing)) == Bool
@test @inferred g25579(Ref{Union{Nothing, Int}}(1)) == Bool
function h25579(g)
    h = g[]
    t = (h === nothing)
    try
        h = -1.25
        error("continue at catch block")
    catch
    end
    return t ? typeof(h) : typeof(h)
end
@test Base.return_types(h25579, (Base.RefValue{Union{Nothing, Int}},)) ==
        Any[Union{Type{Float64}, Type{Int}, Type{Nothing}}]

f26172(v) = Val{length(Base.tail(ntuple(identity, v)))}() # Val(M-1)
g26172(::Val{0}) = ()
g26172(v) = (nothing, g26172(f26172(v))...)
@test @inferred(g26172(Val(10))) === ntuple(_ -> nothing, 10)

function conflicting_assignment_conditional()
    x = iterate([])
    if x === (x = 4; nothing)
        return x
    end
    return 5
end
@test @inferred(conflicting_assignment_conditional()) === 4

# 26826 constant prop through varargs

struct Foo26826{A,B}
    a::A
    b::B
end

x26826 = rand()

apply26826(f, args...) = f(args...)

# We use getproperty to drive these tests because it requires constant
# propagation in order to lower to a well-inferred getfield call.
f26826(x) = apply26826(Base.getproperty, Foo26826(1, x), :b)

@test @inferred(f26826(x26826)) === x26826

getfield26826(x, args...) = Base.getproperty(x, getfield(args, 2))

g26826(x) = getfield26826(x, :a, :b)

@test @inferred(g26826(Foo26826(1, x26826))) === x26826

# Somewhere in here should be a single getfield call, and it should be inferred as Float64.
# If this test is broken (especially if inference is getting a correct, but loose result,
# like a Union) then it's potentially an indication that the optimizer isn't hitting the
# InferenceResult cache properly for varargs methods.
let ct = Core.Compiler.code_typed(f26826, (Float64,))[1]
    typed_code, retty = ct.first, ct.second
    found_poorly_typed_getfield_call = false
    for i = 1:length(typed_code.code)
        stmt = typed_code.code[i]
        rhs = Meta.isexpr(stmt, :(=)) ? stmt.args[2] : stmt
        if Meta.isexpr(rhs, :call) && rhs.args[1] == GlobalRef(Base, :getfield) && typed_code.ssavaluetypes[i] !== Float64
            found_poorly_typed_getfield_call = true
        end
    end
    @test !found_poorly_typed_getfield_call && retty === Float64
end

# 27059 fix fieldtype vararg and union handling

f27059(::Type{T}) where T = i -> fieldtype(T, i)
T27059 = Tuple{Float64,Vararg{Float32}}
@test f27059(T27059)(2) === fieldtype(T27059, 2) === Float32
@test f27059(Union{T27059,Tuple{Vararg{Symbol}}})(2) === Union{Float32,Symbol}
@test fieldtype(Union{Tuple{Int,Symbol},Tuple{Float64,String}}, 1) === Union{Int,Float64}
@test fieldtype(Union{Tuple{Int,Symbol},Tuple{Float64,String}}, 2) === Union{Symbol,String}
@test fieldtype(Union{Tuple{T,Symbol},Tuple{S,String}} where {T<:Number,S<:T}, 1) === Union{S,T} where {T<:Number,S<:T}

# PR #27068, improve `ifelse` inference

@noinline _f_ifelse_isa_() = rand(Bool) ? 1 : nothing
function _g_ifelse_isa_()
    x = _f_ifelse_isa_()
    ifelse(isa(x, Nothing), 1, x)
end
@test Base.return_types(_g_ifelse_isa_, ()) == [Int]

@testset "Conditional forwarding" begin
    # forward `Conditional` if it conveys a constraint on any other argument
    ifelselike(cnd, x, y) = cnd ? x : y

    @test Base.return_types((Any,Int,)) do x, y
        ifelselike(isa(x, Int), x, y)
    end |> only == Int

    # should work nicely with union-split
    @test Base.return_types((Union{Int,Nothing},)) do x
        ifelselike(isa(x, Int), x, 0)
    end |> only == Int

    @test Base.return_types((Any,Int)) do x, y
        ifelselike(!isa(x, Int), y, x)
    end |> only == Int

    @test Base.return_types((Any,Int)) do x, y
        a = ifelselike(x === 0, x, 0) # ::Const(0)
        if a == 0
            return y
        else
            return nothing # dead branch
        end
    end |> only == Int

    # pick up the first if there are multiple constrained arguments
    @test Base.return_types((Any,)) do x
        ifelselike(isa(x, Int), x, x)
    end |> only == Any

    # just propagate multiple constraints
    ifelselike2(cnd1, cnd2, x, y, z) = cnd1 ? x : cnd2 ? y : z
    @test Base.return_types((Any,Any)) do x, y
        ifelselike2(isa(x, Int), isa(y, Int), x, y, 0)
    end |> only == Int

    # work with `invoke`
    @test Base.return_types((Any,Any)) do x, y
        Base.@invoke ifelselike(isa(x, Int), x, y::Int)
    end |> only == Int

    # don't be confused with vararg method
    vacond(cnd, va...) = cnd ? va : 0
    @test Base.return_types((Any,)) do x
        # at runtime we will see `va::Tuple{Tuple{Int,Int}, Tuple{Int,Int}}`
        vacond(isa(x, Tuple{Int,Int}), x, x)
    end |> only == Union{Int,Tuple{Any,Any}}

    # demonstrate extra constraint propagation for Base.ifelse
    @test Base.return_types((Any,Int,)) do x, y
        ifelse(isa(x, Int), x, y)
    end |> only == Int

    # slot as SSA
    @test Base.return_types((Any,Vector{Any})) do x, y
        z = x
        ifelselike(isa(z, Int), z, length(y))
    end |> only === Int
end

# Equivalence of Const(T.instance) and T for singleton types
@test Const(nothing) ⊑ Nothing && Nothing ⊑ Const(nothing)

# Don't pessimize apply_type to anything worse than Type and yield Bottom for invalid Unions
@test Core.Compiler.return_type(Core.apply_type, Tuple{Type{Union}}) == Type{Union{}}
@test Core.Compiler.return_type(Core.apply_type, Tuple{Type{Union},Any}) == Type
@test Core.Compiler.return_type(Core.apply_type, Tuple{Type{Union},Any,Any}) == Type
@test Core.Compiler.return_type(Core.apply_type, Tuple{Type{Union},Int}) == Union{}
@test Core.Compiler.return_type(Core.apply_type, Tuple{Type{Union},Any,Int}) == Union{}
@test Core.Compiler.return_type(Core.apply_type, Tuple{Any}) == Any
@test Core.Compiler.return_type(Core.apply_type, Tuple{Any,Any}) == Any

# PR 27351, make sure optimized type intersection for method invalidation handles typevars

abstract type AbstractT27351 end
struct T27351 <: AbstractT27351 end
for i27351 in 1:15
    @eval f27351(::Val{$i27351}, ::AbstractT27351, ::AbstractT27351) = $i27351
end
f27351(::T, ::T27351, ::T27351) where {T} = 16
@test_throws MethodError f27351(Val(1), T27351(), T27351())

# Domsort stress test (from JLD2.jl) - Issue #27625
function JLD2_hash(k::Ptr{UInt8}, n::Integer=length(k), initval::UInt32=UInt32(0))
    # Set up the internal state
    a = b = c = 0xdeadbeef + convert(UInt32, n) + initval

    ptr = k
    @inbounds while n > 12
        a += unsafe_load(convert(Ptr{UInt32}, ptr))
        ptr += 4
        b += unsafe_load(convert(Ptr{UInt32}, ptr))
        ptr += 4
        c += unsafe_load(convert(Ptr{UInt32}, ptr))
        (a, b, c) = mix(a, b, c)
        ptr += 4
        n -= 12
    end
    @inbounds if n > 0
        if n == 12
            c += unsafe_load(convert(Ptr{UInt32}, ptr+8))
            @goto n8
        elseif n == 11
            c += UInt32(unsafe_load(Ptr{UInt8}(ptr+10)))<<16
            @goto n10
        elseif n == 10
            @label n10
            c += UInt32(unsafe_load(Ptr{UInt8}(ptr+9)))<<8
            @goto n9
        elseif n == 9
            @label n9
            c += unsafe_load(ptr+8)
            @goto n8
        elseif n == 8
            @label n8
            b += unsafe_load(convert(Ptr{UInt32}, ptr+4))
            @goto n4
        elseif n == 7
            @label n7
            b += UInt32(unsafe_load(Ptr{UInt8}(ptr+6)))<<16
            @goto n6
        elseif n == 6
            @label n6
            b += UInt32(unsafe_load(Ptr{UInt8}(ptr+5)))<<8
            @goto n5
        elseif n == 5
            @label n5
            b += unsafe_load(ptr+4)
            @goto n4
        elseif n == 4
            @label n4
            a += unsafe_load(convert(Ptr{UInt32}, ptr))
        elseif n == 3
            @label n3
            a += UInt32(unsafe_load(Ptr{UInt8}(ptr+2)))<<16
            @goto n2
        elseif n == 2
            @label n2
            a += UInt32(unsafe_load(Ptr{UInt8}(ptr+1)))<<8
            @goto n1
        elseif n == 1
            @label n1
            a += unsafe_load(ptr)
        end
        c = a + b + c
    end
    c
end
@test isa(code_typed(JLD2_hash, Tuple{Ptr{UInt8}, Int, UInt32}), Array)

# issue #19668
struct Foo19668
    Foo19668(; kwargs...) = new()
end
@test Base.return_types(Foo19668, ()) == [Foo19668]

# this `if` statement is necessary; make sure front-end var promotion isn't fooled
# by simple control flow.
if true
    struct Bar19668
        x
        Bar19668(; x=true) = new(x)
    end
end
@test Base.return_types(Bar19668, ()) == [Bar19668]

if false
    struct RD19668
        x
        RD19668() = new(0)
    end
else
    struct RD19668
        x
        RD19668(; x = true) = new(x)
    end
end
@test Base.return_types(RD19668, ()) == [RD19668]

# issue #15276
function f15276(x)
    if x > 1
    else
        y = 2
        z->y
    end
end
@test Base.return_types(f15276(1), (Int,)) == [Int]

# issue #29326
function f29326()::Any
    begin
        a = 1
        (() -> a)()
    end
end
@test Base.return_types(f29326, ()) == [Int]

function g15276()
    spp = Int[0]
    sol = [spp[i] for i=1:0]
    if false
        spp[1]
    end
    sol
end
@test g15276() isa Vector{Int}

function inbounds_30563()
    local y
    @inbounds for i in 1:10
        y = (m->2i)(0)
    end
    return y
end
@test Base.return_types(inbounds_30563, ()) == Any[Int]

function ifs_around_var_capture()
    if false end
    x = 1
    if false end
    f = y->x
    f(0)
end
@test Base.return_types(ifs_around_var_capture, ()) == Any[Int]

# issue #27316 - inference shouldn't hang on these
f27316(::Vector) = nothing
f27316(::Any) = f27316(Any[][1]), f27316(Any[][1])
let expected = NTuple{2, Union{Nothing, NTuple{2, Union{Nothing, Tuple{Any, Any}}}}}
    @test Tuple{Nothing, Nothing} <: only(Base.return_types(f27316, Tuple{Int})) == expected # we may be able to improve this bound in the future
end
function g27316()
    x = nothing
    while rand() < 0.5
        x = (x,)
    end
    return x
end
@test Tuple{Tuple{Nothing}} <: only(Base.return_types(g27316, Tuple{})) == Union{Nothing, Tuple{Any}} # we may be able to improve this bound in the future
const R27316 = Tuple{Tuple{Vector{T}}} where T
h27316_(x) = (x,)
h27316_(x::Tuple{Vector}) = (Any[x][1],)::R27316 # a UnionAll of a Tuple, not vice versa!
function h27316()
    x = [1]
    while rand() < 0.5
        x = h27316_(x)
    end
    return x
end
@test Tuple{Tuple{Vector{Int}}} <: only(Base.return_types(h27316, Tuple{})) == Union{Vector{Int}, Tuple{Any}} # we may be able to improve this bound in the future

# PR 27434, inference when splatting iterators with type-based state
splat27434(x) = (x...,)
struct Iterator27434
    x::Int
    y::Int
    z::Int
end
Base.iterate(i::Iterator27434) = i.x, Val(1)
Base.iterate(i::Iterator27434, ::Val{1}) = i.y, Val(2)
Base.iterate(i::Iterator27434, ::Val{2}) = i.z, Val(3)
Base.iterate(::Iterator27434, ::Any) = nothing
@test @inferred(splat27434(Iterator27434(1, 2, 3))) == (1, 2, 3)
@test @inferred((1, 2, 3) == (1, 2, 3))
@test Core.Compiler.return_type(splat27434, Tuple{typeof(Iterators.repeated(1))}) == Union{}

# issue #32465
let rt = Base.return_types(splat27434, (NamedTuple{(:x,), Tuple{T}} where T,))
    @test rt == Any[Tuple{Any}]
    @test !Base.has_free_typevars(rt[1])
end

# issue #27078
f27078(T::Type{S}) where {S} = isa(T, UnionAll) ? f27078(T.body) : T
T27078 = Vector{Vector{T}} where T
@test f27078(T27078) === T27078.body

# issue #28070
g28070(f, args...) = f(args...)
@test @inferred g28070(Core._apply, Base.:/, (1.0, 1.0)) == 1.0
@test @inferred g28070(Core._apply_iterate, Base.iterate, Base.:/, (1.0, 1.0)) == 1.0

# issue #28079
struct Foo28079 end
@inline h28079(x, args...) = g28079(x, args...)
@inline g28079(::Any, f, args...) = f(args...)
test28079(p, n, m) = h28079(Foo28079(), Base.pointerref, p, n, m)
cinfo_unoptimized = code_typed(test28079, (Ptr{Float32}, Int, Int); optimize=false)[].first
cinfo_optimized = code_typed(test28079, (Ptr{Float32}, Int, Int); optimize=true)[].first
@test cinfo_unoptimized.ssavaluetypes[end-1] === cinfo_optimized.ssavaluetypes[end-1] === Float32

# issue #27907
ig27907(T::Type, N::Integer, offsets...) = ig27907(T, T, N, offsets...)

function ig27907(::Type{T}, ::Type, N::Integer, offsets...) where {T}
    if length(offsets) < N
        return typeof(ig27907(T, N, offsets..., 0))
    else
        return 0
    end
end

@test ig27907(Int, Int, 1, 0) == 0

# issue #28279
function f28279(b::Bool)
    i = 1
    while i > b
        i -= 1
    end
    if b end
    return i + 1
end
code28279 = code_lowered(f28279, (Bool,))[1].code
oldcode28279 = deepcopy(code28279)
ssachangemap = fill(0, length(code28279))
labelchangemap = fill(0, length(code28279))
let i
    for i in 1:length(code28279)
        stmt = code28279[i]
        if isa(stmt, GotoIfNot)
            ssachangemap[i] = 1
            if i < length(code28279)
                labelchangemap[i + 1] = 1
            end
        end
    end
end
Core.Compiler.renumber_ir_elements!(code28279, ssachangemap, labelchangemap)
@test length(code28279) === length(oldcode28279)
offset = 1
let i
    for i in 1:length(code28279)
        if i == length(code28279)
            @test isa(code28279[i], ReturnNode)
            @test isa(oldcode28279[i], ReturnNode)
            @test code28279[i].val.id == (oldcode28279[i].val.id + offset - 1)
        elseif isa(code28279[i], GotoIfNot)
            @test isa(oldcode28279[i], GotoIfNot)
            @test code28279[i].cond == oldcode28279[i].cond
            @test code28279[i].dest == (oldcode28279[i].dest + offset)
            global offset += 1
        else
            @test code28279[i] == oldcode28279[i]
        end
    end
end

# issue #28356
# unit test to make sure countunionsplit overflows gracefully
# we don't care what number is returned as long as it's large
@test Core.Compiler.unionsplitcost(Any[Union{Int32, Int64} for i=1:80]) > 100000
@test Core.Compiler.unionsplitcost(Any[Union{Int8, Int16, Int32, Int64}]) == 2
@test Core.Compiler.unionsplitcost(Any[Union{Int8, Int16, Int32, Int64}, Union{Int8, Int16, Int32, Int64}, Int8]) == 8
@test Core.Compiler.unionsplitcost(Any[Union{Int8, Int16, Int32, Int64}, Union{Int8, Int16, Int32}, Int8]) == 6
@test Core.Compiler.unionsplitcost(Any[Union{Int8, Int16, Int32}, Union{Int8, Int16, Int32, Int64}, Int8]) == 6

# make sure compiler doesn't hang in union splitting

struct S28356{T<:Union{Float64,Float32}}
x1::T
x2::T
x3::T
x4::T
x5::T
x6::T
x7::T
x8::T
x9::T
x10::T
x11::T
x12::T
x13::T
x14::T
x15::T
x16::T
x17::T
x18::T
x19::T
x20::T
x21::T
x22::T
x23::T
x24::T
x25::T
x26::T
x27::T
x28::T
x29::T
x30::T
x31::T
x32::T
x33::T
x34::T
x35::T
x36::T
x37::T
x38::T
x39::T
x40::T
x41::T
x42::T
x43::T
x44::T
x45::T
x46::T
x47::T
x48::T
x49::T
x50::T
x51::T
x52::T
x53::T
x54::T
x55::T
x56::T
x57::T
x58::T
x59::T
x60::T
x61::T
x62::T
x63::T
x64::T
x65::T
x66::T
x67::T
x68::T
x69::T
x70::T
x71::T
x72::T
x73::T
x74::T
x75::T
x76::T
x77::T
x78::T
x79::T
x80::T
end

function f28356(::Type{T}) where {T<:Union{Float64,Float32}}
    S28356(T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0),T(0))
end

h28356() = f28356(Any[Float64][1])

@test h28356() isa S28356{Float64}

# Issue #28444
mutable struct foo28444
    a::Int
    b::Int
end
function bar28444()
    a = foo28444(1, 2)
    c, d = a.a, a.b
    e = (c, d)
    e[1]
end
@test bar28444() == 1

# issue #28641
struct VoxelIndices{T <: Integer}
    voxCrnrPos::NTuple{8,NTuple{3,T}}
    voxEdgeCrnrs::NTuple{19, NTuple{2,T}}
    voxEdgeDir::NTuple{19,T}
    voxEdgeIx::NTuple{8,NTuple{8,T}}
    subTets::NTuple{6,NTuple{4,T}}
    tetEdgeCrnrs::NTuple{6,NTuple{2,T}}
    tetTri::NTuple{16,NTuple{6,T}}
end
f28641(x::VoxelIndices, f) = getfield(x, f)
@test Base.return_types(f28641, (Any,Symbol)) == Any[Tuple]

# issue #29036
function f29036(s, i)
    val, i = iterate(s, i)
    val
end
@test Base.return_types(f29036, (String, Int)) == Any[Char]

# issue #26729
module I26729
struct Less{O}
    is_less::O
end

struct By{T,O}
    by::T
    is_less::O
end

struct Reverse{O}
    is_less::O
end

function get_order(by = identity, func = isless, rev = false)
    ord = By(by, Less(func))
    rev ? Reverse(ord) : ord
end

get_order_kwargs(; by = identity, func = isless, rev = false) = get_order(by, func, rev)

# test that this doesn't cause an internal error
get_order_kwargs()
end

# Test that tail-like functions don't block constant propagation
my_tail_const_prop(i, tail...) = tail
function foo_tail_const_prop()
    Val{my_tail_const_prop(1,2,3,4)}()
end
@test (@inferred foo_tail_const_prop()) == Val{(2,3,4)}()

# PR #28955

a28955(f, args...) = f(args...)
b28955(args::Tuple) = a28955(args...)
c28955(args...) = b28955(args)
d28955(f, x, y) = c28955(f, Bool, x, y)
f28955(::Type{Bool}, x, y) = x
f28955(::DataType, x, y) = y

@test @inferred(d28955(f28955, 1, 2.0)) === 1

function g28955(x, y)
    _1 = tuple(Bool)
    _2 = isa(y, Int) ? nothing : _1
    _3 = tuple(_1..., x...)
    return getfield(_3, 1)
end

@test @inferred(g28955((1,), 1.0)) === Bool

# Test that inlining can look through repeated _apply_iterates
foo_inlining_apply(args...) = ccall(:jl_, Nothing, (Any,), args[1])
bar_inlining_apply() = Core._apply_iterate(iterate, Core._apply_iterate, (iterate,), (foo_inlining_apply,), ((1,),))
let ci = code_typed(bar_inlining_apply, Tuple{})[1].first
    @test length(ci.code) == 2
    @test ci.code[1].head == :foreigncall
end

# Test that inference can infer .instance of types
f_instance(::Type{T}) where {T} = T.instance
@test @inferred(f_instance(Nothing)) === nothing

# test for some limit-cycle caching poisoning
_false30098 = false
f30098() = _false30098 ? g30098() : 3
g30098() = (h30098(:f30098); 4)
h30098(f) = getfield(@__MODULE__, f)()
@test @inferred(g30098()) == 4 # make sure that this
@test @inferred(f30098()) == 3 # doesn't pollute the inference cache of this

# issue #30394
mutable struct Base30394
    a::Int
end

mutable struct Foo30394
    foo_inner::Base30394
    Foo30394() = new(Base30394(1))
end

mutable struct Foo30394_2
    foo_inner::Foo30394
    Foo30394_2() = new(Foo30394())
end

f30394(foo::T1, ::Type{T2}) where {T2, T1 <: T2} = foo

f30394(foo, T2) = f30394(foo.foo_inner, T2)

@test Base.return_types(f30394, (Foo30394_2, Type{Base30394})) == Any[Base30394]

# PR #30385

g30385(args...) = h30385(args...)
h30385(f, args...) = f(args...)
f30385(T, y) = g30385(getfield, g30385(tuple, T, y), 1)
k30385(::Type{AbstractFloat}) = 1
k30385(x) = "dummy"
j30385(T, y) = k30385(f30385(T, y))

@test @inferred(j30385(AbstractFloat, 1)) == 1
@test @inferred(j30385(:dummy, 1)) == "dummy"

@test Base.return_types(Tuple, (NamedTuple{<:Any,Tuple{Any,Int}},)) == Any[Tuple{Any,Int}]
@test Base.return_types(Base.splat(tuple), (typeof((a=1,)),)) == Any[Tuple{Int}]

# test that return_type_tfunc isn't affected by max_methods differently than return_type
_rttf_test(::Int8) = 0
_rttf_test(::Int16) = 0
_rttf_test(::Int32) = 0
_rttf_test(::Int64) = 0
_rttf_test(::Int128) = 0
_call_rttf_test() = Core.Compiler.return_type(_rttf_test, Tuple{Any})
@test Core.Compiler.return_type(_rttf_test, Tuple{Any}) === Int
@test _call_rttf_test() === Int

f_with_Type_arg(::Type{T}) where {T} = T
@test Base.return_types(f_with_Type_arg, (Any,)) == Any[Type]
@test Base.return_types(f_with_Type_arg, (Type{Vector{T}} where T,)) == Any[Type{Vector{T}} where T]

# Generated functions that only reference some of their arguments
@inline function my_ntuple(f::F, ::Val{N}) where {F,N}
    N::Int
    (N >= 0) || throw(ArgumentError(string("tuple length should be ≥0, got ", N)))
    if @generated
        quote
            @Base.nexprs $N i -> t_i = f(i)
            @Base.ncall $N tuple t
        end
    else
        Tuple(f(i) for i = 1:N)
    end
end
call_ntuple(a, b) = my_ntuple(i->(a+b; i), Val(4))
@test Base.return_types(call_ntuple, Tuple{Any,Any}) == [NTuple{4, Int}]
@test length(code_typed(my_ntuple, Tuple{Any, Val{4}})) == 1
@test_throws ErrorException code_typed(my_ntuple, Tuple{Any, Val})

@generated unionall_sig_generated(::Vector{T}, b::Vector{S}) where {T, S} = :($b)
@test length(code_typed(unionall_sig_generated, Tuple{Any, Vector{Int}})) == 1

# Test that we don't limit recursions on the number of arguments, even if the
# arguments themselves are getting more complex
f_incr(x::Tuple, y::Tuple, args...) = f_incr((x, y), args...)
f_incr(x::Tuple) = x
@test @inferred(f_incr((), (), (), (), (), (), (), ())) ==
    ((((((((), ()), ()), ()), ()), ()), ()), ())

# Test PartialStruct for closures
@noinline use30783(x) = nothing
function foo30783(b)
    a = 1
    f = ()->(use30783(b); Val(a))
    f()
end
@test @inferred(foo30783(2)) == Val(1)

# PartialStruct tmerge
using Core.Compiler: PartialStruct, tmerge, Const, ⊑
struct FooPartial
    a::Int
    b::Int
    c::Int
end
let PT1 = PartialStruct(FooPartial, Any[Const(1), Const(2), Int]),
    PT2 = PartialStruct(FooPartial, Any[Const(1), Int, Int]),
    PT3 = PartialStruct(FooPartial, Any[Const(1), Int, Const(3)])

    @test PT1 ⊑ PT2
    @test !(PT1 ⊑ PT3) && !(PT2 ⊑ PT1)
    let (==) = (a, b)->(a ⊑ b && b ⊑ a)
        @test tmerge(PT1, PT3) == PT2
    end
end

# issue 31164
struct NoInit31164
    a::Int
    b::Any
    NoInit31164(a::Int) = new(a)
    NoInit31164(a::Int, b) = new(a, b)
end

@eval function foo31164(b, x)
    if b
       a = NoInit31164(1, x)
    else
       a = $(NoInit31164(1))
    end
    return a
end

@test_nowarn code_typed(foo31164, Tuple{Bool, Int}; optimize=false)

# there are errors when these functions are defined inside the @testset
f28762(::Type{<:AbstractArray{T}}) where {T} = T
f28762(::Type{<:AbstractArray}) = Any
g28762(::Type{X}) where {X} = Array{eltype(X)}(undef, 0)
h28762(::Type{X}) where {X} = Array{f28762(X)}(undef, 0)

@testset "@inferred bug from #28762" begin
    # this works since Julia 1.1
    @test (@inferred eltype(Array)) == Any
    @test (@inferred f28762(Array)) == Any
    @inferred g28762(Array{Int})
    @inferred h28762(Array{Int})
    @inferred g28762(Array)
    @inferred h28762(Array)
end

# issue #31663
module I31663
abstract type AbstractNode end

struct Node{N1<:AbstractNode, N2<:AbstractNode} <: AbstractNode
    a::N1
    b::N2
end

struct Leaf <: AbstractNode
end

function gen_nodes(qty::Integer) :: AbstractNode
    @assert qty > 0
    result = Leaf()
    for i in 1:qty
        result = Node(result, Leaf())
    end
    return result
end
end
@test count(==('}'), string(I31663.gen_nodes(50))) == 1275

# issue #31572
struct MixedKeyDict{T<:Tuple} #<: AbstractDict{Any,Any}
    dicts::T
end
Base.merge(f::Function, d::MixedKeyDict, others::MixedKeyDict...) = _merge(f, (), d.dicts, (d->d.dicts).(others)...)
Base.merge(f, d::MixedKeyDict, others::MixedKeyDict...) = _merge(f, (), d.dicts, (d->d.dicts).(others)...)
function _merge(f, res, d, others...)
    ofsametype, remaining = _alloftype(Base.heads(d), ((),), others...)
    return _merge(f, (res..., merge(f, ofsametype...)), Base.tail(d), remaining...)
end
_merge(f, res, ::Tuple{}, others...) = _merge(f, res, others...)
_merge(f, res, d) = MixedKeyDict((res..., d...))
_merge(f, res, ::Tuple{}) = MixedKeyDict(res)
function _alloftype(ofdesiredtype::Tuple{Vararg{D}}, accumulated, d::Tuple{D,Vararg}, others...) where D
    return _alloftype((ofdesiredtype..., first(d)),
                      (Base.front(accumulated)..., (last(accumulated)..., Base.tail(d)...), ()),
                      others...)
end
function _alloftype(ofdesiredtype, accumulated, d, others...)
    return _alloftype(ofdesiredtype,
                      (Base.front(accumulated)..., (last(accumulated)..., first(d))),
                      Base.tail(d), others...)
end
function _alloftype(ofdesiredtype, accumulated, ::Tuple{}, others...)
    return _alloftype(ofdesiredtype,
                      (accumulated..., ()),
                      others...)
end
_alloftype(ofdesiredtype, accumulated) = ofdesiredtype, Base.front(accumulated)
let
    d = MixedKeyDict((Dict(1 => 3), Dict(4. => 2)))
    e = MixedKeyDict((Dict(1 => 7), Dict(5. => 9)))
    @test merge(+, d, e).dicts == (Dict(1 => 10), Dict(4.0 => 2, 5.0 => 9))
    f = MixedKeyDict((Dict(2 => 7), Dict(5. => 11)))
    @test merge(+, d, e, f).dicts == (Dict(1 => 10, 2 => 7), Dict(4.0 => 2, 5.0 => 20))
end

# Issue #31974
f31974(a::UnitRange) = (if first(a) <= last(a); f31974((first(a)+1):last(a)); end; a)
f31974(n::Int) = f31974(1:n)
# This query hangs if type inference improperly attempts to const prop
# call cycles.
@test code_typed(f31974, Tuple{Int}) !== nothing

f_overly_abstract_complex() = Complex(Ref{Number}(1)[])
@test Base.return_types(f_overly_abstract_complex, Tuple{}) == [Complex]

# Issue 26724
const IntRange = AbstractUnitRange{<:Integer}
const DenseIdx = Union{IntRange,Integer}
@inline foo_26724(result) =
    (result...,)
@inline foo_26724(result, i::Integer, I::DenseIdx...) =
    foo_26724(result, I...)
@inline foo_26724(result, r::IntRange, I::DenseIdx...) =
    foo_26724((result..., length(r)), I...)
@test @inferred(foo_26724((), 1:4, 1:5, 1:6)) === (4, 5, 6)

# Non uniformity in expressions with PartialTypeVar
@test Core.Compiler.:⊑(Core.Compiler.PartialTypeVar(TypeVar(:N), true, true), TypeVar)
let N = TypeVar(:N)
    @test Core.Compiler.apply_type_nothrow([Core.Compiler.Const(NTuple),
        Core.Compiler.PartialTypeVar(N, true, true),
        Core.Compiler.Const(Any)], Type{Tuple{Vararg{Any,N}}})
end

# issue #33768
function f33768()
    Core._apply()
end
function g33768()
    a = Any[iterate, tuple, (1,)]
    Core._apply_iterate(a...)
end
function h33768()
    Core._apply_iterate()
end
@test_throws ArgumentError f33768()
@test Base.return_types(f33768, ()) == Any[Union{}]
@test g33768() === (1,)
@test Base.return_types(g33768, ()) == Any[Any]
@test_throws ArgumentError h33768()
@test Base.return_types(h33768, ()) == Any[Union{}]

# constant prop of `Symbol("")`
f_getf_computed_symbol(p) = getfield(p, Symbol("first"))
@test Base.return_types(f_getf_computed_symbol, Tuple{Pair{Int8,String}}) == [Int8]

# issue #33954
struct X33954
    x::Ptr{X33954}
end
f33954(x) = rand(Bool) ? f33954((x,)) : x
@test Base.return_types(f33954, Tuple{X33954})[1] >: X33954

# issue #34752
struct a34752{T} end
function a34752(c, d...)
    length(d) > 1 || error()
end
function h34752()
    g = Tuple[(42, Any[42][1], 42)][1]
    a34752(g...)
end
@test h34752() === true

# issue 34834
pickvarnames(x::Symbol) = x
function pickvarnames(x::Vector{Any})
    varnames = ()
    for a in x
        varnames = (varnames..., pickvarnames(a) )
    end
    return varnames
end
@test pickvarnames(:a) === :a
@test pickvarnames(Any[:a, :b]) === (:a, :b)
@test only(Base.return_types(pickvarnames, (Vector{Any},))) == Tuple{Vararg{Union{Symbol, Tuple}}}
@test only(Base.code_typed(pickvarnames, (Vector{Any},), optimize=false))[2] == Tuple{Vararg{Union{Symbol, Tuple{Vararg{Union{Symbol, Tuple}}}}}}

@test map(>:, [Int], [Int]) == [true]

# issue 35566
module Issue35566
function step(acc, x)
    xs, = acc
    y = x > 0.0 ? x : missing
    if y isa eltype(xs)
        ys = push!(xs, y)
    else
        ys = vcat(xs, [y])
    end
    return (ys,)
end

function probe(y)
    if y isa Tuple{Vector{Missing}}
        return Val(:missing)
    else
        return Val(:expected)
    end
end

function _foldl_iter(rf, val::T, iter, state) where {T}
    while true
        ret = iterate(iter, state)
        ret === nothing && break
        x, state = ret
        y = rf(val, x)
        if y isa T
            val = y
        else
            return probe(y)
        end
    end
    return Val(:expected)
end

f() = _foldl_iter(step, (Missing[],), [0.0], 1)
end
@test Core.Compiler.typesubtract(Tuple{Union{Int,Char}}, Tuple{Char}, 0) == Tuple{Int}
@test Core.Compiler.typesubtract(Tuple{Union{Int,Char}}, Tuple{Char}, 1) == Tuple{Int}
@test Core.Compiler.typesubtract(Tuple{Union{Int,Char}}, Tuple{Char}, 2) == Tuple{Int}
@test Core.Compiler.typesubtract(NTuple{3, Union{Int, Char}}, Tuple{Char, Any, Any}, 0) ==
        Tuple{Int, Union{Char, Int}, Union{Char, Int}}
@test Core.Compiler.typesubtract(NTuple{3, Union{Int, Char}}, Tuple{Char, Any, Any}, 10) ==
        Union{Tuple{Int, Char, Char}, Tuple{Int, Char, Int}, Tuple{Int, Int, Char}, Tuple{Int, Int, Int}}
@test Core.Compiler.typesubtract(NTuple{3, Union{Int, Char}}, NTuple{3, Char}, 0) ==
        NTuple{3, Union{Int, Char}}
@test Core.Compiler.typesubtract(NTuple{3, Union{Int, Char}}, NTuple{3, Char}, 10) ==
        Union{Tuple{Char, Char, Int}, Tuple{Char, Int, Char}, Tuple{Char, Int, Int}, Tuple{Int, Char, Char},
              Tuple{Int, Char, Int}, Tuple{Int, Int, Char}, Tuple{Int, Int, Int}}
# Test that these don't throw
@test Core.Compiler.typesubtract(Tuple{Vararg{Int}}, Tuple{Vararg{Char}}, 0) == Tuple{Vararg{Int}}
@test Core.Compiler.typesubtract(NTuple{3, Real}, NTuple{3, Char}, 0) == NTuple{3, Real}
@test Core.Compiler.typesubtract(NTuple{3, Union{Real, Char}}, NTuple{2, Char}, 0) == NTuple{3, Union{Real, Char}}

@test Base.return_types(Issue35566.f) == [Val{:expected}]

# constant prop through keyword arguments
_unstable_kw(;x=1,y=2) = x == 1 ? 0 : ""
_use_unstable_kw_1() = _unstable_kw(x = 2)
_use_unstable_kw_2() = _unstable_kw(x = 2, y = rand())
@test Base.return_types(_use_unstable_kw_1) == Any[String]
@test Base.return_types(_use_unstable_kw_2) == Any[String]
@eval struct StructWithSplatNew
    x::String
    StructWithSplatNew(t) = $(Expr(:splatnew, :StructWithSplatNew, :t))
end
_construct_structwithsplatnew() = StructWithSplatNew(("",))
@test Base.return_types(_construct_structwithsplatnew) == Any[StructWithSplatNew]
@test isa(_construct_structwithsplatnew(), StructWithSplatNew)

# case where a call cycle can be broken by constant propagation
struct NotQRSparse
    x::Matrix{Float64}
    n::Int
end
@inline function getprop(F::NotQRSparse, d::Symbol)
    if d === :Q
        return NotQRSparse(getprop(F, :B), _size_ish(F, 2))
    elseif d === :A
        return Dict()
    elseif d === :B
        return rand(2,2)
    elseif d === :C
        return ""
    else
        error()
    end
end
_size_ish(F::NotQRSparse, i::Integer) = size(getprop(F, :B), 1)
_call_size_ish(x) = _size_ish(x,1)
@test Base.return_types(_call_size_ish, (NotQRSparse,)) == Any[Int]

module TestConstPropRecursion
mutable struct Node
    data
    child::Node
    sibling::Node
end

function Base.iterate(n::Node, state::Node = n.child)
    n === state && return nothing
    return state, state === state.sibling ? n : state.sibling
end

@inline function depth(node::Node, d)
    childd = d + 1
    for c in node
        d = max(d, depth(c, childd))
    end
    return d
end

f(n) = depth(n, 1)
end
@test Base.return_types(TestConstPropRecursion.f, (TestConstPropRecursion.Node,)) == Any[Int]

# issue #36230, keeping implications of all conditions in a && chain
function symcmp36230(vec)
    a, b = vec[1], vec[2]
    if isa(a, Symbol) && isa(b, Symbol)
        return a == b
    elseif isa(a, Int) && isa(b, Int)
        return a == b
    end
    return false
end
@test Base.return_types(symcmp36230, (Vector{Any},)) == Any[Bool]

function foo42190(r::Union{Nothing,Int}, n::Int)
    while r !== nothing && r < n
        return r # `r::Int`
    end
    return n
end
@test Base.return_types(foo42190, (Union{Nothing, Int}, Int)) == Any[Int]
function bar42190(r::Union{Nothing,Int}, n::Int)
    while r === nothing || r < n
        return n
    end
    return r # `r::Int`
end
@test Base.return_types(bar42190, (Union{Nothing, Int}, Int)) == Any[Int]

# Issue #36531, double varargs in abstract_iteration
f36531(args...) = tuple((args...)...)
@test @inferred(f36531(1,2,3)) == (1,2,3)
@test code_typed(f36531, Tuple{Vararg{Int}}) isa Vector

# PartialStruct results on typeinf edges
partial_return_1(x) = (x, 1)
partial_return_2(x) = Val{partial_return_1(x)[2]}

@test Base.return_types(partial_return_2, (Int,)) == Any[Type{Val{1}}]

# Soundness and precision of abstract_iteration
f41839() = (1:100...,)
@test NTuple{100,Int} <: only(Base.return_types(f41839, ())) <: Tuple{Vararg{Int}}
f_splat(x) = (x...,)
@test Base.return_types(f_splat, (Pair{Int,Int},)) == Any[Tuple{Int, Int}]
@test Base.return_types(f_splat, (UnitRange{Int},)) == Any[Tuple{Vararg{Int}}]
struct Itr41839_1 end # empty or infinite
Base.iterate(::Itr41839_1) = rand(Bool) ? (nothing, nothing) : nothing
Base.iterate(::Itr41839_1, ::Nothing) = (nothing, nothing)
@test Base.return_types(f_splat, (Itr41839_1,)) == Any[Tuple{}]
struct Itr41839_2 end # empty or failing
Base.iterate(::Itr41839_2) = rand(Bool) ? (nothing, nothing) : nothing
Base.iterate(::Itr41839_2, ::Nothing) = error()
@test Base.return_types(f_splat, (Itr41839_2,)) == Any[Tuple{}]
struct Itr41839_3 end
Base.iterate(::Itr41839_3 ) = rand(Bool) ? nothing : (nothing, 1)
Base.iterate(::Itr41839_3 , i) = i < 16 ? (i, i + 1) : nothing
@test only(Base.return_types(f_splat, (Itr41839_3,))) <: Tuple{Vararg{Union{Nothing, Int}}}

# issue #32699
f32699(a) = (id = a[1],).id
@test Base.return_types(f32699, (Vector{Union{Int,Missing}},)) == Any[Union{Int,Missing}]
g32699(a) = Tuple{a}
@test Base.return_types(g32699, (Type{<:Integer},))[1] == Type{<:Tuple{Any}}
@test Base.return_types(g32699, (Type,))[1] == Type{<:Tuple}

# Inference precision of union-split calls
function f_apply_union_split(fs, x)
    i = rand(1:length(fs))
    f = fs[i]
    f(x)
end

@test Base.return_types(f_apply_union_split, Tuple{Tuple{typeof(sqrt), typeof(abs)}, Int64}) == Any[Union{Int64, Float64}]

# Precision of typeassert with PartialStruct
function f_typ_assert(x::Int)
    y = (x, 1)
    y = y::Any
    Val{y[2]}
end
@test Base.return_types(f_typ_assert, (Int,)) == Any[Type{Val{1}}]

function f_typ_assert2(x::Any)
    y = (x::Union{Int, Float64}, 1)
    y = y::Tuple{Int, Any}
    (y[1], Val{y[2]}())
end
@test Base.return_types(f_typ_assert2, (Any,)) == Any[Tuple{Int, Val{1}}]

f_generator_splat(t::Tuple) = tuple((identity(l) for l in t)...)
@test Base.return_types(f_generator_splat, (Tuple{Symbol, Int64, Float64},)) == Any[Tuple{Symbol, Int64, Float64}]

# Issue #36710 - sizeof(::UnionAll) tfunc correctness
@test (sizeof(Ptr),) == sizeof.((Ptr,)) == sizeof.((Ptr{Cvoid},))
@test Core.Compiler.sizeof_tfunc(UnionAll) === Int
@test !Core.Compiler.sizeof_nothrow(UnionAll)

@test Base.return_types(Expr) == Any[Expr]

# Use a global constant to rely less on unrelated constant propagation
const const_int32_typename = Int32.name
# Check constant propagation for field of constant `TypeName`
# works for both valid and invalid field names. (Ref #37443)
getfield_const_typename_good1() = getfield(const_int32_typename, 1)
getfield_const_typename_good2() = getfield(const_int32_typename, :name)
getfield_const_typename_bad1() = getfield(const_int32_typename, 0x1)
@eval getfield_const_typename_bad2() = getfield(const_int32_typename, $(()))
for goodf in [getfield_const_typename_good1, getfield_const_typename_good2]
    local goodf
    local code = code_typed(goodf, Tuple{})[1].first.code
    @test code[1] === Core.ReturnNode(QuoteNode(:Int32))
    @test goodf() === :Int32
end
for badf in [getfield_const_typename_bad1, getfield_const_typename_bad2]
    local badf
    local code = code_typed(badf, Tuple{})[1].first.code
    @test Meta.isexpr(code[1], :call)
    @test code[end] === Core.ReturnNode()
    @test_throws TypeError badf()
end

@test Core.Compiler.return_type(apply26826, Tuple{typeof(sizeof), Vararg{DataType}}) == Int
@test Core.Compiler.return_type(apply26826, Tuple{typeof(sizeof), DataType, Vararg}) == Int
@test Core.Compiler.return_type(apply26826, Tuple{typeof(sizeof), DataType, Any, Vararg}) == Union{}
@test Core.Compiler.return_type(apply26826, Tuple{typeof(===), Vararg}) == Bool
@test Core.Compiler.return_type(apply26826, Tuple{typeof(===), Any, Vararg}) == Bool
@test Core.Compiler.return_type(apply26826, Tuple{typeof(===), Any, Any, Vararg}) == Bool
@test Core.Compiler.return_type(apply26826, Tuple{typeof(===), Any, Any, Any, Vararg}) == Union{}
@test Core.Compiler.return_type(apply26826, Tuple{typeof(setfield!), Vararg{Symbol}}) == Union{}
@test Core.Compiler.return_type(apply26826, Tuple{typeof(setfield!), Any, Vararg{Symbol}}) == Symbol
@test Core.Compiler.return_type(apply26826, Tuple{typeof(setfield!), Any, Symbol, Vararg{Integer}}) == Integer
@test Core.Compiler.return_type(apply26826, Tuple{typeof(setfield!), Any, Symbol, Integer, Vararg}) == Integer
@test Core.Compiler.return_type(apply26826, Tuple{typeof(setfield!), Any, Symbol, Integer, Any, Vararg}) == Integer
@test Core.Compiler.return_type(apply26826, Tuple{typeof(setfield!), Any, Symbol, Integer, Any, Any, Vararg}) == Union{}
@test Core.Compiler.return_type(apply26826, Tuple{typeof(Core._expr), Vararg}) == Expr
@test Core.Compiler.return_type(apply26826, Tuple{typeof(Core._expr), Any, Vararg}) == Expr
@test Core.Compiler.return_type(apply26826, Tuple{typeof(Core._expr), Any, Any, Vararg}) == Expr
@test Core.Compiler.return_type(apply26826, Tuple{typeof(applicable), Vararg}) == Bool
@test Core.Compiler.return_type(apply26826, Tuple{typeof(applicable), Any, Vararg}) == Bool
@test Core.Compiler.return_type(apply26826, Tuple{typeof(applicable), Any, Any, Vararg}) == Bool
@test Core.Compiler.return_type(apply26826, Tuple{typeof(applicable), Any, Any, Any, Vararg}) == Bool
@test Core.Compiler.return_type(apply26826, Tuple{typeof(getfield), Tuple{Int}, Vararg}) == Int
@test Core.Compiler.return_type(apply26826, Tuple{typeof(getfield), Tuple{Int}, Any, Vararg}) == Int
@test Core.Compiler.return_type(apply26826, Tuple{typeof(getfield), Tuple{Int}, Any, Any, Vararg}) == Int
@test Core.Compiler.return_type(apply26826, Tuple{typeof(getfield), Tuple{Int}, Any, Any, Any, Vararg}) == Int
@test Core.Compiler.return_type(apply26826, Tuple{typeof(getfield), Any, Any, Any, Any, Any, Vararg}) == Union{}
@test Core.Compiler.return_type(apply26826, Tuple{typeof(fieldtype), Vararg}) == Any
@test Core.Compiler.return_type(apply26826, Tuple{typeof(fieldtype), Any, Vararg}) == Any
@test Core.Compiler.return_type(apply26826, Tuple{typeof(fieldtype), Any, Any, Vararg}) == Any
@test Core.Compiler.return_type(apply26826, Tuple{typeof(fieldtype), Any, Any, Any, Vararg}) == Any
@test Core.Compiler.return_type(apply26826, Tuple{typeof(fieldtype), Any, Any, Any, Any, Vararg}) == Union{}
@test Core.Compiler.return_type(apply26826, Tuple{typeof(Core.apply_type), Vararg}) == Any
@test Core.Compiler.return_type(apply26826, Tuple{typeof(Core.apply_type), Any, Vararg}) == Any
@test Core.Compiler.return_type(apply26826, Tuple{typeof(Core.apply_type), Any, Any, Vararg}) == Any
f_apply_cglobal(args...) = cglobal(args...)
@test Core.Compiler.return_type(f_apply_cglobal, Tuple{Vararg{Type{Int}}}) == Ptr
@test Core.Compiler.return_type(f_apply_cglobal, Tuple{Any, Vararg{Type{Int}}}) == Ptr
@test Core.Compiler.return_type(f_apply_cglobal, Tuple{Any, Type{Int}, Vararg{Type{Int}}}) == Ptr{Int}
@test Core.Compiler.return_type(f_apply_cglobal, Tuple{Any, Type{Int}, Type{Int}, Vararg{Type{Int}}}) == Union{}

# issue #37532
@test Core.Compiler.intrinsic_nothrow(Core.bitcast, Any[Type{Ptr{Int}}, Int])
@test Core.Compiler.intrinsic_nothrow(Core.bitcast, Any[Type{Ptr{T}} where T, Ptr])
@test !Core.Compiler.intrinsic_nothrow(Core.bitcast, Any[Type{Ptr}, Ptr])
f37532(T, x) = (Core.bitcast(Ptr{T}, x); x)
@test Base.return_types(f37532, Tuple{Any, Int}) == Any[Int]

# PR #37749
# Helper functions for Core.Compiler.Timings. These are normally accessed via a package -
# usually (SnoopCompileCore).
function time_inference(f)
    Core.Compiler.Timings.reset_timings()
    Core.Compiler.__set_measure_typeinf(true)
    f()
    Core.Compiler.__set_measure_typeinf(false)
    Core.Compiler.Timings.close_current_timer()
    return Core.Compiler.Timings._timings[1]
end
function depth(t::Core.Compiler.Timings.Timing)
    maximum(depth.(t.children), init=0) + 1
end
function flatten_times(t::Core.Compiler.Timings.Timing)
    collect(Iterators.flatten([(t.time => t.mi_info,), flatten_times.(t.children)...]))
end
# Some very limited testing of timing the type inference (#37749).
@testset "Core.Compiler.Timings" begin
    # Functions that call each other
    @eval module M1
        i(x) = x+5
        i2(x) = x+2
        h(a::Array) = i2(a[1]::Integer) + i(a[1]::Integer) + 2
        g(y::Integer, x) = h(Any[y]) + Int(x)
    end
    timing1 = time_inference() do
        @eval M1.g(2, 3.0)
    end
    @test occursin(r"Core.Compiler.Timings.Timing\(InferenceFrameInfo for Core.Compiler.Timings.ROOT\(\)\) with \d+ children", sprint(show, timing1))
    # The last two functions to be inferred should be `i` and `i2`, inferred at runtime with
    # their concrete types.
    @test sort([mi_info.mi.def.name for (time,mi_info) in flatten_times(timing1)[end-1:end]]) == [:i, :i2]
    @test all(child->isa(child.bt, Vector), timing1.children)
    @test all(child->child.bt===nothing, timing1.children[1].children)
    # Test the stacktrace
    @test isa(stacktrace(timing1.children[1].bt), Vector{Base.StackTraces.StackFrame})
    # Test that inference has cached some of the Method Instances
    timing2 = time_inference() do
        @eval M1.g(2, 3.0)
    end
    @test length(flatten_times(timing2)) < length(flatten_times(timing1))
    # Printing of InferenceFrameInfo for mi.def isa Module
    @eval module M2
        i(x) = x+5
        i2(x) = x+2
        h(a::Array) = i2(a[1]::Integer) + i(a[1]::Integer) + 2
        g(y::Integer, x) = h(Any[y]) + Int(x)
    end
    # BEGIN LINE NUMBER SENSITIVITY (adjust the line offset below as needed)
    timingmod = time_inference() do
        @eval @testset "Outer" begin
            @testset "Inner" begin
                for i = 1:2 M2.g(2, 3.0) end
            end
        end
    end
    @test occursin("thunk from $(@__MODULE__) starting at $(@__FILE__):$((@__LINE__) - 5)", string(timingmod.children))
    # END LINE NUMBER SENSITIVITY

    # Recursive function
    @eval module _Recursive f(n::Integer) = n == 0 ? 0 : f(n-1) + 1 end
    timing = time_inference() do
        @eval _Recursive.f(Base.inferencebarrier(5))
    end
    @test 2 <= depth(timing) <= 3  # root -> f (-> +)
    @test 2 <= length(flatten_times(timing)) <= 3  # root, f, +

    # Functions inferred with multiple constants
    @eval module C
        i(x) = x === 0 ? 0 : 1 / x
        a(x) = i(0) * i(x)
        b() = i(0) * i(1) * i(0)
        function loopc(n)
            s = 0
            for i = 1:n
                s += i
            end
            return s
        end
        call_loopc() = loopc(5)
        myfloor(::Type{T}, x) where T = floor(T, x)
        d(x) = myfloor(Int16, x)
    end
    timing = time_inference() do
        @eval C.a(2)
        @eval C.b()
        @eval C.call_loopc()
        @eval C.d(3.2)
    end
    ft = flatten_times(timing)
    @test !isempty(ft)
    str = sprint(show, ft)
    @test occursin("InferenceFrameInfo for /(1::$Int, ::$Int)", str)  # inference constants
    @test occursin("InferenceFrameInfo for Core.Compiler.Timings.ROOT()", str) # qualified
    # loopc has internal slots, check constant printing in this case
    sel = filter(ti -> ti.second.mi.def.name === :loopc, ft)
    ifi = sel[end].second
    @test length(ifi.slottypes) > ifi.nargs
    str = sprint(show, sel)
    @test occursin("InferenceFrameInfo for $(@__MODULE__).C.loopc(5::$Int)", str)
    # check that types aren't double-printed as `T::Type{T}`
    sel = filter(ti -> ti.second.mi.def.name === :myfloor, ft)
    str = sprint(show, sel)
    @test occursin("InferenceFrameInfo for $(@__MODULE__).C.myfloor(::Type{Int16}, ::Float64)", str)
end

# issue #37638
@test isa(Core.Compiler.return_type(() -> (nothing, Any[]...)[2], Tuple{}), Type)

# Issue #37943
f37943(x::Any, i::Int) = getfield((x::Pair{false, Int}), i)
g37943(i::Int) = fieldtype(Pair{false, T} where T, i)
@test only(Base.return_types(f37943, Tuple{Any, Int})) === Union{}
@test only(Base.return_types(g37943, Tuple{Int})) === Union{Type{Union{}}, Type{Any}}

# Don't let PartialStruct prevent const prop
f_partial_struct_constprop(a, b) = (a[1]+b[1], nothing)
g_partial_struct_constprop() = Val{f_partial_struct_constprop((1,), (1,))[1]}()
@test only(Base.return_types(g_partial_struct_constprop, Tuple{})) === Val{2}

# N parameter of Vararg is known to be Int
gVarargInt(x::Int) = 1
gVarargInt(x) = 2
fVarargInt(::Tuple{Vararg{Int, N}}) where {N} = Val{gVarargInt(N)}()
@test only(Base.return_types(fVarargInt, Tuple{Tuple{Vararg{Int}}})) == Val{1}

# issue #38888
struct S38888{T}
    S38888(x::S) where {S<:Int} = new{S}()
    S38888(x::S, y) where {S2<:Int,S<:S2} = new{S}()
end
f38888() = S38888(Base.inferencebarrier(3))
@test f38888() isa S38888
g38888() = S38888(Base.inferencebarrier(3), nothing)
@test g38888() isa S38888

f_inf_error_bottom(x::Vector) = isempty(x) ? error(x[1]) : x
@test Core.Compiler.return_type(f_inf_error_bottom, Tuple{Vector{Any}}) == Vector{Any}

# @constprop :aggressive
@noinline g_nonaggressive(y, x) = Val{x}()
@noinline Base.@constprop :aggressive g_aggressive(y, x) = Val{x}()

f_nonaggressive(x) = g_nonaggressive(x, 1)
f_aggressive(x) = g_aggressive(x, 1)

# The first test just makes sure that improvements to the compiler don't
# render the annotation effectless.
@test Base.return_types(f_nonaggressive, Tuple{Int})[1] == Val
@test Base.return_types(f_aggressive, Tuple{Int})[1] == Val{1}

# @constprop :none
@noinline Base.@constprop :none g_noaggressive(flag::Bool) = flag ? 1 : 1.0
ftrue_noaggressive() = g_noaggressive(true)
@test only(Base.return_types(ftrue_noaggressive, Tuple{})) == Union{Int,Float64}


function splat_lotta_unions()
    a = Union{Tuple{Int},Tuple{String,Vararg{Int}},Tuple{Int,Vararg{Int}}}[(2,)][1]
    b = Union{Int8,Int16,Int32,Int64,Int128}[1][1]
    c = Union{Int8,Int16,Int32,Int64,Int128}[1][1]
    (a...,b...,c...)
end
@test Core.Compiler.return_type(splat_lotta_unions, Tuple{}) >: Tuple{Int,Int,Int}

# Bare Core.Argument in IR
@eval f_bare_argument(x) = $(Core.Argument(2))
@test Base.return_types(f_bare_argument, (Int,))[1] == Int

# issue #39611
@test Base.return_types((Union{Int,Nothing},)) do x
    if x === nothing || x < 0
        return 0
    end
    x
end == [Int]

# issue #29100
let f() = Val(fieldnames(Complex{Int}))
    @test @inferred(f()) === Val((:re,:im))
end

@testset "switchtupleunion" begin
    # signature tuple
    let
        tunion = Core.Compiler.switchtupleunion(Tuple{Union{Int32,Int64}, Nothing})
        @test Tuple{Int32, Nothing} in tunion
        @test Tuple{Int64, Nothing} in tunion
    end
    let
        tunion = Core.Compiler.switchtupleunion(Tuple{Union{Int32,Int64}, Union{Float32,Float64}, Nothing})
        @test Tuple{Int32, Float32, Nothing} in tunion
        @test Tuple{Int32, Float64, Nothing} in tunion
        @test Tuple{Int64, Float32, Nothing} in tunion
        @test Tuple{Int64, Float64, Nothing} in tunion
    end

    # argtypes
    let
        tunion = Core.Compiler.switchtupleunion(Any[Union{Int32,Int64}, Core.Const(nothing)])
        @test length(tunion) == 2
        @test Any[Int32, Core.Const(nothing)] in tunion
        @test Any[Int64, Core.Const(nothing)] in tunion
    end
    let
        tunion = Core.Compiler.switchtupleunion(Any[Union{Int32,Int64}, Union{Float32,Float64}, Core.Const(nothing)])
        @test length(tunion) == 4
        @test Any[Int32, Float32, Core.Const(nothing)] in tunion
        @test Any[Int32, Float64, Core.Const(nothing)] in tunion
        @test Any[Int64, Float32, Core.Const(nothing)] in tunion
        @test Any[Int64, Float64, Core.Const(nothing)] in tunion
    end
end

@testset "constant prop' for union split signature" begin
    # indexing into tuples really relies on constant prop', and we will get looser result
    # (`Union{Int,String,Char}`) if constant prop' doesn't happen for splitunion signatures
    tt = (Union{Tuple{Int,String},Tuple{Int,Char}},)
    @test Base.return_types(tt) do t
        getindex(t, 1)
    end == Any[Int]
    @test Base.return_types(tt) do t
        getindex(t, 2)
    end == Any[Union{String,Char}]
    @test Base.return_types(tt) do t
        a, b = t
        a
    end == Any[Int]
    @test Base.return_types(tt) do t
        a, b = t
        b
    end == Any[Union{String,Char}]

    @test (@eval Module() begin
        struct F32
            val::Float32
            _v::Int
        end
        struct F64
            val::Float64
            _v::Int
        end
        Base.return_types((Union{F32,F64},)) do f
            f.val
        end
    end) == Any[Union{Float32,Float64}]

    @test (@eval Module() begin
        struct F32
            val::Float32
            _v
        end
        struct F64
            val::Float64
            _v
        end
        Base.return_types((Union{F32,F64},)) do f
            f.val
        end
    end) == Any[Union{Float32,Float64}]

    @test Base.return_types((Union{Tuple{Nothing,Any,Any},Tuple{Nothing,Any}},)) do t
        getindex(t, 1)
    end == Any[Nothing]

    # issue #37610
    @test Base.return_types((typeof(("foo" => "bar", "baz" => nothing)), Int)) do a, i
        y = iterate(a, i)
        if y !== nothing
            (k, v), st = y
            return k, v
        end
        return y
    end == Any[Union{Nothing, Tuple{String, Union{Nothing, String}}}]
end

@test Base.return_types((Int,)) do x
    if x === 0
        Some(0.0)
    elseif x == 1
        Some(1)
    else
        Some(0x2)
    end
end == [Union{Some{Float64}, Some{Int}, Some{UInt8}}]

# https://github.com/JuliaLang/julia/issues/40336
@testset "make sure a call with signatures with recursively nested Types terminates" begin
    @test @eval Module() begin
        f(@nospecialize(t)) = f(Type{t})

        code_typed() do
            f(Int)
        end
        true
    end

    @test @eval Module() begin
        f(@nospecialize(t)) = tdepth(t) == 10 ? t : f(Type{t})
        tdepth(@nospecialize(t)) = isempty(t.parameters) ? 1 : 1+tdepth(t.parameters[1])

        code_typed() do
            f(Int)
        end
        true
    end
end

# Make sure that const prop doesn't fall into cycles that aren't problematic
# in the type domain
f_recurse(x) = x > 1000000 ? x : f_recurse(x+1)
@test Base.return_types() do
    f_recurse(1)
end |> first === Int

# issue #39915
function f33915(a_tuple, which_ones)
    rest = f33915(Base.tail(a_tuple), Base.tail(which_ones))
    if first(which_ones)
        (first(a_tuple), rest...)
    else
        rest
    end
end
f33915(a_tuple::Tuple{}, which_ones::Tuple{}) = ()
g39915(a_tuple) = f33915(a_tuple, (true, false, true, false))
@test Base.return_types() do
    g39915((1, 1.0, "a", :a))
end |> first === Tuple{Int, String}

# issue #40742
@test Base.return_types(string, (Vector{Tuple{:x}},)) == Any[String]

# issue #40804
@test Base.return_types(()) do; ===(); end == Any[Union{}]
@test Base.return_types(()) do; typeassert(); end == Any[Union{}]

primitive type UInt24ish 24 end
f34288(x) = Core.Intrinsics.checked_sdiv_int(x, Core.Intrinsics.trunc_int(UInt24ish, 0))
@test Base.return_types(f34288, (UInt24ish,)) == Any[UInt24ish]

# Inference of PhiNode showing up in lowered AST
function f_convert_me_to_ir(b, x)
    a = b ? sin(x) : cos(x)
    return a
end

let
    # Test the presence of PhiNodes in lowered IR by taking the above function,
    # running it through SSA conversion and then putting it into an opaque
    # closure.
    mi = Core.Compiler.specialize_method(first(methods(f_convert_me_to_ir)),
        Tuple{Bool, Float64}, Core.svec())
    ci = Base.uncompressed_ast(mi.def)
    ci.ssavaluetypes = Any[Any for i = 1:ci.ssavaluetypes]
    sv = Core.Compiler.OptimizationState(mi, Core.Compiler.OptimizationParams(),
        Core.Compiler.NativeInterpreter())
    ir = Core.Compiler.convert_to_ircode(ci, sv)
    ir = Core.Compiler.slot2reg(ir, ci, sv)
    ir = Core.Compiler.compact!(ir)
    Core.Compiler.replace_code_newstyle!(ci, ir, 4)
    ci.ssavaluetypes = length(ci.code)
    @test any(x->isa(x, Core.PhiNode), ci.code)
    oc = @eval b->$(Expr(:new_opaque_closure, Tuple{Bool, Float64}, Any, Any,
        Expr(:opaque_closure_method, nothing, 2, false, LineNumberNode(0, nothing), ci)))(b, 1.0)
    @test Base.return_types(oc, Tuple{Bool}) == Any[Float64]

    oc = @eval ()->$(Expr(:new_opaque_closure, Tuple{Bool, Float64}, Any, Any,
        Expr(:opaque_closure_method, nothing, 2, false, LineNumberNode(0, nothing), ci)))(true, 1.0)
    @test Base.return_types(oc, Tuple{}) == Any[Float64]
end

@testset "constant prop' on `invoke` calls" begin
    m = Module()

    # simple cases
    @eval m begin
        f(a::Any,    sym::Bool) = sym ? Any : :any
        f(a::Number, sym::Bool) = sym ? Number : :number
    end
    @test (@eval m Base.return_types((Any,)) do a
        Base.@invoke f(a::Any, true::Bool)
    end) == Any[Type{Any}]
    @test (@eval m Base.return_types((Any,)) do a
        Base.@invoke f(a::Number, true::Bool)
    end) == Any[Type{Number}]
    @test (@eval m Base.return_types((Any,)) do a
        Base.@invoke f(a::Any, false::Bool)
    end) == Any[Symbol]
    @test (@eval m Base.return_types((Any,)) do a
        Base.@invoke f(a::Number, false::Bool)
    end) == Any[Symbol]

    # https://github.com/JuliaLang/julia/issues/41024
    @eval m begin
        # mixin, which expects common field `x::Int`
        abstract type AbstractInterface end
        Base.getproperty(x::AbstractInterface, sym::Symbol) =
            sym === :x ? getfield(x, sym)::Int :
            return getfield(x, sym) # fallback

        # extended mixin, which expects additional field `y::Rational{Int}`
        abstract type AbstractInterfaceExtended <: AbstractInterface end
        Base.getproperty(x::AbstractInterfaceExtended, sym::Symbol) =
            sym === :y ? getfield(x, sym)::Rational{Int} :
            return Base.@invoke getproperty(x::AbstractInterface, sym::Symbol)
    end
    @test (@eval m Base.return_types((AbstractInterfaceExtended,)) do x
        x.x
    end) == Any[Int]
end

@testset "fieldtype for unions" begin # e.g. issue #40177
    f40177(::Type{T}) where {T} = fieldtype(T, 1)
    for T in [
        Union{Tuple{Val}, Tuple{Tuple}},
        Union{Base.RefValue{T}, Type{Int32}} where T<:Real,
        Union{Tuple{Vararg{Symbol}}, Tuple{Float64, Vararg{Float32}}},
    ]
        @test @inferred(f40177(T)) == fieldtype(T, 1)
    end
end

# issue #41908
f41908(x::Complex{T}) where {String<:T<:String} = 1
g41908() = f41908(Any[1][1])
@test only(Base.return_types(g41908, ())) <: Int

# issue #42022
let x = Tuple{Int,Any}[
        #= 1=# (0, Expr(:(=), Core.SlotNumber(3), 1))
        #= 2=# (0, Expr(:enter, 18))
        #= 3=# (2, Expr(:(=), Core.SlotNumber(3), 2.0))
        #= 4=# (2, Expr(:enter, 12))
        #= 5=# (4, Expr(:(=), Core.SlotNumber(3), '3'))
        #= 6=# (4, Core.GotoIfNot(Core.SlotNumber(2), 9))
        #= 7=# (4, Expr(:leave, 2))
        #= 8=# (0, Core.ReturnNode(1))
        #= 9=# (4, Expr(:call, GlobalRef(Main, :throw)))
        #=10=# (4, Expr(:leave, 1))
        #=11=# (2, Core.GotoNode(16))
        #=12=# (4, Expr(:leave, 1))
        #=13=# (2, Expr(:(=), Core.SlotNumber(4), Expr(:the_exception)))
        #=14=# (2, Expr(:call, GlobalRef(Main, :rethrow)))
        #=15=# (2, Expr(:pop_exception, Core.SSAValue(4)))
        #=16=# (2, Expr(:leave, 1))
        #=17=# (0, Core.GotoNode(22))
        #=18=# (2, Expr(:leave, 1))
        #=19=# (0, Expr(:(=), Core.SlotNumber(5), Expr(:the_exception)))
        #=20=# (0, nothing)
        #=21=# (0, Expr(:pop_exception, Core.SSAValue(2)))
        #=22=# (0, Core.ReturnNode(Core.SlotNumber(3)))
    ]
    handler_at = Core.Compiler.compute_trycatch(last.(x), Core.Compiler.BitSet())
    @test handler_at == first.(x)
end

@test only(Base.return_types((Bool,)) do y
        x = 1
        try
            x = 2.0
            try
                x = '3'
                y ? (return 1) : throw()
            catch ex1
                rethrow()
            end
        catch ex2
            nothing
        end
        return x
    end) === Union{Int, Float64, Char}

# issue #42097
struct Foo42097{F} end
Foo42097(f::F, args) where {F} = Foo42097{F}()
Foo42097(A) = Foo42097(Base.inferencebarrier(+), Base.inferencebarrier(1)...)
foo42097() = Foo42097([1]...)
@test foo42097() isa Foo42097{typeof(+)}

# eliminate unbound `TypeVar`s on `argtypes` construction
let
    a0(a01, a02, a03, a04, a05, a06, a07, a08, a09, a10, va...) = nothing
    method = only(methods(a0))
    unbound = TypeVar(:Unbound, Integer)
    specTypes = Tuple{typeof(a0),
               # TypeVar
        #=01=# Bound,                  # => Integer
        #=02=# unbound,                # => Integer (invalid `TypeVar` widened beforehand)
               # DataType
        #=03=# Type{Bound},            # => Type{Bound} where Bound<:Integer
        #=04=# Type{unbound},          # => Type
        #=05=# Vector{Bound},          # => Vector{Bound} where Bound<:Integer
        #=06=# Vector{unbound},        # => Any
               # UnionAll
        #=07=# Type{<:Bound},          # => Type{<:Bound} where Bound<:Integer
        #=08=# Type{<:unbound},        # => Any
               # Union
        #=09=# Union{Nothing,Bound},   # => Union{Nothing,Bound} where Bound<:Integer
        #=10=# Union{Nothing,unbound}, # => Any
               # Vararg
        #=va=# Bound, unbound,         # => Tuple{Integer,Integer} (invalid `TypeVar` widened beforehand)
        } where Bound<:Integer
    argtypes = Core.Compiler.most_general_argtypes(method, specTypes, true)
    popfirst!(argtypes)
    @test argtypes[1] == Integer
    @test argtypes[2] == Integer
    @test argtypes[3] == Type{Bound} where Bound<:Integer
    @test argtypes[4] == Type
    @test argtypes[5] == Vector{Bound} where Bound<:Integer
    @test argtypes[6] == Any
    @test argtypes[7] == Type{<:Bound} where Bound<:Integer
    @test argtypes[8] == Any
    @test argtypes[9] == Union{Nothing,Bound} where Bound<:Integer
    @test argtypes[10] == Any
    @test argtypes[11] == Tuple{Integer,Integer}
end

# make sure not to call `widenconst` on `TypeofVararg` objects
@testset "unhandled Vararg" begin
    struct UnhandledVarargCond
        val::Bool
    end
    function Base.:+(a::UnhandledVarargCond, xs...)
        if a.val
            return nothing
        else
            s = 0
            for x in xs
                s += x
            end
            return s
        end
    end
    @test Base.return_types((Vector{Int},)) do xs
        +(UnhandledVarargCond(false), xs...)
    end |> only === Int

    @test (Base.return_types((Vector{Any},)) do xs
        Core.kwfunc(xs...)
    end; true)

    @test Base.return_types((Vector{Vector{Int}},)) do xs
        Tuple(xs...)
    end |> only === Tuple{Vararg{Int}}
end

# issue #42646
@test only(Base.return_types(getindex, (Array{undef}, Int))) >: Union{} # check that it does not throw

# form PartialStruct for extra type information propagation
struct FieldTypeRefinement{S,T}
    s::S
    t::T
end
@test Base.return_types((Int,)) do s
    o = FieldTypeRefinement{Any,Int}(s, s)
    o.s
end |> only == Int
@test Base.return_types((Int,)) do s
    o = FieldTypeRefinement{Int,Any}(s, s)
    o.t
end |> only == Int
@test Base.return_types((Int,)) do s
    o = FieldTypeRefinement{Any,Any}(s, s)
    o.s, o.t
end |> only == Tuple{Int,Int}
@test Base.return_types((Int,)) do a
    s1 = Some{Any}(a)
    s2 = Some{Any}(s1)
    s2.value.value
end |> only == Int

# issue #42986
@testset "narrow down `Union` using `isdefined` checks" begin
    # basic functionality
    @test Base.return_types((Union{Nothing,Core.CodeInstance},)) do x
        if isdefined(x, :inferred)
            return x
        else
            throw("invalid")
        end
    end |> only === Core.CodeInstance

    @test Base.return_types((Union{Nothing,Core.CodeInstance},)) do x
        if isdefined(x, :not_exist)
            return x
        else
            throw("invalid")
        end
    end |> only === Union{}

    # even when isdefined is malformed, we can filter out types with no fields
    @test Base.return_types((Union{Nothing, Core.CodeInstance},)) do x
        if isdefined(x, 5)
            return x
        else
            throw("invalid")
        end
    end |> only === Core.CodeInstance

    struct UnionNarrowingByIsdefinedA; x; end
    struct UnionNarrowingByIsdefinedB; x; end
    struct UnionNarrowingByIsdefinedC; x; end

    # > 2 types in the union
    @test  Base.return_types((Union{UnionNarrowingByIsdefinedA, UnionNarrowingByIsdefinedB, UnionNarrowingByIsdefinedC},)) do x
        if isdefined(x, :x)
            return x
        else
            throw("invalid")
        end
    end |> only === Union{UnionNarrowingByIsdefinedA, UnionNarrowingByIsdefinedB, UnionNarrowingByIsdefinedC}

    # > 2 types in the union and some aren't defined
    @test  Base.return_types((Union{UnionNarrowingByIsdefinedA, Core.CodeInstance, UnionNarrowingByIsdefinedC},)) do x
        if isdefined(x, :x)
            return x
        else
            throw("invalid")
        end
    end |> only === Union{UnionNarrowingByIsdefinedA, UnionNarrowingByIsdefinedC}

    # should respect `Const` information still
    @test Base.return_types((Union{UnionNarrowingByIsdefinedA, UnionNarrowingByIsdefinedB},)) do x
        if isdefined(x, :x)
            return x
        else
            return nothing # dead branch
        end
    end |> only === Union{UnionNarrowingByIsdefinedA, UnionNarrowingByIsdefinedB}
end

# issue #43784
@testset "issue #43784" begin
    init = Base.ImmutableDict{Any,Any}()
    a = Const(init)
    b = Core.PartialStruct(typeof(init), Any[Const(init), Any, Any])
    c = Core.Compiler.tmerge(a, b)
    @test ⊑(a, c)
    @test ⊑(b, c)

    init = Base.ImmutableDict{Number,Number}()
    a = Const(init)
    b = Core.PartialStruct(typeof(init), Any[Const(init), Any, ComplexF64])
    c = Core.Compiler.tmerge(a, b)
    @test ⊑(a, c) && ⊑(b, c)
    @test c === typeof(init)

    a = Core.PartialStruct(typeof(init), Any[Const(init), ComplexF64, ComplexF64])
    c = Core.Compiler.tmerge(a, b)
    @test ⊑(a, c) && ⊑(b, c)
    @test c.fields[2] === Any # or Number
    @test c.fields[3] === ComplexF64

    b = Core.PartialStruct(typeof(init), Any[Const(init), ComplexF32, Union{ComplexF32,ComplexF64}])
    c = Core.Compiler.tmerge(a, b)
    @test ⊑(a, c)
    @test ⊑(b, c)
    @test c.fields[2] === Complex
    @test c.fields[3] === Complex

    global const ginit43784 = Base.ImmutableDict{Any,Any}()
    @test Base.return_types() do
            g = ginit43784
            while true
                g = Base.ImmutableDict(g, 1=>2)
            end
        end |> only === Union{}
end

# Test that purity modeling doesn't accidentally introduce new world age issues
f_redefine_me(x) = x+1
f_call_redefine() = f_redefine_me(0)
f_mk_opaque() = @Base.Experimental.opaque ()->Base.inferencebarrier(f_call_redefine)()
const op_capture_world = f_mk_opaque()
f_redefine_me(x) = x+2
@test op_capture_world() == 1
@test f_mk_opaque()() == 2

# Test that purity doesn't try to accidentally run unreachable code due to
# boundscheck elimination
function f_boundscheck_elim(n)
    # Inbounds here assumes that this is only ever called with n==0, but of
    # course the compiler has no way of knowing that, so it must not attempt
    # to run the @inbounds `getfield(sin, 1)`` that ntuple generates.
    ntuple(x->(@inbounds getfield(sin, x)), n)
end
@test Tuple{} <: code_typed(f_boundscheck_elim, Tuple{Int})[1][2]

@test !Core.Compiler.builtin_nothrow(Core.get_binding_type, Any[Rational{Int}, Core.Const(:foo)], Any)

# Test that max_methods works as expected
@Base.Experimental.max_methods 1 function f_max_methods end
f_max_methods(x::Int) = 1
f_max_methods(x::Float64) = 2
g_max_methods(x) = f_max_methods(x)
@test Core.Compiler.return_type(g_max_methods, Tuple{Int}) === Int
@test Core.Compiler.return_type(g_max_methods, Tuple{Any}) === Any

# Unit tests for BitSetBoundedMinPrioritySet
let bsbmp = Core.Compiler.BitSetBoundedMinPrioritySet(5)
    Core.Compiler.push!(bsbmp, 2)
    Core.Compiler.push!(bsbmp, 2)
    @test Core.Compiler.popfirst!(bsbmp) == 2
    Core.Compiler.push!(bsbmp, 1)
    @test Core.Compiler.popfirst!(bsbmp) == 1
    @test Core.Compiler.isempty(bsbmp)
end

# Make sure return_type_tfunc doesn't accidentally cause bad inference if used
# at top level.
@test let
    Base.Experimental.@force_compile
    Core.Compiler.return_type(+, NTuple{2, Rational})
end == Rational

# https://github.com/JuliaLang/julia/issues/44763
global x44763::Int = 0
increase_x44763!(n) = (global x44763; x44763 += n)
invoke44763(x) = Base.@invoke increase_x44763!(x)
@test Base.return_types() do
    invoke44763(42)
end |> only === Int
@test x44763 == 0
