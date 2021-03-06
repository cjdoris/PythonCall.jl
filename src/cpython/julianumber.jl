pyjlnumber_bool(xo::PyPtr) =
    @pyjltry (iszero(PyJuliaValue_GetValue(xo)::Number) ? Cint(0) : Cint(1)) Cint(-1)

pyjlnumber_positive(xo::PyPtr) =
    @pyjltry PyObject_From(+(PyJuliaValue_GetValue(xo)::Number)) PyNULL

pyjlnumber_negative(xo::PyPtr) =
    @pyjltry PyObject_From(-(PyJuliaValue_GetValue(xo)::Number)) PyNULL

pyjlnumber_absolute(xo::PyPtr) =
    @pyjltry PyObject_From(abs(PyJuliaValue_GetValue(xo)::Number)) PyNULL

struct pyjlnumber_binop{F}
    f::F
end
(f::pyjlnumber_binop)(xo::PyPtr, yo::PyPtr) = begin
    r = PyObject_TryConvert(xo, Number)
    r == -1 && return PyNULL
    r == 0 && return PyNotImplemented_New()
    x = takeresult(Number)
    r = PyObject_TryConvert(yo, Number)
    r == -1 && return PyNULL
    r == 0 && return PyNotImplemented_New()
    y = takeresult(Number)
    @pyjltry PyObject_From(f.f(x, y)) PyNULL (MethodError, f.f)=>NotImplemented
end

pyjlnumber_power(xo::PyPtr, yo::PyPtr, zo::PyPtr) = begin
    r = PyObject_TryConvert(xo, Number)
    r == -1 && return PyNULL
    r == 0 && return PyNotImplemented_New()
    x = takeresult(Number)
    r = PyObject_TryConvert(yo, Number)
    r == -1 && return PyNULL
    r == 0 && return PyNotImplemented_New()
    y = takeresult(Number)
    if PyNone_Check(zo)
        @pyjltry PyObject_From(x^y) PyNULL (MethodError, ^)=>NotImplemented
    else
        r = PyObject_TryConvert(zo, Number)
        r == -1 && return PyNULL
        r == 0 && return PyNotImplemented_New()
        z = takeresult(Number)
        @pyjltry PyObject_From(powermod(x, y, z)) PyNULL (MethodError, powermod)=>NotImplemented
    end
end

pyjlcomplex_real(xo::PyPtr, ::Ptr{Cvoid}) =
    @pyjltry PyObject_From(real(PyJuliaValue_GetValue(xo)::Complex)) PyNULL

pyjlcomplex_imag(xo::PyPtr, ::Ptr{Cvoid}) =
    @pyjltry PyObject_From(imag(PyJuliaValue_GetValue(xo)::Complex)) PyNULL

pyjlcomplex_conjugate(xo::PyPtr, ::PyPtr) =
    @pyjltry PyObject_From(conj(PyJuliaValue_GetValue(xo)::Complex)) PyNULL

pyjlcomplex_complex(xo::PyPtr, ::PyPtr) =
    @pyjltry PyComplex_From(convert(Complex{Float64}, PyJuliaValue_GetValue(xo)::Complex)) PyNULL

pyjlreal_real(xo::PyPtr, ::Ptr{Cvoid}) = (Py_IncRef(xo); xo)

pyjlreal_imag(xo::PyPtr, ::Ptr{Cvoid}) = PyLong_From(0)

pyjlreal_conjugate(xo::PyPtr, ::PyPtr) = (Py_IncRef(xo); xo)

pyjlreal_complex(xo::PyPtr, ::PyPtr) =
    @pyjltry PyComplex_From(convert(Float64, PyJuliaValue_GetValue(xo)::Real)) PyNULL

pyjlreal_float(xo::PyPtr) =
    @pyjltry PyFloat_From(convert(Float64, PyJuliaValue_GetValue(xo)::Real)) PyNULL

pyjlreal_trunc(xo::PyPtr, ::PyPtr) =
    @pyjltry PyObject_From(trunc(Integer, PyJuliaValue_GetValue(xo)::Real)) PyNULL

pyjlreal_floor(xo::PyPtr, ::PyPtr) =
    @pyjltry PyObject_From(floor(Integer, PyJuliaValue_GetValue(xo)::Real)) PyNULL

pyjlreal_ceil(xo::PyPtr, ::PyPtr) =
    @pyjltry PyObject_From(ceil(Integer, PyJuliaValue_GetValue(xo)::Real)) PyNULL

pyjlreal_round(xo::PyPtr, args::PyPtr) = begin
    ism1(PyArg_CheckNumArgsLe("round", args, 1)) && return PyNULL
    ism1(PyArg_GetArg(Union{Int,Nothing}, "round", args, 0, nothing)) && return PyNULL
    ndigits = takeresult(Union{Int,Nothing})
    x = PyJuliaValue_GetValue(xo)::Real
    @pyjltry begin
        if ndigits === nothing
            PyObject_From(round(Integer, x))
        else
            PyObject_From(round(x; digits = ndigits))
        end
    end PyNULL
end

