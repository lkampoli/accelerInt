/** 
* \file radau2a.cu
*
* \author Nicholas J. Curtis
* \date 03/16/2015
*
* A Radau2A IRK implementation for CUDA
* Based off the work of Harier and Wanner (1996),
* and the FATODE ODE integration library
* 
* NOTE: all matricies stored in column major format!
* 
*/

#include "header.cuh"
#include "solver_options.h"
#include "inverse.cuh"
#include "complexInverse_NSP.cuh"
#include "solver_options.h"
#include "jacob.cuh"
#include "dydt.cuh"
#include <cuComplex.h>

//#define WARP_VOTING
#ifdef WARP_VOTING
	#define ANY(X) (__any((X)))
	#define ALL(X) (__all((X)))
#else
	#define ANY(X) ((X))
	#define ALL(X) ((X))
#endif
#define Max_no_steps (200000)
#define NewtonMaxit (8)
#define StartNewton (true)
#define Gustafsson
#define Roundoff (EPS)
#define FacMin (0.2)
#define FacMax (8)
#define FacSafe (0.9)
#define FacRej (0.1)
#define ThetaMin (0.001)
#define NewtonTol (0.03)
#define Qmin (1.0)
#define Qmax (1.2)
#define UNROLL (8)
#define T_ID (threadIdx.x + blockIdx.x * blockDim.x)
#ifdef DIVERGENCE_TEST
 	extern __device__ int integrator_steps[DIVERGENCE_TEST];
#endif
//#define SDIRK_ERROR

__device__
void scale (const double __restrict__ * y0, const double __restrict__* y, double __restrict__* sc) {
	#pragma unroll 8
	for (int i = 0; i < NSP; ++i) {
		sc[INDEX(i)] = 1.0 / (ATOL + fmax(fabs(y0[INDEX(i)]), fabs(y[INDEX(i)])) * RTOL);
	}
}

__device__
void scale_init (const double __restrict__ * y0, double __restrict__ * sc) {
	#pragma unroll 8
	for (int i = 0; i < NSP; ++i) {
		sc[INDEX(i)] = 1.0 / (ATOL + fabs(y0[INDEX(i)]) * RTOL);
	}
}

__device__
void safe_memcpy(double __restrict__* dest, const double __restrict__ * source)
{
	#pragma unroll 8
	for (int i = 0; i < NSP; i++)
	{
		dest[INDEX(i)] = source[INDEX(i)];
	}
}
__device__
void safe_memset3(double __restrict__ * dest1,
				  double __restrict__ * dest2,
				  double __restrict__ * dest3, const double val)
{
	#pragma unroll 8
	for (int i = 0; i < NSP; i++)
	{
		dest1[INDEX(i)] = val;
		dest2[INDEX(i)] = val;
		dest3[INDEX(i)] = val;
	}
}
__device__
void safe_memset(double __restrict__ * dest1, const double val)
{
	#pragma unroll 8
	for (int i = 0; i < NSP; i++)
	{
		dest1[INDEX(i)] = val;
	}
}
__device__
void safe_memset_jac(double __restrict__ * dest1, const double val)
{
	#pragma unroll 8
	for (int i = 0; i < NSP * NSP; i++)
	{
		dest1[INDEX(i)] = val;
	}
}

__constant__ double rkA[3][3] = { {
	 1.968154772236604258683861429918299e-1,
	-6.55354258501983881085227825696087e-2,
	 2.377097434822015242040823210718965e-2
	}, {
	 3.944243147390872769974116714584975e-1,
	 2.920734116652284630205027458970589e-1,
	-4.154875212599793019818600988496743e-2
	}, {
	 3.764030627004672750500754423692808e-1,
	 5.124858261884216138388134465196080e-1,
	 1.111111111111111111111111111111111e-1
	}
};

__constant__ double rkB[3] = {
3.764030627004672750500754423692808e-1,
5.124858261884216138388134465196080e-1,
1.111111111111111111111111111111111e-1
};

__constant__ double rkC[3] = {
1.550510257216821901802715925294109e-1,
6.449489742783178098197284074705891e-1,
1.0
};

