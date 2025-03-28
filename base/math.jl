# This file is a part of Julia. License is MIT: https://julialang.org/license

module Math

export sin, cos, sincos, tan, sinh, cosh, tanh, asin, acos, atan,
       asinh, acosh, atanh, sec, csc, cot, asec, acsc, acot,
       sech, csch, coth, asech, acsch, acoth,
       sinpi, cospi, sincospi, sinc, cosc,
       cosd, cotd, cscd, secd, sind, tand, sincosd,
       acosd, acotd, acscd, asecd, asind, atand,
       rad2deg, deg2rad,
       log, log2, log10, log1p, exponent, exp, exp2, exp10, expm1,
       cbrt, sqrt, significand,
       hypot, max, min, minmax, ldexp, frexp,
       clamp, clamp!, modf, ^, mod2pi, rem2pi,
       @evalpoly, evalpoly

import .Base: log, exp, sin, cos, tan, sinh, cosh, tanh, asin,
             acos, atan, asinh, acosh, atanh, sqrt, log2, log10,
             max, min, minmax, ^, exp2, muladd, rem,
             exp10, expm1, log1p, @constprop, @assume_effects

using .Base: sign_mask, exponent_mask, exponent_one,
            exponent_half, uinttype, significand_mask,
            significand_bits, exponent_bits, exponent_bias,
            exponent_max, exponent_raw_max

using Core.Intrinsics: sqrt_llvm

using .Base: IEEEFloat

@noinline function throw_complex_domainerror(f::Symbol, x)
    throw(DomainError(x,
        LazyString(f," will only return a complex result if called with a complex argument. Try ", f,"(Complex(x)).")))
end
@noinline function throw_exp_domainerror(x)
    throw(DomainError(x, LazyString(
        "Exponentiation yielding a complex result requires a ",
        "complex argument.\nReplace x^y with (x+0im)^y, ",
        "Complex(x)^y, or similar.")))
end

# non-type specific math functions

@inline function two_mul(x::Float64, y::Float64)
    if Core.Intrinsics.have_fma(Float64)
        xy = x*y
        return xy, fma(x, y, -xy)
    end
    return Base.twomul(x,y)
end

@inline function two_mul(x::T, y::T) where T<: Union{Float16, Float32}
    if Core.Intrinsics.have_fma(T)
        xy = x*y
        return xy, fma(x, y, -xy)
    end
    xy = widen(x)*y
    Txy = T(xy)
    return Txy, T(xy-Txy)
end

"""
    clamp(x, lo, hi)

Return `x` if `lo <= x <= hi`. If `x > hi`, return `hi`. If `x < lo`, return `lo`. Arguments
are promoted to a common type.

See also [`clamp!`](@ref), [`min`](@ref), [`max`](@ref).

!!! compat "Julia 1.3"
    `missing` as the first argument requires at least Julia 1.3.

# Examples
```jldoctest
julia> clamp.([pi, 1.0, big(10)], 2.0, 9.0)
3-element Vector{BigFloat}:
 3.141592653589793238462643383279502884197169399375105820974944592307816406286198
 2.0
 9.0

julia> clamp.([11, 8, 5], 10, 6)  # an example where lo > hi
3-element Vector{Int64}:
  6
  6
 10
```
"""
clamp(x::X, lo::L, hi::H) where {X,L,H} =
    ifelse(x > hi, convert(promote_type(X,L,H), hi),
           ifelse(x < lo,
                  convert(promote_type(X,L,H), lo),
                  convert(promote_type(X,L,H), x)))

"""
    clamp(x, T)::T

Clamp `x` between `typemin(T)` and `typemax(T)` and convert the result to type `T`.

See also [`trunc`](@ref).

# Examples
```jldoctest
julia> clamp(200, Int8)
127

julia> clamp(-200, Int8)
-128

julia> trunc(Int, 4pi^2)
39
```
"""
clamp(x, ::Type{T}) where {T<:Integer} = clamp(x, typemin(T), typemax(T)) % T


"""
    clamp!(array::AbstractArray, lo, hi)

Restrict values in `array` to the specified range, in-place.
See also [`clamp`](@ref).

!!! compat "Julia 1.3"
    `missing` entries in `array` require at least Julia 1.3.

# Examples
```jldoctest
julia> row = collect(-4:4)';

julia> clamp!(row, 0, Inf)
1×9 adjoint(::Vector{Int64}) with eltype Int64:
 0  0  0  0  0  1  2  3  4

julia> clamp.((-4:4)', 0, Inf)
1×9 Matrix{Float64}:
 0.0  0.0  0.0  0.0  0.0  1.0  2.0  3.0  4.0
```
"""
function clamp!(x::AbstractArray, lo, hi)
    @inbounds for i in eachindex(x)
        x[i] = clamp(x[i], lo, hi)
    end
    x
end

"""
    clamp(x::Integer, r::AbstractUnitRange)

Clamp `x` to lie within range `r`.

!!! compat "Julia 1.6"
     This method requires at least Julia 1.6.
"""
clamp(x::Integer, r::AbstractUnitRange{<:Integer}) = clamp(x, first(r), last(r))

"""
    evalpoly(x, p)

Evaluate the polynomial ``\\sum_k x^{k-1} p[k]`` for the coefficients `p[1]`, `p[2]`, ...;
that is, the coefficients are given in ascending order by power of `x`.
Loops are unrolled at compile time if the number of coefficients is statically known, i.e.
when `p` is a `Tuple`.
This function generates efficient code using Horner's method if `x` is real, or using
a Goertzel-like [^DK62] algorithm if `x` is complex.

[^DK62]: Donald Knuth, Art of Computer Programming, Volume 2: Seminumerical Algorithms, Sec. 4.6.4.

!!! compat "Julia 1.4"
    This function requires Julia 1.4 or later.

# Example
```jldoctest
julia> evalpoly(2, (1, 2, 3))
17
```
"""
function evalpoly(x, p::Tuple)
    if @generated
        N = length(p.parameters::Core.SimpleVector)
        ex = :(p[end])
        for i in N-1:-1:1
            ex = :(muladd(x, $ex, p[$i]))
        end
        ex
    else
        _evalpoly(x, p)
    end
