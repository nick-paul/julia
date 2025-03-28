# This file is a part of Julia. License is MIT: https://julialang.org/license

const LineNum = Int

# The type of a variable load is either a value or an UndefVarError
# (only used in abstractinterpret, doesn't appear in optimize)
struct VarState
    typ
    undef::Bool
    VarState(@nospecialize(typ), undef::Bool) = new(typ, undef)
end

"""
    const VarTable = Vector{VarState}

The extended lattice that maps local variables to inferred type represented as `AbstractLattice`.
Each index corresponds to the `id` of `SlotNumber` which identifies each local variable.
Note that `InferenceState` will maintain multiple `VarTable`s at each SSA statement
to enable flow-sensitive analysis.
"""
const VarTable = Vector{VarState}

mutable struct BitSetBoundedMinPrioritySet <: AbstractSet{Int}
    elems::BitSet
    min::Int
    # Stores whether min is exact or a lower bound
    # If exact, it is not set in elems
    min_exact::Bool
    max::Int
end

function BitSetBoundedMinPrioritySet(max::Int)
    bs = BitSet()
    bs.offset = 0
    BitSetBoundedMinPrioritySet(bs, max+1, true, max)
end

@noinline function _advance_bsbmp!(bsbmp::BitSetBoundedMinPrioritySet)
    @assert !bsbmp.min_exact
    bsbmp.min = _bits_findnext(bsbmp.elems.bits, bsbmp.min)::Int
    bsbmp.min < 0 && (bsbmp.min = bsbmp.max + 1)
    bsbmp.min_exact = true
    delete!(bsbmp.elems, bsbmp.min)
    return nothing
end

function isempty(bsbmp::BitSetBoundedMinPrioritySet)
    if bsbmp.min > bsbmp.max
        return true
    end
    bsbmp.min_exact && return false
    _advance_bsbmp!(bsbmp)
    return bsbmp.min > bsbmp.max
end

function popfirst!(bsbmp::BitSetBoundedMinPrioritySet)
    bsbmp.min_exact || _advance_bsbmp!(bsbmp)
    m = bsbmp.min
    m > bsbmp.max && throw(ArgumentError("BitSetBoundedMinPrioritySet must be non-empty"))
    bsbmp.min = m+1
    bsbmp.min_exact = false
    return m
end

function push!(bsbmp::BitSetBoundedMinPrioritySet, idx::Int)
    if idx <= bsbmp.min
        if bsbmp.min_exact && bsbmp.min < bsbmp.max && idx != bsbmp.min
            push!(bsbmp.elems, bsbmp.min)
        end
        bsbmp.min = idx
        bsbmp.min_exact = true
        return nothing
    end
    push!(bsbmp.elems, idx)
    return nothing
end

function in(idx::Int, bsbmp::BitSetBoundedMinPrioritySet)
    if bsbmp.min_exact && idx == bsbmp.min
        return true
    end
    return idx in bsbmp.elems
end