//Local order of error estimator 
/*
!~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
!~~~> Diagonalize the RK matrix:               
! rkTinv * inv(rkA) * rkT =          
!           |  rkGamma      0           0     |
!           |      0      rkAlpha   -rkBeta   |
!           |      0      rkBeta     rkAlpha  |
!~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

__constant__ double rkGamma = 3.637834252744495732208418513577775e0;
__constant__ double rkAlpha = 2.681082873627752133895790743211112e0;
__constant__ double rkBeta  = 3.050430199247410569426377624787569e0;

__constant__ double rkT[3][3] = {
{9.443876248897524148749007950641664e-2,
-1.412552950209542084279903838077973e-1,
-3.00291941051474244918611170890539e-2},
{2.502131229653333113765090675125018e-1,
2.041293522937999319959908102983381e-1,
3.829421127572619377954382335998733e-1},
{1.0e0,
1.0e0,
0.0e0}
};

__constant__ double rkTinv[3][3] = {
{4.178718591551904727346462658512057e0,
3.27682820761062387082533272429617e-1,
5.233764454994495480399309159089876e-1},
{-4.178718591551904727346462658512057e0,
-3.27682820761062387082533272429617e-1,
4.766235545005504519600690840910124e-1},
{-5.02872634945786875951247343139544e-1,
2.571926949855605429186785353601676e0,
-5.960392048282249249688219110993024e-1}
};

__constant__ double rkTinvAinv[3][3] = {
{1.520148562492775501049204957366528e+1,
1.192055789400527921212348994770778e0,
1.903956760517560343018332287285119e0},
{-9.669512977505946748632625374449567e0,
-8.724028436822336183071773193986487e0,
3.096043239482439656981667712714881e0},
{-1.409513259499574544876303981551774e+1,
5.895975725255405108079130152868952e0,
-1.441236197545344702389881889085515e-1}
};

__constant__ double rkAinvT[3][3] = {
{0.3435525649691961614912493915818282e0,
-0.4703191128473198422370558694426832e0,
0.3503786597113668965366406634269080e0},
{0.9102338692094599309122768354288852e0,
1.715425895757991796035292755937326e0,
0.4040171993145015239277111187301784e0},
{3.637834252744495732208418513577775e0,
2.681082873627752133895790743211112e0,
-3.050430199247410569426377624787569e0}
};

__constant__ double rkELO = 4;

///////////////////////////////////////////////////////////////////////////////

/*
* calculate E1 & E2 matricies and their LU Decomposition
*/
__device__ void RK_Decomp(double H, double* __restrict__ E1, cuDoubleComplex* __restrict__ E2,
							int* __restrict__ ipiv1, int* __restrict__ ipiv2, int* __restrict__ info) {
	cuDoubleComplex temp = make_cuDoubleComplex(rkAlpha/H, rkBeta/H);
	#pragma unroll 8
	for (int i = 0; i < NSP; i++)
	{
		#pragma unroll 8
		for(int j = 0; j < NSP; j++)
		{
			E2[INDEX(i + j * NSP)] = make_cuDoubleComplex(-E1[INDEX(i + j * NSP)], 0);
			E1[INDEX(i + j * NSP)] = -E1[INDEX(i + j * NSP)];
		}
		E1[INDEX(i + i * NSP)] += rkGamma / H;
		E2[INDEX(i + i * NSP)] = cuCadd(E2[INDEX(i + i * NSP)], temp); 
	}
	getLU(NSP, E1, ipiv1, info);
	if (*info != 0) {
		return;
	}
	getComplexLU(NSP, E2, ipiv2, info);
}

