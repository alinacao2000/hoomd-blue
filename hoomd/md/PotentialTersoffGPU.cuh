// Copyright (c) 2009-2016 The Regents of the University of Michigan
// This file is part of the HOOMD-blue project, released under the BSD 3-Clause License.


#include "hoomd/HOOMDMath.h"
#include "hoomd/TextureTools.h"
#include "hoomd/ParticleData.cuh"
#include "hoomd/Index1D.h"

#include <assert.h>

/*! \file PotentialTersoffGPU.cuh
    \brief Defines templated GPU kernel code for calculating certain three-body forces
*/

#ifndef __POTENTIAL_TERSOFF_GPU_CUH__
#define __POTENTIAL_TERSOFF_GPU_CUH__

//! Wraps arguments to gpu_cgpf
struct tersoff_args_t
    {
    //! Construct a tersoff_args_t
    tersoff_args_t(Scalar4 *_d_force,
                   const unsigned int _N,
                   Scalar * _d_virial,
                   unsigned int _virial_pitch,
                   bool _compute_virial,
                   const Scalar4 *_d_pos,
                   const BoxDim& _box,
                   const unsigned int *_d_n_neigh,
                   const unsigned int *_d_nlist,
                   const unsigned int *_d_head_list,
                   const Scalar *_d_rcutsq,
                   const Scalar *_d_ronsq,
                   const unsigned int _size_nlist,
                   const unsigned int _ntypes,
                   const unsigned int _block_size,
                   const unsigned int _compute_capability,
                   const cudaDeviceProp& _devprop)
                   : d_force(_d_force),
                     N(_N),
                     d_virial(_d_virial),
                     virial_pitch(_virial_pitch),
                     compute_virial(_compute_virial),
                     d_pos(_d_pos),
                     box(_box),
                     d_n_neigh(_d_n_neigh),
                     d_nlist(_d_nlist),
                     d_head_list(_d_head_list),
                     d_rcutsq(_d_rcutsq),
                     d_ronsq(_d_ronsq),
                     size_nlist(_size_nlist),
                     ntypes(_ntypes),
                     block_size(_block_size),
                     compute_capability(_compute_capability),
                     devprop(_devprop)
        {
        };

    Scalar4 *d_force;                //!< Force to write out
    const unsigned int N;            //!< Number of particles
    Scalar *d_virial;                //!< Virial to write out
    const unsigned int virial_pitch; //!< Pitch for N*6 virial array
    bool compute_virial;             //!< True if we are supposed to compute the virial
    const Scalar4 *d_pos;            //!< particle positions
    const BoxDim& box;                //!< Simulation box in GPU format
    const unsigned int *d_n_neigh;  //!< Device array listing the number of neighbors on each particle
    const unsigned int *d_nlist;    //!< Device array listing the neighbors of each particle
    const unsigned int *d_head_list;//!< Indexes for accessing d_nlist
    const Scalar *d_rcutsq;          //!< Device array listing r_cut squared per particle type pair
    const Scalar *d_ronsq;           //!< Device array listing r_on squared per particle type pair
    const unsigned int size_nlist;  //!< Number of elements in the neighborlist
    const unsigned int ntypes;      //!< Number of particle types in the simulation
    const unsigned int block_size;  //!< Block size to execute
    const unsigned int compute_capability; //!< GPU compute capability (20, 30, 35, ...)
    const cudaDeviceProp& devprop;   //!< CUDA device properties
    };


#ifdef NVCC
//! Texture for reading particle positions
scalar4_tex_t pdata_pos_tex;
//! Texture for reading neighbor list
texture<unsigned int, 1, cudaReadModeElementType> nlist_tex;

#ifndef SINGLE_PRECISION
//! atomicAdd function for double-precision floating point numbers
/*! This function is only used when hoomd is compiled for double precision on the GPU.

    \param address Address to write the double to
    \param val Value to add to address
*/
static __device__ inline double atomicAdd(double* address, double val)
    {
    unsigned long long int* address_as_ull = (unsigned long long int*)address;
    unsigned long long int old = *address_as_ull, assumed;

    do {
        assumed = old;
        old = atomicCAS(address_as_ull,
                        assumed,
                        __double_as_longlong(val + __longlong_as_double(assumed)));
    } while (assumed != old);

    return __longlong_as_double(old);
    }
#endif

