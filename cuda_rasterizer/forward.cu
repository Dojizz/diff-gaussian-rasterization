/*
 * Copyright (C) 2023, Inria
 * GRAPHDECO research group, https://team.inria.fr/graphdeco
 * All rights reserved.
 *
 * This software is free for non-commercial, research and evaluation use 
 * under the terms of the LICENSE.md file.
 *
 * For inquiries contact  george.drettakis@inria.fr
 */

#include "forward.h"
#include "auxiliary.h"
#include <cooperative_groups.h>
#include <cooperative_groups/reduce.h>
namespace cg = cooperative_groups;

// Light
__device__ glm::vec3 computeColorFromLight(int idx, const glm::vec3* means, Parameters::Light light_info,const float min_depth, const float max_depth) {
	glm::vec3 pos = means[idx];
	glm::vec3 lightpos = glm::vec3(light_info.position[0], light_info.position[1], light_info.position[2]);
	//glm::vec3 lightpos = glm::vec3(0.f, 0.f, 0.f);
	glm::vec3 dir = lightpos - pos;
	float minn = min(min_depth, max_depth);
	float maxx = max(min_depth, max_depth);
	float distance = glm::length(dir);
	if (distance < minn || distance > maxx)
		return glm::vec3(0.f);
	return glm::vec3(1.0f);
}

// Forward version of 2D covariance matrix computation
__device__ float3 computeCov2D(const float3& mean, float focal_x, float focal_y, float tan_fovx, float tan_fovy, const float* cov3D, const float* viewmatrix)
{
	// The following models the steps outlined by equations 29
	// and 31 in "EWA Splatting" (Zwicker et al., 2002). 
	// Additionally considers aspect / scaling of viewport.
	// Transposes used to account for row-/column-major conventions.
	float3 t = transformPoint4x3(mean, viewmatrix);

	const float limx = 1.3f * tan_fovx;
	const float limy = 1.3f * tan_fovy;
	const float txtz = t.x / t.z;
	const float tytz = t.y / t.z;
	t.x = min(limx, max(-limx, txtz)) * t.z;
	t.y = min(limy, max(-limy, tytz)) * t.z;

	glm::mat3 J = glm::mat3(
		focal_x / t.z, 0.0f, -(focal_x * t.x) / (t.z * t.z),
		0.0f, focal_y / t.z, -(focal_y * t.y) / (t.z * t.z),
		0, 0, 0);

	glm::mat3 W = glm::mat3(
		viewmatrix[0], viewmatrix[4], viewmatrix[8],
		viewmatrix[1], viewmatrix[5], viewmatrix[9],
		viewmatrix[2], viewmatrix[6], viewmatrix[10]);

	glm::mat3 T = W * J;

	glm::mat3 Vrk = glm::mat3(
		cov3D[0], cov3D[1], cov3D[2],
		cov3D[1], cov3D[3], cov3D[4],
		cov3D[2], cov3D[4], cov3D[5]);

	glm::mat3 cov = glm::transpose(T) * glm::transpose(Vrk) * T;

	// Apply low-pass filter: every Gaussian should be at least
	// one pixel wide/high. Discard 3rd row and column.
	cov[0][0] += 0.3f;
	cov[1][1] += 0.3f;
	return { float(cov[0][0]), float(cov[0][1]), float(cov[1][1]) };
}

// Forward method for converting scale and rotation properties of each
// Gaussian to a 3D covariance matrix in world space. Also takes care
// of quaternion normalization.
__device__ void computeCov3D(const glm::vec3 scale, float mod, const glm::vec4 rot, float* cov3D)
{
	// Create scaling matrix
	glm::mat3 S = glm::mat3(1.0f);
	S[0][0] = mod * scale.x;
	S[1][1] = mod * scale.y;
	S[2][2] = mod * scale.z;

	// Normalize quaternion to get valid rotation
	glm::vec4 q = rot;// / glm::length(rot);
	float r = q.x;
	float x = q.y;
	float y = q.z;
	float z = q.w;

	// Compute rotation matrix from quaternion
	glm::mat3 R = glm::mat3(
		1.f - 2.f * (y * y + z * z), 2.f * (x * y - r * z), 2.f * (x * z + r * y),
		2.f * (x * y + r * z), 1.f - 2.f * (x * x + z * z), 2.f * (y * z - r * x),
		2.f * (x * z - r * y), 2.f * (y * z + r * x), 1.f - 2.f * (x * x + y * y)
	);

	glm::mat3 M = S * R;

	// Compute 3D world covariance matrix Sigma
	glm::mat3 Sigma = glm::transpose(M) * M;

	// Covariance is symmetric, only store upper right
	cov3D[0] = Sigma[0][0];
	cov3D[1] = Sigma[0][1];
	cov3D[2] = Sigma[0][2];
	cov3D[3] = Sigma[1][1];
	cov3D[4] = Sigma[1][2];
	cov3D[5] = Sigma[2][2];
}