end

evalpoly(x, p::AbstractVector) = _evalpoly(x, p)

function _evalpoly(x, p)
    N = length(p)
    ex = p[end]
    for i in N-1:-1:1
        ex = muladd(x, ex, p[i])
    end
    ex
end

function evalpoly(z::Complex, p::Tuple)
    if @generated
        N = length(p.parameters)
        a = :(p[end])
        b = :(p[end-1])
        as = []
        for i in N-2:-1:1
            ai = Symbol("a", i)
            push!(as, :($ai = $a))
            a = :(muladd(r, $ai, $b))
            b = :(muladd(-s, $ai, p[$i]))
        end
        ai = :a0
        push!(as, :($ai = $a))
        C = Expr(:block,
                 :(x = real(z)),
                 :(y = imag(z)),
                 :(r = x + x),
                 :(s = muladd(x, x, y*y)),
                 as...,
                 :(muladd($ai, z, $b)))
    else
        _evalpoly(z, p)
    end
end
evalpoly(z::Complex, p::Tuple{<:Any}) = p[1]


evalpoly(z::Complex, p::AbstractVector) = _evalpoly(z, p)

function _evalpoly(z::Complex, p)
    length(p) == 1 && return p[1]
    N = length(p)
    a = p[end]
    b = p[end-1]

    x = real(z)
    y = imag(z)
    r = 2x
    s = muladd(x, x, y*y)
    for i in N-2:-1:1
        ai = a
        a = muladd(r, ai, b)
        b = muladd(-s, ai, p[i])
    end
    ai = a
    muladd(ai, z, b)
end

"""
    @horner(x, p...)

Evaluate `p[1] + x * (p[2] + x * (....))`, i.e. a polynomial via Horner's rule.

See also [`@evalpoly`](@ref), [`evalpoly`](@ref).
"""
macro horner(x, p...)
     xesc, pesc = esc(x), esc.(p)
    :(invoke(evalpoly, Tuple{Any, Tuple}, $xesc, ($(pesc...),)))
end

# Evaluate p[1] + z*p[2] + z^2*p[3] + ... + z^(n-1)*p[n].  This uses
# Horner's method if z is real, but for complex z it uses a more
# efficient algorithm described in Knuth, TAOCP vol. 2, section 4.6.4,
# equation (3).

"""
    @evalpoly(z, c...)

Evaluate the polynomial ``\\sum_k z^{k-1} c[k]`` for the coefficients `c[1]`, `c[2]`, ...;
that is, the coefficients are given in ascending order by power of `z`.  This macro expands
to efficient inline code that uses either Horner's method or, for complex `z`, a more
efficient Goertzel-like algorithm.

See also [`evalpoly`](@ref).

# Examples
```jldoctest
julia> @evalpoly(3, 1, 0, 1)
10

julia> @evalpoly(2, 1, 0, 1)
5

julia> @evalpoly(2, 1, 1, 1)
7
```
"""
macro evalpoly(z, p...)
    zesc, pesc = esc(z), esc.(p)
    :(evalpoly($zesc, ($(pesc...),)))
end

# polynomial evaluation using compensated summation.
# much more accurate, especially when lo can be combined with other rounding errors
@inline function exthorner(x, p::Tuple)
    hi, lo = p[end], zero(x)
    for i in length(p)-1:-1:1
        pi = p[i]
        prod, err = two_mul(hi,x)
        hi = pi+prod
        lo = fma(lo, x, prod - (hi - pi) + err)
    end
    return hi, lo
end

"""
    rad2deg(x)

Convert `x` from radians to degrees.

# Examples
```jldoctest
julia> rad2deg(pi)
180.0
```
"""
rad2deg(z::AbstractFloat) = z * (180 / oftype(z, pi))

"""
    deg2rad(x)

Convert `x` from degrees to radians.

See also: [`rad2deg`](@ref), [`sind`](@ref).

# Examples
```jldoctest
julia> deg2rad(90)
1.5707963267948966
```
"""
deg2rad(z::AbstractFloat) = z * (oftype(z, pi) / 180)
rad2deg(z::Real) = rad2deg(float(z))
deg2rad(z::Real) = deg2rad(float(z))
rad2deg(z::Number) = (z/pi)*180
deg2rad(z::Number) = (z*pi)/180

log(b::T, x::T) where {T<:Number} = log(x)/log(b)

"""
    log(b,x)

Compute the base `b` logarithm of `x`. Throws [`DomainError`](@ref) for negative
[`Real`](@ref) arguments.

# Examples
```jldoctest; filter = r"Stacktrace:(\\n \\[[0-9]+\\].*)*"
julia> log(4,8)
1.5

julia> log(4,2)
0.5

julia> log(-2, 3)
ERROR: DomainError with -2.0:
log will only return a complex result if called with a complex argument. Try log(Complex(x)).
Stacktrace:
 [1] throw_complex_domainerror(::Symbol, ::Float64) at ./math.jl:31
[...]

julia> log(2, -3)
ERROR: DomainError with -3.0:
log will only return a complex result if called with a complex argument. Try log(Complex(x)).
Stacktrace:
 [1] throw_complex_domainerror(::Symbol, ::Float64) at ./math.jl:31
[...]
```

!!! note
    If `b` is a power of 2 or 10, [`log2`](@ref) or [`log10`](@ref) should be used, as these will
    typically be faster and more accurate. For example,

    ```jldoctest
    julia> log(100,1000000)
    2.9999999999999996

    julia> log10(1000000)/2
    3.0
    ```
"""
log(b::Number, x::Number) = log(promote(b,x)...)

