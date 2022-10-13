"""Defines rules for the Xilinx tool, vivado."""

load("//verilog:providers.bzl", "VerilogInfo")
load("//vivado:providers.bzl", "VivadoPlacementCheckpointInfo", "VivadoRoutingCheckpointInfo", "VivadoSynthCheckpointInfo")

def run_tcl_template(ctx, template, substitutions, xilinx_env, input_files, output_files):
    """Runs a tcl template in vivado.

    Args:
        ctx: Context from a rule.
        template: The template file to use.
        substitutions: The substitutions to apply to the template.
        xilinx_env: A shell script to source the vivado environment with.
        input_files: A list of input files that vivado needs to run.
        output_files: A list of expected outputs from the tcl script running on vivado.

    Returns:
        DefaultInfo - The files that were created.
    """
    vivado_tcl = ctx.actions.declare_file("{}_run_vivado.tcl".format(ctx.label.name))
    vivado_log = ctx.actions.declare_file("{}.log".format(ctx.label.name))
    vivado_journal = ctx.actions.declare_file("{}.jou".format(ctx.label.name))

    ctx.actions.expand_template(
        template = template,
        output = vivado_tcl,
        substitutions = substitutions,
    )

    vivado_command = "source " + xilinx_env.path + " && "
    vivado_command += "vivado -mode batch -source " + vivado_tcl.path
    vivado_command += " -log " + vivado_log.path
    vivado_command += " -journal " + vivado_journal.path

    outputs = output_files + [vivado_log, vivado_journal]

    ctx.actions.run_shell(
        outputs = outputs,
        inputs = input_files + [vivado_tcl, xilinx_env],
        progress_message = "Running on vivado: {}".format(ctx.label.name),
        command = vivado_command,
    )

    return [
        DefaultInfo(files = depset(outputs)),
    ]

def create_and_synth(
        ctx,
        with_synth,
        synth_checkpoint = None,
        timing_summary_report = None,
        util_report = None,
        synth_strategy = None):
    """Create a project and optionally synthesize.

    Due to IP issues, it makes sense to do synthesis in project mode.
    This function can also be used to generate a vivado project from the input sources.

    Args:
        ctx: Context from a rule
        with_synth: A flag indicating if synthesis should be run too.
        synth_checkpoint: Optionally define the output synthesis checkpoint. Not used when creating a project only.
        timing_summary_report: Optionally define the timing summary report output. Not used when creating a project only.
        util_report: Optionally define the utilization report output. Not used when creating a project only.
        synth_strategy: Optionally define the synthesis strategy to use. Not used when creating a project only.

    Returns:
        DefaultInfo - Files generated by the project.
    """
    transitive_srcs = depset([], transitive = [ctx.attr.module[VerilogInfo].dag])
    all_srcs = [verilog_info_struct.srcs for verilog_info_struct in transitive_srcs.to_list()]
    all_files = [src for sub_tuple in all_srcs for src in sub_tuple]

    hdl_source_content = ""
    constraints_content = ""
    tcl_content = ""
    for file in all_files:
        if file.extension == "v":
            hdl_source_content += "read_verilog -library xil_defaultlib " + file.path + "\n"
        elif file.extension == "sv":
            hdl_source_content += "read_verilog -library xil_defaultlib -sv " + file.path + "\n"
        elif file.extension in ["vhd", "vhdl"]:
            hdl_source_content += "read_vhdl " + file.path + "\n"
        elif file.extension == "tcl":
            tcl_content += "source " + file.path + "\n"
        elif file.extension == "dat":
            # Don't need to read data files.
            pass
        elif file.extension == "xdc":
            constraints_content += "read_xdc " + file.path + "\n"
        else:
            fail("Unknown file type: " + file.path)

    project_dir = ctx.actions.declare_directory(ctx.label.name)

    if with_synth:
        synth_path = synth_checkpoint.path
        timing_path = timing_summary_report.path
        util_path = util_report.path
        with_synth_str = "1"
        synth_strategy_str = synth_strategy
        outputs = [project_dir, synth_checkpoint, timing_summary_report, util_report]
    else:
        synth_path = ""
        timing_path = ""
        util_path = ""
        with_synth_str = "0"
        synth_strategy_str = ""
        outputs = [project_dir]

    substitutions = {
        "{{PART_NUMBER}}": ctx.attr.part_number,
        "{{HDL_SOURCE_CONTENT}}": hdl_source_content,
        "{{TCL_CONTENT}}": tcl_content,
        "{{CONSTRAINTS_CONTENT}}": constraints_content,
        "{{MODULE_TOP}}": ctx.attr.module_top,
        "{{PROJECT_DIR}}": project_dir.path,
        "{{SYNTH_STRATEGY}}": synth_strategy_str,
        "{{SYNTH_CHECKPOINT}}": synth_path,
        "{{TIMING_SUMMARY_REPORT}}": timing_path,
        "{{UTILIZATION_REPORT}}": util_path,
        "{{JOBS}}": "4",
        "{{WITH_SYNTH}}": with_synth_str,
    }

    return run_tcl_template(
        ctx,
        ctx.file._create_project_tcl_template,
        substitutions,
        ctx.file.xilinx_env,
        all_files,
        outputs,
    )