//! Kernel for calculating the Tersoff forces
/*! This kernel is called to calculate the forces on all N particles. Actual evaluation of the potentials and
    forces for each pair is handled via the template class \a evaluator.

    \param d_force Device memory to write computed forces
    \param N Number of particles in the system
    \param d_pos Positions of all the particles
    \param box Box dimensions used to implement periodic boundary conditions
    \param d_n_neigh Device memory array listing the number of neighbors for each particle
    \param d_nlist Device memory array containing the neighbor list contents
    \param d_head_list Indexes for reading \a d_nlist
    \param d_params Parameters for the potential, stored per type pair
    \param d_rcutsq rcut squared, stored per type pair
    \param d_ronsq ron squared, stored per type pair
    \param ntypes Number of types in the simulation

    \a d_params, \a d_rcutsq, and \a d_ronsq must be indexed with an Index2DUpperTriangler(typei, typej) to access the
    unique value for that type pair. These values are all cached into shared memory for quick access, so a dynamic
    amount of shared memory must be allocatd for this kernel launch. The amount is
    (2*sizeof(Scalar) + sizeof(typename evaluator::param_type)) * typpair_idx.getNumElements()

    Certain options are controlled via template parameters to avoid the performance hit when they are not enabled.
    \tparam evaluator EvaluatorPair class to evualuate V(r) and -delta V(r)/r
    \tparam use_gmem_nlist When non-zero, the neighbor list is read out of global memory. When zero, textures or __ldg
                           is used depending on architecture.

    <b>Implementation details</b>
    Each block will calculate the forces on a block of particles.
    Each thread will calculate the total force on one particle.
    The neighborlist is arranged in columns so that reads are fully coalesced when doing this.
*/
template< class evaluator , unsigned char use_gmem_nlist, unsigned char compute_virial>
__global__ void gpu_compute_triplet_forces_kernel(Scalar4 *d_force,
                                                  const unsigned int N,
                                                  Scalar *d_virial,
                                                  unsigned int virial_pitch,
                                                  const Scalar4 *d_pos,
                                                  const BoxDim box,
                                                  const unsigned int *d_n_neigh,
                                                  const unsigned int *d_nlist,
                                                  const unsigned int *d_head_list,
                                                  const typename evaluator::param_type *d_params,
                                                  const Scalar *d_rcutsq,
                                                  const Scalar *d_ronsq,
                                                  const unsigned int ntypes)
    {
    Index2D typpair_idx(ntypes);
    const unsigned int num_typ_parameters = typpair_idx.getNumElements();

    // shared arrays for per type pair parameters
    extern __shared__ char s_data[];
    typename evaluator::param_type *s_params =
        (typename evaluator::param_type *)(&s_data[0]);
    Scalar *s_rcutsq = (Scalar *)(&s_data[num_typ_parameters*sizeof(evaluator::param_type)]);

    Scalar *s_phi_ab = s_rcutsq + num_typ_parameters;

    // load in the per type pair parameters
    for (unsigned int cur_offset = 0; cur_offset < num_typ_parameters; cur_offset += blockDim.x)
        {
        if (cur_offset + threadIdx.x < num_typ_parameters)
            {
            s_rcutsq[cur_offset + threadIdx.x] = d_rcutsq[cur_offset + threadIdx.x];
            s_params[cur_offset + threadIdx.x] = d_params[cur_offset + threadIdx.x];
            }
        }

    __syncthreads();

    for (unsigned int i = 0; i < ntypes; ++i)
        {
        // reset phi term
        s_phi_ab[threadIdx.x*ntypes+i] = Scalar(0.0);
        }

    // start by identifying which particle we are to handle
    unsigned int idx = blockIdx.x * blockDim.x + threadIdx.x;

    if (idx >= N)
        return;

    // load in the length of the neighbor list (MEM_TRANSFER: 4 bytes)
    unsigned int n_neigh = d_n_neigh[idx];

    // read in the position of the particle
    Scalar4 postypei = texFetchScalar4(d_pos, pdata_pos_tex, idx);
    Scalar3 posi = make_scalar3(postypei.x, postypei.y, postypei.z);

    // initialize the force to 0
    Scalar4 forcei = make_scalar4(Scalar(0.0), Scalar(0.0), Scalar(0.0), Scalar(0.0));

    Scalar viriali_xx(0.0);
    Scalar viriali_xy(0.0);
    Scalar viriali_xz(0.0);
    Scalar viriali_yy(0.0);
    Scalar viriali_yz(0.0);
    Scalar viriali_zz(0.0);

    // loop over neighbors to calculate per-particle energy
    if (evaluator::hasPerParticleEnergy())
        {
        // prefetch neighbor index
        const unsigned int head_idx = d_head_list[idx];
        unsigned int cur_j = 0;
        unsigned int next_j(0);
        if (use_gmem_nlist)
            {
            next_j = d_nlist[head_idx];
            }
        else
            {
            next_j = texFetchUint(d_nlist, nlist_tex, head_idx);
            }

        for (int neigh_idx = 0; neigh_idx < n_neigh; neigh_idx++)
            {
            // read the current neighbor index (MEM TRANSFER: 4 bytes)
            // prefetch the next value and set the current one
            cur_j = next_j;
            if (use_gmem_nlist)
                {
                next_j = d_nlist[head_idx + neigh_idx + 1];
                }
            else
                {
                next_j = texFetchUint(d_nlist, nlist_tex, head_idx + neigh_idx + 1);
                }

            // read the position of j (MEM TRANSFER: 16 bytes)
            Scalar4 postypej = texFetchScalar4(d_pos, pdata_pos_tex, cur_j);
            Scalar3 posj = make_scalar3(postypej.x, postypej.y, postypej.z);

            // initialize the force on j
            Scalar4 forcej = make_scalar4(Scalar(0.0), Scalar(0.0), Scalar(0.0), Scalar(0.0));

            // compute r_ij (FLOPS: 3)
            Scalar3 dxij = posi - posj;

            // apply periodic boundary conditions (FLOPS: 12)
            dxij = box.minImage(dxij);

            // compute rij_sq (FLOPS: 5)
            Scalar rij_sq = dot(dxij, dxij);

            // access the per type-pair parameters
            unsigned int typpair = typpair_idx(__scalar_as_int(postypei.w), __scalar_as_int(postypej.w));
            Scalar rcutsq = s_rcutsq[typpair];
            typename evaluator::param_type param = s_params[typpair];

            evaluator eval(rij_sq, rcutsq, param);
            eval.evalPhi(s_phi_ab[threadIdx.x*ntypes+__scalar_as_int(postypej.w)]);
            }

        // self-energy
        for (unsigned int typ_b = 0; typ_b < ntypes; ++typ_b)
            {
            unsigned int typpair = typpair_idx(__scalar_as_int(postypei.w), typ_b);
            Scalar rcutsq = s_rcutsq[typpair];
            typename evaluator::param_type param = s_params[typpair];

            evaluator eval(Scalar(0.0), rcutsq, param);
            Scalar energy(0.0);
            const Scalar& phi = s_phi_ab[threadIdx.x*ntypes+typ_b];
            eval.evalSelfEnergy(energy, phi);
            forcei.w += energy;
            }
        }

    // prefetch neighbor index
    const unsigned int head_idx = d_head_list[idx];
    unsigned int cur_j = 0;
    unsigned int next_j(0);
    if (use_gmem_nlist)
        {
        next_j = d_nlist[head_idx];
        }
    else
        {
        next_j = texFetchUint(d_nlist, nlist_tex, head_idx);
        }

    // loop over neighbors
    for (int neigh_idx = 0; neigh_idx < n_neigh; neigh_idx++)
        {
        // read the current neighbor index (MEM TRANSFER: 4 bytes)
        // prefetch the next value and set the current one
        cur_j = next_j;
        if (use_gmem_nlist)
            {
            next_j = d_nlist[head_idx + neigh_idx + 1];
            }
        else
            {
            next_j = texFetchUint(d_nlist, nlist_tex, head_idx + neigh_idx + 1);
            }

        // read the position of j (MEM TRANSFER: 16 bytes)
        Scalar4 postypej = texFetchScalar4(d_pos, pdata_pos_tex, cur_j);
        Scalar3 posj = make_scalar3(postypej.x, postypej.y, postypej.z);

        // initialize the force on j
        Scalar4 forcej = make_scalar4(Scalar(0.0), Scalar(0.0), Scalar(0.0), Scalar(0.0));

        Scalar virialj_xx(0.0);
        Scalar virialj_xy(0.0);
        Scalar virialj_xz(0.0);
        Scalar virialj_yy(0.0);
        Scalar virialj_yz(0.0);
        Scalar virialj_zz(0.0);

        // compute r_ij (FLOPS: 3)
        Scalar3 dxij = posi - posj;

        // apply periodic boundary conditions (FLOPS: 12)
        dxij = box.minImage(dxij);

        // compute rij_sq (FLOPS: 5)
        Scalar rij_sq = dot(dxij, dxij);

        // access the per type-pair parameters
        unsigned int typpair = typpair_idx(__scalar_as_int(postypei.w), __scalar_as_int(postypej.w));
        Scalar rcutsq = s_rcutsq[typpair];
        typename evaluator::param_type param = s_params[typpair];

        // compute the base repulsive and attractive terms of the potential
        Scalar fR = Scalar(0.0);
        Scalar fA = Scalar(0.0);
        evaluator eval(rij_sq, rcutsq, param);
        bool evaluatedij = eval.evalRepulsiveAndAttractive(fR, fA);

        if (evaluatedij)
            {
            Scalar chi = Scalar(0.0);

            if (evaluator::needsChi())
                {
                // compute chi
                unsigned int cur_k = 0;
                unsigned int next_k(0);
                if (use_gmem_nlist)
                    {
                    next_k = d_nlist[head_idx];
                    }
                else
                    {
                    next_k = texFetchUint(d_nlist, nlist_tex, head_idx);
                    }
                for (int neigh_idy = 0; neigh_idy < n_neigh; neigh_idy++)
                    {
                    // read the current index of k and prefetch the next one
                    cur_k = next_k;
                    if (use_gmem_nlist)
                        {
                        next_k = d_nlist[head_idx + neigh_idy + 1];
                        }
                    else
                        {
                        next_k = texFetchUint(d_nlist, nlist_tex, head_idx + neigh_idy+1);
                        }

                    // get the position of neighbor k
                    Scalar4 postypek = texFetchScalar4(d_pos, pdata_pos_tex, cur_k);
                    Scalar3 posk = make_scalar3(postypek.x, postypek.y, postypek.z);

                    // get the type pair parameters for i and k
                    typpair = typpair_idx(__scalar_as_int(postypei.w), __scalar_as_int(postypek.w));
                    Scalar temp_rcutsq = s_rcutsq[typpair];
                    typename evaluator::param_type temp_param = s_params[typpair];

                    evaluator temp_eval(rij_sq, temp_rcutsq, temp_param);
                    bool temp_evaluated = temp_eval.areInteractive();

                    if (cur_k != cur_j && temp_evaluated)
                        {
                        // compute rik
                        Scalar3 dxik = posi - posk;

                        // apply the periodic boundary conditions
                        dxik = box.minImage(dxik);

                        // compute rik_sq
                        Scalar rik_sq = dot(dxik, dxik);

                        // compute the bond angle (if needed)
                        Scalar cos_th = Scalar(0.0);
                        if (evaluator::needsAngle())
                            cos_th = dot(dxij, dxik) * fast::rsqrt(rij_sq * rik_sq);
                        else cos_th += Scalar(1.0); // shuts up the compiler warning

                        // set up the evaluator
                        eval.setRik(rik_sq);
                        if (evaluator::needsAngle())
                            eval.setAngle(cos_th);

                        // compute the partial chi term
                        eval.evalChi(chi);
                        }
                    }
                }
            // evaluate the force and energy from the ij interaction
            Scalar force_divr = Scalar(0.0);
            Scalar potential_eng = Scalar(0.0);
            Scalar bij = Scalar(0.0);
            const Scalar& phi = s_phi_ab[threadIdx.x*ntypes+__scalar_as_int(postypej.w)];
            eval.evalForceij(fR, fA, chi, phi, bij, force_divr, potential_eng);

            // add the forces and energies to their respective particles
            Scalar2 v_coeffs = make_scalar2(Scalar(1.0 / 6.0) * rij_sq, Scalar(0.0));
            forcei.x += dxij.x * force_divr;
            forcei.y += dxij.y * force_divr;
            forcei.z += dxij.z * force_divr;

            if (compute_virial)
                {
                Scalar force_div2r = Scalar(0.5)*force_divr;
                viriali_xx += force_div2r*dxij.x*dxij.x;
                viriali_xy += force_div2r*dxij.x*dxij.y;
                viriali_xz += force_div2r*dxij.x*dxij.z;
                viriali_yy += force_div2r*dxij.y*dxij.y;
                viriali_yz += force_div2r*dxij.y*dxij.z;
                viriali_zz += force_div2r*dxij.z*dxij.z;
                }

            forcej.x -= dxij.x * force_divr;
            forcej.y -= dxij.y * force_divr;
            forcej.z -= dxij.z * force_divr;

            if (compute_virial)
                {
                Scalar force_div2r = Scalar(0.5)*force_divr;
                virialj_xx += force_div2r*dxij.x*dxij.x;
                virialj_xy += force_div2r*dxij.x*dxij.y;
                virialj_xz += force_div2r*dxij.x*dxij.z;
                virialj_yy += force_div2r*dxij.y*dxij.y;
                virialj_yz += force_div2r*dxij.y*dxij.z;
                virialj_zz += force_div2r*dxij.z*dxij.z;
                }

            // potential energy of j must be halved
            forcej.w += Scalar(0.5)*potential_eng;

            // potential energy per particle must be halved
            forcei.w += Scalar(0.5)*potential_eng;

            if (evaluator::hasIkForce())
                {
                // now evaluate the force from the ik interactions
                unsigned int cur_k = 0;
                unsigned int next_k(0);
                if (use_gmem_nlist)
                    {
                    next_k = d_nlist[head_idx];
                    }
                else
                    {
                    next_k = texFetchUint(d_nlist, nlist_tex, head_idx);
                    }
                for (int neigh_idy = 0; neigh_idy < n_neigh; neigh_idy++)
                    {
                    // read the current neighbor index and prefetch the next one
                    cur_k = next_k;
                    if (use_gmem_nlist)
                        {
                        next_k = d_nlist[head_idx + neigh_idy + 1];
                        }
                    else
                        {
                        next_k = texFetchUint(d_nlist, nlist_tex, head_idx + neigh_idy+1);
                        }

                    // get the position of neighbor k
                    Scalar4 postypek = texFetchScalar4(d_pos, pdata_pos_tex, cur_k);
                    Scalar3 posk = make_scalar3(postypek.x, postypek.y, postypek.z);

                    // get the type pair parameters for i and k
                    typpair = typpair_idx(__scalar_as_int(postypei.w), __scalar_as_int(postypek.w));
                    Scalar temp_rcutsq = s_rcutsq[typpair];
                    typename evaluator::param_type temp_param = s_params[typpair];

                    evaluator temp_eval(rij_sq, temp_rcutsq, temp_param);
                    bool temp_evaluated = temp_eval.areInteractive();

                    if (cur_k != cur_j && temp_evaluated)
                        {
                        Scalar4 forcek = make_scalar4(Scalar(0.0), Scalar(0.0), Scalar(0.0), Scalar(0.0));

                        // compute rik
                        Scalar3 dxik = posi - posk;

                        // apply the periodic boundary conditions
                        dxik = box.minImage(dxik);

                        // compute rik_sq
                        Scalar rik_sq = dot(dxik, dxik);

                        // compute the bond angle (if needed)
                        Scalar cos_th = Scalar(0.0);
                        if (evaluator::needsAngle())
                            cos_th = dot(dxij, dxik) * fast::rsqrt(rij_sq * rik_sq);
                        else cos_th += Scalar(1.0); // shuts up the compiler warning

                        // set up the evaluator
                        eval.setRik(rik_sq);
                        if (evaluator::needsAngle())
                            eval.setAngle(cos_th);

                        // compute the force
                        Scalar3 force_divr_ij = make_scalar3(Scalar(0.0), Scalar(0.0), Scalar(0.0));
                        Scalar3 force_divr_ik = make_scalar3(Scalar(0.0), Scalar(0.0), Scalar(0.0));
                        bool evaluatedjk = eval.evalForceik(fR, fA, chi, bij, force_divr_ij, force_divr_ik);

                        if (evaluatedjk)
                            {
                            // add the forces to their respective particles
                            v_coeffs.y = Scalar(1.0 / 6.0) * rik_sq;
                            forcei.x += force_divr_ij.x * dxij.x + force_divr_ik.x * dxik.x;
                            forcei.y += force_divr_ij.x * dxij.y + force_divr_ik.x * dxik.y;
                            forcei.z += force_divr_ij.x * dxij.z + force_divr_ik.x * dxik.z;

                            // NOTE: virial for ik forces not tested
                            if (compute_virial)
                                {
                                Scalar force_div2r_ij = Scalar(0.5)*force_divr_ij.x;
                                Scalar force_div2r_ik = Scalar(0.5)*force_divr_ik.x;
                                viriali_xx += force_div2r_ij*dxij.x*dxij.x + force_div2r_ik*dxik.x*dxik.x;
                                viriali_xy += force_div2r_ij*dxij.x*dxij.y + force_div2r_ik*dxik.x*dxik.y;
                                viriali_xz += force_div2r_ij*dxij.x*dxij.z + force_div2r_ik*dxik.x*dxik.z;
                                viriali_yy += force_div2r_ij*dxij.y*dxij.y + force_div2r_ik*dxik.y*dxik.y;
                                viriali_yz += force_div2r_ij*dxij.y*dxij.z + force_div2r_ik*dxik.y*dxik.z;
                                viriali_zz += force_div2r_ij*dxij.z*dxij.z + force_div2r_ik*dxik.z*dxik.z;
                                }

                            forcej.x += force_divr_ij.y * dxij.x + force_divr_ik.y * dxik.x;
                            forcej.y += force_divr_ij.y * dxij.y + force_divr_ik.y * dxik.y;
                            forcej.z += force_divr_ij.y * dxij.z + force_divr_ik.y * dxik.z;

                            if (compute_virial)
                                {
                                Scalar force_div2r_ij = Scalar(0.5)*force_divr_ij.y;
                                Scalar force_div2r_ik = Scalar(0.5)*force_divr_ik.y;
                                virialj_xx += force_div2r_ij*dxij.x*dxij.x + force_div2r_ik*dxik.x*dxik.x;
                                virialj_xy += force_div2r_ij*dxij.x*dxij.y + force_div2r_ik*dxik.x*dxik.y;
                                virialj_xz += force_div2r_ij*dxij.x*dxij.z + force_div2r_ik*dxik.x*dxik.z;
                                virialj_yy += force_div2r_ij*dxij.y*dxij.y + force_div2r_ik*dxik.y*dxik.y;
                                virialj_yz += force_div2r_ij*dxij.y*dxij.z + force_div2r_ik*dxik.y*dxik.z;
                                virialj_zz += force_div2r_ij*dxij.z*dxij.z + force_div2r_ik*dxik.z*dxik.z;
                                }

                            forcek.x += force_divr_ij.z * dxij.x + force_divr_ik.z * dxik.x;
                            forcek.y += force_divr_ij.z * dxij.y + force_divr_ik.z * dxik.y;
                            forcek.z += force_divr_ij.z * dxij.z + force_divr_ik.z * dxik.z;

                            atomicAdd(&d_force[cur_k].x, forcek.x);
                            atomicAdd(&d_force[cur_k].y, forcek.y);
                            atomicAdd(&d_force[cur_k].z, forcek.z);

                            if (compute_virial)
                                {
                                Scalar force_div2r_ij = Scalar(0.5)*force_divr_ij.z;
                                Scalar force_div2r_ik = Scalar(0.5)*force_divr_ik.z;
                                atomicAdd(&d_virial[0*virial_pitch+cur_k],force_div2r_ij*dxij.x*dxij.x + force_div2r_ik*dxik.x*dxik.x);
                                atomicAdd(&d_virial[1*virial_pitch+cur_k],force_div2r_ij*dxij.x*dxij.y + force_div2r_ik*dxik.x*dxik.y);
                                atomicAdd(&d_virial[2*virial_pitch+cur_k],force_div2r_ij*dxij.x*dxij.z + force_div2r_ik*dxik.x*dxik.z);
                                atomicAdd(&d_virial[3*virial_pitch+cur_k],force_div2r_ij*dxij.y*dxij.y + force_div2r_ik*dxik.y*dxik.y);
                                atomicAdd(&d_virial[4*virial_pitch+cur_k],force_div2r_ij*dxij.y*dxij.z + force_div2r_ik*dxik.y*dxik.z);
                                atomicAdd(&d_virial[5*virial_pitch+cur_k],force_div2r_ij*dxij.z*dxij.z + force_div2r_ik*dxik.z*dxik.z);
                                }
                            }
                        }
                    }
                }

            // write out the result for particle j
            atomicAdd(&d_force[cur_j].x, forcej.x);
            atomicAdd(&d_force[cur_j].y, forcej.y);
            atomicAdd(&d_force[cur_j].z, forcej.z);
            atomicAdd(&d_force[cur_j].w, forcej.w);

            if (compute_virial)
                {
                atomicAdd(&d_virial[0*virial_pitch+cur_j], virialj_xx);
                atomicAdd(&d_virial[1*virial_pitch+cur_j], virialj_xy);
                atomicAdd(&d_virial[2*virial_pitch+cur_j], virialj_xz);
                atomicAdd(&d_virial[3*virial_pitch+cur_j], virialj_yy);
                atomicAdd(&d_virial[4*virial_pitch+cur_j], virialj_yz);
                atomicAdd(&d_virial[5*virial_pitch+cur_j], virialj_zz);
                }
            }
        }
    // now that the force calculation is complete, write out the result (MEM TRANSFER: 20 bytes)
    atomicAdd(&d_force[idx].x, forcei.x);
    atomicAdd(&d_force[idx].y, forcei.y);
    atomicAdd(&d_force[idx].z, forcei.z);
    atomicAdd(&d_force[idx].w, forcei.w);

    if (compute_virial)
        {
        atomicAdd(&d_virial[0*virial_pitch+idx], viriali_xx);
        atomicAdd(&d_virial[1*virial_pitch+idx], viriali_xy);
        atomicAdd(&d_virial[2*virial_pitch+idx], viriali_xz);
        atomicAdd(&d_virial[3*virial_pitch+idx], viriali_yy);
        atomicAdd(&d_virial[4*virial_pitch+idx], viriali_yz);
        atomicAdd(&d_virial[5*virial_pitch+idx], viriali_zz);
        }
    }

