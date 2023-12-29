# Parses a string into a Julia DataType object, e.g. `Int`, `Array{Int, 2}`, etc.
function Base.parse(::Type{DataType}, str::AbstractString)
    ast = Meta.parse(str)
    return _parse_type(ast)::DataType
end
function _parse_type(ast)
    if ast isa Expr && ast.head == :curly
        typ = _parse_qualified_type(ast.args[1])
        # PERF: Reuse the vector to save allocations
        for i in 2:length(ast.args)
            ast.args[i] = _parse_type(ast.args[i])
        end
        # PERF: Drop the first element, instead of args[2:end], to avoid a new sub-vector
        popfirst!(ast.args)
        return typ{ast.args...}
    else
        return _parse_qualified_type(ast)
    end
end
function _parse_qualified_type(ast::Expr)
    @assert ast.head === :(.)
    mod = _parse_qualified_type(ast.args[1])
    value = ast.args[2]
    if value isa QuoteNode
        value = value.value
    end
    return getglobal(mod, value)
end
_parse_qualified_type(mod::Symbol) = getglobal(Main, mod)
