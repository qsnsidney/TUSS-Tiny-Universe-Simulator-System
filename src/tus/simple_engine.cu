#include "simple_engine.cuh"
#include "core/timer.h"

#include <stdlib.h>
#include <math.h>
#include <sys/time.h>
#include <assert.h>
#include <iostream>
#include <fstream>

#include "core/physics.hpp"
#include "core/serde.h"
#include "helper.cuh"
#include "data_t.cuh"
#include "constant.h"
#include "basic_kernel.cuh"

namespace
{
    CORE::SYSTEM_STATE generate_system_state(const data_t_3d *h_X, const data_t_3d *h_V, const data_t *mass, const size_t nbody)
    {
        CORE::SYSTEM_STATE system_state;
        system_state.reserve(nbody);
        for (size_t i_body = 0; i_body < nbody; i_body++)
        {
            CORE::POS pos_temp{h_X[i_body].x, h_X[i_body].y, h_X[i_body].z};
            CORE::VEL vel_temp{h_V[i_body].x, h_V[i_body].y, h_V[i_body].z};
            system_state.emplace_back(pos_temp, vel_temp, mass[i_body]);
        }
        return system_state;
    }
}

namespace TUS
{
    SIMPLE_ENGINE::SIMPLE_ENGINE(CORE::SYSTEM_STATE system_state_ic,
                                 CORE::DT dt,
                                 int block_size,
                                 std::optional<std::string> system_state_log_dir_opt) : ENGINE(std::move(system_state_ic), dt, std::move(system_state_log_dir_opt)),
                                                                                       block_size_(block_size)
    {
    }