pyjlrational_numerator(xo::PyPtr, ::Ptr{Cvoid}) =
    @pyjltry PyObject_From(numerator(PyJuliaValue_GetValue(xo)::Rational)) PyNULL

pyjlrational_denominator(xo::PyPtr, ::Ptr{Cvoid}) =
    @pyjltry PyObject_From(denominator(PyJuliaValue_GetValue(xo)::Rational)) PyNULL

pyjlinteger_numerator(xo::PyPtr, ::Ptr{Cvoid}) = (Py_IncRef(xo); xo)

pyjlinteger_denominator(xo::PyPtr, ::Ptr{Cvoid}) = PyLong_From(1)

pyjlinteger_int(xo::PyPtr) = PyLong_From(PyJuliaValue_GetValue(xo)::Integer)

pyjlinteger_index(xo::PyPtr) = PyLong_From(PyJuliaValue_GetValue(xo)::Integer)

pyjlinteger_invert(xo::PyPtr) =
    @pyjltry PyObject_From(~(PyJuliaValue_GetValue(xo)::Integer)) PyNULL

const PyJuliaNumberValue_Type = LazyPyObject() do
    c = []
    base = PyJuliaAnyValue_Type()
    isnull(base) && return PyNULL
    ptr = PyPtr(cacheptr!(c, fill(PyTypeObject(
        name = cacheptr!(c, "juliacall.NumberValue"),
        base = base,
        as_number = cacheptr!(c, fill(PyNumberMethods(
            bool = @cfunctionIO(pyjlnumber_bool),
            positive = @cfunctionOO(pyjlnumber_positive),
            negative = @cfunctionOO(pyjlnumber_negative),
            absolute = @cfunctionOO(pyjlnumber_absolute),
            power = @cfunctionOOOO(pyjlnumber_power),
            add = @cfunctionOOO(pyjlnumber_binop(+)),
            subtract = @cfunctionOOO(pyjlnumber_binop(-)),
            multiply = @cfunctionOOO(pyjlnumber_binop(*)),
            truedivide = @cfunctionOOO(pyjlnumber_binop(/)),
            divmod = @cfunctionOOO(pyjlnumber_binop((x,y)->(fld(x,y), mod(x,y)))),
            floordivide = @cfunctionOOO(pyjlnumber_binop(fld)),
            remainder = @cfunctionOOO(pyjlnumber_binop(mod)),
            lshift = @cfunctionOOO(pyjlnumber_binop(<<)),
            rshift = @cfunctionOOO(pyjlnumber_binop(>>)),
            and = @cfunctionOOO(pyjlnumber_binop(&)),
            xor = @cfunctionOOO(pyjlnumber_binop(⊻)),
            or = @cfunctionOOO(pyjlnumber_binop(|)),
        )))
    ))))
    err = PyType_Ready(ptr)
    ism1(err) && return PyNULL
    abc = PyNumberABC_Type()
    isnull(abc) && return PyNULL
    ism1(PyABC_Register(ptr, abc)) && return PyNULL
    PYJLGCCACHE[ptr] = c
    return ptr
end

PyJuliaNumberValue_New(x::Number) = PyJuliaValue_New(PyJuliaNumberValue_Type(), x)
PyJuliaValue_From(x::Number) = PyJuliaNumberValue_New(x)

const PyJuliaComplexValue_Type = LazyPyObject() do
    c = []
    base = PyJuliaNumberValue_Type()
    isnull(base) && return PyNULL
    ptr = PyPtr(cacheptr!(c, fill(PyTypeObject(
        name = cacheptr!(c, "juliacall.ComplexValue"),
        base = base,
        getset = cacheptr!(c, [
            PyGetSetDef(
                name = cacheptr!(c, "real"),
                get = @cfunctionOOP(pyjlcomplex_real),
            ),
            PyGetSetDef(
                name = cacheptr!(c, "imag"),
                get = @cfunctionOOP(pyjlcomplex_imag),
            ),
            PyGetSetDef(),
        ]),
        methods = cacheptr!(c, [
            PyMethodDef(
                name = cacheptr!(c, "conjugate"),
                flags = Py_METH_NOARGS,
                meth = @cfunctionOOO(pyjlcomplex_conjugate),
            ),
            PyMethodDef(
                name = cacheptr!(c, "__complex__"),
                flags = Py_METH_NOARGS,
                meth = @cfunctionOOO(pyjlcomplex_complex),
            ),
            PyMethodDef(),
        ]),
    ))))
    err = PyType_Ready(ptr)
    ism1(err) && return PyNULL
    abc = PyComplexABC_Type()
    isnull(abc) && return PyNULL
    ism1(PyABC_Register(ptr, abc)) && return PyNULL
    PYJLGCCACHE[ptr] = c
    return ptr
end

PyJuliaComplexValue_New(x::Complex) = PyJuliaValue_New(PyJuliaComplexValue_Type(), x)
PyJuliaValue_From(x::Complex) = PyJuliaComplexValue_New(x)