# type specific math functions

const libm = Base.libm_name

# functions with no domain error
"""
    sinh(x)

Compute hyperbolic sine of `x`.
"""
sinh(x::Number)

"""
    cosh(x)

Compute hyperbolic cosine of `x`.
"""
cosh(x::Number)

"""
    tanh(x)

Compute hyperbolic tangent of `x`.
"""
tanh(x::Number)

"""
    atan(y)
    atan(y, x)

Compute the inverse tangent of `y` or `y/x`, respectively.

For one argument, this is the angle in radians between the positive *x*-axis and the point
(1, *y*), returning a value in the interval ``[-\\pi/2, \\pi/2]``.

For two arguments, this is the angle in radians between the positive *x*-axis and the
point (*x*, *y*), returning a value in the interval ``[-\\pi, \\pi]``. This corresponds to a
standard [`atan2`](https://en.wikipedia.org/wiki/Atan2) function. Note that by convention
`atan(0.0,x)` is defined as ``\\pi`` and `atan(-0.0,x)` is defined as ``-\\pi`` when `x < 0`.
"""
atan(x::Number)

"""
    asinh(x)

Compute the inverse hyperbolic sine of `x`.
"""
asinh(x::Number)


# utility for converting NaN return to DomainError
# the branch in nan_dom_err prevents its callers from inlining, so be sure to force it
# until the heuristics can be improved
@inline nan_dom_err(out, x) = isnan(out) & !isnan(x) ? throw(DomainError(x, "NaN result for non-NaN input.")) : out

# functions that return NaN on non-NaN argument for domain error
"""
    sin(x)

Compute sine of `x`, where `x` is in radians.

See also [`sind`], [`sinpi`], [`sincos`], [`cis`].
"""
sin(x::Number)

"""
    cos(x)

Compute cosine of `x`, where `x` is in radians.

See also [`cosd`], [`cospi`], [`sincos`], [`cis`].
"""
cos(x::Number)

"""
    tan(x)

Compute tangent of `x`, where `x` is in radians.
"""
tan(x::Number)

"""
    asin(x)

Compute the inverse sine of `x`, where the output is in radians.
"""
asin(x::Number)

"""
    acos(x)

Compute the inverse cosine of `x`, where the output is in radians
"""
acos(x::Number)

"""
    acosh(x)

Compute the inverse hyperbolic cosine of `x`.
"""
acosh(x::Number)

"""
    atanh(x)

Compute the inverse hyperbolic tangent of `x`.
"""
atanh(x::Number)

"""
    log(x)

Compute the natural logarithm of `x`. Throws [`DomainError`](@ref) for negative
[`Real`](@ref) arguments. Use complex negative arguments to obtain complex results.

See also [`log1p`], [`log2`], [`log10`].

# Examples
```jldoctest; filter = r"Stacktrace:(\\n \\[[0-9]+\\].*)*"
julia> log(2)
0.6931471805599453

julia> log(-3)
ERROR: DomainError with -3.0:
log will only return a complex result if called with a complex argument. Try log(Complex(x)).
Stacktrace:
 [1] throw_complex_domainerror(::Symbol, ::Float64) at ./math.jl:31
[...]
```
"""
log(x::Number)

"""
    log2(x)

Compute the logarithm of `x` to base 2. Throws [`DomainError`](@ref) for negative
[`Real`](@ref) arguments.

See also: [`exp2`](@ref), [`ldexp`](@ref), [`ispow2`](@ref).

# Examples
```jldoctest; filter = r"Stacktrace:(\\n \\[[0-9]+\\].*)*"
julia> log2(4)
2.0

julia> log2(10)
3.321928094887362

julia> log2(-2)
ERROR: DomainError with -2.0:
log2 will only return a complex result if called with a complex argument. Try log2(Complex(x)).
Stacktrace:
 [1] throw_complex_domainerror(f::Symbol, x::Float64) at ./math.jl:31
[...]
```
"""
log2(x)

"""
    log10(x)

Compute the logarithm of `x` to base 10.
Throws [`DomainError`](@ref) for negative [`Real`](@ref) arguments.

# Examples
```jldoctest; filter = r"Stacktrace:(\\n \\[[0-9]+\\].*)*"
julia> log10(100)
2.0

julia> log10(2)
0.3010299956639812

julia> log10(-2)
ERROR: DomainError with -2.0:
log10 will only return a complex result if called with a complex argument. Try log10(Complex(x)).
Stacktrace:
 [1] throw_complex_domainerror(f::Symbol, x::Float64) at ./math.jl:31
[...]
```
"""
log10(x)

"""
    log1p(x)

Accurate natural logarithm of `1+x`. Throws [`DomainError`](@ref) for [`Real`](@ref)
arguments less than -1.

# Examples
```jldoctest; filter = r"Stacktrace:(\\n \\[[0-9]+\\].*)*"
julia> log1p(-0.5)
-0.6931471805599453

julia> log1p(0)
0.0

julia> log1p(-2)
ERROR: DomainError with -2.0:
log1p will only return a complex result if called with a complex argument. Try log1p(Complex(x)).
Stacktrace:
 [1] throw_complex_domainerror(::Symbol, ::Float64) at ./math.jl:31
[...]
```
"""
log1p(x)

@inline function sqrt(x::Union{Float32,Float64})
    x < zero(x) && throw_complex_domainerror(:sqrt, x)
    sqrt_llvm(x)
