#ifndef RKF45_HPP
#define RKF45_HPP

#include "error_codes.h"
#include "solver.hpp"
#include "rkf45_types.h"


namespace opencl_solvers
{

    class RKF45Integrator : public Integrator<rk_t, rk_counters_t>
    {
private:
        rk_t rk_vals;
        std::vector<std::string> _files;
        std::vector<std::string> _includes;
        std::vector<std::string> _paths;

public:
        RKF45Integrator(int neq, std::size_t numWorkGroups, const IVP& ivp, const RKF45SolverOptions& options) :
            Integrator(neq, numWorkGroups, ivp, options),
            rk_vals(),
            _files({file_relative_to_me(__FILE__, "rkf45.cl")}),
            _includes({"rkf45_types.h"}),
            _paths({path_of(__FILE__)})
        {
            // ensure our internal error code match the enum-types
            static_assert(ErrorCode::SUCCESS == SUCCESS, "Enum mismatch");
            static_assert(ErrorCode::TOO_MUCH_WORK == TOO_MUCH_WORK, "Enum mismatch");
            static_assert(ErrorCode::TDIST_TOO_SMALL == TDIST_TOO_SMALL, "Enum mismatch");
            //static_assert(ErrorCode::MAX_STEPS_EXCEEDED == RK_HIN_MAX_ITERS, "Enum mismatch");

            // init the rk struct
            rk_vals.max_iters = options.maxIters();
            rk_vals.min_iters = options.minIters();
            rk_vals.adaption_limit = options.adaptionLimit();
            rk_vals.s_rtol = options.rtol();
            rk_vals.s_atol = options.atol();

            // and initialize the kernel
            this->initialize_kernel();
        }

protected:

        const rk_t& getSolverStruct() const
        {
            return rk_vals;
        }

        //! \brief The requird size, in bytes of the RKF45 solver (per-IVP)
        std::size_t requiredSolverMemorySize()
        {
            // 8 working vectors solely for rkf45
            return IntegratorBase::requiredSolverMemorySize() + (9 * _neq) * sizeof(double);
        }

        //! \brief return the list of files for this solver
        const std::vector<std::string>& solverFiles() const
        {
            return _files;
        }

        const std::vector<std::string>& solverIncludes() const
        {
            return _includes;
        }

        //! \brief return the list of include paths for this solver
        const std::vector<std::string>& solverIncludePaths() const
        {
            return _paths;
        }


    };
}

#endif