mutable struct InferenceState
    params::InferenceParams
    result::InferenceResult # remember where to put the result
    linfo::MethodInstance
    sptypes::Vector{Any}    # types of static parameter
    slottypes::Vector{Any}
    mod::Module
    currpc::LineNum
    pclimitations::IdSet{InferenceState} # causes of precision restrictions (LimitedAccuracy) on currpc ssavalue
    limitations::IdSet{InferenceState} # causes of precision restrictions (LimitedAccuracy) on return

    # info on the state of inference and the linfo
    src::CodeInfo
    world::UInt
    valid_worlds::WorldRange
    nargs::Int
    stmt_types::Vector{Union{Nothing, VarTable}}
    stmt_edges::Vector{Union{Nothing, Vector{Any}}}
    stmt_info::Vector{Any}
    # return type
    bestguess #::Type
    # current active instruction pointers
    ip::BitSetBoundedMinPrioritySet
    # current exception handler info
    handler_at::Vector{LineNum}
    # ssavalue sparsity and restart info
    ssavalue_uses::Vector{BitSet}

    cycle_backedges::Vector{Tuple{InferenceState, LineNum}} # call-graph backedges connecting from callee to caller
    callers_in_cycle::Vector{InferenceState}
    parent::Union{Nothing, InferenceState}

    # TODO: move these to InferenceResult / Params?
    cached::Bool
    inferred::Bool
    dont_work_on_me::Bool

    # Whether to restrict inference of abstract call sites to avoid excessive work
    # Set by default for toplevel frame.
    restrict_abstract_call_sites::Bool

    # Inferred purity flags
    ipo_effects::Effects

    # The interpreter that created this inference state. Not looked at by
    # NativeInterpreter. But other interpreters may use this to detect cycles
    interp::AbstractInterpreter

    # src is assumed to be a newly-allocated CodeInfo, that can be modified in-place to contain intermediate results
    function InferenceState(result::InferenceResult, src::CodeInfo,
                            cache::Symbol, interp::AbstractInterpreter)
        (; def) = linfo = result.linfo
        code = src.code::Vector{Any}

        params = InferenceParams(interp)

        sp = sptypes_from_meth_instance(linfo::MethodInstance)

        nssavalues = src.ssavaluetypes::Int
        src.ssavaluetypes = Any[ NOT_FOUND for i = 1:nssavalues ]
        stmt_info = Any[ nothing for i = 1:length(code) ]

        nstmts = length(code)
        s_types = Union{Nothing, VarTable}[ nothing for i = 1:nstmts ]
        s_edges = Union{Nothing, Vector{Any}}[ nothing for i = 1:nstmts ]

        # initial types
        nslots = length(src.slotflags)
        argtypes = result.argtypes
        nargs = length(argtypes)
        s_argtypes = VarTable(undef, nslots)
        slottypes = Vector{Any}(undef, nslots)
        for i in 1:nslots
            at = (i > nargs) ? Bottom : argtypes[i]
            s_argtypes[i] = VarState(at, i > nargs)
            slottypes[i] = at
        end
        s_types[1] = s_argtypes

        ssavalue_uses = find_ssavalue_uses(code, nssavalues)

        # exception handlers
        ip = BitSetBoundedMinPrioritySet(nstmts)
        handler_at = compute_trycatch(src.code, ip.elems)
        push!(ip, 1)

        # `throw` block deoptimization
        params.unoptimize_throw_blocks && mark_throw_blocks!(src, handler_at)

        mod = isa(def, Method) ? def.module : def
        valid_worlds = WorldRange(src.min_world,
            src.max_world == typemax(UInt) ? get_world_counter() : src.max_world)

        # TODO: Currently, any :inbounds declaration taints consistency,
        #       because we cannot be guaranteed whether or not boundschecks
        #       will be eliminated and if they are, we cannot be guaranteed
        #       that no undefined behavior will occur (the effects assumptions
        #       are stronger than the inbounds assumptions, since the latter
        #       requires dynamic reachability, while the former is global).
        inbounds = inbounds_option()
        inbounds_taints_consistency = !(inbounds === :on || (inbounds === :default && !any_inbounds(code)))
        consistent = inbounds_taints_consistency ? TRISTATE_UNKNOWN : ALWAYS_TRUE

        @assert cache === :no || cache === :local || cache === :global
        frame = new(
            params, result, linfo,
            sp, slottypes, mod, #=currpc=#0,
            #=pclimitations=#IdSet{InferenceState}(), #=limitations=#IdSet{InferenceState}(),
            src, get_world_counter(interp), valid_worlds,
            nargs, s_types, s_edges, stmt_info,
            #=bestguess=#Union{}, ip, handler_at, ssavalue_uses,
            #=cycle_backedges=#Vector{Tuple{InferenceState,LineNum}}(),
            #=callers_in_cycle=#Vector{InferenceState}(),
            #=parent=#nothing,
            #=cached=#cache === :global,
            #=inferred=#false, #=dont_work_on_me=#false, #=restrict_abstract_call_sites=# isa(linfo.def, Module),
            #=ipo_effects=#Effects(consistent, ALWAYS_TRUE, ALWAYS_TRUE, ALWAYS_TRUE, false, inbounds_taints_consistency),
            interp)
        result.result = frame
        cache !== :no && push!(get_inference_cache(interp), result)
        return frame
    end
end

Effects(state::InferenceState) = state.ipo_effects

function tristate_merge!(caller::InferenceState, effects::Effects)
    caller.ipo_effects = tristate_merge(caller.ipo_effects, effects)
end
tristate_merge!(caller::InferenceState, callee::InferenceState) =
    tristate_merge!(caller, Effects(callee))

is_effect_overridden(sv::InferenceState, effect::Symbol) = is_effect_overridden(sv.linfo, effect)
function is_effect_overridden(linfo::MethodInstance, effect::Symbol)
    def = linfo.def
    return isa(def, Method) && is_effect_overridden(def, effect)
