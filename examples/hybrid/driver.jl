import ClimaAtmos as CA
import Random
Random.seed!(1234)

if !(@isdefined config)
    config = CA.AtmosConfig()
end
integrator = CA.get_integrator(config)
sol_res = CA.solve_atmos!(integrator)

(; simulation, atmos, params) = integrator.p
(; p) = integrator

import ClimaCore
import ClimaAtmos.InitialConditions as ICs
using Statistics: mean
import ClimaAtmos.Parameters as CAP
import Thermodynamics as TD
import ClimaComms
using SciMLBase
using PrettyTables
import DiffEqCallbacks as DECB
using JLD2
using NCDatasets
using ClimaTimeSteppers
import JSON
using Test
import OrderedCollections
using ClimaCoreTempestRemap
using ClimaCorePlots, Plots
using ClimaCoreMakie, CairoMakie
include(joinpath(pkgdir(CA), "post_processing", "common_utils.jl"))

include(joinpath(pkgdir(CA), "post_processing", "contours_and_profiles.jl"))
include(joinpath(pkgdir(CA), "post_processing", "post_processing_funcs.jl"))
include(
    joinpath(pkgdir(CA), "post_processing", "define_tc_quicklook_profiles.jl"),
)
include(joinpath(pkgdir(CA), "post_processing", "plot_single_column_precip.jl"))

ref_job_id = config.parsed_args["reference_job_id"]
reference_job_id = isnothing(ref_job_id) ? simulation.job_id : ref_job_id

is_edmfx =
    atmos.turbconv_model isa CA.PrognosticEDMFX ||
    atmos.turbconv_model isa CA.DiagnosticEDMFX
if is_edmfx && config.parsed_args["post_process"]
    contours_and_profiles(simulation.output_dir, reference_job_id)
    zip_and_cleanup_output(simulation.output_dir, "hdf5files.zip")
end

if sol_res.ret_code == :simulation_crashed
    error(
        "The ClimaAtmos simulation has crashed. See the stack trace for details.",
    )
end
# Simulation did not crash
(; sol, walltime) = sol_res
@assert last(sol.t) == simulation.t_end
CA.verify_callbacks(sol.t)

if CA.is_distributed(config.comms_ctx)
    export_scaling_file(
        sol,
        simulation.output_dir,
        walltime,
        config.comms_ctx,
        ClimaComms.nprocs(config.comms_ctx),
    )
end

if !CA.is_distributed(config.comms_ctx) &&
   config.parsed_args["post_process"] &&
   !is_edmfx &&
   !(atmos.model_config isa CA.SphericalModel)
    ENV["GKSwstype"] = "nul" # avoid displaying plots
    if is_column_without_edmfx(config.parsed_args)
        custom_postprocessing(sol, simulation.output_dir, p)
    elseif is_solid_body(config.parsed_args)
        postprocessing(sol, simulation.output_dir, config.parsed_args["fps"])
    elseif atmos.model_config isa CA.BoxModel
        postprocessing_box(sol, simulation.output_dir)
    elseif atmos.model_config isa CA.PlaneModel
        postprocessing_plane(sol, simulation.output_dir, p)
    else
        error("Uncaught case")
    end
end

include(joinpath(@__DIR__, "..", "..", "regression_tests", "mse_tables.jl"))
if config.parsed_args["regression_test"]
    # Test results against main branch
    include(
        joinpath(
            @__DIR__,
            "..",
            "..",
            "regression_tests",
            "regression_tests.jl",
        ),
    )
    @testset "Test regression table entries" begin
        mse_keys = sort(collect(keys(all_best_mse[simulation.job_id])))
        pcs = collect(Fields.property_chains(sol.u[end]))
        for prop_chain in mse_keys
            @test prop_chain in pcs
        end
    end
    perform_regression_tests(
        simulation.job_id,
        sol.u[end],
        all_best_mse,
        simulation.output_dir,
    )
end

@info "Callback verification, n_expected_calls: $(CA.n_expected_calls(integrator))"
@info "Callback verification, n_measured_calls: $(CA.n_measured_calls(integrator))"

if config.parsed_args["check_conservation"]
    FT = Spaces.undertype(axes(sol.u[end].c.ρ))
    @test sum(sol.u[1].c.ρ) ≈ sum(sol.u[end].c.ρ) rtol = 50 * eps(FT)
    @test sum(sol.u[1].c.ρe_tot) +
          (p.net_energy_flux_sfc[][] - p.net_energy_flux_toa[][]) ≈
          sum(sol.u[end].c.ρe_tot) rtol = 100 * eps(FT)
end

if config.parsed_args["check_precipitation"]

    # plot results of the single column precipitation test
    plot_single_column_precip(simulation.output_dir, reference_job_id)

    # run some simple tests based on the output
    FT = Spaces.undertype(axes(sol.u[end].c.ρ))
    Yₜ = similar(sol.u[end])

    Yₜ_ρ = similar(Yₜ.c.ρq_rai)
    Yₜ_ρqₚ = similar(Yₜ.c.ρq_rai)
    Yₜ_ρqₜ = similar(Yₜ.c.ρq_rai)

    CA.remaining_tendency!(Yₜ, sol.u[end], sol.prob.p, sol.t[end])

    @. Yₜ_ρqₚ = -Yₜ.c.ρq_rai - Yₜ.c.ρq_sno
    @. Yₜ_ρqₜ = Yₜ.c.ρq_tot
    @. Yₜ_ρ = Yₜ.c.ρ

    Fields.bycolumn(axes(sol.u[end].c.ρ)) do colidx

        # no nans
        @assert !any(isnan, Yₜ.c.ρ[colidx])
        @assert !any(isnan, Yₜ.c.ρq_tot[colidx])
        @assert !any(isnan, Yₜ.c.ρe_tot[colidx])
        @assert !any(isnan, Yₜ.c.ρq_rai[colidx])
        @assert !any(isnan, Yₜ.c.ρq_sno[colidx])
        @assert !any(isnan, sol.prob.p.precomputed.ᶜwᵣ[colidx])
        @assert !any(isnan, sol.prob.p.precomputed.ᶜwₛ[colidx])

        # treminal velocity is positive
        @test minimum(sol.prob.p.precomputed.ᶜwᵣ[colidx]) >= FT(0)
        @test minimum(sol.prob.p.precomputed.ᶜwₛ[colidx]) >= FT(0)

        # checking for water budget conservation
        # in the presence of precipitation sinks
        # (This test only works without surface flux of q_tot)
        @test all(
            ClimaCore.isapprox(
                Yₜ_ρqₜ[colidx],
                Yₜ_ρqₚ[colidx],
                rtol = 1e2 * eps(FT),
            ),
        )

        # mass budget consistency
        @test all(
            ClimaCore.isapprox(Yₜ_ρ[colidx], Yₜ_ρqₜ[colidx], rtol = eps(FT)),
        )
    end
end
