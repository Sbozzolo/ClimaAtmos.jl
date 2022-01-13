@inline function calculate_pressure(Y, Ya, _...)
    error("not implemented for this model configuration.")
end

@inline function calculate_pressure(
    Y,
    Ya,
    ::AbstractBaseModelStyle,
    ::PotentialTemperature,
    ::Dry,
    params,
    FT,
)
    ρ = Y.base.ρ
    ρθ = Y.thermodynamics.ρθ

    thermo_state = @. Thermodynamics.PhaseDry_ρθ(params, ρ, ρθ / ρ)
    p = @. Thermodynamics.air_pressure(thermo_state)

    return p
end

@inline function calculate_pressure(
    Y,
    Ya,
    ::AdvectiveForm,
    ::TotalEnergy,
    ::Dry,
    params,
    FT,
)
    ρ = Y.base.ρ
    uh = Y.base.uh
    w = Y.base.w
    ρe_tot = Y.thermodynamics.ρe_tot

    interp_f2c = Operators.InterpolateF2C()

    z = Fields.coordinate_field(axes(ρ)).z
    uvw = @. Geometry.Covariant123Vector(uh) +
       Geometry.Covariant123Vector(interp_f2c(w))
    Φ = calculate_gravitational_potential(Y, Ya, params, FT)

    e_int = @. ρe_tot / ρ - Φ - norm(uvw)^2 / 2
    thermo_state = Thermodynamics.PhaseDry.(params, e_int, ρ)
    p = Thermodynamics.air_pressure.(thermo_state)

    return p
end