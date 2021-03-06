#include <cstdio>
#include <cuda.h>
#include <cmath>
#include <iostream>
#include <thrust/execution_policy.h>
#include <thrust/random.h>
#include <thrust/remove.h>
#include <thrust/host_vector.h>
#include <thrust/device_vector.h>
#include <thrust/copy.h>

#include "sceneStructs.h"
#include "scene.h"
#include "glm/glm.hpp"
#include "glm/gtx/norm.hpp"
#include "utilities.h"
#include "pathtrace.h"
#include "intersections.h"
#include "interactions.h"
#include "mesh.h"

#define ERRORCHECK 1

#define FILENAME (strrchr(__FILE__, '/') ? strrchr(__FILE__, '/') + 1 : __FILE__)
#define checkCUDAError(msg) checkCUDAErrorFn(msg, FILENAME, __LINE__)
void checkCUDAErrorFn(const char *msg, const char *file, int line) {
#if ERRORCHECK
    cudaDeviceSynchronize();
    cudaError_t err = cudaGetLastError();
    if (cudaSuccess == err) {
        return;
    }

    fprintf(stderr, "CUDA error");
    if (file) {
        fprintf(stderr, " (%s:%d)", file, line);
    }
    fprintf(stderr, ": %s: %s\n", msg, cudaGetErrorString(err));
    exit(EXIT_FAILURE);
#endif
}



//=== kernel functions ====

__host__ __device__
thrust::default_random_engine makeSeededRandomEngine(int iter, int index, int depth) {
    int h = utilhash((1 << 31) | (depth << 22) | iter) ^ utilhash(index);
    return thrust::default_random_engine(h);
}

//Kernel that writes the image to the OpenGL PBO directly.
__global__ void sendImageToPBO(uchar4* pbo, glm::ivec2 resolution,
        int iter, glm::vec3* image) {
    int x = (blockIdx.x * blockDim.x) + threadIdx.x;
    int y = (blockIdx.y * blockDim.y) + threadIdx.y;

    if (x < resolution.x && y < resolution.y) {
        int index = x + (y * resolution.x);
        glm::vec3 pix = image[index];

        glm::ivec3 color;
        color.x = glm::clamp((int) (pix.x / iter * 255.0), 0, 255);
        color.y = glm::clamp((int) (pix.y / iter * 255.0), 0, 255);
        color.z = glm::clamp((int) (pix.z / iter * 255.0), 0, 255);

        // Each thread writes one pixel location in the texture (textel)
        pbo[index].w = 0;
        pbo[index].x = color.x;
        pbo[index].y = color.y;
        pbo[index].z = color.z;
    }
}


/**
* Example function to generate static and test the CUDA-GL interop.
* Delete this once you're done looking at it!
*/
__global__ void generateNoiseDeleteMe(Camera cam, int iter, glm::vec3 *image) {
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x < cam.resolution.x && y < cam.resolution.y) {
		int index = x + (y * cam.resolution.x);

		thrust::default_random_engine rng = makeSeededRandomEngine(iter, index, 0);
		thrust::uniform_real_distribution<float> u01(0, 1);

		// CHECKITOUT: Note that on every iteration, noise gets added onto
		// the image (not replaced). As a result, the image smooths out over
		// time, since the output image is the contents of this array divided
		// by the number of iterations.
		//
		// Your renderer will do the same thing, and, over time, it will become
		// smoother.
		image[index] += glm::vec3(u01(rng));
	}
}

