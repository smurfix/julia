# Parses a string into a Julia type object, e.g. `Int`, `Array{Int, 2}`, etc.
function Base.parse(::Type{T}, str::AbstractString) where T<:Type
    ast = Meta.parse(str)
    v = _parse_type(ast)
    # Don't pay for the assertion if not needed (~2 μs)
    T === Type && return v
    return v::T
end
function _parse_type(ast; type_vars = nothing)
    if ast isa Expr && ast.head == :curly
        typ = _parse_qualified_type(ast.args[1], type_vars)
        # PERF: Reuse the vector to save allocations
        type_vars === nothing && (type_vars = Dict{Symbol, TypeVar}())
        for i in 2:length(ast.args)
            if ast.args[i] isa Expr && ast.args[i].head === :(<:)
                # Change `Vector{<:Number}` to `Vector{#s#27} where #s#27<:Number`
                type_var = TypeVar(gensym("s"), _parse_type(ast.args[i].args[2]; type_vars))
                pushfirst!(ast.args[i].args, type_var)
                type_vars[type_var.name] = type_var
        @show type_vars
        @show ast.args[i]
               body = _parse_type(ast.args[i]; type_vars)
               ast.args[i] = UnionAll(type_var, body)

                # ast.args[i] = TypeVar(gensym("s"), _parse_type(ast.args[i].args[1]; type_vars))
            else
                ast.args[i] = _parse_type(ast.args[i]; type_vars)
            end
        end
        # PERF: Drop the first element, instead of args[2:end], to avoid a new sub-vector
        popfirst!(ast.args)
        return typ{ast.args...}
    elseif ast isa Expr && ast.head == :where
        # Collect all the type vars
        type_vars = Dict{Symbol, TypeVar}()
        for i in 2:length(ast.args)
            type_var = _parse_type_var(ast.args[i], type_vars)::TypeVar
            type_vars[type_var.name] = type_var
        end
        # Then evaluate the body in the context of those type vars
        body = _parse_type(ast.args[1]; type_vars)
        for (name, type_var) in type_vars
            body = UnionAll(type_var, body)
        end
        return body
    else
        return _parse_qualified_type(ast, type_vars)
    end
end
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

_parse_type_var(ast::Symbol, type_vars) = Core.TypeVar(ast)
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
