"""
    PyIO(o; own=false, text=missing, buflen=4096)

Wrap the Python byte-based IO stream `o` as a Julia IO stream.

When this goes out of scope and is finalized, it is automatically flushed. If `own=true` then it is also closed.

If `text=false` then `o` must be a binary stream and arbitrary binary I/O is possible. If `text=true` then `o` must be a text stream and only UTF-8 must be written (i.e. use `print` not `write`). If `text` is not specified then it is chosen automatically. If `o` is a text stream and you really need a binary stream, then often `PyIO(o.buffer)` will work.

For efficiency, reads and writes are buffered before being sent to `o`. The size of the buffer is `buflen`.
"""
mutable struct PyIO <: IO
    ptr::CPyPtr
    # true to close the file automatically
    own::Bool
    # true if `o` is text, false if binary
    text::Bool
    # true if we are definitely at the end of the file; false if we are not or don't know
    eof::Bool
    # input buffer
    ibuflen::Int
    ibuf::Vector{UInt8}
    # output buffer
    obuflen::Int
    obuf::Vector{UInt8}

    PyIO(::Val{:new}, ptr::Ptr, own::Bool, text::Bool, ibuflen::Int, obuflen::Int) = begin
        io = new(CPyPtr(ptr), own, text, false, ibuflen, UInt8[], obuflen, UInt8[])
        finalizer(pyio_finalize!, io)
    end
end
PyIO(o; own::Bool = false, text::Union{Missing,Bool} = missing, buflen::Integer = 4096, ibuflen::Integer = buflen, obuflen::Integer = buflen) =
    PyIO(Val(:new), checknull(C.PyObject_From(o)), own, text === missing ? pyhasattr(o, "encoding") : text, convert(Int, ibuflen), convert(Int, obuflen))
export PyIO

pyio_finalize!(x::PyIO) = begin
    CONFIG.isinitialized || return
    io.own ? close(io) : flush(io)
    pyref_finalize!(io)
    return
end

ispyreftype(::Type{PyIO}) = true
pyptr(io::PyIO) = io.ptr
Base.unsafe_convert(::Type{CPyPtr}, io::PyIO) = checknull(pyptr(io))
C.PyObject_TryConvert__initial(o, ::Type{PyIO}) = C.putresult(PyIO(pyborrowedref(o)))

"""
    PyIO(f, o; ...)

Equivalent to `f(PyIO(o; ...))` except the stream is automatically flushed or closed according to `own`.

For use in a `do` block, like `PyIO(o, ...) do io; ...; end`.
"""
function PyIO(f::Function, o; opts...)
    io = PyIO(o; opts...)
    try
        return f(io)
    finally
        io.own ? close(io) : flush(io)
    end
end

# If obuf is non-empty, write it to the underlying stream.
function putobuf(io::PyIO)
    if !isempty(io.obuf)
        @py `$io.write($(io.text ? pystr(String(io.obuf)) : pybytes(io.obuf)))`
        empty!(io.obuf)
    end
    nothing
end

# If ibuf is empty, read some more from the underlying stream.
# After this call, if ibuf is empty then we are at EOF.
# TODO: in binary mode, `io.readinto()` to avoid copying data
function getibuf(io::PyIO)
    if isempty(io.ibuf)
        append!(io.ibuf, @pyv `$io.read($(io.ibuflen))`::Vector{UInt8})
    end
    nothing
end

function Base.flush(io::PyIO)
    putobuf(io)
    @py `$io.flush()`
    nothing
end

Base.close(io::PyIO) = (flush(io); @py `$io.close()`; nothing)

function Base.eof(io::PyIO)
    if io.eof
        true
    elseif !isempty(io.ibuf)
        false
    else
        getibuf(io)
        io.eof = isempty(io.ibuf)
    end
end

Base.fd(io::PyIO) = @pyv `$io.fileno()`::Int

Base.isreadable(io::PyIO) = @pyv `$io.readable()`::Bool

Base.iswritable(io::PyIO) = @pyv `$io.writable()`::Bool

Base.isopen(io::PyIO) = @pyv `not $io.closed`::Bool

function Base.unsafe_write(io::PyIO, ptr::Ptr{UInt8}, n::UInt)
    ntodo = n
    while true
        nroom = max(0, io.obuflen - length(io.obuf))
        if ntodo < nroom
            append!(io.obuf, unsafe_wrap(Array, ptr, ntodo))
            return n
        else
            append!(io.obuf, unsafe_wrap(Array, ptr, nroom))
            putobuf(io)
            ptr += nroom
            ntodo -= nroom
        end
    end
end

function Base.write(io::PyIO, c::UInt8)
    push!(io.obuf, c)
    if length(io.obuf) ≥ io.obuflen
        putobuf(io)
    end
end

function Base.unsafe_read(io::PyIO, ptr::Ptr{UInt8}, n::UInt)
    ntodo = n
    while true
        navail = length(io.ibuf)
        if ntodo ≤ navail
            unsafe_wrap(Array, ptr, ntodo) .= splice!(io.ibuf, 1:ntodo)
            return
        else
            unsafe_wrap(Array, ptr, navail) .= io.ibuf
            ptr += navail
            ntodo -= navail
            empty!(io.ibuf)
            eof(io) && throw(EOFError())
        end
    end
end

function Base.read(io::PyIO, ::Type{UInt8})
    eof(io) && throw(EOFError())
    popfirst!(io.ibuf)
end

function Base.seek(io::PyIO, pos::Integer)
    putobuf(io)
    empty!(io.ibuf)
    io.eof = false
    @py `$io.seek($pos, 0)`
    io
end

function Base.truncate(io::PyIO, pos::Integer)
    seek(io, position(io))
    @py `$io.truncate($pos)`
    io
end

function Base.seekstart(io::PyIO)
    putobuf(io)
    empty!(io.ibuf)
    io.eof = false
    @py `$io.seek(0, 0)`
    io
end

function Base.seekend(io::PyIO)
    putobuf(io)
    empty!(io.ibuf)
    io.eof = false
    @py `$io.seek(0, 2)`
    io
end

function Base.skip(io::PyIO, n::Integer)
    putobuf(io)
    if io.text
        if n ≥ 0
            read(io, n)
        else
            error("`skip(io, n)` for text PyIO streams only implemented for positive `n`")
        end
    else
        if 0 ≤ n ≤ io.ibuflen
            read(io, n)
        else
            @py `$io.seek($(n - length(io.ibuf)), 1)`
            empty!(io.ibuf)
            io.eof = false
        end
    end
end

function Base.position(io::PyIO)
    putobuf(io)
    if io.text
        if isempty(io.ibuf)
            @pyv `$io.tell()`::Int
        else
            error(
                "`position(io)` text PyIO streams only implemented for empty input buffer (e.g. do `read(io, length(io.ibuf))` first)",
            )
        end
    else
        (@pyv `$io.tell()`::Int) - length(io.ibuf)
    end
end