end

"""
    sqrt(x)

Return ``\\sqrt{x}``. Throws [`DomainError`](@ref) for negative [`Real`](@ref) arguments.
Use complex negative arguments instead. The prefix operator `√` is equivalent to `sqrt`.

See also: [`hypot`](@ref).

# Examples
```jldoctest; filter = r"Stacktrace:(\\n \\[[0-9]+\\].*)*"
julia> sqrt(big(81))
9.0

julia> sqrt(big(-81))
ERROR: DomainError with -81.0:
NaN result for non-NaN input.
Stacktrace:
 [1] sqrt(::BigFloat) at ./mpfr.jl:501
[...]

julia> sqrt(big(complex(-81)))
0.0 + 9.0im

julia> .√(1:4)
4-element Vector{Float64}:
 1.0
 1.4142135623730951
 1.7320508075688772
 2.0
```
"""
sqrt(x)

"""
    hypot(x, y)

Compute the hypotenuse ``\\sqrt{|x|^2+|y|^2}`` avoiding overflow and underflow.

This code is an implementation of the algorithm described in:
An Improved Algorithm for `hypot(a,b)`
by Carlos F. Borges
The article is available online at ArXiv at the link
  https://arxiv.org/abs/1904.09481

    hypot(x...)

Compute the hypotenuse ``\\sqrt{\\sum |x_i|^2}`` avoiding overflow and underflow.

See also `norm` in the [`LinearAlgebra`](@ref man-linalg) standard library.

# Examples
```jldoctest; filter = r"Stacktrace:(\\n \\[[0-9]+\\].*)*"
julia> a = Int64(10)^10;

julia> hypot(a, a)
1.4142135623730951e10

julia> √(a^2 + a^2) # a^2 overflows
ERROR: DomainError with -2.914184810805068e18:
sqrt will only return a complex result if called with a complex argument. Try sqrt(Complex(x)).
Stacktrace:
[...]

julia> hypot(3, 4im)
5.0

julia> hypot(-5.7)
5.7

julia> hypot(3, 4im, 12.0)
13.0

julia> using LinearAlgebra

julia> norm([a, a, a, a]) == hypot(a, a, a, a)
true
```
"""
hypot(x::Number) = abs(float(x))
hypot(x::Number, y::Number) = _hypot(promote(float(x), y)...)
hypot(x::Number, y::Number, xs::Number...) = _hypot(promote(float(x), y, xs...))
function _hypot(x, y)
    # preserves unit
    axu = abs(x)
    ayu = abs(y)

    # unitless
    ax = axu / oneunit(axu)
    ay = ayu / oneunit(ayu)

    # Return Inf if either or both inputs is Inf (Compliance with IEEE754)
    if isinf(ax) || isinf(ay)
        return typeof(axu)(Inf)
    end

    # Order the operands
    if ay > ax
        axu, ayu = ayu, axu
        ax, ay = ay, ax
    end

    # Widely varying operands
    if ay <= ax*sqrt(eps(typeof(ax))/2)  #Note: This also gets ay == 0
        return axu
    end

    # Operands do not vary widely
    scale = eps(typeof(ax))*sqrt(floatmin(ax))  #Rescaling constant
    if ax > sqrt(floatmax(ax)/2)
        ax = ax*scale
        ay = ay*scale
        scale = inv(scale)
    elseif ay < sqrt(floatmin(ax))
        ax = ax/scale
        ay = ay/scale
    else
        scale = oneunit(scale)
    end
    h = sqrt(muladd(ax, ax, ay*ay))
    # This branch is correctly rounded but requires a native hardware fma.
    if Core.Intrinsics.have_fma(typeof(h))
        hsquared = h*h
        axsquared = ax*ax
        h -= (fma(-ay, ay, hsquared-axsquared) + fma(h, h,-hsquared) - fma(ax, ax, -axsquared))/(2*h)
    # This branch is within one ulp of correctly rounded.
    else
        if h <= 2*ay
            delta = h-ay
            h -= muladd(delta, delta-2*(ax-ay), ax*(2*delta - ax))/(2*h)
        else
            delta = h-ax
            h -= muladd(delta, delta, muladd(ay, (4*delta - ay), 2*delta*(ax - 2*ay)))/(2*h)
        end
    end
    return h*scale*oneunit(axu)
end
@inline function _hypot(x::Float32, y::Float32)
    if isinf(x) || isinf(y)
        return Inf32
    end
    _x, _y = Float64(x), Float64(y)
    return Float32(sqrt(muladd(_x, _x, _y*_y)))
end
@inline function _hypot(x::Float16, y::Float16)
    if isinf(x) || isinf(y)
        return Inf16
    end
    _x, _y = Float32(x), Float32(y)
    return Float16(sqrt(muladd(_x, _x, _y*_y)))
end
_hypot(x::ComplexF16, y::ComplexF16) = Float16(_hypot(ComplexF32(x), ComplexF32(y)))

function _hypot(x::NTuple{N,<:Number}) where {N}
    maxabs = maximum(abs, x)
    if isnan(maxabs) && any(isinf, x)
        return typeof(maxabs)(Inf)
    elseif (iszero(maxabs) || isinf(maxabs))
        return maxabs
    else
        return maxabs * sqrt(sum(y -> abs2(y / maxabs), x))
    end
end

atan(y::Real, x::Real) = atan(promote(float(y),float(x))...)
atan(y::T, x::T) where {T<:AbstractFloat} = Base.no_op_err("atan", T)

max(x::T, y::T) where {T<:AbstractFloat} = ifelse((y > x) | (signbit(y) < signbit(x)),
                                    ifelse(isnan(x), x, y), ifelse(isnan(y), y, x))


