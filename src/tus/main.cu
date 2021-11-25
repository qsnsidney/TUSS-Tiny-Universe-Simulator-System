#include <stdlib.h>
#include <math.h>
#include <memory>
#include <iostream>

#include "core/physics.hpp"
#include "core/serde.h"
#include "helper.h"
#include "data_t.h"
#include "constant.h"
#include "basic_kernel.h"
#include "core/timer.h"
#include "core/macros.hpp"
#include "simple_engine.cuh"
#include "core/cxxopts.hpp"

#define DEFAULT_BLOCK_SIZE 32

auto parse_args(int argc, const char *argv[])
{
    cxxopts::Options options(argv[0]);
    options
        .positional_help("[optional args]")
        .show_positional_help()
        .set_tab_expansion()
        .allow_unrecognised_options();

    auto option_group = options.add_options();
    option_group("i,ic_file", "ic_file: .bin or .csv", cxxopts::value<std::string>());
    option_group("b,num_bodies", "max_n_bodies: optional (default -1), no effect if < 0 or >= n_body from ic_file", cxxopts::value<int>()->default_value("-1"));
    option_group("d,dt", "dt", cxxopts::value<CORE::UNIVERSE::floating_value_type>());
    option_group("n,num_iterations", "num_iterations", cxxopts::value<int>());
    option_group("t,block_size", "num_threads_per_block for CUDA", cxxopts::value<int>()->default_value(std::to_string(DEFAULT_BLOCK_SIZE)));
    option_group("o,out", "body_states_log_dir: optional", cxxopts::value<std::string>());
    option_group("h,help", "Print usage");

    auto result = options.parse(argc, argv);

    if (result.count("help"))
    {
        std::cout << options.help() << std::endl;
        exit(0);
    }

    return result;
}

int main(int argc, const char *argv[])
{
    CORE::TIMER timer("tus");

    // Load args
    auto arg_result = parse_args(argc, argv);
    const std::string ic_file_path = arg_result["ic_file"].as<std::string>();
    const int max_n_body = arg_result["num_bodies"].as<int>();
    const CORE::DT dt = arg_result["dt"].as<CORE::UNIVERSE::floating_value_type>();
    const int n_iteration = arg_result["num_iterations"].as<int>();
    const int block_size = arg_result["block_size"].as<int>();
    // I know some none-power-of 2 also makes sense
    // but incase someone enter a dumb number, assert it here
    // later this can be removed
    ASSERT(IsPowerOfTwo(block_size));
    std::optional<std::string> body_states_log_dir_opt = {};
    if (arg_result.count("out"))
    {
        body_states_log_dir_opt = arg_result["out"].as<std::string>();
    }

    std::cout << "Running.." << std::endl;
    std::cout << "ic_file: " << ic_file_path << std::endl;
    std::cout << "max_n_body: " << max_n_body << std::endl;
    std::cout << "dt: " << dt << std::endl;
    std::cout << "n_iteration: " << n_iteration << std::endl;
    std::cout << "block_size: " << block_size << std::endl;
    std::cout << "body_states_log_dir: " << (body_states_log_dir_opt ? *body_states_log_dir_opt : std::string("null")) << std::endl;
    std::cout << std::endl;
    timer.elapsed_previous("parsing_args");

    /* Get Dimension */
    /// TODO: Add more arguments for input and output
    /// Haiqi: I think it should be "main [num_body] [simulation_end_time] [num_iteration] or [step_size]". or we simply let step_size = 1
    if (argc < 3 or argc > 4)
    {
        std::cout << "Error: The number of arguments must be either 3 or 4" << std::endl;
        std::cout << "Expecting: <maxnbodies> <path_to_ic_file> <thread_per_block(optional)>" << std::endl;
        return 1;
    }

    timer.elapsed_previous("parsing_args");

    /* BIN file of initial conditions */
    CORE::BODY_STATE_VEC
        body_states = CORE::deserialize_body_state_vec_from_file(ic_file_path);
    if (max_n_body >= 0 && max_n_body < static_cast<int>(body_states.size()))
    {
        body_states.resize(max_n_body);
        std::cout << "Limiting number of bodies to " << max_n_body << std::endl;
    }
    timer.elapsed_previous("loading_ic");

    // Select engine here
    std::unique_ptr<CORE::ENGINE> engine(new TUS::SIMPLE_ENGINE(std::move(body_states), dt, block_size, body_states_log_dir_opt));
    timer.elapsed_previous("initializing_engine");

    engine->run(n_iteration);
    timer.elapsed_previous("running_engine");

    return 0;
}
