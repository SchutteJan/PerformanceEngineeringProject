/*
  ======================================================================
   

  =======================================================================
*/

#include <stdlib.h>
#include <stdio.h>
#include <GL/glut.h>

#include "solver.h"
#include "io.h"

#include "cuda_solver.h"

/* Device Simulation State */
static GPUSTATE gpu;

/* global variables */
static int N;
static float dt, diff, visc;
static float force, source;
static int dvel;

static fluid *u, *v, *u_prev, *v_prev;
static fluid *dens, *dens_prev;

static int win_id;
static int win_x, win_y;
static int mouse_down[3];
static int omx, omy, mx, my;

/*
  ----------------------------------------------------------------------
   free/clear/allocate simulation data
  ----------------------------------------------------------------------
*/

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

static void free_cuda_data(void)
{
	checkCuda(cudaFree(gpu.u));
	checkCuda(cudaFree(gpu.u_prev));
	checkCuda(cudaFree(gpu.v));
	checkCuda(cudaFree(gpu.v_prev));
	checkCuda(cudaFree(gpu.dens));
	checkCuda(cudaFree(gpu.dens_prev));
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

/*
  ----------------------------------------------------------------------
   OpenGL specific drawing routines
  ----------------------------------------------------------------------
*/

static void pre_display(void)
{
	glViewport(0, 0, win_x, win_y);
	glMatrixMode(GL_PROJECTION);
	glLoadIdentity();
	gluOrtho2D(0.0, 1.0, 0.0, 1.0);
	glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
	glClear(GL_COLOR_BUFFER_BIT);
}

static void post_display(void)
{
	glutSwapBuffers();
}

static void draw_velocity(void)
{
	int i, j;
	float x, y, h;

	h = 1.0f / N;

	glColor3f(1.0f, 1.0f, 1.0f);
	glLineWidth(1.0f);

	glBegin(GL_LINES);

	for (i = 1; i <= N; i++)
	{
		x = (i - 0.5f) * h;
		for (j = 1; j <= N; j++)
		{
			y = (j - 0.5f) * h;

			glVertex2f(x, y);
			glVertex2f(x + u[IX(i, j)], y + v[IX(i, j)]);
		}
	}

	glEnd();
}

static void draw_density(void)
{
	int i, j;
	float x, y, h, d00, d01, d10, d11;

	h = 1.0f / N;

	glBegin(GL_QUADS);

	for (i = 0; i <= N; i++)
	{
		x = (i - 0.5f) * h;
		for (j = 0; j <= N; j++)
		{
			y = (j - 0.5f) * h;

			d00 = dens[IX(i, j)];
			d01 = dens[IX(i, j + 1)];
			d10 = dens[IX(i + 1, j)];
			d11 = dens[IX(i + 1, j + 1)];

			glColor3f(d00, d00, d00);
			glVertex2f(x, y);
			glColor3f(d10, d10, d10);
			glVertex2f(x + h, y);
			glColor3f(d11, d11, d11);
			glVertex2f(x + h, y + h);
			glColor3f(d01, d01, d01);
			glVertex2f(x, y + h);
		}
	}

	glEnd();
}

/*
  ----------------------------------------------------------------------
   relates mouse movements to forces sources
  ----------------------------------------------------------------------
*/

static void get_from_UI(fluid *d, fluid *u, fluid *v)
{
	int i, j, size = (N + 2) * (N + 2);
	int range = (N/128) + 1;

	for (i = 0; i < size; i++)
	{
		u[i] = v[i] = d[i] = 0.0f;
	}

	if (!mouse_down[0] && !mouse_down[2])
		return;

	i = (int)((mx / (float)win_x) * N + 1);
	j = (int)(((win_y - my) / (float)win_y) * N + 1);

	if (i < 1 || i > N || j < 1 || j > N)
		return;

	if (mouse_down[0])
	{
		u[IX(i, j)] = force * (mx - omx);
		v[IX(i, j)] = force * (omy - my);
	}

	if (mouse_down[2])
	{
		for (int ii = -range; ii <= range; ii++) 
		{
			for (int jj = -range; jj <= range; jj++) 
			{
				if (i + ii < 1 || i + ii > N || j + jj < 1 || j + jj > N)
					continue;
				d[IX(i + ii, j + jj)] = source / (3 + range);
			}
		}
	}

	omx = mx;
	omy = my;

	return;
}

/*
  ----------------------------------------------------------------------
   GLUT callback routines
  ----------------------------------------------------------------------
*/

static void key_func(unsigned char key, int x, int y)
{
	switch (key)
	{
	case 'c':
	case 'C':
		clear_data();
		break;

	case 'q':
	case 'Q':
		free_data();
		free_cuda_data();
		exit(0);
		break;

	case 'v':
	case 'V':
		dvel = !dvel;
		break;
	case 's':
	case 'S':
		save_to_disk("state.fluid", N, u, v, u_prev, v_prev, dens, dens_prev);
		break;
	case 'r':
	case 'R':
		read_from_disk("state.fluid", N, u, v, u_prev, v_prev, dens, dens_prev);
		break;
	}
}

static void mouse_func(int button, int state, int x, int y)
{
	omx = mx = x;
	omx = my = y;

	mouse_down[button] = state == GLUT_DOWN;
}

static void motion_func(int x, int y)
{
	mx = x;
	my = y;
}

static void reshape_func(int width, int height)
{
	glutSetWindow(win_id);
	// glutReshapeWindow(width, height);

	win_x = width;
	win_y = height;
}

static void idle_func(void)
{
	get_from_UI(dens_prev, u_prev, v_prev);
	step_cuda(N, u, v, u_prev, v_prev, dens, dens_prev, visc, dt, diff, gpu);
	glutSetWindow(win_id);
	glutPostRedisplay();
}

static void display_func(void)
{
	pre_display();

	if (dvel)
		draw_velocity();
	else
		draw_density();

	post_display();
}

/*
  ----------------------------------------------------------------------
   open_glut_window --- open a glut compatible window and set callbacks
  ----------------------------------------------------------------------
*/

static void open_glut_window(void)
{
	glutInitDisplayMode(GLUT_RGBA | GLUT_DOUBLE);

	glutInitWindowPosition((glutGet(GLUT_SCREEN_WIDTH)-win_x)/2,
                       	   (glutGet(GLUT_SCREEN_HEIGHT)-win_y)/2);
	glutInitWindowSize(win_x, win_y);
	win_id = glutCreateWindow("Fluid Simulator");

	glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
	glClear(GL_COLOR_BUFFER_BIT);
	glutSwapBuffers();
	glClear(GL_COLOR_BUFFER_BIT);
	glutSwapBuffers();

	pre_display();

	glutKeyboardFunc(key_func);
	glutMouseFunc(mouse_func);
	glutMotionFunc(motion_func);
	glutReshapeFunc(reshape_func);
	glutIdleFunc(idle_func);
	glutDisplayFunc(display_func);
}

/*
  ----------------------------------------------------------------------
   main --- main routine
  ----------------------------------------------------------------------
*/

int main(int argc, char **argv)
{
	glutInit(&argc, argv);

	if (argc != 1 && argc != 7)
	{
		fprintf(stderr, "usage : %s N dt diff visc force source\n", argv[0]);
		fprintf(stderr, "where:\n");
		fprintf(stderr, "\t N      : grid resolution\n");
		fprintf(stderr, "\t dt     : time step\n");
		fprintf(stderr, "\t diff   : diffusion rate of the density\n");
		fprintf(stderr, "\t visc   : viscosity of the fluid\n");
		fprintf(stderr, "\t force  : scales the mouse movement that generate a force\n");
		fprintf(stderr, "\t source : amount of density that will be deposited\n");
		exit(1);
	}

	if (argc == 1)
	{
		N = 128;
		dt = 0.1f;
		diff = 0.0f;
		visc = 0.0f;
		force = 5.0f;
		source = 100.0f;
		fprintf(stderr, "Using defaults : N=%d dt=%g diff=%g visc=%g force=%g source=%g\n",
				N, dt, diff, visc, force, source);
	}
	else
	{
		N = atoi(argv[1]);
		dt = atof(argv[2]);
		diff = atof(argv[3]);
		visc = atof(argv[4]);
		force = atof(argv[5]);
		source = atof(argv[6]);
	}

	printf("\n\nHow to use this demo:\n\n");
	printf("\t Add densities with the right mouse button\n");
	printf("\t Add velocities with the left mouse button and dragging the mouse\n");
	printf("\t Toggle density/velocity display with the 'v' key\n");
	printf("\t Clear the simulation by pressing the 'c' key\n");
	printf("\t Quit by pressing the 'q' key\n");
	printf("\t Save state of the simulation by pressing the 's' key\n");
	printf("\t Read state of the simulation by pressing the 'r' key\n");

	dvel = 0;

	if (!allocate_data())
		exit(1);

	if (!cuda_allocate_data())
		exit(1);
	
	clear_data();

	win_x = 1024;
	win_y = 1024;
	open_glut_window();

	glutMainLoop();

	exit(0);
}
