/******************************************************************************
* Copyright (C) 2023 Advanced Micro Devices, Inc. All Rights Reserved.
* SPDX-License-Identifier: MIT
******************************************************************************/
/*
 * helloworld.c: simple test application
 *
 * This application configures UART 16550 to baud rate 9600.
 * PS7 UART (Zynq) is not initialized by this application, since
 * bootrom/bsp configures it to baud rate 115200
 *
 * ------------------------------------------------
 * | UART TYPE   BAUD RATE                        |
 * ------------------------------------------------
 *   uartns550   9600
 *   uartlite    Configurable only in HW design
 *   ps7_uart    115200 (configured by bootrom/bsp)
 */

#include <stdio.h>
#include <stdint.h>
#include "platform.h"
#include "xil_printf.h"
#include "xil_io.h"
#include "xiltimer.h"

/* TPU registers - base address comes from the Vivado design */
#define TPU_BASE   XPS_FPGA_AXI_S0_BASEADDR
#define TPU_CTRL   0x000
#define TPU_STATUS 0x004
#define TPU_W      0x040
#define TPU_X      0x080
#define TPU_C      0x100

/* Zynq global timer - free running counter, ticks at the CPU clock / 2 */
#define GTIMER_COUNT  0xF8F00200
#define GTIMER_CTRL   0xF8F00208

#define N 8

/* fixed test matrices - 8-bit signed, so values must stay within -128..127 */
int8_t A[N][N] = {
    {   69,   67,  -69,  -67,   42,  -42,   21,   -7 },
    {  -69,  -67,   69,   67,   -8,   90,  -55,   13 },
    {   67,   69,  -67,  -69,   77,  -12,   33,  -88 },
    {  -67,  -69,   67,   69, -100,   50,   -5,   11 },
    {   42,  -42,    7,   -7,   69,  -69,   67,  -67 },
    {  -90,   90,  -13,   13,  -67,   67,  -69,   69 },
    {   21,  -21,   99,  -99,   69,   67,  -69,  -67 },
    {   -7,    7,  -44,   44,  -67,  -69,   67,   69 }
};
int8_t B[N][N] = {
    {   67,  -69,   12,   -8,   69,  -67,   40,  -40 },
    {  -67,   69,  -12,    8,  -69,   67,  -40,   40 },
    {   69,   67,  -69,  -67,   21,  -21,   90,  -90 },
    {  -69,  -67,   69,   67,  -21,   21,  -90,   90 },
    {    7,   -7,   42,  -42,   69,   67,   -3,    3 },
    {   -7,    7,  -42,   42,  -69,  -67,    3,   -3 },
    {   55,  -55,   11,  -11,   67,   69,  -77,   77 },
    {  -55,   55,  -11,   11,  -67,  -69,   77,  -77 }
};
int32_t C_tpu[N][N];   /* what the TPU gives back */
int32_t C_cpu[N][N];   /* the CPU answer, used to check the TPU */

/* squeeze 4 signed bytes into one 32-bit word for the AXI write */
uint32_t pack(int8_t *m, int word)
{
    int b = word * 4;
    return ((uint32_t)(uint8_t)m[b+0])
         | ((uint32_t)(uint8_t)m[b+1] << 8)
         | ((uint32_t)(uint8_t)m[b+2] << 16)
         | ((uint32_t)(uint8_t)m[b+3] << 24);
}

/* print an 8x8 matrix, tab between numbers so the columns line up */
void print8(char *name, int8_t m[N][N])
{
    int i, j;
    xil_printf("%s\r\n", name);
    for (i = 0; i < N; i++) {
        for (j = 0; j < N; j++)
            xil_printf("%d\t", m[i][j]);
        xil_printf("\r\n");
    }
    xil_printf("\r\n");
}

void print32(char *name, int32_t m[N][N])
{
    int i, j;
    xil_printf("%s\r\n", name);
    for (i = 0; i < N; i++) {
        for (j = 0; j < N; j++)
            xil_printf("%d\t", m[i][j]);
        xil_printf("\r\n");
    }
    xil_printf("\r\n");
}

int main()
{
    int i, j, k;
    int bad;
    uint32_t t0, t1, t2, t3;
    uint32_t ps0, ps1;
    uint32_t compute_ns, total_ns, ps_ns;

    init_platform();

    /* turn the global timer on so the counter actually moves */
    Xil_Out32(GTIMER_CTRL, 1);

    /* do the same matmul in software, and time it - this is the PS side */
    ps0 = Xil_In32(GTIMER_COUNT);
    for (i = 0; i < N; i++) {
        for (j = 0; j < N; j++) {
            int32_t sum = 0;
            for (k = 0; k < N; k++)
                sum += A[i][k] * B[k][j];
            C_cpu[i][j] = sum;
        }
    }
    ps1 = Xil_In32(GTIMER_COUNT);

    t0 = Xil_In32(GTIMER_COUNT);

    /* send both matrices to the TPU, 4 bytes per word */
    for (k = 0; k < 16; k++) {
        Xil_Out32(TPU_BASE + TPU_W + k*4, pack(&B[0][0], k));
        Xil_Out32(TPU_BASE + TPU_X + k*4, pack(&A[0][0], k));
    }

    t1 = Xil_In32(GTIMER_COUNT);

    /* start it; wait for busy first (run has started), then done. done is
       still set from the previous run until start clears it */
    Xil_Out32(TPU_BASE + TPU_CTRL, 1);
    while ((Xil_In32(TPU_BASE + TPU_STATUS) & 2) == 0)
        ;
    while ((Xil_In32(TPU_BASE + TPU_STATUS) & 1) == 0)
        ;

    t2 = Xil_In32(GTIMER_COUNT);

    /* read the result back */
    for (i = 0; i < N; i++)
        for (j = 0; j < N; j++)
            C_tpu[i][j] = Xil_In32(TPU_BASE + TPU_C + (i*N + j)*4);

    t3 = Xil_In32(GTIMER_COUNT);

    /* timer ticks -> ns (it counts at COUNTS_PER_SECOND) */
    ps_ns      = (uint32_t)((uint64_t)(ps1 - ps0) * 1000000000ULL / COUNTS_PER_SECOND);
    compute_ns = (uint32_t)((uint64_t)(t2 - t1) * 1000000000ULL / COUNTS_PER_SECOND);
    total_ns   = (uint32_t)((uint64_t)(t3 - t0) * 1000000000ULL / COUNTS_PER_SECOND);

    /* print the three matrices */
    print8("Matrix A", A);
    print8("Matrix B", B);
    print32("Matrix C = A x B", C_tpu);

    /* compare the TPU result against the CPU one */
    bad = 0;
    for (i = 0; i < N; i++)
        for (j = 0; j < N; j++)
            if (C_tpu[i][j] != C_cpu[i][j])
                bad++;

    if (bad == 0)
        xil_printf("result OK - matches the CPU\r\n");
    else
        xil_printf("result WRONG - %d bad elements\r\n", bad);

    xil_printf("\r\n");
    xil_printf("PS (CPU) compute:    %d ns\r\n", (int)ps_ns);
    xil_printf("PL (TPU) compute:    %d ns\r\n", (int)compute_ns);
    xil_printf("PL (TPU) total run:  %d ns\r\n", (int)total_ns);

    cleanup_platform();
    return 0;
}