__device__ void RK_Make_Interpolate(const double* __restrict__ Z1, const double* __restrict__ Z2,
										const double* __restrict__ Z3, double* __restrict__ CONT) {
	double den = (rkC[2] - rkC[1]) * (rkC[1] - rkC[0]) * (rkC[0] - rkC[2]); 
	#pragma unroll 8
	for (int i = 0; i < NSP; i++) {
		CONT[INDEX(i)] = ((-rkC[2] * rkC[2] * rkC[1] * Z1[INDEX(i)] + Z3[INDEX(i)] * rkC[1]* rkC[0] * rkC[0]
                    + rkC[1] * rkC[1] * rkC[2] * Z1[INDEX(i)] - rkC[1] * rkC[1] * rkC[0] * Z3[INDEX(i)] 
                    + rkC[2] * rkC[2] * rkC[0] * Z2[INDEX(i)] - Z2[INDEX(i)] * rkC[2] * rkC[0] * rkC[0])
                    /den) - Z3[INDEX(i)];
        CONT[INDEX(NSP + i)] = -( rkC[0] * rkC[0] * (Z3[INDEX(i)] - Z2[INDEX(i)]) + rkC[1] * rkC[1] * (Z1[INDEX(i)] - Z3[INDEX(i)]) 
        				 + rkC[2] * rkC[2] * (Z2[INDEX(i)] - Z1[INDEX(i)]) )/den;
        CONT[INDEX(NSP + NSP + i)] = ( rkC[0] * (Z3[INDEX(i)] - Z2[INDEX(i)]) + rkC[1] * (Z1[INDEX(i)] - Z3[INDEX(i)]) 
                           + rkC[2] * (Z2[INDEX(i)] - Z1[INDEX(i)]) ) / den;
	}
}

__device__ void RK_Interpolate(double H, double Hold, double* __restrict__ Z1,
								double* __restrict__ Z2, double* __restrict__ Z3, const double* __restrict__ CONT) {
	double r = H / Hold;
	register double x1 = 1.0 + rkC[0] * r;
	register double x2 = 1.0 + rkC[1] * r;
	register double x3 = 1.0 + rkC[2] * r;
	#pragma unroll 8
	for (int i = 0; i < NSP; i++) {
		Z1[INDEX(i)] = CONT[INDEX(i)] + x1 * (CONT[INDEX(NSP + i)] + x1 * CONT[INDEX(NSP + NSP + i)]);
		Z2[INDEX(i)] = CONT[INDEX(i)] + x2 * (CONT[INDEX(NSP + i)] + x2 * CONT[INDEX(NSP + NSP + i)]);
		Z3[INDEX(i)] = CONT[INDEX(i)] + x2 * (CONT[INDEX(NSP + i)] + x3 * CONT[INDEX(NSP + NSP + i)]);
	}
}


__device__ void WADD(const double* __restrict__ X, const double* __restrict__ Y, double* __restrict__ Z) {
	#pragma unroll 8
	for (int i = 0; i < NSP; i++)
	{
		Z[INDEX(i)] = X[INDEX(i)] + Y[INDEX(i)];
	}
}

__device__ void DAXPY3(double DA1, double DA2, double DA3,
						const double* __restrict__ DX, double* __restrict__ DY1,
						double* __restrict__ DY2, double* __restrict__ DY3) {
	#pragma unroll 8
	for (int i = 0; i < NSP; i++) {
		DY1[INDEX(i)] += DA1 * DX[INDEX(i)];
		DY2[INDEX(i)] += DA2 * DX[INDEX(i)];
		DY3[INDEX(i)] += DA3 * DX[INDEX(i)];
	}
}

/*
*Prepare the right-hand side for Newton iterations
*     R = Z - hA * F
*/
__device__ void RK_PrepareRHS(double t, double pr, double H, double* Y, double* __restrict__ Z1,
								double* __restrict__ Z2, double* __restrict__ Z3, double* __restrict__ R1,
								double* __restrict__ R2, double* __restrict__ R3, double* __restrict__ TMP,
								double* __restrict__ F) {
	#pragma unroll 8
	for (int i = 0; i < NSP; i++) {
		R1[INDEX(i)] = Z1[INDEX(i)];
		R2[INDEX(i)] = Z2[INDEX(i)];
		R3[INDEX(i)] = Z3[INDEX(i)];
	}

	// TMP = Y + Z1
	WADD(Y, Z1, TMP);
	dydt(t + rkC[0] * H, pr, TMP, F);
	//R[:] -= -h * rkA[:][0] * F[:]
	DAXPY3(-H * rkA[0][0], -H * rkA[1][0], -H * rkA[2][0], F, R1, R2, R3);

	// TMP = Y + Z2
	WADD(Y, Z2, TMP);
	dydt(t + rkC[1] * H, pr, TMP, F);
	//R[:] -= -h * rkA[:][1] * F[:]
	DAXPY3(-H * rkA[0][1], -H * rkA[1][1], -H * rkA[2][1], F, R1, R2, R3);

	// TMP = Y + Z3
	WADD(Y, Z3, TMP);
	dydt(t + rkC[2] * H, pr, TMP, F);
	//R[:] -= -h * rkA[:][2] * F[:]
	DAXPY3(-H * rkA[0][2], -H * rkA[1][2], -H * rkA[2][2], F, R1, R2, R3);
}

