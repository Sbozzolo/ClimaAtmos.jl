using Test
import CLIMAParameters as CP
import ClimaAtmos as CA

FT = Float64

default_args = CA.cli_defaults(CA.argparse_settings())

@testset "Test types" begin

    config_dict = Dict(
        "krylov_rtol" => Float64(1),
        "newton_rtol" => Float32(1),
        "max_newton_iters_ode" => Int64(1),
        "nh_poly" => Int32(1),
        "dt_save_to_disk" => "str",
        "bubble" => true,
    )
    parsed_args = CA.AtmosConfig(config_dict).parsed_args
    @test parsed_args["krylov_rtol"] isa FT
    @test parsed_args["newton_rtol"] isa FT
    @test parsed_args["max_newton_iters_ode"] isa Int
    @test parsed_args["nh_poly"] isa Int
    @test parsed_args["dt_save_to_disk"] isa String
    @test parsed_args["bubble"] isa Bool
end

@testset "Test unique aliases" begin
    config_dict =
        Dict("toml" => [joinpath(pkgdir(CA), "test", "parameter_tests.toml")])
    config = CA.AtmosConfig(config_dict)
    @test_throws ErrorException CP.get_parameter_values!(
        config.toml_dict,
        ["same_alias"],
    )
end

@testset "Test all parameter tomls in toml/" begin
    toml_path = joinpath(pkgdir(CA), "toml")
    for toml in readdir(toml_path)
        config_dict = Dict("toml" => [joinpath(toml_path, toml)])
        config = CA.AtmosConfig(config_dict)
        # Ensure that there are no errors
        @test CA.create_parameter_set(config) isa
              CA.Parameters.ClimaAtmosParameters
    end
end