// Forward method for converting the input spherical harmonics
// coefficients of each Gaussian to a simple RGB color.
__device__ glm::vec3 computeColorFromSH(int idx, int deg, int max_coeffs, const glm::vec3* means, glm::vec3 campos, const float* shs, bool* clamped)
{
	// The implementation is loosely based on code for 
	// "Differentiable Point-Based Radiance Fields for 
	// Efficient View Synthesis" by Zhang et al. (2022)
	glm::vec3 pos = means[idx];
	glm::vec3 dir = pos - campos;
	dir = dir / glm::length(dir);

	glm::vec3* sh = ((glm::vec3*)shs) + idx * max_coeffs;
	glm::vec3 result = SH_C0 * sh[0];

	if (deg > 0)
	{
		float x = dir.x;
		float y = dir.y;
		float z = dir.z;
		result = result - SH_C1 * y * sh[1] + SH_C1 * z * sh[2] - SH_C1 * x * sh[3];

		if (deg > 1)
		{
			float xx = x * x, yy = y * y, zz = z * z;
			float xy = x * y, yz = y * z, xz = x * z;
			result = result +
				SH_C2[0] * xy * sh[4] +
				SH_C2[1] * yz * sh[5] +
				SH_C2[2] * (2.0f * zz - xx - yy) * sh[6] +
				SH_C2[3] * xz * sh[7] +
				SH_C2[4] * (xx - yy) * sh[8];

			if (deg > 2)
			{
				result = result +
					SH_C3[0] * y * (3.0f * xx - yy) * sh[9] +
					SH_C3[1] * xy * z * sh[10] +
					SH_C3[2] * y * (4.0f * zz - xx - yy) * sh[11] +
					SH_C3[3] * z * (2.0f * zz - 3.0f * xx - 3.0f * yy) * sh[12] +
					SH_C3[4] * x * (4.0f * zz - xx - yy) * sh[13] +
					SH_C3[5] * z * (xx - yy) * sh[14] +
					SH_C3[6] * x * (xx - 3.0f * yy) * sh[15];
			}
		}
	}
	result += 0.5f;

	// RGB colors are clamped to positive values. If values are
	// clamped, we need to keep track of this for the backward pass.
	clamped[3 * idx + 0] = (result.x < 0);
	clamped[3 * idx + 1] = (result.y < 0);
	clamped[3 * idx + 2] = (result.z < 0);
	return glm::max(result, 0.0f);
}

// depth is not simply p_view.z, the depth should refer to the distance
// to the camera pos
__device__ glm::vec3 computeColorFromDepth(int idx, const glm::vec3* means, glm::vec3 campos, const float min_depth, const float max_depth) {
	glm::vec3 pos = means[idx];
	glm::vec3 dir = campos - pos;
	float minn = min(min_depth, max_depth);
	float maxx = max(min_depth, max_depth);
	float distance = glm::length(dir);
	if (distance < minn || distance > maxx)
		return glm::vec3(0.f);
	float norm_d = 1. - (distance - minn) / (maxx - minn);
	return glm::vec3(norm_d);
	//return glm::vec3(distance);
}

__device__ glm::mat3 quatToMat3(const glm::vec4 rotation) {
	float qx = rotation.y;
	float qy = rotation.z;
	float qz = rotation.w;
	float qw = rotation.x;
	float qxx = qx * qx;
	float qyy = qy * qy;
	float qzz = qz * qz;
	float qxz = qx * qz;
	float qxy = qx * qy;
	float qyw = qy * qw;
	float qzw = qz * qw;
	float qyz = qy * qz;
	float qxw = qx * qw;

	return glm::mat3(1.0 - 2.0 * (qyy + qzz), 2.0 * (qxy - qzw), 2.0 * (qxz + qyw),
				     2.0 * (qxy + qzw), 1.0 - 2.0 * (qxx + qzz), 2.0 * (qyz - qxw), 
				     2.0 * (qxz - qyw), 2.0 * (qyz + qxw), 1.0 - 2.0 * (qxx + qyy));
}

// approximate method, derive normal from the ellipsoids
// based on the calculation in gaussian_surface.frag
__device__ glm::vec3 computeColorFromNormal(int idx, const glm::vec3* means, glm::vec3 campos, const glm::vec3 scale, const glm::vec4 rotation) {
	glm::vec3 center = means[idx];
	glm::mat3 ellip_rot = quatToMat3(rotation);
	glm::vec3 ray_dir = center - campos;
	glm::vec3 local_ray_origin = (campos - center) * ellip_rot;
	glm::vec3 local_ray_dir = glm::normalize(ray_dir * ellip_rot);
	glm::vec3 oneover = glm::vec3(1. / scale.x, 1. / scale.y, 1. / scale.z);
	double a = glm::dot(local_ray_dir * oneover, local_ray_dir * oneover);
	double b = 2.f * glm::dot(local_ray_dir * oneover, local_ray_origin * oneover);
	double c = glm::dot(local_ray_origin * oneover, local_ray_origin * oneover) - 1.f;
	double discriminant = b * b - 4.0 * a * c;
	if (discriminant < 0.0) return glm::vec3(0.f);
	float t1 = float((-b - sqrt(discriminant)) / (2.0 * a));
	float t2 = float((-b + sqrt(discriminant)) / (2.0 * a));
	float t = min(t1, t2);
	glm::vec3 local_sect = glm::vec3(local_ray_origin + t * local_ray_dir);
	glm::vec3 n = glm::normalize(local_sect / scale);
	n = glm::normalize(ellip_rot * n);

	return n;
}