__device__ void dlaswp(double* __restrict__ A, int* __restrict__ ipiv) {
	#pragma unroll 8
	for (int i = 0; i < NSP; i++) {
		int ip = ipiv[INDEX(i)];
		if (ip != i) {
			double temp = A[INDEX(i)];
			A[INDEX(i)] = A[INDEX(ip)];
			A[INDEX(ip)] = temp;
		}
	}	
}

//diag == 'n' -> nounit = true
//upper == 'u' -> upper = true
__device__ void dtrsm(bool upper, bool nounit, double* __restrict__ A, double* __restrict__ b) {
	if (upper) {
		#pragma unroll 8
		for (int k = NSP - 1; k >= 0; --k)
		{
			if (nounit) {
				b[INDEX(k)] /= A[INDEX(k + k * NSP)];
			}
			#pragma unroll 8
			for (int i = 0; i < k; i++)
			{
				b[INDEX(i)] -= b[INDEX(k)] * A[INDEX(i + k * NSP)];
			}
		}
	}
	else{
		#pragma unroll 8
		for (int k = 0; k < NSP; k++) {
			if (fabs(b[INDEX(k)]) > 0) {
				if (nounit) {
					b[INDEX(k)] /= A[INDEX(k + k * NSP)];
				}
				#pragma unroll 8
				for (int i = k + 1; i < NSP; i++)
				{
					b[INDEX(i)] -= b[INDEX(k)] * A[INDEX(i + k * NSP)];
				}
			}
		}
	}
}

__device__ void dgetrs(double* __restrict__ A, double* __restrict__ B, int* __restrict__ ipiv) {
	dlaswp(B, ipiv);
	dtrsm(false, false, A, B);
	dtrsm(true, true, A, B);
}

__device__ void zlaswp(cuDoubleComplex* __restrict__ A, int* __restrict__ ipiv) {
	#pragma unroll 8
	for (int i = 0; i < NSP; i++) {
		int ip = ipiv[INDEX(i)];
		if (ip != i) {
			cuDoubleComplex temp = A[INDEX(i)];
			A[INDEX(i)] = A[INDEX(ip)];
			A[INDEX(ip)] = temp;
		}
	}	
}

//diag == 'n' -> nounit = true
//upper == 'u' -> upper = true
__device__ void ztrsm(bool upper, bool nounit, cuDoubleComplex* __restrict__ A, cuDoubleComplex* __restrict__ b) {
	if (upper) {
		#pragma unroll 8
		for (int k = NSP - 1; k >= 0; --k)
		{
			if (nounit) {
				b[INDEX(k)] = cuCdiv(b[INDEX(k)], A[INDEX(k + k * NSP)]);
			}
			#pragma unroll 8
			for (int i = 0; i < k; i++)
			{
				b[INDEX(i)] = cuCsub(b[INDEX(i)], cuCmul(b[INDEX(k)], A[INDEX(i + k * NSP)]));
			}
		}
	}
	else{
		#pragma unroll 8
		for (int k = 0; k < NSP; k++) {
			if (cuCabs(b[INDEX(k)]) > 0) {
				if (nounit) {
					b[INDEX(k)] = cuCdiv(b[INDEX(k)], A[INDEX(k + k * NSP)]);
				}
				#pragma unroll 8
				for (int i = k + 1; i < NSP; i++)
				{
					b[INDEX(i)] = cuCsub(b[INDEX(i)], cuCmul(b[INDEX(k)], A[INDEX(i + k * NSP)]));
				}
			}
		}
	}
}

__device__ void zgetrs(cuDoubleComplex* __restrict__ A, cuDoubleComplex* __restrict__ B, int* __restrict__ ipiv) {
	zlaswp(B, ipiv);
	ztrsm(false, false, A, B);
	ztrsm(true, true, A, B);
}