min(x::T, y::T) where {T<:AbstractFloat} = ifelse((y < x) | (signbit(y) > signbit(x)),
                                    ifelse(isnan(x), x, y), ifelse(isnan(y), y, x))

minmax(x::T, y::T) where {T<:AbstractFloat} =
    ifelse(isnan(x) | isnan(y), ifelse(isnan(x), (x,x), (y,y)),
           ifelse((y > x) | (signbit(x) > signbit(y)), (x,y), (y,x)))


"""
    ldexp(x, n)

Compute ``x \\times 2^n``.

# Examples
```jldoctest
julia> ldexp(5., 2)
20.0
```
"""
function ldexp(x::T, e::Integer) where T<:IEEEFloat
    xu = reinterpret(Unsigned, x)
    xs = xu & ~sign_mask(T)
    xs >= exponent_mask(T) && return x # NaN or Inf
    k = (xs >> significand_bits(T)) % Int
    if k == 0 # x is subnormal
        xs == 0 && return x # +-0
        m = leading_zeros(xs) - exponent_bits(T)
        ys = xs << unsigned(m)
        xu = ys | (xu & sign_mask(T))
        k = 1 - m
        # underflow, otherwise may have integer underflow in the following n + k
        e < -50000 && return flipsign(T(0.0), x)
    end
    # For cases where e of an Integer larger than Int make sure we properly
    # overflow/underflow; this is optimized away otherwise.
    if e > typemax(Int)
        return flipsign(T(Inf), x)
    elseif e < typemin(Int)
        return flipsign(T(0.0), x)
    end
    n = e % Int
    k += n
    # overflow, if k is larger than maximum possible exponent
    if k >= exponent_raw_max(T)
        return flipsign(T(Inf), x)
    end
    if k > 0 # normal case
        xu = (xu & ~exponent_mask(T)) | (rem(k, uinttype(T)) << significand_bits(T))
        return reinterpret(T, xu)
    else # subnormal case
        if k <= -significand_bits(T) # underflow
            # overflow, for the case of integer overflow in n + k
            e > 50000 && return flipsign(T(Inf), x)
            return flipsign(T(0.0), x)
        end
        k += significand_bits(T)
        # z = T(2.0) ^ (-significand_bits(T))
        z = reinterpret(T, rem(exponent_bias(T)-significand_bits(T), uinttype(T)) << significand_bits(T))
        xu = (xu & ~exponent_mask(T)) | (rem(k, uinttype(T)) << significand_bits(T))
        return z*reinterpret(T, xu)
    end
end
ldexp(x::Float16, q::Integer) = Float16(ldexp(Float32(x), q))

"""
    exponent(x::AbstractFloat) -> Int

Get the exponent of a normalized floating-point number.
Returns the largest integer `y` such that `2^y ≤ abs(x)`.

# Examples
```jldoctest
julia> exponent(6.5)
2

julia> exponent(16.0)
4
```
"""
function exponent(x::T) where T<:IEEEFloat
    @noinline throw1(x) = throw(DomainError(x, "Cannot be NaN or Inf."))
    @noinline throw2(x) = throw(DomainError(x, "Cannot be ±0.0."))
    xs = reinterpret(Unsigned, x) & ~sign_mask(T)
    xs >= exponent_mask(T) && throw1(x)
    k = Int(xs >> significand_bits(T))
    if k == 0 # x is subnormal
        xs == 0 && throw2(x)
        m = leading_zeros(xs) - exponent_bits(T)
        k = 1 - m
    end
    return k - exponent_bias(T)
end

# Like exponent, but assumes the nothrow precondition. For
# internal use only. Could be written as
# @assume_effects :nothrow exponent()
# but currently this form is easier on the compiler.
function _exponent_finite_nonzero(x::T) where T<:IEEEFloat
    # @precond :nothrow !isnan(x) && !isinf(x) && !iszero(x)
    xs = reinterpret(Unsigned, x) & ~sign_mask(T)
    k = rem(xs >> significand_bits(T), Int)
    if k == 0 # x is subnormal
        m = leading_zeros(xs) - exponent_bits(T)
        k = 1 - m
    end
    return k - exponent_bias(T)
end

"""
    significand(x)

Extract the significand (a.k.a. mantissa) of a floating-point number. If `x` is
a non-zero finite number, then the result will be a number of the same type and
sign as `x`, and whose absolute value is on the interval ``[1,2)``. Otherwise
`x` is returned.

# Examples
```jldoctest
julia> significand(15.2)
1.9

julia> significand(-15.2)
-1.9

julia> significand(-15.2) * 2^3
-15.2

julia> significand(-Inf), significand(Inf), significand(NaN)
(-Inf, Inf, NaN)
```
"""
function significand(x::T) where T<:IEEEFloat
    xu = reinterpret(Unsigned, x)
    xs = xu & ~sign_mask(T)
    xs >= exponent_mask(T) && return x # NaN or Inf
    if xs <= (~exponent_mask(T) & ~sign_mask(T)) # x is subnormal
        xs == 0 && return x # +-0
        m = unsigned(leading_zeros(xs) - exponent_bits(T))
        xs <<= m
        xu = xs | (xu & sign_mask(T))
    end
    xu = (xu & ~exponent_mask(T)) | exponent_one(T)
    return reinterpret(T, xu)
end