// choose the most flat direction as normal, 
__device__ glm::vec3 computeColorFromNormal2(int idx, const glm::vec3* means, const glm::vec3 scale, const glm::vec4 rotation, glm::vec3 campos) {
	int dir_idx = 0;
	if (scale[dir_idx] < scale[1])
		dir_idx = 1;
	if (scale[dir_idx] < scale[2])
		dir_idx = 2;
	glm::vec3 dir(0.f);
	dir[dir_idx] = 1.f;
	// rotate by rotation
	glm::mat3 rot_m = quatToMat3(rotation);
	return glm::normalize(rot_m * dir);
}

// choose the intersection point normal as normal
// the ball is initially a sphere at origin, radius is 1.
__device__ glm::vec3 computeColorFromNormal3(const glm::vec3 center, const glm::vec3 scale, const glm::vec4 rotation,
	const glm::vec3 campos, const glm::vec3 dir) {

	glm::mat3 ellip_rot = glm::transpose(quatToMat3(rotation));
	glm::vec3 local_ray_origin = (campos - center) * ellip_rot;
	glm::vec3 local_ray_dir = glm::normalize(dir * ellip_rot);
	glm::vec3 oneover = glm::vec3(1. / scale.x, 1. / scale.y, 1. / scale.z);
	double a = glm::dot(local_ray_dir * oneover, local_ray_dir * oneover);
	double b = 2.f * glm::dot(local_ray_dir * oneover, local_ray_origin * oneover);
	double c = glm::dot(local_ray_origin * oneover, local_ray_origin * oneover) - 1.f;
	double discriminant = b * b - 4.0 * a * c;

	if (discriminant < 0.0) return glm::vec3(0.f);

	float t1 = float((-b - sqrt(discriminant)) / (2.0 * a));
	float t2 = float((-b + sqrt(discriminant)) / (2.0 * a));
	float t = min(t1, t2);
	glm::vec3 local_sect = glm::vec3(local_ray_origin + t * local_ray_dir);
	glm::vec3 n = glm::normalize(local_sect / scale);
	return glm::normalize(ellip_rot * n);
}

__device__ glm::mat3 computeCov3D(const glm::vec3 scale, const glm::vec4 rotation)
{
	auto R_t = quatToMat3(rotation);
	glm::mat3 S = glm::mat3(1.f);
	S[0][0] = scale.x;
	S[1][1] = scale.y;
	S[2][2] = scale.z;
	return glm::transpose(R_t) * S * S * R_t;
}

__device__ float clamp(float value, float minn, float maxx) {
	if (value < minn)
		return minn;
	if (value > maxx)
		return maxx;
	return value;
}

__device__ glm::mat3 computCov3DInv(const glm::vec3 scale, const glm::vec4 rotation)
{
	auto R_t = quatToMat3(rotation);
	glm::mat3 S_i = glm::mat3(1.f);
	/*S_i[0][0] = clamp(1. / scale.x, 1e-3, 1e3);
	S_i[1][1] = clamp(1. / scale.y, 1e-3, 1e3);
	S_i[2][2] = clamp(1. / scale.z, 1e-3, 1e3);*/
	S_i[0][0] = 1. / (scale.x + 1e-5);
	S_i[1][1] = 1. / (scale.y + 1e-5);
	S_i[2][2] = 1. / (scale.z + 1e-5);
	return glm::transpose(R_t) * S_i * S_i * R_t;
}

// this function return the true gradient, without normalization
__device__ glm::vec3 computeGrad(const glm::mat3 cov_inv, const glm::vec3 center, const glm::vec3 pos, const glm::vec3 dir)
{
	glm::vec3 grad = cov_inv * (pos - center);
	//float gaussian_value = exp(-0.5 * glm::dot(pos - center, cov_inv * (pos - center)));
	//grad = grad * gaussian_value;
	//grad = glm::normalize(grad);
	return grad;
}

// compute gradient at the gaussion max value point, 
// method from Fuzzy Metaballs by Leonid et al., 2022
__device__ glm::vec3 computeColorFromNormal4(const glm::vec3 center, const glm::vec3 scale, const glm::vec4 rotation,
	const glm::vec3 campos, const glm::vec3 dir) {
	glm::vec3 mu = center - campos;	
	glm::mat3 cov_inv = computCov3DInv(scale, rotation);
	float max_t = glm::dot(mu * cov_inv, dir) / glm::dot(dir * cov_inv, dir);
	glm::vec3 pos = campos + dir * max_t;

	// grad direction point towards camera
	glm::vec3 grad = computeGrad(cov_inv, center, pos, dir);
	grad = glm::normalize(grad);
	return grad;
}

__device__ glm::vec3 computeColorFromNormal5(const glm::vec3 center, const glm::vec3 scale, const glm::vec4 rotation,
	const glm::vec3 campos, const glm::vec3 dir, const float depth) {
	glm::mat3 cov_inv = computCov3DInv(scale, rotation);
	glm::vec3 pos = campos + dir * depth;
	// the gradiant should not be normalized
	return computeGrad(cov_inv, center, pos, dir);
}

