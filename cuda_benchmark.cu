/*
  ======================================================================
   cuda_benchmark.c --- Benchmark fluid solver
  ----------------------------------------------------------------------
   Author : Jan Schutte (jan.schutte@student.uva.nl)
   Creation Date : Apr 26 2021

   Description:

	Interface for creating reproducible benchmark results

  =======================================================================
*/

#include <stdlib.h>
#include <stdio.h>
#include <sys/time.h>
#include <sys/resource.h>
#include <string.h>

#include "solver.h"
#include "io.h"

#include "cuda_solver.h"


/* Simulation State */
static int N;
static float dt, diff, visc;
static float force, source;
static fluid *u, *v, *u_prev, *v_prev;
static fluid *dens, *dens_prev;

/* Device Simulation State */
static GPUSTATE gpu;

/* Benchmark State */
static int steps;
static int runs;

/* Timing Functions */

// Return number of seconds since unix Epoch
double get_time()
{
	struct timeval t;
	gettimeofday(&t, NULL);
	return t.tv_sec + t.tv_usec * 1e-6;
}

static void free_data(void)
{
	if (u)
		cudaFreeHost(u);
	if (v)
		cudaFreeHost(v);
	if (u_prev)
		cudaFreeHost(u_prev);
	if (v_prev)
		cudaFreeHost(v_prev);
	if (dens)
		cudaFreeHost(dens);
	if (dens_prev)
		cudaFreeHost(dens_prev);
}

static void clear_data(void)
{
	int i, size = (N + 2) * (N + 2);

	for (i = 0; i < size; i++)
	{
		u[i] = v[i] = u_prev[i] = v_prev[i] = dens[i] = dens_prev[i] = 0.0f;
	}
}

static int allocate_data(void)
{
	int size = (N + 2) * (N + 2) * sizeof(fluid);

	checkCuda(cudaMallocHost((void**)&u, size));
	checkCuda(cudaMallocHost((void**)&v, size));
	checkCuda(cudaMallocHost((void**)&u_prev, size));
	checkCuda(cudaMallocHost((void**)&v_prev, size));
	checkCuda(cudaMallocHost((void**)&dens, size));
	checkCuda(cudaMallocHost((void**)&dens_prev, size));

	if (!u || !v || !u_prev || !v_prev || !dens || !dens_prev)
	{
		fprintf(stderr, "cannot allocate data\n");
		return (0);
	}

	return (1);
}

static int cuda_allocate_data(void)
{
	int size = (N + 2) * (N + 2) * sizeof(fluid);
	
	gpu.u = NULL;
	checkCuda(cudaMalloc((void **) &gpu.u, size));
	
	gpu.v = NULL;
	checkCuda(cudaMalloc((void **) &gpu.v, size));
	
	gpu.u_prev = NULL;
	checkCuda(cudaMalloc((void **) &gpu.u_prev, size));

	gpu.v_prev = NULL;
	checkCuda(cudaMalloc((void **) &gpu.v_prev, size));

	gpu.dens = NULL;
	checkCuda(cudaMalloc((void **) &gpu.dens, size));

	gpu.dens_prev = NULL;
	checkCuda(cudaMalloc((void **) &gpu.dens_prev, size));

	if (!gpu.u || !gpu.v || !gpu.u_prev || 
		!gpu.v_prev || !gpu.dens || !gpu.dens_prev ) {
		return 0;
	}
	return 1;
}

static void step(void)
{
	step_cuda(N, u, v, u_prev, v_prev, dens, dens_prev, visc, dt, diff, gpu);
}

float random_float(float min, float max)
{
	float number;
	number = (float)rand() / (float)(RAND_MAX / (max - min));
	number += min;
	return number;
}

static void set_random_state()
{
	int i, j;
	const float min = -1;
	const float max = 1;

	FOR_EACH_CELL
		u[IX(i, j)] = random_float(min, max);
		v[IX(i, j)] = random_float(min, max);
		u_prev[IX(i, j)] = random_float(min, max);
		v_prev[IX(i, j)] = random_float(min, max);
		dens[IX(i, j)] = random_float(min * 10, max * 10);
		dens_prev[IX(i, j)] = random_float(min * 10, max * 10);
	END_FOR
}

