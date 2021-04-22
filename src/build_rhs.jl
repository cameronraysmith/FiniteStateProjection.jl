""" 
    getsubstitutions(idxhandler::AbstractIndexHandler, sys::FSPSystem; state_sym::Symbol)::Dict

Construct the map `speciesname => expr` that gives the species abundances
in terms of the state variable `state_sym`. See [`NaiveIndexHandler`](@ref)
for the default implementation.

See also: [`build_ratefuncs`](@ref), [`build_rhs`](@ref)
"""
function getsubstitutions end

""" 
    build_ratefuncs(idxhandler::AbstractIndexHandler, sys::FSPSystem; state_sym::Symbol)::Vector

Return the rate functions converted to Julia expressions in the state variable 
`state_sym`. Abundances of the species are computed using `getsubstitutions`.

See also: [`getsubstitutions`](@ref), [`build_rhs`](@ref)
"""
function build_ratefuncs(idxhandler::AbstractIndexHandler, sys::FSPSystem; state_sym::Symbol)::Vector
    substitutions = getsubstitutions(idxhandler, sys, state_sym=state_sym)
    
    return [ toexpr(substitute(jumpratelaw(reac), substitutions)) for reac in sys.rs.eqs ]
end

"""
    unpackparams(sys::FSPSystem, psym::Symbol)

Returns code unpacking the parameters of the system from the symbol
`psym` in the form `(p1, p2, ...) = psym`. This should be called in
all overloads of [`build_rhs_header`](@ref). It is assumed that
the variable `psym` is an `AbstractVector{Float64}`.

See also: [`build_rhs_header`](@ref), [`build_rhs`](@ref)
"""
function unpackparams(sys::FSPSystem, psym::Symbol)::Expr
    param_names = Expr(:tuple, map(par -> par.name, params(sys.rs))...)
     
    quote 
        $(param_names) = ps::AbstractVector{Float64}
    end
end

"""
    build_rhs_header(idxhandler::AbstractIndexHandler, sys::FSPSystem)::Expr

Return initialisation code for the RHS function, unpacking the parameters
`p` supplied by `DifferentialEquations`. The default implementation
just unpacks parameters from `p`.

See also: [`unpackparams`](@ref), [`build_rhs`](@ref)
"""
function build_rhs_header(::AbstractIndexHandler, sys::FSPSystem)::Expr
    quote 
        ps::AbstractVector{Float64} = p
        $(unpackparams(sys, :ps))
    end
end

##

"""
    build_rhs_firstpass(sys::FSPSystem, rfs)::Expr

Return code for the first pass of the RHS function. Goes through
all reactions and computes the negative part of the CME (probability
flowing out of states). This is a simple array traversal and can be
done in one go for all reactions.

See also: [`build_rhs`](@ref)
"""
function build_rhs_firstpass(idxhandler::AbstractIndexHandler, sys::FSPSystem, rfs::AbstractVector)::Expr
    isempty(rfs) && return quote end
        
    first_line = :(du[idx_in] = -u[idx_in] * $(rfs[1]))
    other_lines = (:(du[idx_in] -= u[idx_in] * $(rf)) for rf in rfs[2:end])
    
    quote
        for idx_in in singleindices($(idxhandler), u)
            $first_line
            $(other_lines...)
        end
    end
end

##

"""
    build_rhs_secondpass(sys::FSPSystem, rfs)::Expr

Return code for the second pass of the RHS function. Goes through
all reactions and computes the positive part of the CME (probability
flowing into states). This requires accessing `du` and `u` at different
locations depending on the net stoichiometries. In order to reduce 
random memory access reactions are processed one by one.

See also: [`build_rhs`](@ref)
"""
function build_rhs_secondpass(idxhandler::AbstractIndexHandler, sys::FSPSystem, rfs::AbstractVector)::Expr
    isempty(rfs) && return quote end
    
    S = netstoichmat(sys.rs)
    ret = Expr(:block)
    
    for (i, rf) in enumerate(rfs)
        ex = quote
            for (idx_in, idx_out) in pairedindices($(idxhandler), u, $(CartesianIndex(S[i,:]...)))
                du[idx_out] += u[idx_in] * $(rf)
            end
        end
        
        append!(ret.args, ex.args)
    end
    
    return ret
end

##

"""
    build_rhs(idxhandler::AbstractIndexHandler, sys::FSPSystem)

Builds the function `f(du,u,p,t)` that defines the right-hand side of the CME, 
for use in the ODE solver. If `expression` is true, returns an expression, else
compiles the function. 
"""
function build_rhs(idxhandler::AbstractIndexHandler, sys::FSPSystem; expression::Bool=true, striplines::Bool=expression) 
    rfs = build_ratefuncs(idxhandler, sys, state_sym=:idx_in)
    header = build_rhs_header(idxhandler, sys)

    first_pass = build_rhs_firstpass(idxhandler, sys, rfs)
    second_pass = build_rhs_secondpass(idxhandler, sys, rfs)
    
    args = Expr(:tuple, :du, :u, :p, :t)
    body = Expr(:block, header, first_pass, second_pass)
    
    ex = Expr(:function, args, body) 
    
    striplines && (ex = MacroTools.striplines(ex))
    
    ex = ex |> MacroTools.flatten |> MacroTools.prettify
    
    if expression
        return ex
    else
        return @RuntimeGeneratedFunction(ex)
    end
end

##

"""
    convert(::Type{ODEFunction}, idxhandler::AbstractIndexHandler, sys::FSPSystem)

Return an `ODEFunction` defining the right-hand side of the CME.

Combines the RHS func and its Jacobian to define an `ODEFunction` for 
use with `DifferentialEquations`.
"""
function Base.convert(::Type{ODEFunction}, idxhandler::AbstractIndexHandler, sys::FSPSystem)::ODEFunction
    rhs = build_rhs(idxhandler, sys, expression=false, striplines=false)
    ODEFunction{true}(rhs)
end

"""
    convert(::Type{ODEProblem}, idxhandler::AbstractIndexHandler, sys::FSPSystem, u0, tmax, p)

Return an `ODEProblem` for use in `DifferentialEquations. 
"""
function Base.convert(::Type{ODEProblem}, idxhandler::AbstractIndexHandler, sys::FSPSystem, u0, tmax, p)::ODEProblem
     ODEProblem(convert(ODEFunction, idxhandler, sys), u0, tmax, p)
end