__global__ void kern_generateInitRays(Ray *m_rays, Camera cam, glm::vec3 m_upper_left_pos, glm::vec3 m_cam_right, glm::vec3 m_cam_up, glm::vec3 *image, float tan_fovx, float tan_fovy)
{

	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x < cam.resolution.x && y < cam.resolution.y) {
		int index = x + (y * cam.resolution.x);
		
		
		//if the final image is inverse on the x axis we can change the expression of x ratio to fix this problem
		float ratio_x = (float)(cam.resolution.x - 1-x) / (float)(cam.resolution.x - 1);
		float ratio_y = (float)y / (float)(cam.resolution.y - 1);
		
		glm::vec3 dx = 2 *tan_fovx*ratio_x*m_cam_right;
		glm::vec3 dy = 2 * tan_fovy*ratio_y* (-m_cam_up);

		glm::vec3 cur_pos = m_upper_left_pos + dx + dy;

		Ray m_cur_ray;
		m_cur_ray.origin = cam.position;
		m_cur_ray.direction = glm::normalize(cur_pos - cam.position);

		m_rays[index] = m_cur_ray;


		//for debug
		//image[index] += m_cur_ray.direction;

	
	}
}


//__global__ void kern_generateInitRays(Ray *m_rays, Camera cam, glm::vec3 m_down_left_pos, glm::vec3 m_cam_right, glm::vec3 m_cam_up, glm::vec3 *image, float tan_fovx, float tan_fovy)
//{
//
//	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
//	int y = (blockIdx.y * blockDim.y) + threadIdx.y;
//
//	if (x < cam.resolution.x && y < cam.resolution.y) {
//		int index = x + (y * cam.resolution.x);
//
//
//		//if the final image is inverse on the x axis we can change the expression of x ratio to fix this problem
//		float ratio_x = (float)x / (float)(cam.resolution.x - 1);
//		float ratio_y = (float)y / (float)(cam.resolution.y - 1);
//
//		glm::vec3 dx = 2 * tan_fovx*ratio_x*m_cam_right;
//		glm::vec3 dy = 2 * tan_fovy*ratio_y*m_cam_up;
//
//		glm::vec3 cur_pos = m_down_left_pos  + dx + dy;
//
//		Ray m_cur_ray;
//		m_cur_ray.origin = cam.position;
//		m_cur_ray.direction = glm::normalize(cur_pos - cam.position);
//
//		m_rays[index] = m_cur_ray;
//
//
//		//for debug
//		image[index] += m_cur_ray.direction;
//
//
//	}
//}


__device__ float kern_IntersectionTest(Ray cur_ray, Geom* m_geoms, int num_of_geoms, cuda_OBJMesh_head* m_objmeshes, int num_of_objmeshes, glm::vec3 &m_intersectionPoint, glm::vec3 &m_normal, bool &m_outside, int &m_materialid) //currently using brute force algo
{
	float t = -1;
	//iterate over all the geom in the scene

	glm::vec3 cur_intersectionPoint;
	glm::vec3 cur_normal;
	bool cur_outside;
	float cur_t;
	float cur_index; //which geom intersect

	
	//check intersection with the geoms
	for (int i = 0; i<num_of_geoms; i++)
	{
		if (m_geoms[i].type == CUBE)
		{
			
			cur_t = boxIntersectionTest(m_geoms[i],cur_ray,cur_intersectionPoint,cur_normal,cur_outside);
		}
		else if (m_geoms[i].type == SPHERE)
		{
			cur_t = sphereIntersectionTest(m_geoms[i], cur_ray, cur_intersectionPoint, cur_normal, cur_outside);
		}

		if ((cur_t>0 && cur_t < t) || (cur_t>0 && t<0))
		{
			

			t = cur_t;

			m_intersectionPoint = cur_intersectionPoint;
			m_normal = cur_normal;
			m_outside = cur_outside;
			m_materialid =  m_geoms[i].materialid;

		}
	}

	//check the intersection with the objmeshes
	for (int i = 0; i<num_of_objmeshes; i++)
	{
		cur_t = OBJMeshIntersectionTest(m_objmeshes[i], cur_ray, cur_intersectionPoint, cur_normal, cur_outside);

		if ((cur_t>0 && cur_t < t) || (cur_t>0 && t<0))
		{


			t = cur_t;

			m_intersectionPoint = cur_intersectionPoint;
			m_normal = cur_normal;
			m_outside = cur_outside;
			m_materialid = m_objmeshes[i].m_box.materialid;

		}
	}


	return t;
	
}

