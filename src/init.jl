const PYCALL_UUID = Base.UUID("438e738f-606a-5dbb-bf0a-cddfbfd45ab0")
const PYCALL_PKGID = Base.PkgId(PYCALL_UUID, "PyCall")

check_libpath(PyCall) = begin
    if realpath(PyCall.libpython) == realpath(CONFIG.libpath)
        # @info "libpython path agrees between PythonCall and PyCall" PythonCall.CONFIG.libpath PyCall.libpython
    else
        @warn "PythonCall and PyCall are using different versions of libpython. This will probably go badly." PythonCall.CONFIG.libpath PyCall.libpython
    end
end

init() = begin
    # Check if libpython is already loaded (i.e. if the Julia interpreter was started from a Python process)
    CONFIG.isembedded = haskey(ENV, "JULIA_PYTHONCALL_LIBPTR")

    if CONFIG.isembedded
        # In this case, getting a handle to libpython is easy
        CONFIG.libptr = Ptr{Cvoid}(parse(UInt, ENV["JULIA_PYTHONCALL_LIBPTR"]))
        C.init_pointers()
        # Check Python is initialized
        C.Py_IsInitialized() == 0 && error("Python is not already initialized.")
        CONFIG.isinitialized = CONFIG.preinitialized = true
    elseif get(ENV, "JULIA_PYTHONCALL_EXE", "") == "PYCALL"
        # Import PyCall and use its choices for libpython
        PyCall = get(Base.loaded_modules, PYCALL_PKGID, nothing)
        if PyCall === nothing
            PyCall = Base.require(PYCALL_PKGID)
        end
        CONFIG.exepath = PyCall.python
        CONFIG.libpath = PyCall.libpython
        CONFIG.libptr = dlopen_e(CONFIG.libpath, CONFIG.dlopenflags)
        if CONFIG.libptr == C_NULL
            error("Python library $(repr(CONFIG.libpath)) (from PyCall) could not be opened.")
        end
        CONFIG.pyprogname = PyCall.pyprogramname
        CONFIG.pyhome = PyCall.PYTHONHOME
        C.init_pointers()
        # Check Python is initialized
        C.Py_IsInitialized() == 0 && error("Python is not already initialized.")
        CONFIG.isinitialized = CONFIG.preinitialized = true
    else
        # Find Python executable
        exepath = something(
            CONFIG.exepath,
            get(ENV, "JULIA_PYTHONCALL_EXE", nothing),
            Sys.which("python3"),
            Sys.which("python"),
            get(ENV, "JULIA_PKGEVAL", "") == "true" ? "CONDA" : nothing,
            Some(nothing),
        )
        if exepath === nothing
            error(
                """
              Could not find Python executable.

              Ensure 'python3' or 'python' is in your PATH or set environment variable 'JULIA_PYTHONCALL_EXE'
              to the path to the Python executable.
              """,
            )
        end
        if exepath == "CONDA" || startswith(exepath, "CONDA:")
            CONFIG.isconda = true
            CONFIG.condaenv = exepath == "CONDA" ? Conda.ROOTENV : exepath[7:end]
            Conda._install_conda(CONFIG.condaenv)
            exepath = joinpath(
                Conda.python_dir(CONFIG.condaenv),
                Sys.iswindows() ? "python.exe" : "python",
            )
        end
        if isfile(exepath)
            CONFIG.exepath = exepath
        else
            error("""
                Python executable $(repr(exepath)) does not exist.

                Ensure either:
                - python3 or python is in your PATH
                - JULIA_PYTHONCALL_EXE is "CONDA", "CONDA:<env>" or "PYCALL"
                - JULIA_PYTHONCALL_EXE is the path to the Python executable
                """)
        end

        # For calling Python with UTF-8 IO
        function python_cmd(args)
            env = copy(ENV)
            env["PYTHONIOENCODING"] = "UTF-8"
            setenv(`$(CONFIG.exepath) $args`, env)
        end

        # Find Python library
        libpath =
            something(CONFIG.libpath, get(ENV, "JULIA_PYTHONCALL_LIB", nothing), Some(nothing))
        if libpath !== nothing
            libptr = dlopen_e(path, CONFIG.dlopenflags)
            if libptr == C_NULL
                error("Python library $(repr(libpath)) could not be opened.")
            else
                CONFIG.libpath = libpath
                CONFIG.libptr = libptr
            end
        else
            for libpath in readlines(
                python_cmd([joinpath(@__DIR__, "find_libpython.py"), "--list-all"]),
            )
                libptr = dlopen_e(libpath, CONFIG.dlopenflags)
                if libptr == C_NULL
                    @warn "Python library $(repr(libpath)) could not be opened."
                else
                    CONFIG.libpath = libpath
                    CONFIG.libptr = libptr
                    break
                end
            end
            CONFIG.libpath === nothing && error("""
                Could not find Python library for Python executable $(repr(CONFIG.exepath)).

                If you know where the library is, set environment variable 'JULIA_PYTHONCALL_LIB' to its path.
                """)
        end
        C.init_pointers()

        # Compare libpath with PyCall
        PyCall = get(Base.loaded_modules, PYCALL_PKGID, nothing)
        if PyCall === nothing
            @require PyCall="438e738f-606a-5dbb-bf0a-cddfbfd45ab0" check_libpath(PyCall)
        else
            check_libpath(PyCall)
        end

        # Initialize
        with_gil() do
            if C.Py_IsInitialized() != 0
                # Already initialized (maybe you're using PyCall as well)
            else
                # Find ProgramName and PythonHome
                script = if Sys.iswindows()
                    """
                    import sys
                    print(sys.executable)
                    if hasattr(sys, "base_exec_prefix"):
                        sys.stdout.write(sys.base_exec_prefix)
                    else:
                        sys.stdout.write(sys.exec_prefix)
                    """
                else
                    """
                    import sys
                    print(sys.executable)
                    if hasattr(sys, "base_exec_prefix"):
                        sys.stdout.write(sys.base_prefix)
                        sys.stdout.write(":")
                        sys.stdout.write(sys.base_exec_prefix)
                    else:
                        sys.stdout.write(sys.prefix)
                        sys.stdout.write(":")
                        sys.stdout.write(sys.exec_prefix)
                    """
                end
                CONFIG.pyprogname, CONFIG.pyhome = readlines(python_cmd(["-c", script]))

                # Set PythonHome
                CONFIG.pyhome_w = Base.cconvert(Cwstring, CONFIG.pyhome)
                C.Py_SetPythonHome(pointer(CONFIG.pyhome_w))

                # Set ProgramName
                CONFIG.pyprogname_w = Base.cconvert(Cwstring, CONFIG.pyprogname)
                C.Py_SetProgramName(pointer(CONFIG.pyprogname_w))

                # Start the interpreter and register exit hooks
                C.Py_InitializeEx(0)
                atexit() do
                    CONFIG.isinitialized = false
                    CONFIG.version < v"3.6" ? C.Py_Finalize() : checkm1(C.Py_FinalizeEx())
                end
            end
            CONFIG.isinitialized = true
            check(
                C.Py_AtExit(
                    @cfunction(() -> (CONFIG.isinitialized = false; nothing), Cvoid, ())
                ),
            )
        end
    end

    C.PyObject_TryConvert_AddRule("builtins.object", PyObject, CTryConvertRule_wrapref, -100)
    C.PyObject_TryConvert_AddRule("builtins.object", PyRef, CTryConvertRule_wrapref, -200)
    C.PyObject_TryConvert_AddRule("collections.abc.Sequence", PyList, CTryConvertRule_wrapref, 100)
    C.PyObject_TryConvert_AddRule("collections.abc.Set", PySet, CTryConvertRule_wrapref, 100)
    C.PyObject_TryConvert_AddRule("collections.abc.Mapping", PyDict, CTryConvertRule_wrapref, 100)
    C.PyObject_TryConvert_AddRule("_io._IOBase", PyIO, CTryConvertRule_trywrapref, 100)
    C.PyObject_TryConvert_AddRule("io.IOBase", PyIO, CTryConvertRule_trywrapref, 100)
    C.PyObject_TryConvert_AddRule("<buffer>", PyArray, CTryConvertRule_trywrapref, 200)
    C.PyObject_TryConvert_AddRule("<buffer>", Array, CTryConvertRule_PyArray_tryconvert, 0)
    C.PyObject_TryConvert_AddRule("<buffer>", PyBuffer, CTryConvertRule_wrapref, -200)
    C.PyObject_TryConvert_AddRule("<arrayinterface>", PyArray, CTryConvertRule_trywrapref, 200)
    C.PyObject_TryConvert_AddRule("<arrayinterface>", Array, CTryConvertRule_PyArray_tryconvert, 0)
    C.PyObject_TryConvert_AddRule("<arraystruct>", PyArray, CTryConvertRule_trywrapref, 200)
    C.PyObject_TryConvert_AddRule("<arraystruct>", Array, CTryConvertRule_PyArray_tryconvert, 0)
    C.PyObject_TryConvert_AddRule("<array>", PyArray, CTryConvertRule_trywrapref, 0)
    C.PyObject_TryConvert_AddRule("<array>", Array, CTryConvertRule_PyArray_tryconvert, 0)

    with_gil() do

        @pyg `import sys, os`

        pywordsize = (@pyv `sys.maxsize > 2**32`::Bool) ? 64 : 32
        pywordsize == Sys.WORD_SIZE || error("Julia is $(Sys.WORD_SIZE)-bit but Python is $(pywordsize)-bit (at $(CONFIG.exepath ? "unknown location" : CONFIG.exepath))")

        if !CONFIG.isembedded
            @py ```
            # Some modules expect sys.argv to be set
            sys.argv = [""]
            sys.argv.extend($ARGS)

            # Some modules test for interactivity by checking if sys.ps1 exists
            if $(isinteractive()) and not hasattr(sys, "ps1"):
                sys.ps1 = ">>> "
            ```
        end

        # Is this the same Python as in Conda?
        if !CONFIG.isconda &&
           haskey(ENV, "CONDA_PREFIX") &&
           isdir(ENV["CONDA_PREFIX"]) &&
           haskey(ENV, "CONDA_PYTHON_EXE") &&
           isfile(ENV["CONDA_PYTHON_EXE"]) &&
           realpath(ENV["CONDA_PYTHON_EXE"]) == realpath(
               CONFIG.exepath === nothing ? @pyv(`sys.executable`::String) : CONFIG.exepath,
           )

            CONFIG.isconda = true
            CONFIG.condaenv = ENV["CONDA_PREFIX"]
            CONFIG.exepath === nothing && (CONFIG.exepath = @pyv(`sys.executable`::String))
        end

        # Get the python version
        CONFIG.version =
            let (a, b, c, d, e) = @pyv(`sys.version_info`::Tuple{Int,Int,Int,String,Int})
                VersionNumber(a, b, c, (d,), (e,))
            end
        v"3" ≤ CONFIG.version < v"4" || error(
            "Only Python 3 is supported, this is Python $(CONFIG.version) at $(CONFIG.exepath===nothing ? "unknown location" : CONFIG.exepath).",
        )

        # set up the 'juliacall' module
        @py ```
        import sys
        if $(CONFIG.isembedded):
            jl = sys.modules["juliacall"]
        elif "juliacall" in sys.modules:
            raise ImportError("'juliacall' module already exists")
        else:
            jl = sys.modules["juliacall"] = type(sys)("juliacall")
            jl.CONFIG = dict()
        jl.Main = $(pyjl(Main))
        jl.Base = $(pyjl(Base))
        jl.Core = $(pyjl(Core))
        code = """
        def newmodule(name):
            "A new module with the given name."
            return Base.Module(Base.Symbol(name))
        class As:
            "Interpret 'value' as type 'type' when converting to Julia."
            __slots__ = ("value", "type")
            def __init__(self, value, type):
                self.value = value
                self.type = type
            def __repr__(self):
                return "juliacall.As({!r}, {!r})".format(self.value, self.type)
        """
        exec(code, jl.__dict__)
        ```

        # EXPERIMENTAL: hooks to perform actions when certain modules are loaded
        if !CONFIG.isembedded
            @py ```
            import sys
            class JuliaCompatHooks:
                def __init__(self):
                    self.hooks = {}
                def find_module(self, name, path=None):
                    hs = self.hooks.get(name)
                    if hs is not None:
                        for h in hs:
                            h()
                def add_hook(self, name, h):
                    if name not in self.hooks:
                        self.hooks[name] = [h]
                    else:
                        self.hooks[name].append(h)
                    if name in sys.modules:
                        h()
            JULIA_COMPAT_HOOKS = JuliaCompatHooks()
            sys.meta_path.insert(0, JULIA_COMPAT_HOOKS)

            # Before Qt is loaded, fix the path used to look up its plugins
            qtfix_hook = $(() -> (CONFIG.qtfix && fix_qt_plugin_path(); nothing))
            JULIA_COMPAT_HOOKS.add_hook("PyQt4", qtfix_hook)
            JULIA_COMPAT_HOOKS.add_hook("PyQt5", qtfix_hook)
            JULIA_COMPAT_HOOKS.add_hook("PySide", qtfix_hook)
            JULIA_COMPAT_HOOKS.add_hook("PySide2", qtfix_hook)
            ```

            @require IJulia = "7073ff75-c697-5162-941a-fcdaad2a7d2a" begin
                IJulia.push_postexecute_hook() do
                    CONFIG.pyplotautoshow && pyplotshow()
                end
            end
        end

        # EXPERIMENTAL: IPython integration
        if CONFIG.isembedded && CONFIG.ipythonintegration
            if !CONFIG.isipython
                @py ```
                try:
                    ok = "IPython" in sys.modules and sys.modules["IPython"].get_ipython() is not None
                except:
                    ok = False
                $(CONFIG.isipython::Bool) = ok
                ```
            end
            if CONFIG.isipython
                # Set `Base.stdout` to `sys.stdout` and ensure it is flushed after each execution
                @eval Base stdout = $(@pyv `sys.stdout`::PyIO)
                pushdisplay(TextDisplay(Base.stdout))
                pushdisplay(IPythonDisplay())
                @py ```
                mkcb = lambda cb: lambda: cb()
                sys.modules["IPython"].get_ipython().events.register("post_execute", mkcb($(() -> flush(Base.stdout))))
                ```
            end
        end
    end

    @debug "Initialized PythonCall.jl" CONFIG.isembedded CONFIG.isinitialized CONFIG.exepath CONFIG.libpath CONFIG.libptr CONFIG.pyprogname CONFIG.pyhome CONFIG.version CONFIG.isconda CONFIG.condaenv
end
precompile(init, ())
@init init()