__device__ float computeColorFromDepth2(const glm::vec3 center, const glm::vec3 scale, const glm::vec4 rotation,
	const glm::vec3 campos, const glm::vec3 dir) {
	glm::vec3 mu = center - campos;
	glm::mat3 cov_inv = computCov3DInv(scale, rotation);
	float max_t = glm::dot(mu * cov_inv, dir) / glm::dot(dir * cov_inv, dir);
	return glm::length(dir) * max_t;
}

__device__ float computeAccurateT(const glm::vec3 center, const glm::vec3 scale, const glm::vec4 rotation,
	const glm::vec3 campos, const glm::vec3 dir, const float alpha) {
	glm::vec3 mu = center - campos;
	glm::mat3 cov_inv = computCov3DInv(scale, rotation);
	float max_t = glm::dot(mu * cov_inv, dir) / glm::dot(dir * cov_inv, dir);
	// compute A, B, C
	float A = -0.5 * glm::dot(dir * cov_inv, dir);
	float B = -1 * glm::dot(dir * cov_inv, -mu);
	float C = -0.5 * glm::dot(-mu * cov_inv, -mu);
	if (A > 0)
		return 0;

	float int_value = -1 * alpha * exp(C - B * B / (4 * A)) * sqrt(3.1415926535) *
		(-1 + erf((B + 2 * A * max_t) / (2 * sqrt(-A)))) / (2 * sqrt(-A));
	return exp(-int_value);
}

__device__ float computeAccurateInt(const glm::vec3 center, const glm::vec3 scale, const glm::vec4 rotation,
	const glm::vec3 campos, const glm::vec3 dir) {
	glm::vec3 mu = center - campos;
	glm::mat3 cov_inv = computCov3DInv(scale, rotation);
	// compute A, B, C
	float A = -0.5 * glm::dot(dir * cov_inv, dir); // A < 0
	float B = -1 * glm::dot(dir * cov_inv, -mu);   // B > 0
	float C = -0.5 * glm::dot(-mu * cov_inv, -mu); // C < 0
	if (A > 0)
		return 0;
	// numerical instability is such a nightmare

	return -1 * B * exp(C - B * B / (4 * A)) * sqrt(3.1415926535) / (2 * sqrt(-A) * A);
}

// use camera parameter & thread location to compute ray direction
// this function need test, as I'm not sure the coordinate corresponds to my understanding
__device__ glm::vec3 computeDirFromPixel(const glm::vec3 campos, float tan_fovx, float tan_fovy, const float* viewmatrix,
	float pix_x, float pix_y, int W, int H)
{
	float pix_x_ndc = pix2Ndc(pix_x, W), pix_y_ndc = pix2Ndc(pix_y, H);
	float view_x = pix_x_ndc * tan_fovx, view_y = pix_y_ndc * tan_fovy;
	glm::vec3 dir_view(view_x, view_y, 1.f);
	//return glm::normalize(dir_view);
	// only need rotation matrix
	glm::mat3 view_rot = glm::mat3(
		viewmatrix[0], viewmatrix[1], viewmatrix[2],
		viewmatrix[4], viewmatrix[5], viewmatrix[6],
		viewmatrix[8], viewmatrix[9], viewmatrix[10]
	);
	glm::vec3 dir_world = glm::transpose(view_rot) * dir_view;
	return glm::normalize(dir_world);
}