__global__ void kern_calCurDepthColor(Ray *m_rays, Camera cam, bool* is_alive, glm::vec3 * cumulativeColor, Geom* m_geoms, Material* m_materials, cuda_OBJMesh_head* m_objmeshes, int num_of_geom, int num_of_objmeshes, int cur_depth, int cur_iter, int max_depth, glm::vec3 *image)
{
	if (cur_depth == max_depth)
	{
		return;
	}

	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x < cam.resolution.x && y < cam.resolution.y) {
		int index = x + (y * cam.resolution.x);

		if (!is_alive[index]) return;
				
		Ray cur_ray = m_rays[index];

		//find intersection
		glm::vec3 m_intersectionPoint;
		glm::vec3 m_normal;
		bool m_outside;
		float m_t;
		int m_material_id; //which geom intersect

		bool is_total_internalReflection = false;

		m_t = kern_IntersectionTest(cur_ray, m_geoms, num_of_geom, m_objmeshes,num_of_objmeshes,m_intersectionPoint, m_normal, m_outside, m_material_id);

		if (m_t == -1) //no intersection
		{
			//image[index] += glm::vec3(0.98f, 0.98f, 0.98f);
			is_alive[index] == false;
			return;
		}
		else  //update the new Ray & update current cumulative color
		{
			int m_mat_id = m_material_id;
			if (m_materials[m_mat_id].emittance != 0) // light
			{
				
				////debug
				//glm::vec3 visualize_normal;
				//visualize_normal.x = glm::abs(m_normal.x);
				//visualize_normal.y = glm::abs(m_normal.y);
				//visualize_normal.z = glm::abs(m_normal.z);
				//visualize_normal = glm::normalize(visualize_normal);
				//image[index] += visualize_normal;
				image[index] += m_materials[m_mat_id].emittance * m_materials[m_mat_id].color * cumulativeColor[index];
				is_alive[index] = false;
				return;
			}
			else if (m_materials[m_mat_id].hasReflective)  //reflect material 
			{
				
				//update cultimativeColor
				cumulativeColor[index] *= m_materials[m_mat_id].specular.color;



				glm::vec3 tmp_color;
				thrust::default_random_engine m_rng = makeSeededRandomEngine(cur_iter, index, cur_depth);
				scatterRay(cur_ray, tmp_color, m_intersectionPoint, m_normal, m_materials[m_mat_id], m_outside, is_total_internalReflection, m_rng);
				//udpate ray dir in the scatterRay
				//update the ray
				cur_ray.origin = m_intersectionPoint;
				m_rays[index] = cur_ray;

				return;
			}
			else if (m_materials[m_mat_id].hasRefractive)  //refract material
			{
				//update cultimativeColor
				cumulativeColor[index] *= m_materials[m_mat_id].color;



				glm::vec3 tmp_color;
				thrust::default_random_engine m_rng = makeSeededRandomEngine(cur_iter, index, cur_depth);
				scatterRay(cur_ray, tmp_color, m_intersectionPoint, m_normal, m_materials[m_mat_id], m_outside, is_total_internalReflection, m_rng);
				//udpate ray dir in the scatterRay
				//update the ray
				if (is_total_internalReflection)
				{
					cur_ray.origin = m_intersectionPoint;
				}
				else
				{
					cur_ray.origin = m_intersectionPoint - m_normal * 0.001f ; //go to the other side of the object
				}
				
				m_rays[index] = cur_ray;

				return;
			}
			else //diffuse material
			{
				//update cultimativeColor
				cumulativeColor[index] *= m_materials[m_mat_id].color;
				
				

				glm::vec3 tmp_color;
				thrust::default_random_engine m_rng = makeSeededRandomEngine(cur_iter, index, cur_depth);
				scatterRay(cur_ray, tmp_color, m_intersectionPoint, m_normal, m_materials[m_mat_id], m_outside, is_total_internalReflection, m_rng);
				//udpate ray dir in the scatterRay
				//update the ray
				cur_ray.origin = m_intersectionPoint;
				m_rays[index] = cur_ray;

				return;
			}
		}
	}

}