"""
    frexp(val)

Return `(x,exp)` such that `x` has a magnitude in the interval ``[1/2, 1)`` or 0,
and `val` is equal to ``x \\times 2^{exp}``.
# Examples
```jldoctest
julia> frexp(12.8)
(0.8, 4)
```
"""
function frexp(x::T) where T<:IEEEFloat
    xu = reinterpret(Unsigned, x)
    xs = xu & ~sign_mask(T)
    xs >= exponent_mask(T) && return x, 0 # NaN or Inf
    k = Int(xs >> significand_bits(T))
    if k == 0 # x is subnormal
        xs == 0 && return x, 0 # +-0
        m = leading_zeros(xs) - exponent_bits(T)
        xs <<= unsigned(m)
        xu = xs | (xu & sign_mask(T))
        k = 1 - m
    end
    k -= (exponent_bias(T) - 1)
    xu = (xu & ~exponent_mask(T)) | exponent_half(T)
    return reinterpret(T, xu), k
end

# NOTE: This `rem` method is adapted from the msun `remainder` and `remainderf`
# functions, which are under the following license:
#
# Copyright (C) 1993 by Sun Microsystems, Inc. All rights reserved.
#
# Developed at SunSoft, a Sun Microsystems, Inc. business.
# Permission to use, copy, modify, and distribute this
# software is freely granted, provided that this notice
# is preserved.
function rem(x::T, p::T, ::RoundingMode{:Nearest}) where T<:IEEEFloat
    (iszero(p) || !isfinite(x) || isnan(p)) && return T(NaN)
    x == p && return copysign(zero(T), x)
    oldx = x
    x = abs(rem(x, 2p))  # 2p may overflow but that's okay
    p = abs(p)
    if p < 2 * floatmin(T)  # Check whether dividing p by 2 will underflow
        if 2x > p
            x -= p
            if 2x >= p
                x -= p
            end
        end
    else
        p_half = p / 2
        if x > p_half
            x -= p
            if x >= p_half
                x -= p
            end
        end
    end
    return flipsign(x, oldx)
end


"""
    modf(x)

Return a tuple `(fpart, ipart)` of the fractional and integral parts of a number. Both parts
have the same sign as the argument.

# Examples
```jldoctest
julia> modf(3.5)
(0.5, 3.0)

julia> modf(-3.5)
(-0.5, -3.0)
```
"""
modf(x) = isinf(x) ? (flipsign(zero(x), x), x) : (rem(x, one(x)), trunc(x))

function modf(x::T) where T<:IEEEFloat
    isinf(x) && return (copysign(zero(T), x), x)
    ix = trunc(x)
    rx = copysign(x - ix, x)
    return (rx, ix)
end

# @constprop aggressive to help the compiler see the switch between the integer and float
# variants for callers with constant `y`
@constprop :aggressive function ^(x::Float64, y::Float64)
    yint = unsafe_trunc(Int, y) # Note, this is actually safe since julia freezes the result
    y == yint && return x^yint
    #numbers greater than 2*inv(eps(T)) must be even, and the pow will overflow
    y >= 2*inv(eps()) && return x^(typemax(Int64)-1)
    x<0 && y > -4e18 && throw_exp_domainerror(x) # |y| is small enough that y isn't an integer
    x == 1 && return 1.0
    return pow_body(x, y)
end

@inline function pow_body(x::Float64, y::Float64)
    !isfinite(x) && return x*(y>0 || isnan(x))
    x==0 && return abs(y)*Inf*(!(y>0))
    logxhi,logxlo = Base.Math._log_ext(x)
    xyhi, xylo = two_mul(logxhi,y)
    xylo = muladd(logxlo, y, xylo)
    hi = xyhi+xylo
    return Base.Math.exp_impl(hi, xylo-(hi-xyhi), Val(:ℯ))
end

@constprop :aggressive function ^(x::T, y::T) where T <: Union{Float16, Float32}
    yint = unsafe_trunc(Int64, y) # Note, this is actually safe since julia freezes the result
    y == yint && return x^yint
    #numbers greater than 2*inv(eps(T)) must be even, and the pow will overflow
    y >= 2*inv(eps(T)) && return x^(typemax(Int64)-1)
    x < 0 && y > -4e18 && throw_exp_domainerror(x) # |y| is small enough that y isn't an integer
    return pow_body(x, y)
end

@inline function pow_body(x::T, y::T) where T <: Union{Float16, Float32}
    x == 1 && return one(T)
    !isfinite(x) && return x*(y>0 || isnan(x))
    x==0 && return abs(y)*T(Inf)*(!(y>0))
    return T(exp2(log2(abs(widen(x))) * y))
end

# compensated power by squaring
@constprop :aggressive @inline function ^(x::Float64, n::Integer)
    n == 0 && return one(x)
    return pow_body(x, n)
end

@assume_effects :terminates_locally @noinline function pow_body(x::Float64, n::Integer)
    y = 1.0
    xnlo = ynlo = 0.0
    n == 3 && return x*x*x # keep compatibility with literal_pow
    if n < 0
        rx = inv(x)
        n==-2 && return rx*rx #keep compatability with literal_pow
        isfinite(x) && (xnlo = -fma(x, rx, -1.) * rx)
        x = rx
        n = -n
    end
    while n > 1
        if n&1 > 0
            err = muladd(y, xnlo, x*ynlo)
            y, ynlo = two_mul(x,y)
            ynlo += err
        end
        err = x*2*xnlo
        x, xnlo = two_mul(x, x)
        xnlo += err
        n >>>= 1
    end
    !isfinite(x) && return x*y
    return muladd(x, y, muladd(y, xnlo, x*ynlo))
end

function ^(x::Float32, n::Integer)
    n == -2 && return (i=inv(x); i*i)
    n == 3 && return x*x*x #keep compatibility with literal_pow
    n < 0 && return Float32(Base.power_by_squaring(inv(Float64(x)),-n))
    Float32(Base.power_by_squaring(Float64(x),n))
end
@inline ^(x::Float16, y::Integer) = Float16(Float32(x) ^ y)
@inline literal_pow(::typeof(^), x::Float16, ::Val{p}) where {p} = Float16(literal_pow(^,Float32(x),Val(p)))