__device__ void RK_Solve(double H, double* __restrict__ E1, cuDoubleComplex* __restrict__ E2, double* __restrict__ R1,
								   double* __restrict__ R2, double* __restrict__ R3, int* __restrict__ ipiv1,
								   int* __restrict__ ipiv2, cuDoubleComplex* __restrict__ temp) {
	// Z = (1/h) T^(-1) A^(-1) * Z
	#pragma unroll 8
	for(int i = 0; i < NSP; i++)
	{
		double x1 = R1[INDEX(i)] / H;
		double x2 = R2[INDEX(i)] / H;
		double x3 = R3[INDEX(i)] / H;
		R1[INDEX(i)] = rkTinvAinv[0][0] * x1 + rkTinvAinv[0][1] * x2 + rkTinvAinv[0][2] * x3;
		R2[INDEX(i)] = rkTinvAinv[1][0] * x1 + rkTinvAinv[1][1] * x2 + rkTinvAinv[1][2] * x3;
		R3[INDEX(i)] = rkTinvAinv[2][0] * x1 + rkTinvAinv[2][1] * x2 + rkTinvAinv[2][2] * x3;
	}
	dgetrs(E1, R1, ipiv1);
	#pragma unroll 8
	for (int i = 0; i < NSP; ++i)
	{
		temp[INDEX(i)] = make_cuDoubleComplex(R2[INDEX(i)], R3[INDEX(i)]);
	}
	zgetrs(E2, temp, ipiv2);
	#pragma unroll 8
	for (int i = 0; i < NSP; ++i)
	{
		R2[INDEX(i)] = cuCreal(temp[INDEX(i)]);
		R3[INDEX(i)] = cuCimag(temp[INDEX(i)]);
	}

	// Z = T * Z
	#pragma unroll 8
	for (int i = 0; i < NSP; ++i) {
		double x1 = R1[INDEX(i)];
		double x2 = R2[INDEX(i)];
		double x3 = R3[INDEX(i)];
		R1[INDEX(i)] = rkT[0][0] * x1 + rkT[0][1] * x2 + rkT[0][2] * x3;
		R2[INDEX(i)] = rkT[1][0] * x1 + rkT[1][1] * x2 + rkT[1][2] * x3;
		R3[INDEX(i)] = rkT[2][0] * x1 + rkT[2][1] * x2 + rkT[2][2] * x3;
	}
}

__device__ double RK_ErrorNorm(double* __restrict__ scale, double* __restrict__ DY) {
	double sum = 0;
	#pragma unroll 8
	for (int i = 0; i < NSP; ++i){
		sum += (scale[INDEX(i)] * scale[INDEX(i)] * DY[INDEX(i)] * DY[INDEX(i)]);
	}
	return fmax(sqrt(sum / ((double)NSP)), 1e-10);
}

__device__ double RK_ErrorEstimate(double H, double t, double pr, double* __restrict__ Y,
											 double* __restrict__ F0, double* __restrict__ Z1,
											 double* __restrict__ Z2, double* __restrict__ Z3, double* __restrict__ scale,
											 double* __restrict__ E1, int* __restrict__ ipiv1, bool FirstStep, bool Reject,
											 double* __restrict__ F1, double* __restrict__ F2, double* __restrict__ TMP) {
	double HrkE1  = rkE[1]/H;
    double HrkE2  = rkE[2]/H;
    double HrkE3  = rkE[3]/H;

    #pragma unroll 8
    for (int i = 0; i < NSP; ++i) {
    	F2[INDEX(i)] = HrkE1 * Z1[INDEX(i)] + HrkE2 * Z2[INDEX(i)] + HrkE3 * Z3[INDEX(i)];
    }
    #pragma unroll 8
    for (int i = 0; i < NSP; ++i) {
    	TMP[INDEX(i)] = rkE[0] * F0[INDEX(i)] + F2[INDEX(i)];
    }
    dgetrs(E1, TMP, ipiv1);
    double Err = RK_ErrorNorm(scale, TMP);
    if (Err >= 1.0 && (FirstStep || Reject)) {
        #pragma unroll 8
    	for (int i = 0; i < NSP; i++) {
        	TMP[INDEX(i)] += Y[INDEX(i)];
        }
    	dydt(t, pr, TMP, F1);
    	#pragma unroll 8
    	for (int i = 0; i < NSP; i++) {
        	TMP[INDEX(i)] = F1[INDEX(i)] + F2[INDEX(i)];
        }
        dgetrs(E1, TMP, ipiv1);
        Err = RK_ErrorNorm(scale, TMP);
    }
    return Err;
}