def _create_project_impl(ctx):
    return create_and_synth(ctx, 0)

create_project = rule(
    implementation = _create_project_impl,
    attrs = {
        "module": attr.label(
            doc = "The top level build.",
            providers = [VerilogInfo],
            mandatory = True,
        ),
        "module_top": attr.string(
            doc = "The name of the verilog module to verilate.",
            mandatory = True,
        ),
        "part_number": attr.string(
            doc = "The targeted xilinx part.",
            mandatory = True,
        ),
        "xilinx_env": attr.label(
            doc = "A shell script to source the vivado environment and " +
                  "point to license server",
            mandatory = True,
            allow_single_file = [".sh"],
        ),
        "_create_project_tcl_template": attr.label(
            doc = "The create project tcl template",
            default = "@rules_hdl//vivado:create_project.tcl.template",
            allow_single_file = [".template"],
        ),
    },
)

def _synthesize_impl(ctx):
    synth_checkpoint = ctx.actions.declare_file("{}_synth.dcp".format(ctx.label.name))
    timing_summary_report = ctx.actions.declare_file("{}_synth_timing.rpt".format(ctx.label.name))
    util_report = ctx.actions.declare_file("{}_synth_util.rpt".format(ctx.label.name))

    default_info = create_and_synth(
        ctx,
        1,
        synth_checkpoint,
        timing_summary_report,
        util_report,
        ctx.attr.synth_strategy,
    )

    return [
        default_info[0],
        VivadoSynthCheckpointInfo(checkpoint = synth_checkpoint),
    ]

synthesize = rule(
    implementation = _synthesize_impl,
    attrs = {
        "module": attr.label(
            doc = "The top level build.",
            providers = [VerilogInfo],
            mandatory = True,
        ),
        "module_top": attr.string(
            doc = "The name of the verilog module to verilate.",
            mandatory = True,
        ),
        "part_number": attr.string(
            doc = "The targeted xilinx part.",
            mandatory = True,
        ),
        "synth_strategy": attr.string(
            doc = "The synthesis strategy to use.",
            default = "Vivado Synthesis Defaults",
        ),
        "xilinx_env": attr.label(
            doc = "A shell script to source the vivado environment and " +
                  "point to license server",
            mandatory = True,
            allow_single_file = [".sh"],
        ),
        "_create_project_tcl_template": attr.label(
            doc = "The create project tcl template",
            default = "@rules_hdl//vivado:create_project.tcl.template",
            allow_single_file = [".template"],
        ),
    },
    provides = [
        DefaultInfo,
        VivadoSynthCheckpointInfo,
    ],
)