// Perform initial steps for each Gaussian prior to rasterization.
template<int C>
__global__ void preprocessCUDA(
	CudaRasterizer::CudaDebInfo* deb_info,
	Parameters::Light light_info,
	int P, int D, int M,
	const float* orig_points,
	const glm::vec3* scales,
	const float scale_modifier,
	const glm::vec4* rotations,
	const float* opacities,
	const float* shs,
	bool* clamped,
	const float* cov3D_precomp,
	const float* colors_precomp,
	const float* viewmatrix,
	const float* projmatrix,
	const glm::vec3* cam_pos,
	const int W, int H,
	const float tan_fovx, float tan_fovy,
	const float focal_x, float focal_y,
	int* radii,
	float2* points_xy_image,
	float* depths,
	float* cov3Ds,
	float* rgb,
	float4* conic_opacity,
	const dim3 grid,
	uint32_t* tiles_touched,
	bool prefiltered,
	int2* rects,
	float3 boxmin,
	float3 boxmax)
{
	auto idx = cg::this_grid().thread_rank();
	if (idx >= P)
		return;

	// Initialize radius and touched tiles to 0. If this isn't changed,
	// this Gaussian will not be processed further.
	radii[idx] = 0;
	tiles_touched[idx] = 0;

	// Perform near culling, quit if outside.
	float3 p_view;
	if (!in_frustum(idx, orig_points, viewmatrix, projmatrix, prefiltered, p_view))
		return;

	// Transform point by projecting
	float3 p_orig = { orig_points[3 * idx], orig_points[3 * idx + 1], orig_points[3 * idx + 2] };

	if (p_orig.x < boxmin.x || p_orig.y < boxmin.y || p_orig.z < boxmin.z ||
		p_orig.x > boxmax.x || p_orig.y > boxmax.y || p_orig.z > boxmax.z)
		return;

	float4 p_hom = transformPoint4x4(p_orig, projmatrix);
	float p_w = 1.0f / (p_hom.w + 0.0000001f);
	float3 p_proj = { p_hom.x * p_w, p_hom.y * p_w, p_hom.z * p_w };

	// If 3D covariance matrix is precomputed, use it, otherwise compute
	// from scaling and rotation parameters. 
	const float* cov3D;
	if (cov3D_precomp != nullptr)
	{
		cov3D = cov3D_precomp + idx * 6;
	}
	else
	{
		// use debug scale info to get cov
		glm::vec3 scale = scales[idx] * glm::vec3(deb_info->scale_x, deb_info->scale_y, deb_info->scale_z);
		computeCov3D(scale, scale_modifier, rotations[idx], cov3Ds + idx * 6);
		cov3D = cov3Ds + idx * 6;
	}

	// Compute 2D screen-space covariance matrix
	float3 cov = computeCov2D(p_orig, focal_x, focal_y, tan_fovx, tan_fovy, cov3D, viewmatrix);

	// Invert covariance (EWA algorithm)
	float det = (cov.x * cov.z - cov.y * cov.y);
	if (det == 0.0f)
		return;
	float det_inv = 1.f / det;
	float3 conic = { cov.z * det_inv, -cov.y * det_inv, cov.x * det_inv };

	// Compute extent in screen space (by finding eigenvalues of
	// 2D covariance matrix). Use extent to compute a bounding rectangle
	// of screen-space tiles that this Gaussian overlaps with. Quit if
	// rectangle covers 0 tiles. 

	float mid = 0.5f * (cov.x + cov.z);
	float lambda1 = mid + sqrt(max(0.1f, mid * mid - det));
	float lambda2 = mid - sqrt(max(0.1f, mid * mid - det));
	float my_radius = ceil(3.f * sqrt(max(lambda1, lambda2)));
	float2 point_image = { ndc2Pix(p_proj.x, W), ndc2Pix(p_proj.y, H) };
	uint2 rect_min, rect_max;

	if (rects == nullptr) 	// More conservative
	{
		getRect(point_image, my_radius, rect_min, rect_max, grid);
	}
	else // Slightly more aggressive, might need a math cleanup
	{
		const int2 my_rect = { (int)ceil(3.f * sqrt(cov.x)), (int)ceil(3.f * sqrt(cov.z)) };
		rects[idx] = my_rect;
		getRect(point_image, my_rect, rect_min, rect_max, grid);
	}

	if ((rect_max.x - rect_min.x) * (rect_max.y - rect_min.y) == 0)
		return;

	// If colors have been precomputed, use them, otherwise convert
	// spherical harmonics coefficients to RGB color.
	if (colors_precomp == nullptr)
	{
		glm::vec3 result(0.f);
		// other render mode will be handled in renderCUDA
		if (deb_info->render_mode == 0)
			result = computeColorFromSH(idx, D, M, (glm::vec3*)orig_points, *cam_pos, shs, clamped);
		else if (deb_info->render_mode == 1)
			result = computeColorFromDepth(idx, (glm::vec3*)orig_points, *cam_pos, deb_info->min_depth, deb_info->max_depth);
		else if (deb_info->render_mode == 2)
			result = computeColorFromNormal2(idx, (glm::vec3*)orig_points, scales[idx], rotations[idx], *cam_pos);
		rgb[idx * C + 0] = result.x;
		rgb[idx * C + 1] = result.y;
		rgb[idx * C + 2] = result.z;
	}

	// Store some useful helper data for the next steps.
	depths[idx] = p_view.z;
	radii[idx] = my_radius;
	points_xy_image[idx] = point_image; // gaussian position in pixel screen
	// Inverse 2D covariance and opacity neatly pack into one float4
	conic_opacity[idx] = { conic.x, conic.y, conic.z, opacities[idx] * deb_info->opacity };
	tiles_touched[idx] = (rect_max.y - rect_min.y) * (rect_max.x - rect_min.x);
}