//! Kernel for zeroing forces and virial before computation with atomic additions.
/*! \param d_force Device memory to write forces to
    \param N Number of particles in the system

*/
__global__ void gpu_zero_forces_kernel(Scalar4 *d_force,
                                       Scalar *d_virial,
                                       unsigned int virial_pitch,
                                       const unsigned int N)
    {
    // identify the particle we are supposed to handle
    unsigned int idx = blockIdx.x * blockDim.x + threadIdx.x;

    if (idx >= N)
        return;

    // zero the force
    d_force[idx] = make_scalar4(Scalar(0.0), Scalar(0.0), Scalar(0.0), Scalar(0.0));

    // zero the virial
    d_virial[0*virial_pitch+idx] = Scalar(0.0);
    d_virial[1*virial_pitch+idx] = Scalar(0.0);
    d_virial[2*virial_pitch+idx] = Scalar(0.0);
    d_virial[3*virial_pitch+idx] = Scalar(0.0);
    d_virial[4*virial_pitch+idx] = Scalar(0.0);
    d_virial[5*virial_pitch+idx] = Scalar(0.0);
    }

//! Kernel driver that computes the three-body forces
/*! \param pair_args Other arugments to pass onto the kernel
    \param d_params Parameters for the potential, stored per type pair

    This is just a driver function for gpu_compute_triplet_forces_kernel(), see it for details.
*/
template< class evaluator >
cudaError_t gpu_compute_triplet_forces(const tersoff_args_t& pair_args,
                                       const typename evaluator::param_type *d_params)
    {
    assert(d_params);
    assert(pair_args.d_rcutsq);
    assert(pair_args.d_ronsq);
    assert(pair_args.ntypes > 0);

    unsigned int run_block_size = 0;

    static unsigned int kernel_shared_bytes = 0;

    if (pair_args.compute_virial)
        {
        static unsigned int max_block_size = UINT_MAX;
        if (max_block_size == UINT_MAX)
            {
            if (pair_args.compute_capability < 35 && pair_args.size_nlist > (unsigned int) pair_args.devprop.maxTexture1DLinear)
                {
                cudaFuncAttributes attr;
                cudaFuncGetAttributes(&attr, gpu_compute_triplet_forces_kernel<evaluator, 1, 1>);
                max_block_size = attr.maxThreadsPerBlock;
                kernel_shared_bytes = attr.sharedSizeBytes;
                }
            else
                {
                cudaFuncAttributes attr;
                cudaFuncGetAttributes(&attr, gpu_compute_triplet_forces_kernel<evaluator, 0, 1>);
                max_block_size = attr.maxThreadsPerBlock;
                kernel_shared_bytes = attr.sharedSizeBytes;
                }
            }

        run_block_size = min(pair_args.block_size, max_block_size);
        }
    else
        {
        static unsigned int max_block_size = UINT_MAX;
        if (max_block_size == UINT_MAX)
            {
            if (pair_args.compute_capability < 35 && pair_args.size_nlist > (unsigned int) pair_args.devprop.maxTexture1DLinear)
                {
                cudaFuncAttributes attr;
                cudaFuncGetAttributes(&attr, gpu_compute_triplet_forces_kernel<evaluator, 1, 0>);
                max_block_size = attr.maxThreadsPerBlock;
                kernel_shared_bytes = attr.sharedSizeBytes;
                }
            else
                {
                cudaFuncAttributes attr;
                cudaFuncGetAttributes(&attr, gpu_compute_triplet_forces_kernel<evaluator, 0, 0>);
                max_block_size = attr.maxThreadsPerBlock;
                kernel_shared_bytes = attr.sharedSizeBytes;
                }
            }

        run_block_size = min(pair_args.block_size, max_block_size);
        }

    // bind to texture
    if (pair_args.compute_capability < 35)
        {
        pdata_pos_tex.normalized = false;
        pdata_pos_tex.filterMode = cudaFilterModePoint;
        cudaError_t error = cudaBindTexture(0, pdata_pos_tex, pair_args.d_pos, sizeof(Scalar4) * pair_args.N);
        if (error != cudaSuccess)
            return error;

        if (pair_args.size_nlist <= (unsigned int) pair_args.devprop.maxTexture1DLinear)
            {
            nlist_tex.normalized = false;
            nlist_tex.filterMode = cudaFilterModePoint;
            error = cudaBindTexture(0, nlist_tex, pair_args.d_nlist, sizeof(unsigned int) * pair_args.size_nlist);
            if (error != cudaSuccess)
                return error;
            }
        }

    Index2D typpair_idx(pair_args.ntypes);
    unsigned int shared_bytes = (sizeof(Scalar) + sizeof(typename evaluator::param_type))
                                * typpair_idx.getNumElements() + pair_args.ntypes*run_block_size*sizeof(Scalar);

    while (shared_bytes + kernel_shared_bytes >= pair_args.devprop.sharedMemPerBlock)
        {
        run_block_size -= pair_args.devprop.warpSize;

        shared_bytes = (sizeof(Scalar) + sizeof(typename evaluator::param_type))
                       * typpair_idx.getNumElements() + pair_args.ntypes*run_block_size*sizeof(Scalar);
        }

    // setup the grid to run the kernel
    dim3 grid( pair_args.N / run_block_size + 1, 1, 1);
    dim3 threads(run_block_size, 1, 1);

    // zero the forces
    gpu_zero_forces_kernel<<<grid, threads>>>(pair_args.d_force,
                                            pair_args.d_virial,
                                            pair_args.virial_pitch,
                                            pair_args.N);

    // compute the new forces
    if (!pair_args.compute_virial)
        {
        if (pair_args.compute_capability < 35 && pair_args.size_nlist > (unsigned int) pair_args.devprop.maxTexture1DLinear)
            {
            gpu_compute_triplet_forces_kernel<evaluator, 1, 0>
              <<<grid, threads, shared_bytes>>>(pair_args.d_force,
                                                pair_args.N,
                                                pair_args.d_virial,
                                                pair_args.virial_pitch,
                                                pair_args.d_pos,
                                                pair_args.box,
                                                pair_args.d_n_neigh,
                                                pair_args.d_nlist,
                                                pair_args.d_head_list,
                                                d_params,
                                                pair_args.d_rcutsq,
                                                pair_args.d_ronsq,
                                                pair_args.ntypes);
            }
        else
            {
            gpu_compute_triplet_forces_kernel<evaluator, 0, 0>
              <<<grid, threads, shared_bytes>>>(pair_args.d_force,
                                                pair_args.N,
                                                pair_args.d_virial,
                                                pair_args.virial_pitch,
                                                pair_args.d_pos,
                                                pair_args.box,
                                                pair_args.d_n_neigh,
                                                pair_args.d_nlist,
                                                pair_args.d_head_list,
                                                d_params,
                                                pair_args.d_rcutsq,
                                                pair_args.d_ronsq,
                                                pair_args.ntypes);
            }
        }
    else
        {
        if (pair_args.compute_capability < 35 && pair_args.size_nlist > (unsigned int) pair_args.devprop.maxTexture1DLinear)
            {
            gpu_compute_triplet_forces_kernel<evaluator, 1, 1>
              <<<grid, threads, shared_bytes>>>(pair_args.d_force,
                                                pair_args.N,
                                                pair_args.d_virial,
                                                pair_args.virial_pitch,
                                                pair_args.d_pos,
                                                pair_args.box,
                                                pair_args.d_n_neigh,
                                                pair_args.d_nlist,
                                                pair_args.d_head_list,
                                                d_params,
                                                pair_args.d_rcutsq,
                                                pair_args.d_ronsq,
                                                pair_args.ntypes);
            }
        else
            {
            gpu_compute_triplet_forces_kernel<evaluator, 0, 1>
              <<<grid, threads, shared_bytes>>>(pair_args.d_force,
                                                pair_args.N,
                                                pair_args.d_virial,
                                                pair_args.virial_pitch,
                                                pair_args.d_pos,
                                                pair_args.box,
                                                pair_args.d_n_neigh,
                                                pair_args.d_nlist,
                                                pair_args.d_head_list,
                                                d_params,
                                                pair_args.d_rcutsq,
                                                pair_args.d_ronsq,
                                                pair_args.ntypes);
            }
        }
    return cudaSuccess;
    }
#endif

#endif // __POTENTIAL_TERSOFF_GPU_CUH__