def _synthesis_optimize_impl(ctx):
    synth_checkpoint = ctx.actions.declare_file("{}_synth.dcp".format(ctx.label.name))
    timing_summary_report = ctx.actions.declare_file("{}_synth_timing.rpt".format(ctx.label.name))
    util_report = ctx.actions.declare_file("{}_synth_util.rpt".format(ctx.label.name))
    drc_report = ctx.actions.declare_file("{}_drc.rpt".format(ctx.label.name))

    checkpoint_in = ctx.attr.checkpoint[VivadoSynthCheckpointInfo].checkpoint

    substitutions = {
        "{{THREADS}}": "8",
        "{{CHECKPOINT_IN}}": checkpoint_in.path,
        "{{OPT_DIRECTIVE}}": ctx.attr.opt_directive,
        "{{TIMING_REPORT}}": timing_summary_report.path,
        "{{UTIL_REPORT}}": util_report.path,
        "{{DRC_REPORT}}": drc_report.path,
        "{{CHECKPOINT_OUT}}": synth_checkpoint.path,
    }

    outputs = [synth_checkpoint, timing_summary_report, util_report, drc_report]

    default_info = run_tcl_template(
        ctx,
        ctx.file._synthesis_optimize_template,
        substitutions,
        ctx.file.xilinx_env,
        [checkpoint_in],
        outputs,
    )

    return [
        default_info[0],
        VivadoSynthCheckpointInfo(checkpoint = synth_checkpoint),
    ]

synthesis_optimize = rule(
    implementation = _synthesis_optimize_impl,
    attrs = {
        "checkpoint": attr.label(
            doc = "Synthesis checkpoint.",
            providers = [VivadoSynthCheckpointInfo],
            mandatory = True,
        ),
        "xilinx_env": attr.label(
            doc = "A shell script to source the vivado environment and " +
                  "point to license server",
            mandatory = True,
            allow_single_file = [".sh"],
        ),
        "opt_directive": attr.string(
            doc = "The optimization directive.",
            default = "Explore",
        ),
        "_synthesis_optimize_template": attr.label(
            doc = "The synthesis optimzation tcl template",
            default = "@rules_hdl//vivado:synth_optimize.tcl.template",
            allow_single_file = [".template"],
        ),
    },
    provides = [
        DefaultInfo,
        VivadoSynthCheckpointInfo,
    ],
)

def _placement_impl(ctx):
    placement_checkpoint = ctx.actions.declare_file("{}_place.dcp".format(ctx.label.name))
    timing_summary_report = ctx.actions.declare_file("{}_synth_timing.rpt".format(ctx.label.name))
    util_report = ctx.actions.declare_file("{}_synth_util.rpt".format(ctx.label.name))

    checkpoint_in = ctx.attr.checkpoint[VivadoSynthCheckpointInfo].checkpoint

    substitutions = {
        "{{THREADS}}": "8",
        "{{CHECKPOINT_IN}}": checkpoint_in.path,
        "{{PLACEMENT_DIRECTIVE}}": ctx.attr.placement_directive,
        "{{TIMING_REPORT}}": timing_summary_report.path,
        "{{UTIL_REPORT}}": util_report.path,
        "{{CHECKPOINT_OUT}}": placement_checkpoint.path,
    }

    outputs = [placement_checkpoint, timing_summary_report, util_report]

    default_info = run_tcl_template(
        ctx,
        ctx.file._placement_template,
        substitutions,
        ctx.file.xilinx_env,
        [checkpoint_in],
        outputs,
    )

    return [
        default_info[0],
        VivadoPlacementCheckpointInfo(checkpoint = placement_checkpoint),
    ]

placement = rule(
    implementation = _placement_impl,
    attrs = {
        "checkpoint": attr.label(
            doc = "Synthesis checkpoint.",
            providers = [VivadoSynthCheckpointInfo],
            mandatory = True,
        ),
        "xilinx_env": attr.label(
            doc = "A shell script to source the vivado environment and " +
                  "point to license server",
            mandatory = True,
            allow_single_file = [".sh"],
        ),
        "placement_directive": attr.string(
            doc = "The optimization directive.",
            default = "Explore",
        ),
        "_placement_template": attr.label(
            doc = "The placement tcl template",
            default = "@rules_hdl//vivado:placement.tcl.template",
            allow_single_file = [".template"],
        ),
    },
    provides = [
        DefaultInfo,
        VivadoPlacementCheckpointInfo,
    ],
)