template<int C>
__global__ void lightpreprocessCUDA(
	CudaRasterizer::CudaDebInfo* deb_info,
	Parameters::Light light_info,
	int P, int D, int M,
	const float* orig_points,
	const glm::vec3* scales,
	const float scale_modifier,
	const glm::vec4* rotations,
	const float* opacities,
	const float* shs,
	bool* clamped,
	const float* cov3D_precomp,
	const float* colors_precomp,
	const float* viewmatrix,
	const float* projmatrix,
	const glm::vec3* cam_pos,
	const int W, int H,
	
	const float tan_fovx, float tan_fovy,
	const float focal_x, float focal_y,
	int* radii,
	float2* points_xy_image,
	float* depths,
	float* cov3Ds,
	float* rgb,
	float4* conic_opacity,
	const dim3 grid,
	uint32_t* tiles_touched,
	bool prefiltered,
	int2* rects,
	float3 boxmin,
	float3 boxmax)
{
	auto idx = cg::this_grid().thread_rank();
	if (idx >= P)
		return;

	// Initialize radius and touched tiles to 0. If this isn't changed,
	// this Gaussian will not be processed further.
	radii[idx] = 0;
	tiles_touched[idx] = 0;

	// Perform near culling, quit if outside.
	float3 p_view;
	if (!in_frustum(idx, orig_points, viewmatrix, projmatrix, prefiltered, p_view))
		return;

	// Transform point by projecting
	float3 p_orig = { orig_points[3 * idx], orig_points[3 * idx + 1], orig_points[3 * idx + 2] };

	if (p_orig.x < boxmin.x || p_orig.y < boxmin.y || p_orig.z < boxmin.z ||
		p_orig.x > boxmax.x || p_orig.y > boxmax.y || p_orig.z > boxmax.z)
		return;

	float4 p_hom = transformPoint4x4(p_orig, projmatrix);
	float p_w = 1.0f / (p_hom.w + 0.0000001f);
	float3 p_proj = { p_hom.x * p_w, p_hom.y * p_w, p_hom.z * p_w };

	// If 3D covariance matrix is precomputed, use it, otherwise compute
	// from scaling and rotation parameters. 
	const float* cov3D;
	if (cov3D_precomp != nullptr)
	{
		cov3D = cov3D_precomp + idx * 6;
	}
	else
	{
		computeCov3D(scales[idx], scale_modifier, rotations[idx], cov3Ds + idx * 6);
		cov3D = cov3Ds + idx * 6;
	}

	// Compute 2D screen-space covariance matrix
	float3 cov = computeCov2D(p_orig, focal_x, focal_y, tan_fovx, tan_fovy, cov3D, viewmatrix);

	// Invert covariance (EWA algorithm)
	float det = (cov.x * cov.z - cov.y * cov.y);
	if (det == 0.0f)
		return;
	float det_inv = 1.f / det;
	float3 conic = { cov.z * det_inv, -cov.y * det_inv, cov.x * det_inv };

	// Compute extent in screen space (by finding eigenvalues of
	// 2D covariance matrix). Use extent to compute a bounding rectangle
	// of screen-space tiles that this Gaussian overlaps with. Quit if
	// rectangle covers 0 tiles. 

	float mid = 0.5f * (cov.x + cov.z);
	float lambda1 = mid + sqrt(max(0.1f, mid * mid - det));
	float lambda2 = mid - sqrt(max(0.1f, mid * mid - det));
	float my_radius = ceil(3.f * sqrt(max(lambda1, lambda2)));
	float2 point_image = { ndc2Pix(p_proj.x, W), ndc2Pix(p_proj.y, H) };
	uint2 rect_min, rect_max;

	if (rects == nullptr) 	// More conservative
	{
		getRect(point_image, my_radius, rect_min, rect_max, grid);
	}
	else // Slightly more aggressive, might need a math cleanup
	{
		const int2 my_rect = { (int)ceil(3.f * sqrt(cov.x)), (int)ceil(3.f * sqrt(cov.z)) };
		rects[idx] = my_rect;
		getRect(point_image, my_rect, rect_min, rect_max, grid);
	}

	if ((rect_max.x - rect_min.x) * (rect_max.y - rect_min.y) == 0)
		return;

	// If colors have been precomputed, use them, otherwise convert
	// spherical harmonics coefficients to RGB color.
	if (colors_precomp == nullptr)
	{
		glm::vec3 result;
		if (deb_info->render_mode == 0)
			result = computeColorFromSH(idx, D, M, (glm::vec3*)orig_points, *cam_pos, shs, clamped);
		else if (deb_info->render_mode == 1)
			result = computeColorFromDepth(idx, (glm::vec3*)orig_points, *cam_pos, deb_info->min_depth, deb_info->max_depth);
		else if (deb_info->render_mode == 2)
			result = computeColorFromNormal2(idx, (glm::vec3*)orig_points, scales[idx], rotations[idx], *cam_pos);
		else if (deb_info->render_mode == 3)
			result = computeColorFromLight(idx, (glm::vec3*)orig_points, light_info, deb_info->min_depth, deb_info->max_depth);
		//result = computeColorFromNormal(idx, (glm::vec3*)orig_points, *cam_pos, scales[idx], rotations[idx]);
		rgb[idx * C + 0] = result.x;
		rgb[idx * C + 1] = result.y;
		rgb[idx * C + 2] = result.z;
	}

	// Store some useful helper data for the next steps.
	depths[idx] = p_view.z;
	radii[idx] = my_radius;
	points_xy_image[idx] = point_image; // gaussian position in pixel screen
	// Inverse 2D covariance and opacity neatly pack into one float4
	conic_opacity[idx] = { conic.x, conic.y, conic.z, opacities[idx] };
	tiles_touched[idx] = (rect_max.y - rect_min.y) * (rect_max.x - rect_min.x);
}

