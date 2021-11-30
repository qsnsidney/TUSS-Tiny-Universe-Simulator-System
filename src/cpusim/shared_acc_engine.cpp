#include "shared_acc_engine.h"
#include "core/timer.h"

#include <iostream>
#include "buffer.h"

namespace CPUSIM
{
    CORE::BODY_STATE_VEC SHARED_ACC_ENGINE::execute(int n_iter)
    {
        const int n_body = body_states_ic().size();

        CORE::TIMER timer(std::string("SHARED_ACC_ENGINE(") + std::to_string(n_body) + "," + std::to_string(dt()) + "*" + std::to_string(n_iter) + ")");

        std::vector<CORE::MASS> mass(n_body, 0);
        BUFFER buf_in(n_body);
        // Step 1: Prepare ic
        for (int i_body = 0; i_body < n_body; i_body++)
        {
            const auto &[body_pos, body_vel, body_mass] = body_states_ic()[i_body];
            buf_in.pos[i_body] = body_pos;
            buf_in.vel[i_body] = body_vel;
            mass[i_body] = body_mass;
        }
        timer.elapsed_previous("step1");

        // Step 2: Prepare acceleration for ic
        parallel_for_helper(0, n_body, [&buf_in](int i_target_body)
                            { buf_in.acc[i_target_body].reset(); });
        for (int i_target_body = 0; i_target_body < n_body; i_target_body++)
        {
            buf_in.acc[i_target_body].reset();
        }
        for (int i_target_body = 0; i_target_body < n_body; i_target_body++)
        {
            for (int j_source_body = i_target_body + 1; j_source_body < n_body; j_source_body++)
            {
                const CORE::ACC tgt_to_src{CORE::universal_field(buf_in.pos[j_source_body], buf_in.pos[i_target_body])};
                buf_in.acc[i_target_body] += mass[j_source_body] * tgt_to_src;
                buf_in.acc[j_source_body] -= mass[i_target_body] * tgt_to_src;
            }
        }
        timer.elapsed_previous("step2");

        BUFFER buf_out(n_body);
        std::vector<CORE::VEL> vel_tmp(n_body);
        // Core iteration loop
        for (int i_iter = 0; i_iter < n_iter; i_iter++)
        {
            if (false)
            {
                debug_workspace(buf_in, mass);
            }

            for (int i_target_body = 0; i_target_body < n_body; i_target_body++)
            {
                // Step 3: Compute temp velocity
                vel_tmp[i_target_body] = CORE::VEL::updated(buf_in.vel[i_target_body], buf_in.acc[i_target_body], dt());

                // Step 4: Update position
                buf_out.pos[i_target_body] = CORE::POS::updated(buf_in.pos[i_target_body], buf_in.vel[i_target_body], buf_in.acc[i_target_body], dt());
            }

            for (int i_target_body = 0; i_target_body < n_body; i_target_body++)
            {
                buf_out.acc[i_target_body].reset();
            }
            for (int i_target_body = 0; i_target_body < n_body; i_target_body++)
            {
                // Step 5: Compute acceleration
                for (int j_source_body = i_target_body + 1; j_source_body < n_body; j_source_body++)
                {
                    const CORE::ACC tgt_to_src{CORE::universal_field(buf_out.pos[j_source_body], buf_out.pos[i_target_body])};
                    buf_out.acc[i_target_body] += mass[j_source_body] * tgt_to_src;
                    buf_out.acc[j_source_body] -= mass[i_target_body] * tgt_to_src;
                }

                // Step 6: Update velocity
                buf_out.vel[i_target_body] = CORE::VEL::updated(vel_tmp[i_target_body], buf_out.acc[i_target_body], dt());
            }

            // Write BODY_STATE_VEC to log
            if (i_iter == 0)
            {
                push_body_states_to_log([&]()
                                        { return generate_body_state_vec(buf_in, mass); });
            }
            push_body_states_to_log([&]()
                                    { return generate_body_state_vec(buf_out, mass); });
            if (i_iter % 10 == 0)
            {
                serialize_body_states_log();
            }

            // Prepare for next iteration
            std::swap(buf_in, buf_out);

            timer.elapsed_previous(std::string("iter") + std::to_string(i_iter), CORE::TIMER::TRIGGER_LEVEL::INFO);
        }

        timer.elapsed_previous("all_iters");

        return generate_body_state_vec(buf_in, mass);
    }
}