/** 
 *  5th-order Radau2A implementation
 * 
 */
__device__ void integrate (const double t_start, const double t_end, const double var, double* __restrict__ y,
							const mechanism_memory* __restrict__ mech, const solver_memory* __restrict__ solver) {
	double Hmin = 0;
	double Hold = 0;
#ifdef Gustafsson
	double Hacc = 0;
	double ErrOld = 0;
#endif
	double H = fmin(5e-7, t_end - t_start);
	double Hnew;
	double t = t_start;
	bool Reject = false;
	bool FirstStep = true;
	bool SkipJac = false;
	bool SkipLU = false;
	scale_init(y, solver->sc);
	safe_memcpy(solver->y0, y);
#ifndef FORCE_ZERO
	safe_memset(solver->F0, 0.0);
#endif
	int info = 0;
	int Nconsecutive = 0;
	int Nsteps = 0;
	double NewtonRate = pow(2.0, 1.25);
	while (t + Roundoff < t_end) {
		#ifdef DIVERGENCE_TEST
			integrator_steps[T_ID]++;
		#endif
		if(!Reject) {
			dydt (t, var, y, mech->dy, solver->F0);
		}
		if(!SkipLU) { 
			//need to update Jac/LU
			if(!SkipJac) {
				safe_memset_jac(solver->E1, mech);
#ifndef FINITE_DIFF
				eval_jacob (t, var, y, solver->E1, mech);
#else
				eval_jacob (t, var, y, solver->E1, mech, solver->work1, solver->work2);
#endif
			}
			RK_Decomp(H, solver->E1, solver->E2, solver->ipiv1, solver->ipiv2, &info);
			if(info != 0) {
				Nconsecutive += 1;
				if (Nconsecutive >= 5)
				{
					result[T_ID] = errorCodes.err_consecutive_steps;
					return;
				}
				H *= 0.5;
				Reject = true;
				SkipJac = true;
				SkipLU = false;
				continue;
			}
			else
			{
				Nconsecutive = 0;
			}
		}
		Nsteps += 1;
		if (Nsteps >= Max_no_steps)
		{
			result[T_ID] = errorCodes.max_steps_exceeded;
			return;
		}
		if (0.1 * fabs(H) <= fabs(t) * Roundoff)
		{
			result[T_ID] = errorCodes.h_plus_t_equals_h;
			return;
		}
		if (FirstStep || !StartNewton) {
			safe_memset3(solver->Z1, solver->Z2, solver->Z3, 0.0);
		} else {
			RK_Interpolate(H, Hold, solver->Z1, solver->Z2, solver->Z3, solver->CONT);
		}
		bool NewtonDone = false;
		double NewtonIncrementOld = 0;
		double Fac = 0.5; //Step reduction if too many iterations
		int NewtonIter = 0;
		double Theta = 0;
		
		//reuse previous NewtonRate
		NewtonRate = pow(fmax(NewtonRate, EPS), 0.8);

		for (; NewtonIter < NewtonMaxit; NewtonIter++) {
			RK_PrepareRHS(t, var, H, y, solver->Z1, solver->Z2, solver->Z3,
							solver->DZ1, solver->DZ2, solver->DZ3, solver->work1,
							solver->work2);
			RK_Solve(H, solver->E1, solver->E2, solver->DZ1, solver->DZ2, solver->DZ3,
						solver->ipiv1, solver->ipiv2, solver->work4);
			double d1 = RK_ErrorNorm(solver->sc, solver->DZ1);
			double d2 = RK_ErrorNorm(solver->sc, solver->DZ2);
			double d3 = RK_ErrorNorm(solver->sc, solver->DZ3);
			double NewtonIncrement = sqrt((d1 * d1 + d2 * d2 + d3 * d3) / 3.0);

			Theta = ThetaMin;
			if (NewtonIter > 0) 
			{
				Theta = NewtonIncrement / NewtonIncrementOld;
				if(Theta >= 0.99) //! Non-convergence of Newton: Theta too large
					break;
				else
					NewtonRate = Theta / (1.0 - Theta);
				//Predict error at the end of Newton process 
				double NewtonPredictedErr = (NewtonIncrement * pow(Theta, (NewtonMaxit - NewtonIter - 1))) / (1.0 - Theta);
				if(NewtonPredictedErr >= NewtonTol) {
					//Non-convergence of Newton: predicted error too large
					double Qnewton = fmin(10.0, NewtonPredictedErr / NewtonTol);
                    Fac = 0.8 * pow(Qnewton, -1.0/((double)(NewtonMaxit-NewtonIter)));
                    break;
				}
			}

			NewtonIncrementOld = fmax(NewtonIncrement, Roundoff);
            // Update solution
            #pragma unroll 8
            for (int i = 0; i < NSP; i++)
            {
            	solver->Z1[i] -= solver->DZ1[i];
            	solver->Z2[i] -= solver->DZ2[i];
            	solver->Z3[i] -= solver->DZ3[i];
            }

            NewtonDone = (NewtonRate * NewtonIncrement <= NewtonTol);
            if (NewtonIter >= NewtonMaxit)
            {
				result[T_ID] = errorCodes.newton_max_iterations_exceeded;
				return;
			}
		}
		if(!NewtonDone) {
			H = Fac * H;
			Reject = true;
			SkipJac = true;
			SkipLU = false;
			continue;
		}

		double Err = RK_ErrorEstimate(H, t, var, y, 
						solver->F0, solver->Z1, solver->Z2, 
						solver->Z3, solver->sc, solver->E1, solver->ipiv1, 
						FirstStep, Reject, solver->work1, solver->work2,
						solver->work3);

		//!~~~> Computation of new step size Hnew
		Fac = pow(Err, (-1.0 / rkELO)) * (1.0 + 2 * NewtonMaxit) / (NewtonIter + 1 + 2 * NewtonMaxit);
		Fac = fmin(FacMax, fmax(FacMin, Fac));
		Hnew = Fac * H;
		if (Err < 1.0) {
#ifdef Gustafsson
			if (!FirstStep) {
				double FacGus = FacSafe * (H / Hacc) * pow(Err * Err / ErrOld, -0.25);
				FacGus = fmin(FacMax, fmax(FacMin, FacGus));
				Fac = fmin(Fac, FacGus);
				Hnew = Fac * H;
			}
			Hacc = H;
			ErrOld = fmax(1e-2, Err);
#endif
			FirstStep = false;
			Hold = H;
			t += H;
			#pragma unroll 8
			for (int i = 0; i < NSP; i++) {
				y[i] += solver->Z3[i];
			}
			// Construct the solution quadratic interpolant Q(c_i) = Z_i, i=1:3
			if (StartNewton) {
				RK_Make_Interpolate(solver->Z1, solver->Z2, solver->Z3, solver->CONT);
			}
			scale(y, solver->y0, solver->sc);
			safe_memcpy(solver->y0, y);
			Hnew = fmin(fmax(Hnew, Hmin), t_end - t);
			if (Reject) {
				Hnew = fmin(Hnew, H);
			}
			Reject = false;
			if (t + Hnew / Qmin - t_end >= 0.0) {
				H = t_end - t;
			} else {
				double Hratio = Hnew / H;
	            // Reuse the LU decomposition
	            SkipLU = (Theta <= ThetaMin) && (Hratio>=Qmin) && (Hratio<=Qmax);
	            if (!SkipLU) H = Hnew;
			}
			// If convergence is fast enough, do not update Jacobian
         	SkipJac = NewtonIter == 1 || NewtonRate <= ThetaMin;
		}
		else {
			if (FirstStep || Reject) {
				H = FacRej * H;
			} else {
				H = Hnew;
			}
			Reject = true;
			SkipJac = true;
			SkipLU = false;
		}
	}
	result[T_ID] = errorCodes.success;
}