end
is_effect_overridden(method::Method, effect::Symbol) = is_effect_overridden(decode_effects_override(method.purity), effect)
is_effect_overridden(override::EffectsOverride, effect::Symbol) = getfield(override, effect)

function any_inbounds(code::Vector{Any})
    for i=1:length(code)
        stmt = code[i]
        if isa(stmt, Expr) && stmt.head === :inbounds
            return true
        end
    end
    return false
end

function compute_trycatch(code::Vector{Any}, ip::BitSet)
    # The goal initially is to record the frame like this for the state at exit:
    # 1: (enter 3) # == 0
    # 3: (expr)    # == 1
    # 3: (leave 1) # == 1
    # 4: (expr)    # == 0
    # then we can find all trys by walking backwards from :enter statements,
    # and all catches by looking at the statement after the :enter
    n = length(code)
    empty!(ip)
    ip.offset = 0 # for _bits_findnext
    push!(ip, n + 1)
    handler_at = fill(0, n)

    # start from all :enter statements and record the location of the try
    for pc = 1:n
        stmt = code[pc]
        if isexpr(stmt, :enter)
            l = stmt.args[1]::Int
            handler_at[pc + 1] = pc
            push!(ip, pc + 1)
            handler_at[l] = pc
            push!(ip, l)
        end
    end

    # now forward those marks to all :leave statements
    pc´´ = 0
    while true
        # make progress on the active ip set
        pc = _bits_findnext(ip.bits, pc´´)::Int
        pc > n && break
        while true # inner loop optimizes the common case where it can run straight from pc to pc + 1
            pc´ = pc + 1 # next program-counter (after executing instruction)
            if pc == pc´´
                pc´´ = pc´
            end
            delete!(ip, pc)
            cur_hand = handler_at[pc]
            @assert cur_hand != 0 "unbalanced try/catch"
            stmt = code[pc]
            if isa(stmt, GotoNode)
                pc´ = stmt.label
            elseif isa(stmt, GotoIfNot)
                l = stmt.dest::Int
                if handler_at[l] != cur_hand
                    @assert handler_at[l] == 0 "unbalanced try/catch"
                    handler_at[l] = cur_hand
                    if l < pc´´
                        pc´´ = l
                    end
                    push!(ip, l)
                end
            elseif isa(stmt, ReturnNode)
                @assert !isdefined(stmt, :val) "unbalanced try/catch"
                break
            elseif isa(stmt, Expr)
                head = stmt.head
                if head === :enter
                    cur_hand = pc
                elseif head === :leave
                    l = stmt.args[1]::Int
                    for i = 1:l
                        cur_hand = handler_at[cur_hand]
                    end
                    cur_hand == 0 && break
                end
            end

            pc´ > n && break # can't proceed with the fast-path fall-through
            if handler_at[pc´] != cur_hand
                @assert handler_at[pc´] == 0 "unbalanced try/catch"
                handler_at[pc´] = cur_hand
            elseif !in(pc´, ip)
                break  # already visited
            end
            pc = pc´
        end
    end

    @assert first(ip) == n + 1
    return handler_at
end

"""
    Iterate through all callers of the given InferenceState in the abstract
    interpretation stack (including the given InferenceState itself), vising
    children before their parents (i.e. ascending the tree from the given
    InferenceState). Note that cycles may be visited in any order.
"""
struct InfStackUnwind
    inf::InferenceState
end
iterate(unw::InfStackUnwind) = (unw.inf, (unw.inf, 0))
function iterate(unw::InfStackUnwind, (infstate, cyclei)::Tuple{InferenceState, Int})
    # iterate through the cycle before walking to the parent
    if cyclei < length(infstate.callers_in_cycle)
        cyclei += 1
        infstate = infstate.callers_in_cycle[cyclei]
    else
        cyclei = 0
        infstate = infstate.parent
    end
    infstate === nothing && return nothing
    (infstate::InferenceState, (infstate, cyclei))
end

function InferenceState(result::InferenceResult, cache::Symbol, interp::AbstractInterpreter)
    # prepare an InferenceState object for inferring lambda
    src = retrieve_code_info(result.linfo)
    src === nothing && return nothing
    validate_code_in_debug_mode(result.linfo, src, "lowered")
    return InferenceState(result, src, cache, interp)
end