// ===== vairiable =====

static Scene *hst_scene = NULL;
static glm::vec3 *dev_image = NULL;
// TODO: static variables for device memory, scene/camera info, etc
// ...
glm::vec3 m_cam_right;
glm::vec3 m_cam_up;
glm::vec3 center_pos;
glm::vec3 upper_left_pos;
glm::vec3 down_left_pos;

bool is_ray_init;

int cur_depth;
int num_of_geoms;
int num_of_objmeshes;

static thrust::device_vector<Ray> dev_ray_vec;

static thrust::device_vector<bool> dev_is_alive_vec;

static thrust::device_vector<glm::vec3> dev_cumulativeColor;

static thrust::device_vector<Geom> dev_geoms;

static thrust::device_vector<Material> dev_materials;

static thrust::device_vector<cuda_OBJMesh_head> dev_objmeshes;

static cuda_OBJMesh_head* dev_obj_ptr = NULL;

//===== pathtracer fucntion =====


void copyOBJMeshData(Scene *hst_scene)
{
	
	cout << "start Copy Mesh data... " << endl;
	cudaMalloc((&dev_obj_ptr), num_of_objmeshes*sizeof(cuda_OBJMesh_head));
	
	cuda_OBJMesh* hst_obj_ptr = hst_scene->cuda_objmeshes.data();
	
	//cout << "start Copy Mesh data One by One... " << endl;
	//copy data one by one
	for (int i = 0; i<num_of_objmeshes; i++)
	{
		cout << i << endl;
		int cur_num_v = hst_obj_ptr[i].m_vertices.size();
		int cur_num_tri = hst_obj_ptr[i].m_triangle_list.size()/3;
		
		cout << cur_num_v << endl;
		cout << cur_num_tri << endl;


		//cout << "start Memset... " << endl;
		cudaMemcpy(&dev_obj_ptr[i].num_of_v, &cur_num_v, sizeof(int), cudaMemcpyHostToDevice);
		cudaMemcpy(&dev_obj_ptr[i].num_of_tri, &cur_num_tri, sizeof(int), cudaMemcpyHostToDevice);
		
		//cout << "start Memcpy... " << endl;
		cudaMemcpy(&dev_obj_ptr[i].m_box, &hst_obj_ptr[i].m_box, sizeof(Geom),cudaMemcpyHostToDevice);
		cout << "check 1... " << endl;
		
		glm::vec3* tmp_add1;
		cudaMalloc((&tmp_add1), cur_num_v*sizeof(glm::vec3));
		cudaMemcpy(tmp_add1, &hst_obj_ptr[i].m_vertices[0], cur_num_v*sizeof(glm::vec3), cudaMemcpyHostToDevice);
		cudaMemcpy(&dev_obj_ptr[i].m_v, &tmp_add1, sizeof(glm::vec3*), cudaMemcpyHostToDevice);
		
		
		//cudaMalloc(&dev_obj_ptr[i].m_v, cur_num_v*sizeof(glm::vec3));
		//cudaMemcpy(dev_obj_ptr[i].m_v, &hst_obj_ptr[i].m_vertices[0], cur_num_v*sizeof(glm::vec3), cudaMemcpyHostToDevice);
		
		
		
		cout << "check 2... " << endl;
		
		glm::vec3* tmp_add2;
		cudaMalloc((&tmp_add2), cur_num_tri*sizeof(glm::vec3));
		cudaMemcpy(tmp_add2, &hst_obj_ptr[i].m_per_tri_normals[0], cur_num_tri*sizeof(glm::vec3), cudaMemcpyHostToDevice);
		cudaMemcpy(&dev_obj_ptr[i].m_n, &tmp_add2, sizeof(glm::vec3*), cudaMemcpyHostToDevice);
		
		//cout << "check 3... " << endl;
		
		unsigned int* tmp_add3;
		cudaMalloc((&tmp_add3), 3*cur_num_tri*sizeof(unsigned int));
		cudaMemcpy(tmp_add3, &hst_obj_ptr[i].m_triangle_list[0], 3*cur_num_tri*sizeof(unsigned int), cudaMemcpyHostToDevice);
		cudaMemcpy(&dev_obj_ptr[i].m_tri_list, &tmp_add3, sizeof(unsigned int*), cudaMemcpyHostToDevice);

		//cout << "check 4... " << endl;
		
		
		glm::vec3* aa;
		cudaMemcpy(&aa, &dev_obj_ptr[i].m_v, sizeof(glm::vec3*), cudaMemcpyDeviceToHost);
		cout << aa << endl;

		cout << tmp_add1 << endl;

		glm::vec3 bb;
		cudaMemcpy(&bb, &tmp_add1[1], sizeof(glm::vec3), cudaMemcpyDeviceToHost);
		cout << bb.x << bb.y << bb.z << endl;



		/*unsigned int aa;
		cudaMemcpy(&aa, dev_obj_ptr[i].m_tri_list, sizeof(unsigned int), cudaMemcpyDeviceToHost);
		cout << aa << endl;*/
		
		
		checkCUDAError("copyOBJdata");
		
	}

	cout << "finish Copy Mesh data... " << endl;
}


