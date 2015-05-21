/* read_initial_conditions.c
 * the generic initial condition reader
 * \file read_initial_conditions
 *
 * \author Nicholas Curtis
 * \date 03/10/2015
 *
 */

#include "header.h"
#include "gpu_memory.cuh"
#include "gpu_macros.cuh"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <sys/time.h>

 int read_initial_conditions(const char* filename, int NUM, int block_size, int grid_size, double** y_host, double** y_device, double** variable_host, double** variable_device) {
    int padded = initialize_gpu_memory(NUM, block_size, grid_size, y_device, variable_device);
    (*y_host) = (double*)malloc(padded * NN * sizeof(double));
    (*variable_host) = (double*)malloc(padded * sizeof(double));
    FILE *fp = fopen (filename, "rb");
    if (fp == NULL)
    {
        fprintf(stderr, "Could not open file: %s\n", filename);
        exit(-1);
    }
    double buffer[NN + 1];

    // load temperature and mass fractions for all threads (cells)
    for (int i = 0; i < NUM; ++i)
    {
        // read line from data file
        int count = fread(buffer, sizeof(double), NN + 1, fp);
        if (count != (NN + 1))
        {
            fprintf(stderr, "File (%s) is incorrectly formatted, %d doubles were expected but only %d were read.\n", filename, NN + 1, count);
            exit(-1);
        }
        //put into y_host
        (*y_host)[i] = buffer[0];
#ifdef CONP
        (*variable_host)[i] = buffer[1];
#elif CONV
        double pres = buffer[1];
#endif
        for (int j = 2; j <= NN; j++)
            (*y_host)[i + (j - 1) * padded] = buffer[j];

        // if constant volume, calculate density
#ifdef CONV
        double Yi[NSP];
        double Xi[NSP];

        for (int j = 1; j < NN; ++j)
        {
            Yi[j - 1] = (*y_host)[i + j * padded];
        }

        mass2mole (Yi, Xi);
        (*variable_host)[i] = getDensity ((*y_host)[i], pres, Xi);
#endif
    }
    fclose (fp);
    return padded;
}