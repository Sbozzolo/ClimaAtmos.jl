# includes init_bickley_jet_2d_plane(
include("initial_conditions/bickley_jet_2d_plane.jl")

function run_bickley_jet_2d_plane(
    FT;
    stepper = SSPRK33(),
    nelements = (16, 16),
    npolynomial = 4,
    dt = 0.04,
    callbacks = (),
    mode = :regression,
)
    if FT <: Float32
        @info "Bickley jet 2D plane test does not run for $FT."
        return nothing
    end

    params = map(FT, (
        g = 9.8,  # gravitational constant
        D₄ = 1e-4,  # hyperdiffusion constant
        ϵ = 0.1,  # perturbation size for initial condition
        l = 0.5,  # Gaussian width
        k = 0.5,  # sinusoidal wavenumber
        ρ₀ = 1.0,  # reference density
    ))

    domain = PeriodicPlane(
        FT,
        xlim = (-2π, 2π),
        ylim = (-2π, 2π),
        nelements = nelements,
        npolynomial = npolynomial,
    )

    model = ShallowWaterModel(
        domain = domain,
        boundary_conditions = nothing,
        initial_conditions = init_bickley_jet_2d_plane,
        parameters = params,
    )

    # execute differently depending on testing mode
    if mode == :unit
        # TODO!: run with input callbacks = ...
        simulation = Simulation(model, stepper, dt = dt, tspan = (0.0, 1.0))
        #step!(simulation)

        @test true # either error or integration runs
    elseif mode == :regression
        simulation = Simulation(model, stepper, dt = dt, tspan = (0.0, 1.0))
        step!(simulation)
        u = simulation.integrator.u

        # perform regression check
        current_min = -0.019531432010661924
        current_max = 0.41271930346029584
        @test minimum(parent(u.u)) ≈ current_min atol = 1e-3
        @test maximum(parent(u.u)) ≈ current_max atol = 1e-3
    elseif mode == :validation
        # TODO!: run with callbacks = ...
        simulation = Simulation(model, stepper, dt = dt, tspan = (0.0, 80.0))
        run!(simulation)
        u_end = simulation.integrator.u

        # post-processing
        ENV["GKSwstype"] = "nul"
        Plots.GRBackend()

        # make output directory
        path = joinpath(@__DIR__, "output_validation")
        mkpath(path)

        # plot final state
        foi = Plots.plot(u_end.ρθ, clim = (-1, 1))
        Plots.png(foi, joinpath(path, "bickley_jet_2d_plane_FT_$FT"))

        @test true # check is visual
    else
        throw(ArgumentError("$mode incompatible with test case."))
    end

    nothing
end