def _place_optimize_impl(ctx):
    placement_checkpoint = ctx.actions.declare_file("{}_place.dcp".format(ctx.label.name))
    timing_summary_report = ctx.actions.declare_file("{}_synth_timing.rpt".format(ctx.label.name))
    util_report = ctx.actions.declare_file("{}_synth_util.rpt".format(ctx.label.name))

    checkpoint_in = ctx.attr.checkpoint[VivadoPlacementCheckpointInfo].checkpoint

    substitutions = {
        "{{THREADS}}": "8",
        "{{CHECKPOINT_IN}}": checkpoint_in.path,
        "{{PHYS_OPT_DIRECTIVE}}": ctx.attr.phys_opt_directive,
        "{{TIMING_REPORT}}": timing_summary_report.path,
        "{{UTIL_REPORT}}": util_report.path,
        "{{CHECKPOINT_OUT}}": placement_checkpoint.path,
    }

    outputs = [placement_checkpoint, timing_summary_report, util_report]

    default_info = run_tcl_template(
        ctx,
        ctx.file._place_optimize_template,
        substitutions,
        ctx.file.xilinx_env,
        [checkpoint_in],
        outputs,
    )

    return [
        default_info[0],
        VivadoPlacementCheckpointInfo(checkpoint = placement_checkpoint),
    ]

place_optimize = rule(
    implementation = _place_optimize_impl,
    attrs = {
        "checkpoint": attr.label(
            doc = "Placement checkpoint.",
            providers = [VivadoPlacementCheckpointInfo],
            mandatory = True,
        ),
        "xilinx_env": attr.label(
            doc = "A shell script to source the vivado environment and " +
                  "point to license server",
            mandatory = True,
            allow_single_file = [".sh"],
        ),
        "phys_opt_directive": attr.string(
            doc = "The optimization directive.",
            default = "AggressiveExplore",
        ),
        "_place_optimize_template": attr.label(
            doc = "The placement tcl template",
            default = "@rules_hdl//vivado:place_optimize.tcl.template",
            allow_single_file = [".template"],
        ),
    },
    provides = [
        DefaultInfo,
        VivadoPlacementCheckpointInfo,
    ],
)

def _routing_impl(ctx):
    route_checkpoint = ctx.actions.declare_file("{}_route.dcp".format(ctx.label.name))
    timing_summary_report = ctx.actions.declare_file("{}_synth_timing.rpt".format(ctx.label.name))
    util_report = ctx.actions.declare_file("{}_synth_util.rpt".format(ctx.label.name))
    status_report = ctx.actions.declare_file("{}_status.rpt".format(ctx.label.name))
    io_report = ctx.actions.declare_file("{}_io.rpt".format(ctx.label.name))
    power_report = ctx.actions.declare_file("{}_power.rpt".format(ctx.label.name))
    design_analysis_report = ctx.actions.declare_file("{}_design_analysis.rpt".format(ctx.label.name))

    checkpoint_in = ctx.attr.checkpoint[VivadoPlacementCheckpointInfo].checkpoint

    substitutions = {
        "{{THREADS}}": "8",
        "{{CHECKPOINT_IN}}": checkpoint_in.path,
        "{{ROUTE_DIRECTIVE}}": ctx.attr.route_directive,
        "{{TIMING_REPORT}}": timing_summary_report.path,
        "{{UTIL_REPORT}}": util_report.path,
        "{{STATUS_REPORT}}": status_report.path,
        "{{IO_REPORT}}": io_report.path,
        "{{POWER_REPORT}}": power_report.path,
        "{{DESIGN_ANALYSIS_REPORT}}": design_analysis_report.path,
        "{{CHECKPOINT_OUT}}": route_checkpoint.path,
    }

    outputs = [
        route_checkpoint,
        timing_summary_report,
        util_report,
        status_report,
        io_report,
        power_report,
        design_analysis_report,
    ]

    default_info = run_tcl_template(
        ctx,
        ctx.file._route_template,
        substitutions,
        ctx.file.xilinx_env,
        [checkpoint_in],
        outputs,
    )

    return [
        default_info[0],
        VivadoRoutingCheckpointInfo(checkpoint = route_checkpoint),
    ]