    CORE::SYSTEM_STATE SIMPLE_ENGINE::execute(int n_iter)
    {
        size_t nBody = system_state_snapshot().size();

        CORE::TIMER timer(std::string("SIMPLE_ENGINE(") + std::to_string(nBody) + "," + std::to_string(dt()) + "*" + std::to_string(n_iter) + ")");

        /* BIN file of initial conditions */
        const auto &ic = system_state_snapshot();

        // random initializer just for now
        srand(time(NULL));
        size_t vector_size = sizeof(data_t_3d) * nBody;
        size_t data_size = sizeof(data_t) * nBody;

        /*
     *   host side memory allocation
     */
        data_t_3d *h_X, *h_A, *h_V, *h_output_X, *h_output_V;
        data_t *h_M;
        host_malloc_helper((void **)&h_X, vector_size);
        host_malloc_helper((void **)&h_A, vector_size);
        host_malloc_helper((void **)&h_V, vector_size);
        host_malloc_helper((void **)&h_output_X, vector_size);
        host_malloc_helper((void **)&h_output_V, vector_size);
        host_malloc_helper((void **)&h_M, data_size);
        timer.elapsed_previous("allocated host side memory");
        /*
     *   input randome initialize
     */

        parse_ic(h_X, h_V, h_M, ic);
        timer.elapsed_previous("deserialize_system_state_from_csv");

        /*
     *  mass 
     */
        data_t *d_M;
        gpuErrchk(cudaMalloc((void **)&d_M, data_size));
        /*
     *   create double buffer on device side
     */
        data_t_3d **d_X, **d_A, **d_V;
        unsigned src_index = 0;
        unsigned dest_index = 1;
        d_X = (data_t_3d **)malloc(2 * sizeof(data_t_3d *));
        gpuErrchk(cudaMalloc((void **)&d_X[src_index], vector_size));
        gpuErrchk(cudaMalloc((void **)&d_X[dest_index], vector_size));

        d_A = (data_t_3d **)malloc(2 * sizeof(data_t_3d *));
        gpuErrchk(cudaMalloc((void **)&d_A[src_index], vector_size));
        gpuErrchk(cudaMalloc((void **)&d_A[dest_index], vector_size));

        d_V = (data_t_3d **)malloc(2 * sizeof(data_t_3d *));
        gpuErrchk(cudaMalloc((void **)&d_V[src_index], vector_size));
        gpuErrchk(cudaMalloc((void **)&d_V[dest_index], vector_size));

        data_t_3d *d_V_half;
        gpuErrchk(cudaMalloc((void **)&d_V_half, vector_size));

        timer.elapsed_previous("allocated device memory");
        /*
     *   create double buffer on device side
     */
        // cudaMemcpy(d_A[0], h_A, vector_size, cudaMemcpyHostToDevice);
        cudaMemcpy(d_X[src_index], h_X, vector_size, cudaMemcpyHostToDevice);
        cudaMemcpy(d_V[src_index], h_V, vector_size, cudaMemcpyHostToDevice);
        cudaMemcpy(d_M, h_M, data_size, cudaMemcpyHostToDevice);
        timer.elapsed_previous("copied input data from host to device");

        // nthread is assigned to either 32 by default or set to a custom power of 2 by user
        std::cout << "Set thread_per_block to " << block_size_ << std::endl;
        unsigned nblocks = (nBody + block_size_ - 1) / block_size_;

        // calculate the initialia acceleration
        calculate_acceleration<<<nblocks, block_size_>>>(nBody, d_X[src_index], d_M, d_A[src_index]);
        timer.elapsed_previous("Calculated initial acceleration");

        {
            CORE::TIMER core_timer("all_iters");
            for (int i_iter = 0; i_iter < n_iter; i_iter++)
            {
                update_step_pos<<<nblocks, block_size_>>>(nBody, (data_t)dt(), d_X[src_index], d_V[src_index], d_A[src_index], d_M, //input
                                                            d_X[dest_index], d_V_half);                                               // output

                cudaDeviceSynchronize();

                calculate_acceleration<<<nblocks, block_size_>>>(nBody, d_X[dest_index], d_M, //input
                                                                   d_A[dest_index]);            // output

                cudaDeviceSynchronize();

                update_step_vel<<<nblocks, block_size_>>>(nBody, (data_t)dt(), d_M, d_A[dest_index], d_V_half, //input
                                                            d_V[dest_index]);                                    // output
                cudaDeviceSynchronize();

                timer.elapsed_previous(std::string("iter") + std::to_string(i_iter), CORE::TIMER::TRIGGER_LEVEL::INFO);

                if (is_system_state_logging_enabled())
                {
                    cudaMemcpy(h_output_X, d_X[dest_index], vector_size, cudaMemcpyDeviceToHost);
                    cudaMemcpy(h_output_V, d_V[dest_index], vector_size, cudaMemcpyDeviceToHost);

                    if (i_iter == 0)
                    {
                        push_system_state_to_log(generate_system_state(h_X, h_V, h_M, nBody));
                    }
                    push_system_state_to_log(generate_system_state(h_output_X, h_output_V, h_M, nBody));

                    if (i_iter % 10 == 0)
                    {
                        serialize_system_state_log();
                    }

                    timer.elapsed_previous(std::string("Transfer to CPU"), CORE::TIMER::TRIGGER_LEVEL::INFO);
                }

                swap(src_index, dest_index);
            }
            cudaDeviceSynchronize();
        }

        // at end, the final data is actually at src_index because the last swap
                // at end, the final data is actually at src_index because the last swap
        cudaMemcpy(h_output_X, d_X[src_index], vector_size, cudaMemcpyDeviceToHost);
        cudaMemcpy(h_output_V, d_V[src_index], vector_size, cudaMemcpyDeviceToHost);

        // Hack Hack Hack. dump out the data
        cudaMemcpy(h_A, d_A[src_index], vector_size, cudaMemcpyDeviceToHost);

        std::ofstream X_file;
        std::ofstream V_file;
        std::ofstream A_file;
        X_file.open ("simpleX.output");
        V_file.open ("simpleV.output");
        A_file.open ("simpleA.output");
        for(int i = 0; i < nBody; i++) {
            X_file << h_output_X[i].x << "\n";
            X_file << h_output_X[i].y << "\n";
            X_file << h_output_X[i].z << "\n";
            V_file << h_output_V[i].x << "\n";
            V_file << h_output_V[i].y << "\n";
            V_file << h_output_V[i].z << "\n";
            A_file << h_A[i].x << "\n";
            A_file << h_A[i].y << "\n";
            A_file << h_A[i].z << "\n";
        }
        X_file.close();
        V_file.close();
        A_file.close();
        timer.elapsed_previous("copied output back to host");

        // Just for debug purpose on small inputs
        //for (unsigned i = 0; i < nBody; i++)
        //{
        //   printf("object = %d, %f, %f, %f\n", i, h_output_X[i].x, h_output_X[i].y, h_output_X[i].z);
        //}

        return generate_system_state(h_output_X, h_output_V, h_M, nBody);
    }
}