## rem2pi-related calculations ##

function add22condh(xh::Float64, xl::Float64, yh::Float64, yl::Float64)
    # This algorithm, due to Dekker, computes the sum of two
    # double-double numbers and returns the high double. References:
    # [1] http://www.digizeitschriften.de/en/dms/img/?PID=GDZPPN001170007
    # [2] https://doi.org/10.1007/BF01397083
    r = xh+yh
    s = (abs(xh) > abs(yh)) ? (xh-r+yh+yl+xl) : (yh-r+xh+xl+yl)
    zh = r+s
    return zh
end

# multiples of pi/2, as double-double (ie with "tail")
const pi1o2_h  = 1.5707963267948966     # convert(Float64, pi * BigFloat(1/2))
const pi1o2_l  = 6.123233995736766e-17  # convert(Float64, pi * BigFloat(1/2) - pi1o2_h)

const pi2o2_h  = 3.141592653589793      # convert(Float64, pi * BigFloat(1))
const pi2o2_l  = 1.2246467991473532e-16 # convert(Float64, pi * BigFloat(1) - pi2o2_h)

const pi3o2_h  = 4.71238898038469       # convert(Float64, pi * BigFloat(3/2))
const pi3o2_l  = 1.8369701987210297e-16 # convert(Float64, pi * BigFloat(3/2) - pi3o2_h)

const pi4o2_h  = 6.283185307179586      # convert(Float64, pi * BigFloat(2))
const pi4o2_l  = 2.4492935982947064e-16 # convert(Float64, pi * BigFloat(2) - pi4o2_h)

"""
    rem2pi(x, r::RoundingMode)

Compute the remainder of `x` after integer division by `2π`, with the quotient rounded
according to the rounding mode `r`. In other words, the quantity

    x - 2π*round(x/(2π),r)

without any intermediate rounding. This internally uses a high precision approximation of
2π, and so will give a more accurate result than `rem(x,2π,r)`

- if `r == RoundNearest`, then the result is in the interval ``[-π, π]``. This will generally
  be the most accurate result. See also [`RoundNearest`](@ref).

- if `r == RoundToZero`, then the result is in the interval ``[0, 2π]`` if `x` is positive,.
  or ``[-2π, 0]`` otherwise. See also [`RoundToZero`](@ref).

- if `r == RoundDown`, then the result is in the interval ``[0, 2π]``.
  See also [`RoundDown`](@ref).
- if `r == RoundUp`, then the result is in the interval ``[-2π, 0]``.
  See also [`RoundUp`](@ref).

# Examples
```jldoctest
julia> rem2pi(7pi/4, RoundNearest)
-0.7853981633974485

julia> rem2pi(7pi/4, RoundDown)
5.497787143782138
```
"""
function rem2pi end
function rem2pi(x::Float64, ::RoundingMode{:Nearest})
    abs(x) < pi && return x

    n,y = rem_pio2_kernel(x)

    if iseven(n)
        if n & 2 == 2 # n % 4 == 2: add/subtract pi
            if y.hi <= 0
                return add22condh(y.hi,y.lo,pi2o2_h,pi2o2_l)
            else
                return add22condh(y.hi,y.lo,-pi2o2_h,-pi2o2_l)
            end
        else          # n % 4 == 0: add 0
            return y.hi+y.lo
        end
    else
        if n & 2 == 2 # n % 4 == 3: subtract pi/2
            return add22condh(y.hi,y.lo,-pi1o2_h,-pi1o2_l)
        else          # n % 4 == 1: add pi/2
            return add22condh(y.hi,y.lo,pi1o2_h,pi1o2_l)
        end
    end
end
function rem2pi(x::Float64, ::RoundingMode{:ToZero})
    ax = abs(x)
    ax <= 2*Float64(pi,RoundDown) && return x

    n,y = rem_pio2_kernel(ax)

    if iseven(n)
        if n & 2 == 2 # n % 4 == 2: add pi
            z = add22condh(y.hi,y.lo,pi2o2_h,pi2o2_l)
        else          # n % 4 == 0: add 0 or 2pi
            if y.hi > 0
                z = y.hi+y.lo
            else      # negative: add 2pi
                z = add22condh(y.hi,y.lo,pi4o2_h,pi4o2_l)
            end
        end
    else
        if n & 2 == 2 # n % 4 == 3: add 3pi/2
            z = add22condh(y.hi,y.lo,pi3o2_h,pi3o2_l)
        else          # n % 4 == 1: add pi/2
            z = add22condh(y.hi,y.lo,pi1o2_h,pi1o2_l)
        end
    end
    copysign(z,x)
end
function rem2pi(x::Float64, ::RoundingMode{:Down})
    if x < pi4o2_h
        if x >= 0
            return x
        elseif x > -pi4o2_h
            return add22condh(x,0.0,pi4o2_h,pi4o2_l)
        end
    end

    n,y = rem_pio2_kernel(x)

    if iseven(n)
        if n & 2 == 2 # n % 4 == 2: add pi
            return add22condh(y.hi,y.lo,pi2o2_h,pi2o2_l)
        else          # n % 4 == 0: add 0 or 2pi
            if y.hi > 0
                return y.hi+y.lo
            else      # negative: add 2pi
                return add22condh(y.hi,y.lo,pi4o2_h,pi4o2_l)
            end
        end
    else
        if n & 2 == 2 # n % 4 == 3: add 3pi/2
            return add22condh(y.hi,y.lo,pi3o2_h,pi3o2_l)
        else          # n % 4 == 1: add pi/2
            return add22condh(y.hi,y.lo,pi1o2_h,pi1o2_l)
        end
    end
