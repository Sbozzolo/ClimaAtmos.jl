module TurbulenceConvectionUtils

using LinearAlgebra, StaticArrays
import ClimaCore
const CC = ClimaCore
const CCG = CC.Geometry
const CCO = CC.Operators
import ClimaCore.Geometry: ⊗

import UnPack

import OrdinaryDiffEq
const ODE = OrdinaryDiffEq

import CLIMAParameters
const CP = CLIMAParameters

import Logging
import TerminalLoggers
Logging.global_logger(TerminalLoggers.TerminalLogger())

import TurbulenceConvection
const TC = TurbulenceConvection
const tc_dir = pkgdir(TC)

include(joinpath(tc_dir, "driver", "dycore.jl"))
include(joinpath(tc_dir, "driver", "Surface.jl"))
include(joinpath(tc_dir, "driver", "initial_conditions.jl"))

include(joinpath(tc_dir, "driver", "Cases.jl"))
import .Cases

const tc_dir = pkgdir(TC)
include(joinpath(tc_dir, "driver", "generate_namelist.jl"))
import .NameList

function get_aux(edmf, Y, ::Type{FT}) where {FT}
    fspace = axes(Y.f)
    cspace = axes(Y.c)
    aux_cent_fields = TC.FieldFromNamedTuple(cspace, cent_aux_vars(FT, edmf))
    aux_face_fields = TC.FieldFromNamedTuple(fspace, face_aux_vars(FT, edmf))
    aux = CC.Fields.FieldVector(cent = aux_cent_fields, face = aux_face_fields)
    return aux
end

function get_edmf_cache(Y, namelist, param_set)
    Ri_bulk_crit = namelist["turbulence"]["EDMF_PrognosticTKE"]["Ri_crit"]
    case_type = Cases.get_case(namelist)
    Fo = TC.ForcingBase(case_type, param_set)
    Rad = TC.RadiationBase(case_type)
    surf_ref_state = Cases.surface_ref_state(case_type, param_set, namelist)
    surf_params =
        Cases.surface_params(case_type, surf_ref_state, param_set; Ri_bulk_crit)
    case = Cases.CasesBase(case_type; surf_params, Fo, Rad)
    precip_name = TC.parse_namelist(
        namelist,
        "microphysics",
        "precipitation_model";
        default = "None",
        valid_options = ["None", "cutoff", "clima_1m"],
    )
    # TODO: move to grid mean model
    precip_model = if precip_name == "None"
        TC.NoPrecipitation()
    elseif precip_name == "cutoff"
        TC.CutoffPrecipitation()
    elseif precip_name == "clima_1m"
        TC.Clima1M()
    else
        error("Invalid precip_name $(precip_name)")
    end
    FT = CC.Spaces.undertype(axes(Y.c))
    edmf = TC.EDMFModel(FT, namelist, precip_model)
    @info "EDMFModel: \n$(summary(edmf))"
    return (;
        edmf,
        case,
        param_set,
        surf_ref_state,
        aux = get_aux(edmf, Y, FT),
        precip_model,
    )
end

function tc_column_state(prog, aux, tendencies, inds...)
    prog_cent_column = CC.column(prog.c, inds...)
    prog_face_column = CC.column(prog.f, inds...)
    aux_cent_column = CC.column(aux.cent, inds...)
    aux_face_column = CC.column(aux.face, inds...)
    tends_cent_column = CC.column(tendencies.c, inds...)
    tends_face_column = CC.column(tendencies.f, inds...)
    prog_column =
        CC.Fields.FieldVector(cent = prog_cent_column, face = prog_face_column)
    aux_column =
        CC.Fields.FieldVector(cent = aux_cent_column, face = aux_face_column)
    tends_column = CC.Fields.FieldVector(
        cent = tends_cent_column,
        face = tends_face_column,
    )

    return TC.State(prog_column, aux_column, tends_column)
end

function tc_column_state(prog, aux, tendencies::Nothing, inds...)
    prog_cent_column = CC.column(prog.c, inds...)
    prog_face_column = CC.column(prog.f, inds...)
    aux_cent_column = CC.column(aux.cent, inds...)
    aux_face_column = CC.column(aux.face, inds...)
    prog_column =
        CC.Fields.FieldVector(cent = prog_cent_column, face = prog_face_column)
    aux_column =
        CC.Fields.FieldVector(cent = aux_cent_column, face = aux_face_column)
    tends_column = nothing

    return TC.State(prog_column, aux_column, tends_column)
end


function init_tc!(Y, p, param_set, namelist)
    (; edmf_cache, Δt) = p
    (; edmf, param_set, surf_ref_state, aux, case) = edmf_cache

    FT = eltype(edmf)
    N_up = TC.n_updrafts(edmf)

    for inds in TC.iterate_columns(Y.c)
        # `nothing` goes into State because OrdinaryDiffEq.jl owns tendencies.
        state = tc_column_state(Y, aux, nothing, inds...)

        grid = TC.Grid(axes(state.prog.cent))
        FT = eltype(grid)
        t = FT(0)
        compute_ref_state!(state, grid, param_set; ts_g = surf_ref_state)

        Cases.initialize_profiles(case, grid, param_set, state)
        set_thermo_state_pθq!(state, grid, edmf.moisture_model, param_set)
        set_grid_mean_from_thermo_state!(param_set, state, grid)
        assign_thermo_aux!(state, grid, edmf.moisture_model, param_set)
        Cases.initialize_forcing(case, grid, state, param_set)
        Cases.initialize_radiation(case, grid, state, param_set)
        initialize_edmf(edmf, grid, state, case, param_set, t)
    end
end


function sgs_flux_tendency!(Yₜ, Y, p, t)
    (; edmf_cache, Δt) = p
    (; edmf, param_set, aux, case, precip_model) = edmf_cache

    # TODO: write iterator for this
    for inds in TC.iterate_columns(Y.c)
        state = tc_column_state(Y, aux, Yₜ, inds...)
        grid = TC.Grid(axes(state.prog.cent))

        set_thermo_state_peq!(state, grid, edmf.moisture_model, param_set)

        aux_gm = TC.center_aux_grid_mean(state)

        @. aux_gm.θ_virt = TD.virtual_pottemp(param_set, aux_gm.ts)

        surf = get_surface(case.surf_params, grid, state, t, param_set)
        force = case.Fo
        radiation = case.Rad

        TC.affect_filter!(edmf, grid, state, param_set, surf, case.casename, t)

        # Update aux / pre-tendencies filters. TODO: combine these into a function that minimizes traversals
        # Some of these methods should probably live in `compute_tendencies`, when written, but we'll
        # treat them as auxiliary variables for now, until we disentangle the tendency computations.
        Cases.update_forcing(case, grid, state, t, param_set)
        Cases.update_radiation(case.Rad, grid, state, t, param_set)

        TC.update_aux!(edmf, grid, state, surf, param_set, t, Δt)

        TC.compute_precipitation_sink_tendencies(
            precip_model,
            edmf,
            grid,
            state,
            param_set,
            Δt,
        )
        TC.compute_precipitation_advection_tendencies(
            precip_model,
            edmf,
            grid,
            state,
            param_set,
        )

        TC.compute_turbconv_tendencies!(edmf, grid, state, param_set, surf, Δt)

        # TODO: incrementally disable this and enable proper grid mean terms
        compute_gm_tendencies!(
            edmf,
            grid,
            state,
            surf,
            radiation,
            force,
            param_set,
        )
    end
end

end # module