static void benchmark(int file_N)
{
	double start_time, end_time, total_time, lin_solve_time, advect_time, project_time, add_source_time, cuda_copy, cuda_copy_async;
	int s = 0;
	total_time = lin_solve_time = advect_time = project_time = add_source_time = cuda_copy = cuda_copy_async = 0.0;
	
	N = file_N;

	if (u)
		free_data();
	
	if (!allocate_data()) {
		fprintf(stderr, "Could not allocate data for run\n");
		return;
	}

	if (!cuda_allocate_data()) {
		fprintf(stderr, "Could not allocate data on GPU device for run\n");
		return;
	}
	
	clear_data();

	printf("N: %d, ", N);
	int size = (N + 2) * (N + 2);
	int bytes = size * sizeof(fluid);

	for (int r = 0; r < runs; r++)
	{	
		set_random_state();
		// read_from_disk(start_state, file_N, u, v, u_prev, v_prev, dens, dens_prev);
	
		// Time for whole application
		start_time = get_time();
		for (s = 0; s < steps; s++)
		{
			step();
		}
		end_time = get_time();
		total_time += end_time - start_time;

		// Time for project function
		start_time = get_time();
		for (s = 0; s < steps; s++)
		{
			project_cuda(N, gpu.u, gpu.v, gpu.u_prev, gpu.v_prev);
		}
		end_time = get_time();
		project_time += end_time - start_time;

		// Time for lin solve function
		start_time = get_time();
		for (s = 0; s < steps; s++)
		{
			lin_solve_cuda(N, 0, gpu.dens, gpu.dens_prev, 1, 4);
		}
		end_time = get_time();
		lin_solve_time += end_time - start_time;

		// Time for advect function
		start_time = get_time();
		for (s = 0; s < steps; s++)
		{
			advect_cuda(N, 0, gpu.dens, gpu.dens_prev, gpu.u, gpu.v, dt);
		}
		end_time = get_time();
		advect_time += end_time - start_time;

		// Time for add_source function
		start_time = get_time();
		for (s = 0; s < steps; s++)
		{
			add_source_cuda(N, u, u_prev, dt);
		}
		end_time = get_time();
		add_source_time += end_time - start_time;

		start_time = get_time();
		for (s = 0; s < steps; s++)
		{
			checkCuda(cudaMemcpy(gpu.dens, dens, bytes, cudaMemcpyHostToDevice));
			checkCuda(cudaMemcpy(gpu.dens_prev, dens_prev, bytes, cudaMemcpyHostToDevice));
			checkCuda(cudaMemcpy(gpu.u, u, bytes, cudaMemcpyHostToDevice));
			checkCuda(cudaMemcpy(gpu.u_prev, u_prev, bytes, cudaMemcpyHostToDevice));
			checkCuda(cudaMemcpy(gpu.v, v, bytes, cudaMemcpyHostToDevice));
			checkCuda(cudaMemcpy(gpu.v_prev, v_prev, bytes, cudaMemcpyHostToDevice));

			checkCuda(cudaMemcpy(dens, gpu.dens, bytes, cudaMemcpyDeviceToHost));
			checkCuda(cudaMemcpy(dens_prev, gpu.dens_prev, bytes, cudaMemcpyDeviceToHost));
			checkCuda(cudaMemcpy(u, gpu.u, bytes, cudaMemcpyDeviceToHost));
			checkCuda(cudaMemcpy(u_prev, gpu.u_prev, bytes, cudaMemcpyDeviceToHost));
			checkCuda(cudaMemcpy(v, gpu.v, bytes, cudaMemcpyDeviceToHost));
			checkCuda(cudaMemcpy(v_prev, gpu.v_prev, bytes, cudaMemcpyDeviceToHost));
		}
		end_time = get_time();
		cuda_copy += end_time - start_time;

		start_time = get_time();
		for (s = 0; s < steps; s++)
		{
			checkCuda(cudaMemcpyAsync(gpu.dens, dens, bytes, cudaMemcpyHostToDevice));
			checkCuda(cudaMemcpyAsync(gpu.dens_prev, dens_prev, bytes, cudaMemcpyHostToDevice));
			checkCuda(cudaMemcpyAsync(gpu.u, u, bytes, cudaMemcpyHostToDevice));
			checkCuda(cudaMemcpyAsync(gpu.u_prev, u_prev, bytes, cudaMemcpyHostToDevice));
			checkCuda(cudaMemcpyAsync(gpu.v, v, bytes, cudaMemcpyHostToDevice));
			checkCuda(cudaMemcpyAsync(gpu.v_prev, v_prev, bytes, cudaMemcpyHostToDevice));
			cudaDeviceSynchronize();

			checkCuda(cudaMemcpyAsync(dens, gpu.dens, bytes, cudaMemcpyDeviceToHost));
			checkCuda(cudaMemcpyAsync(dens_prev, gpu.dens_prev, bytes, cudaMemcpyDeviceToHost));
			checkCuda(cudaMemcpyAsync(u, gpu.u, bytes, cudaMemcpyDeviceToHost));
			checkCuda(cudaMemcpyAsync(u_prev, gpu.u_prev, bytes, cudaMemcpyDeviceToHost));
			checkCuda(cudaMemcpyAsync(v, gpu.v, bytes, cudaMemcpyDeviceToHost));
			checkCuda(cudaMemcpyAsync(v_prev, gpu.v_prev, bytes, cudaMemcpyDeviceToHost));
			cudaDeviceSynchronize();
		}
		end_time = get_time();
		cuda_copy_async += end_time - start_time;
		
	}

	double step_time_total_s = (total_time / (runs * steps));
	double step_time_advect_s = (advect_time / (runs * steps));
	double step_time_lin_solve_s = (lin_solve_time / (runs * steps));
	double step_time_add_source_s = (add_source_time / (runs * steps));
	double step_time_project_s = (project_time / (runs * steps));
	double step_time_cuda_copy_s = (cuda_copy / (runs * steps * 6 * size));	
	double step_time_cuda_copy_async_s = (cuda_copy_async / (runs * steps * 6 * size));
	printf("total: %lf s, total step: %lf ms, frames per second: %lf, ", total_time, step_time_total_s * 1e3, 1.0 / step_time_total_s);
	printf("advect: %lf ms, ", step_time_advect_s * 1e3);
	printf("lin_solve: %lf ms, ", step_time_lin_solve_s * 1e3);
	printf("add_source: %lf ms, ", step_time_add_source_s * 1e3);
	printf("threads: %d, ", (int)(N / (float)BLOCKSIZE));
	printf("CUDA copy: %.10lf ms, ", step_time_cuda_copy_s * 1e3);
	printf("CUDA copy async: %.10lf ms, ", step_time_cuda_copy_async_s * 1e3);
	printf("project: %lf ms \n", step_time_project_s * 1e3);
}