void pathtraceInit(Scene *scene) {
    hst_scene = scene;
    const Camera &cam = hst_scene->state.camera;
    const int pixelcount = cam.resolution.x * cam.resolution.y;

    cudaMalloc(&dev_image, pixelcount * sizeof(glm::vec3));
    cudaMemset(dev_image, 0, pixelcount * sizeof(glm::vec3));
    // TODO: initialize the above static variables added above

	
	// intialize the dev_vector
	dev_ray_vec.resize(pixelcount); //initially there are pixelcount rays
	dev_is_alive_vec.resize(pixelcount);
	dev_cumulativeColor.resize(pixelcount);
	dev_materials.resize(pixelcount);

	dev_geoms = hst_scene->geoms;

	//dev_objmeshes = hst_scene->cuda_objmeshes;

	
	
	num_of_objmeshes = hst_scene->cuda_objmeshes.size();
	copyOBJMeshData(hst_scene);
	
	num_of_geoms = hst_scene->geoms.size();

	

	dev_materials = hst_scene->materials;


	//calculate the pos of the center pixel and the upper left pixel
	center_pos = cam.position + cam.view;

	//std::cout << cam.position.x << " " << cam.position.y << " " << cam.position.z << " " << std::endl;
	m_cam_right = glm::cross(cam.view,cam.up); 
	m_cam_right = glm::normalize(m_cam_right);
	m_cam_up = glm::cross(m_cam_right, cam.view);
	m_cam_up = glm::normalize(m_cam_up);

	upper_left_pos = center_pos + glm::tan(cam.fov.y* (PI / 180))*m_cam_up - glm::tan(cam.fov.x* (PI / 180))*m_cam_right;
	down_left_pos =  center_pos - glm::tan(cam.fov.y* (PI / 180))*m_cam_up - glm::tan(cam.fov.x* (PI / 180))*m_cam_right;
	
	



    checkCUDAError("pathtraceInit");

	cout << "pathtraceInit Succeed... " << endl;
}

void pathtraceFree() {
	cudaFree(dev_image);  // no-op if dev_image is null
    // TODO: clean up the above static variables

	dev_ray_vec.clear();
	dev_is_alive_vec.clear();
	dev_cumulativeColor.clear();
	dev_geoms.clear();
	dev_materials.clear();
	dev_objmeshes.clear();

	cout << "pathtraceFree Succeed... " << endl;

    checkCUDAError("pathtraceFree");
}

void reset()
{
	is_ray_init = false;
	cur_depth = 0;
	thrust::fill(dev_is_alive_vec.begin(), dev_is_alive_vec.end(), true);
	thrust::fill(dev_cumulativeColor.begin(), dev_cumulativeColor.end(), glm::vec3(1.f));

}


