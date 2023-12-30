# Parses a string into a Julia type object, e.g. `Int`, `Array{Int, 2}`, etc.
function Base.parse(::Type{T}, str::AbstractString) where T<:Type
    ast = Meta.parse(str)
    v = _parse_type(ast)
    # Don't pay for the assertion if not needed (~2 μs)
    T === Type && return v
    return v::T
end

# NOTE: This pattern is a hard-coded part of types: unnamed type variables start with `#s`.
_unnamed_type_var() = Symbol("#s$(gensym())")

function _parse_type(ast; type_vars = nothing)
    if ast isa Expr && ast.head == :curly
        typ = _parse_qualified_type(ast.args[1], type_vars)
        # PERF: Reuse the vector to save allocations
        #type_vars === nothing && (type_vars = Dict{Symbol, TypeVar}())
        new_type_vars = Vector{TypeVar}()
        for i in 2:length(ast.args)
            arg = ast.args[i]
            if arg isa Expr && arg.head === :(<:) && length(arg.args) == 1
                # Change `Vector{<:Number}` to `Vector{#s#27} where #s#27<:Number`
                type_var = TypeVar(_unnamed_type_var(), _parse_type(arg.args[1]; type_vars))
                push!(new_type_vars, type_var)
                # We've consumed this type parameter, so remove it from the AST
                #popfirst!(ast.args)
                ast.args[i] = type_var
                #pushfirst!(arg.args, type_var)
                #type_vars[type_var.name] = type_var
        #@show type_vars
               #body = typ{type_var}
               #typ = UnionAll(type_var, body)

                # ast.args[i] = TypeVar(gensym("s"), _parse_type(ast.args[i].args[1]; type_vars))
            else
                ast.args[i] = _parse_type(ast.args[i]; type_vars)
            end
        end
        # PERF: Drop the first element, instead of args[2:end], to avoid a new sub-vector
        popfirst!(ast.args)
        #@show typ
        #@show ast.args
        body = typ{ast.args...}
        #@show new_type_vars
        if !isempty(new_type_vars)
            # Now work backwards through the new type vars and construct our wrapper UnionAlls:
            for type_var in reverse(new_type_vars)
                body = UnionAll(type_var, body)
            end
        end
        return body
    elseif ast isa Expr && ast.head == :where
        # Collect all the type vars
        type_vars = Dict{Symbol, TypeVar}()
        for i in 2:length(ast.args)
            type_var = _parse_type_var(ast.args[i], type_vars)::TypeVar
            type_vars[type_var.name] = type_var
        end
        # Then evaluate the body in the context of those type vars
        body = _parse_type(ast.args[1]; type_vars)
        for (_, type_var) in type_vars
            body = UnionAll(type_var, body)
        end
        return body
    elseif ast isa Expr && ast.head == :call && ast.args[1] === :typeof
        return typeof(_parse_type(ast.args[2]; type_vars))
    elseif ast isa Expr && ast.head == :call
        return _parse_isbits_constructor(ast, type_vars)
    else
        return _parse_qualified_type(ast, type_vars)
    end
end
_parse_qualified_type(val, _) = val
function _parse_qualified_type(ast::Expr, type_vars)
    @assert ast.head === :(.) "Failed to parse type expression. Expected a \
            qualified type, e.g. `Base.Dict`, got: `$ast`"
    mod = _parse_qualified_type(ast.args[1], type_vars)
    value = ast.args[2]
    if value isa QuoteNode
        value = value.value
    end
    return getglobal(mod, value)
end
function _parse_qualified_type(sym::Symbol, type_vars)
    # First try to look up the symbol in the type vars
    if type_vars !== nothing
        v_if_found = get(type_vars, sym, :not_found)
        if v_if_found !== :not_found
            return v_if_found
        end
    end
    #@show type_vars
    # Otherwise, look up the symbol in Main
    getglobal(Main, sym)
end

# Parses constant isbits constructor expressions, like `Int32(10)` or `Point(0,0)`, as used in type
# parameters like `Val{10}()` or `DefaultDict{Point(0,0)}`.
function _parse_isbits_constructor(ast, type_vars)
    typ = _parse_type(ast.args[1]; type_vars)
    # PERF: Reuse the args vector when parsing the type values.
    popfirst!(ast.args)
    for i in 1:length(ast.args)
        ast.args[i] = _parse_type(ast.args[i]; type_vars)
    end
    # We use reinterpret to avoid evaluating code, which may have side effects.
    return reinterpret(typ, Tuple(ast.args))
end

_parse_type_var(ast::Symbol, _type_vars) = Core.TypeVar(ast)
function _parse_type_var(ast::Expr, type_vars)
    if ast.head === :(<:)
        return Core.TypeVar(ast.args[1], _parse_type(ast.args[2]; type_vars))
    elseif ast.head === :(>:)
        return Core.TypeVar(ast.args[2], _parse_type(ast.args[1]; type_vars))
    elseif ast.head === :comparison
        if ast.args[2] === :(<:)
            @assert ast.args[4] === :(<:) "invalid bounds in \"where\": $ast"
            return Core.TypeVar(ast.args[3], _parse_type(ast.args[1]; type_vars), _parse_type(ast.args[5]; type_vars))
        else
            @assert ast.args[2] === ast.args[4] === :(>:) "invalid bounds in \"where\": $ast"
            return Core.TypeVar(ast.args[3], _parse_type(ast.args[5]; type_vars), _parse_type(ast.args[1]; type_vars))
        end
    else
        @assert false "invalid bounds in \"where\": $ast"
    end
end