int main(int argc, char **argv)
{
	if (argc != 1 && argc != 8)
	{
		fprintf(stderr, "usage : %s N dt diff visc force source\n", argv[0]);
		fprintf(stderr, "where:\n");
		fprintf(stderr, "\t dt     : time step\n");
		fprintf(stderr, "\t diff   : diffusion rate of the density\n");
		fprintf(stderr, "\t visc   : viscosity of the fluid\n");
		fprintf(stderr, "\t force  : scales the mouse movement that generate a force\n");
		fprintf(stderr, "\t source : amount of density that will be deposited\n");
		fprintf(stderr, "\t steps  : Number of steps to run simulation for\n");
		fprintf(stderr, "\t runs   : Number of times to a single simulation\n");
		exit(1);
	}

	if (argc == 1)
	{
		dt = 0.1f;
		diff = 0.0f;
		visc = 0.0f;
		force = 5.0f;
		source = 100.0f;
		steps = 10;
		runs = 10;
	}
	else
	{
		dt = atof(argv[1]);
		diff = atof(argv[2]);
		visc = atof(argv[3]);
		force = atof(argv[4]);
		source = atof(argv[5]);
		steps = atoi(argv[6]);
		runs = atoi(argv[7]);
	}

	printf("Arguments: dt=%g diff=%g visc=%g force=%g source=%g steps=%d runs=%d\n",
		   dt, diff, visc, force, source, steps, runs);

	for (int i = 128; i < 1024; i += 64)
		benchmark(i);
	
	free_data();

	exit(0);
}