/**
 * Wrapper for the __global__ call that sets up the kernel calls and does a ton
 * of memory management
 */
void pathtrace(uchar4 *pbo, int frame, int iter) {
    const int traceDepth = hst_scene->state.traceDepth;
    const Camera &cam = hst_scene->state.camera;
    const int pixelcount = cam.resolution.x * cam.resolution.y;

    const int blockSideLength = 8;
    const dim3 blockSize(blockSideLength, blockSideLength);
    const dim3 blocksPerGrid(
            (cam.resolution.x + blockSize.x - 1) / blockSize.x,
            (cam.resolution.y + blockSize.y - 1) / blockSize.y);

	//reset before compute the color
	reset();


    ///////////////////////////////////////////////////////////////////////////

    // Recap:
    // * Initialize array of path rays (using rays that come out of the camera)
    //   * You can pass the Camera object to that kernel.
    //   * Each path ray is a (ray, color) pair, where color starts as the
    //     multiplicative identity, white = (1, 1, 1).
    //   * For debugging, you can output your ray directions as colors.
    // * For each depth:
    //   * Compute one new (ray, color) pair along each path (using scatterRay).
    //     Note that many rays will terminate by hitting a light or hitting
    //     nothing at all. You'll have to decide how to represent your path rays
    //     and how you'll mark terminated rays.
    //     * Color is attenuated (multiplied) by reflections off of any object
    //       surface.
    //     * You can debug your ray-scene intersections by displaying various
    //       values as colors, e.g., the first surface normal, the first bounced
    //       ray direction, the first unlit material color, etc.
    //   * Add all of the terminated rays' results into the appropriate pixels.
    //   * Stream compact away all of the terminated paths.
    //     You may use either your implementation or `thrust::remove_if` or its
    //     cousins.
    // * Finally, handle all of the paths that still haven't terminated.
    //   (Easy way is to make them black or background-colored.)

    // TODO: perform one iteration of path tracing

    //generateNoiseDeleteMe<<<blocksPerGrid, blockSize>>>(cam, iter, dev_image);
	
	

	Ray* ray_vec_ptr = thrust::raw_pointer_cast(dev_ray_vec.data());

	//init the rays
	if (!is_ray_init)
	{
		
		float tan_fov_x = glm::tan(cam.fov.x* (PI / 180));
		float tan_fov_y = glm::tan(cam.fov.y* (PI / 180));
		kern_generateInitRays << <blocksPerGrid, blockSize >> >(ray_vec_ptr, cam, upper_left_pos, m_cam_right, m_cam_up, dev_image, tan_fov_x, tan_fov_y);

		is_ray_init = true;
	}

	bool* is_alive_ptr = thrust::raw_pointer_cast(dev_is_alive_vec.data());
	glm::vec3* cumulativeColor_ptr = thrust::raw_pointer_cast(dev_cumulativeColor.data());
	Geom* geoms_ptr = thrust::raw_pointer_cast(dev_geoms.data());
	Material* materials_ptr = thrust::raw_pointer_cast(dev_materials.data());
	

	//interatively calculate color of each pixel 
	for (int i = 0; i < traceDepth; i++)
	{
		kern_calCurDepthColor << <blocksPerGrid, blockSize >> >(ray_vec_ptr, cam, is_alive_ptr, cumulativeColor_ptr, geoms_ptr, materials_ptr, dev_obj_ptr, num_of_geoms, num_of_objmeshes, i, iter, traceDepth, dev_image);
	}




    ///////////////////////////////////////////////////////////////////////////

    // Send results to OpenGL buffer for rendering
    sendImageToPBO<<<blocksPerGrid, blockSize>>>(pbo, cam.resolution, iter, dev_image);

    // Retrieve image from GPU
    cudaMemcpy(hst_scene->state.image.data(), dev_image,
            pixelcount * sizeof(glm::vec3), cudaMemcpyDeviceToHost);

    checkCUDAError("pathtrace");
}