// Main rasterization method. Collaboratively works on one tile per
// block, each thread treats one pixel. Alternates between fetching 
// and rasterizing data.
template <uint32_t CHANNELS>
__global__ void __launch_bounds__(BLOCK_X* BLOCK_Y)
renderCUDA(
	CudaRasterizer::CudaDebInfo* deb_info,
	Parameters::Light light_info,
	const uint2* __restrict__ ranges,
	const uint32_t* __restrict__ point_list,
	int W, int H,
	const float2* __restrict__ points_xy_image,
	const float* __restrict__ features,
	const float4* __restrict__ conic_opacity,
	float* __restrict__ final_T,
	uint32_t* __restrict__ n_contrib,
	const float* __restrict__ bg_color,
	float* __restrict__ out_color,
	const float* means3D, // info that is used to compute normal per gaussian
	const glm::vec3* scales,
	const glm::vec4* rotations,
	const glm::vec3* cam_pos,
	const float* viewmatrix,
	const float tan_fovx, float tan_fovy)
{
	// Identify current tile and associated min/max pixel range.
	auto block = cg::this_thread_block();
	uint32_t horizontal_blocks = (W + BLOCK_X - 1) / BLOCK_X;
	uint2 pix_min = { block.group_index().x * BLOCK_X, block.group_index().y * BLOCK_Y };
	uint2 pix_max = { min(pix_min.x + BLOCK_X, W), min(pix_min.y + BLOCK_Y , H) };
	uint2 pix = { pix_min.x + block.thread_index().x, pix_min.y + block.thread_index().y };
	uint32_t pix_id = W * pix.y + pix.x;
	float2 pixf = { (float)pix.x, (float)pix.y };

	// Check if this thread is associated with a valid pixel or outside.
	bool inside = pix.x < W&& pix.y < H;
	// Done threads can help with fetching, but don't rasterize
	bool done = !inside;

	// Load start/end range of IDs to process in bit sorted list.
	// fetch the block's ranges
	uint2 range = ranges[block.group_index().y * horizontal_blocks + block.group_index().x]; 
	const int rounds = ((range.y - range.x + BLOCK_SIZE - 1) / BLOCK_SIZE);
	int toDo = range.y - range.x;

	// Allocate storage for batches of collectively fetched data.
	// __shared__ means share memory in the same thread block
	__shared__ int collected_id[BLOCK_SIZE];
	__shared__ float2 collected_xy[BLOCK_SIZE];
	__shared__ float4 collected_conic_opacity[BLOCK_SIZE];

	// Initialize helper variables
	float T = 1.0f;
	uint32_t contributor = 0;
	uint32_t last_contributor = 0;
	float C[CHANNELS] = { 0 };

	// Use new approximate method to get more accurate depth
	for (int i = 0; i < rounds; i++, toDo -= BLOCK_SIZE)
	{
		// End if entire block votes that it is done rasterizing, 
		// syncthreads counts how many dones in the same block 
		int num_done = __syncthreads_count(done);
		if (num_done == BLOCK_SIZE)
			break;

		// Collectively fetch per-Gaussian data from global to shared
		int progress = i * BLOCK_SIZE + block.thread_rank();
		if (range.x + progress < range.y)
		{
			int coll_id = point_list[range.x + progress];
			collected_id[block.thread_rank()] = coll_id;
			collected_xy[block.thread_rank()] = points_xy_image[coll_id];
			collected_conic_opacity[block.thread_rank()] = conic_opacity[coll_id];
		}
		block.sync();

		// Iterate over current batch
		for (int j = 0; !done && j < min(BLOCK_SIZE, toDo); j++)
		{
			// Keep track of current position in range
			contributor++;

			// Resample using conic matrix (cf. "Surface 
			// Splatting" by Zwicker et al., 2001)
			float2 xy = collected_xy[j];
			float2 d = { xy.x - pixf.x, xy.y - pixf.y };
			float4 con_o = collected_conic_opacity[j];
			float power = -0.5f * (con_o.x * d.x * d.x + con_o.z * d.y * d.y) - con_o.y * d.x * d.y;
			if (power > 0.0f)
				continue;

			// Eq. (2) from 3D Gaussian splatting paper.
			// Obtain alpha by multiplying with Gaussian opacity
			// and its exponential falloff from mean.
			// Avoid numerical instabilities (see paper appendix). 
			float alpha = min(0.99f, con_o.w * exp(power));
			if (alpha < 1.0f / 255.0f)
				continue;
			float test_T = T * (1 - alpha);
			if (test_T < 0.0001f)
			{
				done = true;
				continue;
			}
			unsigned int gaussian_id = collected_id[j];

			// compute accurate depth
			if (deb_info->render_mode == 3) {
				glm::vec3 ray_dir = computeDirFromPixel(*cam_pos, tan_fovx, tan_fovy, viewmatrix, pixf.x, pixf.y, W, H);
				glm::vec3 center(means3D[gaussian_id * 3], means3D[gaussian_id * 3 + 1], means3D[gaussian_id * 3 + 2]);
				glm::vec3 scale = scales[gaussian_id] * glm::vec3(deb_info->scale_x, deb_info->scale_y, deb_info->scale_z);
				float T_max = computeAccurateT(center, scale, rotations[gaussian_id],
					*cam_pos, ray_dir, con_o.w);
				float int_value = computeAccurateInt(center, scale, rotations[gaussian_id],
					*cam_pos, ray_dir);
				// depth contribution should be T * con_o.w * T_max * integral value
				float depth = T * con_o.w * T_max * int_value;
				for (int ch = 0; ch < CHANNELS; ch++)
					C[ch] += depth;
			}
			// TODO: compute accurate normal
			else if (deb_info->render_mode == 4) {
				for (int ch = 0; ch < CHANNELS; ch++)
					C[ch] += 1.f;
			}
			else {
				// Eq. (3) from 3D Gaussian splatting paper.
				for (int ch = 0; ch < CHANNELS; ch++)
					C[ch] += features[collected_id[j] * CHANNELS + ch] * alpha * T;
			}
			T = test_T;

			// Keep track of last range entry to update this
			// pixel.
			last_contributor = contributor;
		}
	}

	// All threads that treat valid pixel write out their final
	// rendering data to the frame and auxiliary buffers.
	if (inside)
	{
		final_T[pix_id] = T;
		n_contrib[pix_id] = last_contributor;

		for (int ch = 0; ch < CHANNELS; ch++)
			out_color[ch * H * W + pix_id] = C[ch] + T * bg_color[ch];
	}
}