const PyJuliaRealValue_Type = LazyPyObject() do
    c = []
    base = PyJuliaNumberValue_Type()
    isnull(base) && return PyNULL
    ptr = PyPtr(cacheptr!(c, fill(PyTypeObject(
        name = cacheptr!(c, "juliacall.RealValue"),
        base = base,
        as_number = cacheptr!(c, fill(PyNumberMethods(
            float = @cfunctionOO(pyjlreal_float),
        ))),
        getset = cacheptr!(c, [
            PyGetSetDef(
                name = cacheptr!(c, "real"),
                get = @cfunctionOOP(pyjlreal_real),
            ),
            PyGetSetDef(
                name = cacheptr!(c, "imag"),
                get = @cfunctionOOP(pyjlreal_imag),
            ),
            PyGetSetDef(),
        ]),
        methods = cacheptr!(c, [
            PyMethodDef(
                name = cacheptr!(c, "conjugate"),
                flags = Py_METH_NOARGS,
                meth = @cfunctionOOO(pyjlreal_conjugate),
            ),
            PyMethodDef(
                name = cacheptr!(c, "__complex__"),
                flags = Py_METH_NOARGS,
                meth = @cfunctionOOO(pyjlreal_complex),
            ),
            PyMethodDef(
                name = cacheptr!(c, "__trunc__"),
                flags = Py_METH_NOARGS,
                meth = @cfunctionOOO(pyjlreal_trunc),
            ),
            PyMethodDef(
                name = cacheptr!(c, "__floor__"),
                flags = Py_METH_NOARGS,
                meth = @cfunctionOOO(pyjlreal_floor),
            ),
            PyMethodDef(
                name = cacheptr!(c, "__ceil__"),
                flags = Py_METH_NOARGS,
                meth = @cfunctionOOO(pyjlreal_ceil),
            ),
            PyMethodDef(
                name = cacheptr!(c, "__round__"),
                flags = Py_METH_VARARGS,
                meth = @cfunctionOOO(pyjlreal_round),
            ),
            PyMethodDef(),
        ]),
    ))))
    err = PyType_Ready(ptr)
    ism1(err) && return PyNULL
    abc = PyRealABC_Type()
    isnull(abc) && return PyNULL
    ism1(PyABC_Register(ptr, abc)) && return PyNULL
    PYJLGCCACHE[ptr] = c
    return ptr
end

PyJuliaRealValue_New(x::Real) = PyJuliaValue_New(PyJuliaRealValue_Type(), x)
PyJuliaValue_From(x::Real) = PyJuliaRealValue_New(x)

const PyJuliaRationalValue_Type = LazyPyObject() do
    c = []
    base = PyJuliaRealValue_Type()
    isnull(base) && return PyNULL
    ptr = PyPtr(cacheptr!(c, fill(PyTypeObject(
        name = cacheptr!(c, "juliacall.RationalValue"),
        base = base,
        getset = cacheptr!(c, [
            PyGetSetDef(
                name = cacheptr!(c, "numerator"),
                get = @cfunctionOOP(pyjlrational_numerator),
            ),
            PyGetSetDef(
                name = cacheptr!(c, "denominator"),
                get = @cfunctionOOP(pyjlrational_denominator),
            ),
            PyGetSetDef(),
        ])
    ))))
    err = PyType_Ready(ptr)
    ism1(err) && return PyNULL
    abc = PyRationalABC_Type()
    isnull(abc) && return PyNULL
    ism1(PyABC_Register(ptr, abc)) && return PyNULL
    PYJLGCCACHE[ptr] = c
    return ptr
end

PyJuliaRationalValue_New(x::Rational) = PyJuliaValue_New(PyJuliaRationalValue_Type(), x)
PyJuliaValue_From(x::Rational) = PyJuliaRationalValue_New(x)

const PyJuliaIntegerValue_Type = LazyPyObject() do
    c = []
    base = PyJuliaRealValue_Type()
    isnull(base) && return PyNULL
    ptr = PyPtr(cacheptr!(c, fill(PyTypeObject(
        name = cacheptr!(c, "juliacall.IntegerValue"),
        base = base,
        as_number = cacheptr!(c, fill(PyNumberMethods(
            int = @cfunctionOO(pyjlinteger_int),
            index = @cfunctionOO(pyjlinteger_index),
            invert = @cfunctionOO(pyjlinteger_invert),
        ))),
        getset = cacheptr!(c, [
            PyGetSetDef(
                name = cacheptr!(c, "numerator"),
                get = @cfunctionOOP(pyjlinteger_numerator),
            ),
            PyGetSetDef(
                name = cacheptr!(c, "denominator"),
                get = @cfunctionOOP(pyjlinteger_denominator),
            ),
            PyGetSetDef(),
        ]),
    ))))
    err = PyType_Ready(ptr)
    ism1(err) && return PyNULL
    abc = PyIntegralABC_Type()
    isnull(abc) && return PyNULL
    ism1(PyABC_Register(ptr, abc)) && return PyNULL
    PYJLGCCACHE[ptr] = c
    return ptr
end

PyJuliaIntegerValue_New(x::Integer) = PyJuliaValue_New(PyJuliaIntegerValue_Type(), x)
PyJuliaValue_From(x::Integer) = PyJuliaIntegerValue_New(x)
