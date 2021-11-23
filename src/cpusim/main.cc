#include <iostream>
#include <memory>

#include "macros.h"
#include "serde.h"
#include "engine.h"
#include "simple_engine.h"
#include "timer.h"

int main(int argc, char *argv[])
{
    CORE::TIMER timer("cpusim");

    // Load args
    if (argc != 5)
    {
        std::cout << std::endl;
        std::cout << "Expect arguments: [ic_bin_file] [max_n_body] [dt] [n_iteration]" << std::endl;
        std::cout << "  [max_n_body]: no effect if < 0 or >= n_body from ic_bin_file" << std::endl;
        std::cout << std::endl;
        ASSERT(false && "Wrong number of arguments");
    }
    const std::string ic_bin_file_path = argv[1];
    const int max_n_body = std::stoi(argv[2]);
    const CORE::DT dt = std::stod(argv[3]);
    const int n_iteration = std::stoi(argv[4]);
    std::cout << "Running.." << std::endl;
    std::cout << "IC: " << ic_bin_file_path << std::endl;
    std::cout << "max_n_body: " << max_n_body << std::endl;
    std::cout << "dt: " << dt << std::endl;
    std::cout << "n_iteration: " << n_iteration << std::endl;
    std::cout << std::endl;
    timer.elapsed_previous("parsing_args");

    // Load ic
    CORE::BODY_IC_VEC
        body_ics = CORE::deserialize_body_ic_vec_from_bin(ic_bin_file_path);
    if (max_n_body >= 0 && max_n_body < static_cast<int>(body_ics.size()))
    {
        body_ics.resize(max_n_body);
        std::cout << "Limiting number of bodies to " << max_n_body << std::endl;
    }
    timer.elapsed_previous("loading_ic");

    // Select engine here
    std::unique_ptr<CPUSIM::ENGINE> engine(new CPUSIM::SIMPLE_ENGINE);
    engine->init(std::move(body_ics));
    timer.elapsed_previous("initializing_engine");

    // Execute engine
    engine->execute(dt, n_iteration);
    timer.elapsed_previous("running_engine");

    return 0;
}