routing = rule(
    implementation = _routing_impl,
    attrs = {
        "checkpoint": attr.label(
            doc = "Placement checkpoint.",
            providers = [VivadoPlacementCheckpointInfo],
            mandatory = True,
        ),
        "xilinx_env": attr.label(
            doc = "A shell script to source the vivado environment and " +
                  "point to license server",
            mandatory = True,
            allow_single_file = [".sh"],
        ),
        "route_directive": attr.string(
            doc = "The routing directive.",
            default = "Explore",
        ),
        "_route_template": attr.label(
            doc = "The placement tcl template",
            default = "@rules_hdl//vivado:route.tcl.template",
            allow_single_file = [".template"],
        ),
    },
    provides = [
        DefaultInfo,
        VivadoRoutingCheckpointInfo,
    ],
)

def _write_bitstream_impl(ctx):
    bitstream = ctx.actions.declare_file("{}.bit".format(ctx.label.name))

    checkpoint_in = ctx.attr.checkpoint[VivadoRoutingCheckpointInfo].checkpoint

    substitutions = {
        "{{THREADS}}": "8",
        "{{CHECKPOINT_IN}}": checkpoint_in.path,
        "{{BITSTREAM}}": bitstream.path,
    }

    outputs = [bitstream]

    return run_tcl_template(
        ctx,
        ctx.file._write_bitstream_template,
        substitutions,
        ctx.file.xilinx_env,
        [checkpoint_in],
        outputs,
    )

write_bitstream = rule(
    implementation = _write_bitstream_impl,
    attrs = {
        "checkpoint": attr.label(
            doc = "Routed checkpoint.",
            providers = [VivadoRoutingCheckpointInfo],
            mandatory = True,
        ),
        "xilinx_env": attr.label(
            doc = "A shell script to source the vivado environment and " +
                  "point to license server",
            mandatory = True,
            allow_single_file = [".sh"],
        ),
        "_write_bitstream_template": attr.label(
            doc = "The write bitstream tcl template",
            default = "@rules_hdl//vivado:write_bitstream.tcl.template",
            allow_single_file = [".template"],
        ),
    },
    provides = [
        DefaultInfo,
    ],
)

def vivado_flow(name, module, module_top, part_number, xilinx_env, tags = []):
    """Runs the entire bitstream flow as a convenience macro.

    Args:
        name: The name to use when calling the rules.
        module: The verilog library to use as the top level.
        module_top: The name of the top level module.
        part_number: The part number to target.
        xilinx_env: The shell script to setup the Xilinx/vivado environment.
        tags: Optional tags to use for the rules.
    """
    synthesize(
        name = "{}_synth".format(name),
        module = module,
        module_top = module_top,
        part_number = part_number,
        xilinx_env = xilinx_env,
        tags = tags,
    )

    synthesis_optimize(
        name = "{}_synth_opt".format(name),
        checkpoint = ":{}_synth".format(name),
        xilinx_env = xilinx_env,
        tags = tags,
    )

    placement(
        name = "{}_placement".format(name),
        checkpoint = "{}_synth_opt".format(name),
        xilinx_env = xilinx_env,
        tags = tags,
    )

    place_optimize(
        name = "{}_place_opt".format(name),
        checkpoint = "{}_placement".format(name),
        xilinx_env = xilinx_env,
        tags = tags,
    )

    routing(
        name = "{}_route".format(name),
        checkpoint = "{}_place_opt".format(name),
        xilinx_env = xilinx_env,
        tags = tags,
    )

    write_bitstream(
        name = name,
        checkpoint = "{}_route".format(name),
        xilinx_env = xilinx_env,
        tags = tags,
    )