function sptypes_from_meth_instance(linfo::MethodInstance)
    toplevel = !isa(linfo.def, Method)
    if !toplevel && isempty(linfo.sparam_vals) && isa(linfo.def.sig, UnionAll)
        # linfo is unspecialized
        sp = Any[]
        sig = linfo.def.sig
        while isa(sig, UnionAll)
            push!(sp, sig.var)
            sig = sig.body
        end
    else
        sp = collect(Any, linfo.sparam_vals)
    end
    for i = 1:length(sp)
        v = sp[i]
        if v isa TypeVar
            fromArg = 0
            # if this parameter came from arg::Type{T}, then `arg` is more precise than
            # Type{T} where lb<:T<:ub
            sig = linfo.def.sig
            temp = sig
            for j = 1:i-1
                temp = temp.body
            end
            Pi = temp.var
            while temp isa UnionAll
                temp = temp.body
            end
            sigtypes = (temp::DataType).parameters
            for j = 1:length(sigtypes)
                tj = sigtypes[j]
                if isType(tj) && tj.parameters[1] === Pi
                    fromArg = j
                    break
                end
            end
            if fromArg > 0
                ty = fieldtype(linfo.specTypes, fromArg)
            else
                ub = v.ub
                while ub isa TypeVar
                    ub = ub.ub
                end
                if has_free_typevars(ub)
                    ub = Any
                end
                lb = v.lb
                while lb isa TypeVar
                    lb = lb.lb
                end
                if has_free_typevars(lb)
                    lb = Bottom
                end
                if Any <: ub && lb <: Bottom
                    ty = Any
                else
                    tv = TypeVar(v.name, lb, ub)
                    ty = UnionAll(tv, Type{tv})
                end
            end
        elseif isvarargtype(v)
            ty = Int
        else
            ty = Const(v)
        end
        sp[i] = ty
    end
    return sp
end

_topmod(sv::InferenceState) = _topmod(sv.mod)

# work towards converging the valid age range for sv
function update_valid_age!(sv::InferenceState, worlds::WorldRange)
    sv.valid_worlds = intersect(worlds, sv.valid_worlds)
    @assert(sv.world in sv.valid_worlds, "invalid age range update")
    nothing
end

update_valid_age!(edge::InferenceState, sv::InferenceState) = update_valid_age!(sv, edge.valid_worlds)

function record_ssa_assign(ssa_id::Int, @nospecialize(new), frame::InferenceState)
    ssavaluetypes = frame.src.ssavaluetypes::Vector{Any}
    old = ssavaluetypes[ssa_id]
    if old === NOT_FOUND || !(new ⊑ old)
        # typically, we expect that old ⊑ new (that output information only
        # gets less precise with worse input information), but to actually
        # guarantee convergence we need to use tmerge here to ensure that is true
        ssavaluetypes[ssa_id] = old === NOT_FOUND ? new : tmerge(old, new)
        W = frame.ip
        s = frame.stmt_types
        for r in frame.ssavalue_uses[ssa_id]
            if s[r] !== nothing # s[r] === nothing => unreached statement
                push!(W, r)
            end
        end
    end
    nothing
end

function add_cycle_backedge!(frame::InferenceState, caller::InferenceState, currpc::Int)
    update_valid_age!(frame, caller)
    backedge = (caller, currpc)
    contains_is(frame.cycle_backedges, backedge) || push!(frame.cycle_backedges, backedge)
    add_backedge!(frame.linfo, caller)
    return frame
end

# temporarily accumulate our edges to later add as backedges in the callee
function add_backedge!(li::MethodInstance, caller::InferenceState)
    isa(caller.linfo.def, Method) || return # don't add backedges to toplevel exprs
    edges = caller.stmt_edges[caller.currpc]
    if edges === nothing
        edges = caller.stmt_edges[caller.currpc] = []
    end
    push!(edges, li)
    nothing
end

# used to temporarily accumulate our no method errors to later add as backedges in the callee method table
function add_mt_backedge!(mt::Core.MethodTable, @nospecialize(typ), caller::InferenceState)
    isa(caller.linfo.def, Method) || return # don't add backedges to toplevel exprs
    edges = caller.stmt_edges[caller.currpc]
    if edges === nothing
        edges = caller.stmt_edges[caller.currpc] = []
    end
    push!(edges, mt)
    push!(edges, typ)
    nothing
end

function print_callstack(sv::InferenceState)
    while sv !== nothing
        print(sv.linfo)
        !sv.cached && print("  [uncached]")
        println()
        for cycle in sv.callers_in_cycle
            print(' ', cycle.linfo)
            println()
        end
        sv = sv.parent
    end
end

get_curr_ssaflag(sv::InferenceState) = sv.src.ssaflags[sv.currpc]