end
function rem2pi(x::Float64, ::RoundingMode{:Up})
    if x > -pi4o2_h
        if x <= 0
            return x
        elseif x < pi4o2_h
            return add22condh(x,0.0,-pi4o2_h,-pi4o2_l)
        end
    end

    n,y = rem_pio2_kernel(x)

    if iseven(n)
        if n & 2 == 2 # n % 4 == 2: sub pi
            return add22condh(y.hi,y.lo,-pi2o2_h,-pi2o2_l)
        else          # n % 4 == 0: sub 0 or 2pi
            if y.hi < 0
                return y.hi+y.lo
            else      # positive: sub 2pi
                return add22condh(y.hi,y.lo,-pi4o2_h,-pi4o2_l)
            end
        end
    else
        if n & 2 == 2 # n % 4 == 3: sub pi/2
            return add22condh(y.hi,y.lo,-pi1o2_h,-pi1o2_l)
        else          # n % 4 == 1: sub 3pi/2
            return add22condh(y.hi,y.lo,-pi3o2_h,-pi3o2_l)
        end
    end
end

rem2pi(x::Float32, r::RoundingMode) = Float32(rem2pi(Float64(x), r))
rem2pi(x::Float16, r::RoundingMode) = Float16(rem2pi(Float64(x), r))
rem2pi(x::Int32, r::RoundingMode) = rem2pi(Float64(x), r)
function rem2pi(x::Int64, r::RoundingMode)
    fx = Float64(x)
    fx == x || throw(ArgumentError("Int64 argument to rem2pi is too large: $x"))
    rem2pi(fx, r)
end

"""
    mod2pi(x)

Modulus after division by `2π`, returning in the range ``[0,2π)``.

This function computes a floating point representation of the modulus after division by
numerically exact `2π`, and is therefore not exactly the same as `mod(x,2π)`, which would
compute the modulus of `x` relative to division by the floating-point number `2π`.

!!! note
    Depending on the format of the input value, the closest representable value to 2π may
    be less than 2π. For example, the expression `mod2pi(2π)` will not return `0`, because
    the intermediate value of `2*π` is a `Float64` and `2*Float64(π) < 2*big(π)`. See
    [`rem2pi`](@ref) for more refined control of this behavior.

# Examples
```jldoctest
julia> mod2pi(9*pi/4)
0.7853981633974481
```
"""
mod2pi(x) = rem2pi(x,RoundDown)

# generic fallback; for number types, promotion.jl does promotion

"""
    muladd(x, y, z)

Combined multiply-add: computes `x*y+z`, but allowing the add and multiply to be merged
with each other or with surrounding operations for performance.
For example, this may be implemented as an [`fma`](@ref) if the hardware supports it
efficiently.
The result can be different on different machines and can also be different on the same machine
due to constant propagation or other optimizations.
See [`fma`](@ref).

# Examples
```jldoctest
julia> muladd(3, 2, 1)
7

julia> 3 * 2 + 1
7
```
"""
muladd(x,y,z) = x*y+z


# helper functions for Libm functionality

"""
    highword(x)

Return the high word of `x` as a `UInt32`.
"""
@inline highword(x::Float64) = highword(reinterpret(UInt64, x))
@inline highword(x::UInt64)  = (x >>> 32) % UInt32
@inline highword(x::Float32) = reinterpret(UInt32, x)

@inline fromhighword(::Type{Float64}, u::UInt32) = reinterpret(Float64, UInt64(u) << 32)
@inline fromhighword(::Type{Float32}, u::UInt32) = reinterpret(Float32, u)


"""
    poshighword(x)

Return positive part of the high word of `x` as a `UInt32`.
"""
@inline poshighword(x::Float64) = poshighword(reinterpret(UInt64, x))
@inline poshighword(x::UInt64)  = highword(x) & 0x7fffffff
@inline poshighword(x::Float32) = highword(x) & 0x7fffffff

# More special functions
include("special/cbrt.jl")
include("special/exp.jl")
include("special/hyperbolic.jl")
include("special/trig.jl")
include("special/rem_pio2.jl")
include("special/log.jl")


# Float16 definitions

for func in (:sin,:cos,:tan,:asin,:acos,:atan,:cosh,:tanh,:asinh,:acosh,
             :atanh,:log,:log2,:log10,:sqrt,:lgamma,:log1p)
    @eval begin
        $func(a::Float16) = Float16($func(Float32(a)))
        $func(a::ComplexF16) = ComplexF16($func(ComplexF32(a)))
    end
end

for func in (:exp,:exp2,:exp10,:sinh)
     @eval $func(a::ComplexF16) = ComplexF16($func(ComplexF32(a)))
end


atan(a::Float16,b::Float16) = Float16(atan(Float32(a),Float32(b)))
sincos(a::Float16) = Float16.(sincos(Float32(a)))

for f in (:sin, :cos, :tan, :asin, :atan, :acos,
          :sinh, :cosh, :tanh, :asinh, :acosh, :atanh,
          :exp, :exp2, :exp10, :expm1, :log, :log2, :log10, :log1p,
          :exponent, :sqrt, :cbrt)
    @eval function ($f)(x::Real)
        xf = float(x)
        x === xf && throw(MethodError($f, (x,)))
        return ($f)(xf)
    end
    @eval $(f)(::Missing) = missing
end

for f in (:atan, :hypot, :log)
    @eval $(f)(::Missing, ::Missing) = missing
    @eval $(f)(::Number, ::Missing) = missing
    @eval $(f)(::Missing, ::Number) = missing
end

exp2(x::AbstractFloat) = 2^x
exp10(x::AbstractFloat) = 10^x
clamp(::Missing, lo, hi) = missing

end # module