void FORWARD::render(
	CudaRasterizer::CudaDebInfo* deb_info,
	Parameters::Light light_info,
	const dim3 grid, dim3 block,
	const uint2* ranges,
	const uint32_t* point_list,
	int W, int H,
	const float2* means2D,
	const float* colors,
	const float4* conic_opacity,
	float* final_T,
	uint32_t* n_contrib,
	const float* bg_color,
	float* out_color, 
	const float* means3D, // info that is used to compute normal per gaussian
	const glm::vec3* scales,
	const glm::vec4* rotations,
	const glm::vec3* cam_pos,
	const float* viewmatrix,
	const float tan_fovx, float tan_fovy
	)
{
	renderCUDA<NUM_CHANNELS> << <grid, block >> > (
		deb_info,
		light_info,
		ranges,
		point_list,
		W, H,
		means2D,
		colors,
		conic_opacity,
		final_T,
		n_contrib,
		bg_color,
		out_color,
		means3D,
		scales,
		rotations,
		cam_pos,
		viewmatrix,
		tan_fovx, tan_fovy);
}

void FORWARD::lightpreprocess(
	CudaRasterizer::CudaDebInfo* deb_info,
	Parameters::Light light_info,
	int P, int D, int M,
	const float* means3D,
	const glm::vec3* scales,
	const float scale_modifier,
	const glm::vec4* rotations,
	const float* opacities,
	const float* shs,
	bool* clamped,
	const float* cov3D_precomp,
	const float* colors_precomp,
	const float* viewmatrix,
	const float* projmatrix,
	const glm::vec3* cam_pos,
	const int W, int H,
	const float focal_x, float focal_y,
	const float tan_fovx, float tan_fovy,
	int* radii,
	float2* means2D,
	float* depths,
	float* cov3Ds,
	float* rgb,
	float4* conic_opacity,
	const dim3 grid,
	uint32_t* tiles_touched,
	bool prefiltered,
	int2* rects,
	float3 boxmin,
	float3 boxmax)
{
	lightpreprocessCUDA<NUM_CHANNELS> << <(P + 255) / 256, 256 >> > (
		deb_info,
		light_info,
		P, D, M,
		means3D,
		scales,
		scale_modifier,
		rotations,
		opacities,
		shs,
		clamped,
		cov3D_precomp,
		colors_precomp,
		viewmatrix,
		projmatrix,
		cam_pos,
		W, H,
		tan_fovx, tan_fovy,
		focal_x, focal_y,
		radii,
		means2D,
		depths,
		cov3Ds,
		rgb,
		conic_opacity,
		grid,
		tiles_touched,
		prefiltered,
		rects,
		boxmin,
		boxmax
		);
}

void FORWARD::preprocess(
	CudaRasterizer::CudaDebInfo* deb_info,
	Parameters::Light light_info,
	int P, int D, int M,
	const float* means3D,
	const glm::vec3* scales,
	const float scale_modifier,
	const glm::vec4* rotations,
	const float* opacities,
	const float* shs,
	bool* clamped,
	const float* cov3D_precomp,
	const float* colors_precomp,
	const float* viewmatrix,
	const float* projmatrix,
	const glm::vec3* cam_pos,
	const int W, int H,
	const float focal_x, float focal_y,
	const float tan_fovx, float tan_fovy,
	int* radii,
	float2* means2D,
	float* depths,
	float* cov3Ds,
	float* rgb,
	float4* conic_opacity,
	const dim3 grid,
	uint32_t* tiles_touched,
	bool prefiltered,
	int2* rects,
	float3 boxmin,
	float3 boxmax)
{
	preprocessCUDA<NUM_CHANNELS> << <(P + 255) / 256, 256 >> > (
		deb_info,
		light_info,
		P, D, M,
		means3D,
		scales,
		scale_modifier,
		rotations,
		opacities,
		shs,
		clamped,
		cov3D_precomp,
		colors_precomp,
		viewmatrix, 
		projmatrix,
		cam_pos,
		W, H,
		tan_fovx, tan_fovy,
		focal_x, focal_y,
		radii,
		means2D,
		depths,
		cov3Ds,
		rgb,
		conic_opacity,
		grid,
		tiles_touched,
		prefiltered,
		rects,
		boxmin,
		boxmax
		);
}