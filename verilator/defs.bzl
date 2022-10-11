"""Functions for verilator."""

load("//verilog:providers.bzl", "VerilogInfo")
load("@bazel_tools//tools/cpp:toolchain_utils.bzl", "find_cpp_toolchain")

def cc_compile_and_link_static_library(ctx, srcs, hdrs, deps, includes = [], defines = []):
    """Compile and link C++ source into a static library"""
    cc_toolchain = find_cpp_toolchain(ctx)
    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = ctx.features,
        unsupported_features = ctx.disabled_features,
    )

    compilation_contexts = [dep[CcInfo].compilation_context for dep in deps]
    compilation_context, compilation_outputs = cc_common.compile(
        name = ctx.label.name,
        actions = ctx.actions,
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        srcs = srcs,
        includes = includes,
        defines = defines,
        public_hdrs = hdrs,
        compilation_contexts = compilation_contexts,
    )

    linking_contexts = [dep[CcInfo].linking_context for dep in deps]
    linking_context, linking_output = cc_common.create_linking_context_from_compilation_outputs(
        actions = ctx.actions,
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        compilation_outputs = compilation_outputs,
        linking_contexts = linking_contexts,
        name = ctx.label.name,
        disallow_dynamic_library = True,
    )

    output_files = []
    if linking_output.library_to_link.static_library != None:
        output_files.append(linking_output.library_to_link.static_library)
    if linking_output.library_to_link.dynamic_library != None:
        output_files.append(linking_output.library_to_link.dynamic_library)

    return [
        DefaultInfo(files = depset(output_files)),
        CcInfo(
            compilation_context = compilation_context,
            linking_context = linking_context,
        ),
    ]

_CPP_SRC = ["cc", "cpp", "cxx", "c++"]
_HPP_SRC = ["h", "hh", "hpp"]

def _only_cpp(f):
    """Filter for just C++ source/headers"""
    if f.extension in _CPP_SRC + _HPP_SRC:
        return f.path
    return None

def _only_hpp(f):
    """Filter for just C++ headers"""
    if f.extension in _HPP_SRC:
        return f.path
    return None

_COPY_TREE_SH = """
OUT=$1; shift && mkdir -p "$OUT" && cp $* "$OUT"
"""

def _copy_tree(ctx, idir, odir, map_each = None, progress_message = None):
    """Copy files from a TreeArtifact to a new directory"""
    args = ctx.actions.args()
    args.add(odir.path)
    args.add_all([idir], map_each = map_each)
    ctx.actions.run_shell(
        arguments = [args],
        command = _COPY_TREE_SH,
        inputs = [idir],
        outputs = [odir],
        progress_message = progress_message,
    )

    return odir

def _verilator_cc_library(ctx):
    transitive_srcs = depset([], transitive = [ctx.attr.module[VerilogInfo].dag])
    verilog_srcs = [verilog_info_struct.srcs for verilog_info_struct in transitive_srcs.to_list()]
    verilog_files = [src for sub_tuple in verilog_srcs for src in sub_tuple]


    verilator_output = ctx.actions.declare_directory(ctx.label.name + "-gen")
    verilator_output_cpp = ctx.actions.declare_directory(ctx.label.name + ".cpp")
    verilator_output_hpp = ctx.actions.declare_directory(ctx.label.name + ".h")

    module_top = ctx.attr.module[VerilogInfo].dag.to_list()[0].label.name
    prefix = "V" + module_top

    args = ctx.actions.args()
    args.add("--cc")
    args.add("--Mdir", verilator_output.path)
    args.add("--top-module", module_top)
    args.add("--prefix", prefix)
    if ctx.attr.trace:
        args.add("--trace")
    for verilog_file in verilog_files:
        args.add(verilog_file.path)
    args.add_all(ctx.attr.vopts, expand_directories = False)

    ctx.actions.run(
        arguments = [args],
        executable = ctx.executable._verilator,
        inputs = verilog_files,
        outputs = [verilator_output],
        progress_message = "[Verilator] Compiling {}".format(ctx.label),
    )

    _copy_tree(
        ctx,
        verilator_output,
        verilator_output_cpp,
        map_each = _only_cpp,
        progress_message = "[Verilator] Extracting C++ source files",
    )
    _copy_tree(
        ctx,
        verilator_output,
        verilator_output_hpp,
        map_each = _only_hpp,
        progress_message = "[Verilator] Extracting C++ header files",
    )

    # Do actual compile
    defines = ["VM_TRACE"] if ctx.attr.trace else []
    deps = [ctx.attr._verilator_lib, ctx.attr._zlib, ctx.attr._verilator_svdpi]

    return cc_compile_and_link_static_library(
        ctx,
        srcs = [verilator_output_cpp],
        hdrs = [verilator_output_hpp],
        defines = defines,
        includes = [verilator_output_hpp.path],
        deps = deps,
    )

verilator_cc_library = rule(
    _verilator_cc_library,
    attrs = {
        "module": attr.label(
            doc = "The top level module to verilate.",
            providers = [VerilogInfo],
        ),
        "trace": attr.bool(
            doc = "Enable tracing for Verilator",
            default = False,
        ),
        "vopts": attr.string_list(
            doc = "Additional command line options to pass to Verilator",
            default = ["-Wall"],
        ),
        "_cc_toolchain": attr.label(
            doc = "CC compiler.",
            default = Label("@bazel_tools//tools/cpp:current_cc_toolchain"),
        ),
        "_verilator": attr.label(
            doc = "Verilator binary.",
            executable = True,
            cfg = "exec",
            default = Label("@verilator_v4.224//:verilator_executable"),
        ),
        "_verilator_lib" : attr.label(
            doc = "Verilator library",
            default = Label("@verilator_v4.224//:libverilator"),
        ),
        "_verilator_svdpi" : attr.label(
            doc = "Verilator svdpi lib",
            default = Label("@verilator_v4.224//:svdpi")
        ),
        "_zlib" : attr.label(
            doc = "zlib dependency",
            default = Label("@net_zlib//:zlib")
        ),
    },
    provides = [
        CcInfo,
        DefaultInfo,
    ],
    toolchains = [
        "@bazel_tools//tools/cpp:toolchain_type",
    ],
    fragments = ["cpp"],
)
