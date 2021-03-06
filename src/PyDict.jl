"""
    PyDict{K=PyObject, V=PyObject}([o])

Wrap the Python dictionary `o` (or anything satisfying the mapping interface) as a Julia dictionary with keys of type `K` and values of type `V`.

If `o` is not a Python object, it must iterate pairs and is converted to a Python dict.

If `o` is not given, an empty dict is created.
"""
mutable struct PyDict{K,V} <: AbstractDict{K,V}
    ptr::CPyPtr
    hasbuiltins::Bool
    PyDict{K,V}(::Val{:new}, ptr::Ptr, hasbuiltins::Bool=false) where {K,V} = finalizer(pyref_finalize!, new{K,V}(CPyPtr(ptr), hasbuiltins))
end
PyDict{K,V}(o) where {K,V} = PyDict{K,V}(Val(:new), checknull(ispyref(o) ? C.PyObject_From(o) : C.PyDict_FromPairs(o)))
PyDict{K,V}() where {K,V} = PyDict{K,V}(Val(:new), CPyPtr(0))
PyDict{K}(args...) where {K} = PyDict{K,PyObject}(args...)
PyDict(args...) = PyDict{PyObject,PyObject}(args...)
export PyDict

const pyglobals = PyDict{String}()
export pyglobals

ispyreftype(::Type{<:PyDict}) = true
pyptr(x::PyDict) = begin
    ptr = x.ptr
    if isnull(ptr)
        ptr = x.ptr = C.PyDict_New()
    end
    ptr
end
Base.unsafe_convert(::Type{CPyPtr}, x::PyDict) = checknull(pyptr(x))
C.PyObject_TryConvert__initial(o, ::Type{PyDict}) =
    C.PyObject_TryConvert__initial(o, PyDict{PyObject, PyObject})
C.PyObject_TryConvert__initial(o, ::Type{PyDict{K}}) where {K} =
    C.PyObject_TryConvert__initial(o, PyDict{K, PyObject})
C.PyObject_TryConvert__initial(o, ::Type{PyDict{K,V}}) where {K,V} = begin
    C.Py_IncRef(o)
    C.putresult(PyDict{K,V}(Val(:new), o))
end

ensurehasbuiltins!(x::PyDict) = begin
    if !x.hasbuiltins
        if C.PyMapping_HasKeyString(x, "__builtins__") == 0
            err = C.PyMapping_SetItemString(
                x,
                "__builtins__",
                C.PyEval_GetBuiltins(),
            )
            ism1(err) && pythrow()
        end
        x.hasbuiltins = true
    end
end

Base.iterate(x::PyDict{K,V}, it::PyRef = pyiter(PyRef, x)) where {K,V} = begin
    ko = C.PyIter_Next(it)
    if !isnull(ko)
        # key
        r = C.PyObject_Convert(ko, K)
        r == -1 && (C.Py_DecRef(ko); pythrow())
        k = C.takeresult(K)
        # value
        vo = C.PyObject_GetItem(x, ko)
        C.Py_DecRef(ko)
        isnull(vo) && pythrow()
        r = C.PyObject_Convert(vo, V)
        C.Py_DecRef(vo)
        r == -1 && pythrow()
        v = C.takeresult(V)
        # done
        (k => v, it)
    elseif C.PyErr_IsSet()
        pythrow()
    else
        nothing
    end
end

Base.iterate(x::Base.KeySet{K,PyDict{K,V}}, it::PyRef = pyiter(PyRef, x.dict)) where {K,V} = begin
    ko = C.PyIter_Next(it)
    if !isnull(ko)
        r = C.PyObject_Convert(ko, K)
        C.Py_DecRef(ko)
        r == -1 && pythrow()
        k = C.takeresult(K)
        (k, it)
    elseif C.PyErr_IsSet()
        pythrow()
    else
        nothing
    end
end

Base.setindex!(x::PyDict{K,V}, v, k) where {K,V} =
    pysetitem(x, convertref(K, k), convertref(V, v))

Base.getindex(x::PyDict{K,V}, k) where {K,V} = pygetitem(V, x, convertref(K, k))

Base.delete!(x::PyDict{K}, k) where {K} = pydelitem(x, convertref(K, k))

Base.length(x::PyDict) = Int(pylen(x))

Base.empty!(x::PyDict) = (@py `$x.clear()`; x)

Base.copy(x::PyDict) = @pyv `$x.copy()`::typeof(x)

Base.haskey(x::PyDict{K}, _k) where {K} = begin
    k = tryconvertref(K, _k)
    k === PYERR() && pythrow()
    k === NOTIMPLEMENTED() && return false
    pycontains(x, k)
end

Base.get(x::PyDict{K}, _k, d) where {K} = begin
    k = tryconvertref(K, _k)
    k === PYERR() && pythrow()
    (k !== NOTIMPLEMENTED() && pycontains(x, k)) ? x[k] : d
end

Base.get(d::Function, x::PyDict{K}, _k) where {K} = begin
    k = tryconvertref(K, _k)
    k === PYERR() && pythrow()
    (k !== NOTIMPLEMENTED() && pycontains(x, k)) ? x[k] : d()
end

Base.get!(x::PyDict{K,V}, _k, d) where {K,V} = begin
    k = convertref(K, _k)
    pycontains(x, k) ? x[k] : (x[k] = convert(V, d))
end

Base.get!(d::Function, x::PyDict{K,V}, _k) where {K,V} = begin
    k = convertref(K, _k)
    pycontains(x, k) ? x[k] : (x[k] = convert(V, d()))
end
