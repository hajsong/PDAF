! Copyright (c) 2004-2024 Lars Nerger
!
! This file is part of PDAF.
!
! PDAF is free software: you can redistribute it and/or modify
! it under the terms of the GNU Lesser General Public License
! as published by the Free Software Foundation, either version
! 3 of the License, or (at your option) any later version.
!
! PDAF is distributed in the hope that it will be useful,
! but WITHOUT ANY WARRANTY; without even the implied warranty of
! MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
! GNU Lesser General Public License for more details.
!
! You should have received a copy of the GNU Lesser General Public
! License along with PDAF.  If not, see <http://www.gnu.org/licenses/>.
!
!$Id: PDAF_letkf_analysis_T.F90 1147 2023-03-12 16:14:34Z lnerger $
!BOP
!
! !ROUTINE: PDAF_letkf_analysis_T --- LETKF analysis using T-matrix
!
! !INTERFACE:
SUBROUTINE PDAF_letkf_analysis_T(domain_p, step, dim_l, dim_obs_f, dim_obs_l, &
     dim_ens, state_l, Ainv_l, ens_l, HX_f, &
     HXbar_f, state_inc_l, rndmat, forget, U_g2l_obs, &
     U_init_obs_l, U_prodRinvA_l, U_init_obsvar_l, U_init_n_domains_p, &
     screen, incremental, type_forget, flag)

! !DESCRIPTION:
! Analysis step of the LETKF using a matrix T analogous
! to the SEIK filter. The consistent use of the operation
! of removing the mean from an ensemble matrix in form of
! a linear transformation (T-matrix) reduces the computational
! complexity.
!
! The implementation also supports an adaptive forgetting factor.
!
! Variant for domain decomposed states.
!
! !  This is a core routine of PDAF and
!    should not be changed by the user   !
!
! !REVISION HISTORY:
! 2009-07 - Lars Nerger - Initial code
! Later revisions - see svn log
!
! !USES:
! Include definitions for real type of different precision
! (Defines BLAS/LAPACK routines and MPI_REALTYPE)
#include "typedefs.h"

  USE PDAF_timer, &
       ONLY: PDAF_timeit
  USE PDAF_memcounting, &
       ONLY: PDAF_memcount
  USE PDAF_mod_filtermpi, &
       ONLY: mype
  USE PDAF_mod_filter, &
       ONLY: type_trans, obs_member, debug
  USE PDAFomi, &
       ONLY: omi_omit_obs => omit_obs
#if defined (_OPENMP)
  USE omp_lib, &
       ONLY: omp_get_num_threads, omp_get_thread_num
#endif

  IMPLICIT NONE

! !ARGUMENTS:
! ! Variable naming scheme:
! !   suffix _p: Denotes a full variable on the PE-local domain
! !   suffix _l: Denotes a local variable on the current analysis domain
  INTEGER, INTENT(in) :: domain_p    ! Current local analysis domain
  INTEGER, INTENT(in) :: step        ! Current time step
  INTEGER, INTENT(in) :: dim_l       ! State dimension on local analysis domain
  INTEGER, INTENT(in) :: dim_obs_f   ! PE-local dimension of full observation vector
  INTEGER, INTENT(in) :: dim_obs_l   ! Size of obs. vector on local ana. domain
  INTEGER, INTENT(in) :: dim_ens     ! Size of ensemble 
  REAL, INTENT(inout) :: state_l(dim_l)           ! local forecast state
  REAL, INTENT(out)   :: Ainv_l(dim_ens, dim_ens) ! on entry: uninitialized
                               ! on exit: local weight matrix for ensemble transformation
  REAL, INTENT(inout) :: ens_l(dim_l, dim_ens)    ! Local state ensemble
  REAL, INTENT(in) :: HX_f(dim_obs_f, dim_ens) ! PE-local full observed state ens.
  REAL, INTENT(in) :: HXbar_f(dim_obs_f)       ! PE-local full observed ens. mean
  REAL, INTENT(in) :: state_inc_l(dim_l)       ! Local state increment
  REAL, INTENT(inout) :: rndmat(dim_ens, dim_ens) ! Global random rotation matrix
  REAL, INTENT(inout) :: forget      ! Forgetting factor
  INTEGER, INTENT(in) :: screen      ! Verbosity flag
  INTEGER, INTENT(in) :: incremental ! Control incremental updating
  INTEGER, INTENT(in) :: type_forget ! Type of forgetting factor
  INTEGER, INTENT(inout) :: flag     ! Status flag

! ! External subroutines 
! ! (PDAF-internal names, real names are defined in the call to PDAF)
  EXTERNAL :: U_g2l_obs, &   ! Restrict full obs. vector to local analysis domain
       U_init_obs_l, &       ! Init. observation vector on local analysis domain
       U_init_obsvar_l, &    ! Initialize local mean observation error variance
       U_init_n_domains_p, & ! Provide PE-local number of local analysis domains
       U_prodRinvA_l         ! Provide product R^-1 A for local analysis domain

! !CALLING SEQUENCE:
! Called by: PDAF_letkf_update
! Calls: U_g2l_obs
! Calls: U_init_obs_l
! Calls: U_prodRinvA_l
! Calls: PDAF_timeit
! Calls: PDAF_memcount
! Calls: PDAF_set_forget_local
! Calls: PDAF_etkf_Tright
! Calls: PDAF_etkf_Tleft
! Calls: gemmTYPE (BLAS; dgemm or sgemm dependent on precision)
! Calls: gemvTYPE (BLAS; dgemv or sgemv dependent on precision)
! Calls: syevTYPE (LAPACK; dsyev or ssyev dependent on precision)
!EOP
       
! *** local variables ***
  INTEGER :: i, member, col, row       ! Counters
  INTEGER, SAVE :: allocflag = 0       ! Flag whether first time allocation is done
  INTEGER :: syev_info                 ! Status flag for SYEV
  INTEGER :: ldwork                    ! Size of work array for SYEV
  INTEGER :: maxblksize, blkupper, blklower  ! Variables for blocked ensemble update
  REAL    :: sqrtNm1                   ! Temporary variable: sqrt(dim_ens-1)
  INTEGER, SAVE :: lastdomain = -1     ! store domain index
  LOGICAL, SAVE :: screenout = .true.  ! Whether to print information to stdout
  REAL, ALLOCATABLE :: HZ_l(:,:)       ! Temporary matrices for analysis
  REAL, ALLOCATABLE :: RiHZ_l(:,:)     ! Temporary matrices for analysis
  REAL, ALLOCATABLE :: resid_l(:)      ! local observation residual
  REAL, ALLOCATABLE :: obs_l(:)        ! local observation vector
  REAL, ALLOCATABLE :: HXbar_l(:)      ! state projected onto obs. space
  REAL, ALLOCATABLE :: RiHZd_l(:)      ! local RiHZd
  REAL, ALLOCATABLE :: VRiHZd_l(:)     ! Temporary vector for analysis
  REAL, ALLOCATABLE :: tmp_Ainv_l(:,:) ! Temporary storage of Ainv
  REAL, ALLOCATABLE :: Asqrt_l(:,:)    ! Temporary for square-root of A
  REAL, ALLOCATABLE :: ens_blk(:,:)    ! Temporary block of state ensemble
  REAL, ALLOCATABLE :: svals(:)        ! Singular values of Ainv
  REAL, ALLOCATABLE :: work(:)         ! Work array for SYEV
  INTEGER, SAVE :: mythread, nthreads  ! Thread variables for OpenMP
  INTEGER :: incremental_dummy         ! Dummy variable to avoid compiler warning
  REAL :: state_inc_l_dummy            ! Dummy variable to avoid compiler warning

!$OMP THREADPRIVATE(mythread, nthreads, lastdomain, allocflag, screenout)


! *******************
! *** Preparation ***
! *******************

  CALL PDAF_timeit(51, 'new')

  ! Initialize variable to prevent compiler warning
  incremental_dummy = incremental
  state_inc_l_dummy = state_inc_l(1)

#if defined (_OPENMP)
  nthreads = omp_get_num_threads()
  mythread = omp_get_thread_num()
#else
  nthreads = 1
  mythread = 0
#endif

  ! Control screen output
  IF (lastdomain<domain_p .AND. lastdomain>-1) THEN
     screenout = .false.
  ELSE
     screenout = .true.

     ! In case of OpenMP, let only thread 0 write output to the screen
     IF (mythread>0) screenout = .false.

     ! Output, only in case of OpenMP parallelization
#if defined (_OPENMP)
     IF (screenout) THEN
        WRITE (*,'(a, 5x, a, i5, a)') &
             'PDAF', '--- Use OpenMP parallelization with ', nthreads, ' threads'
     END IF
#endif
  END IF

  IF (debug>0) &
       WRITE (*,*) '++ PDAF-debug: ', debug, 'PDAF_letkf_analysis -- START'

  CALL PDAF_timeit(51, 'old')


! ************************
! *** Compute residual ***
! ***   d = y - H x    ***
! ************************

  CALL PDAF_timeit(12, 'new')

  haveobsB: IF (dim_obs_l > 0) THEN
     ! *** The residual only exists for domains with observations ***

     ALLOCATE(resid_l(dim_obs_l))
     ALLOCATE(obs_l(dim_obs_l))
     ALLOCATE(HXbar_l(dim_obs_l))
     IF (allocflag == 0) CALL PDAF_memcount(3, 'r', 3 * dim_obs_l)

     ! Restrict mean obs. state onto local observation space
     IF (debug>0) &
          WRITE (*,*) '++ PDAF-debug: ', debug, 'PDAF_letkf_analysis -- call g2l_obs for mean'

     CALL PDAF_timeit(46, 'new')
     obs_member = 0
     CALL U_g2l_obs(domain_p, step, dim_obs_f, dim_obs_l, HXbar_f, HXbar_l)
     CALL PDAF_timeit(46, 'old')

     ! get local observation vector
     IF (debug>0) &
          WRITE (*,*) '++ PDAF-debug: ', debug, 'PDAF_letkf_analysis -- call init_obs_l'

     CALL PDAF_timeit(47, 'new')
     CALL U_init_obs_l(domain_p, step, dim_obs_l, obs_l)
     CALL PDAF_timeit(47, 'old')

     ! Get residual as difference of observation and observed state
     CALL PDAF_timeit(51, 'new')
     resid_l = obs_l - HXbar_l
     CALL PDAF_timeit(51, 'old')

     IF (debug>0) &
          WRITE (*,*) '++ PDAF-debug PDAF_letkf_analysis:', debug, '  innovation d_l', resid_l

  END IF haveobsB

  ! Omit observations with too high innovation
  IF (omi_omit_obs) CALL PDAFomi_omit_by_inno_l_cb(domain_p, dim_obs_l, resid_l, obs_l)

  CALL PDAF_timeit(12, 'old')


! **********************************************
! ***   Compute analyzed matrix Ainv         ***
! ***                                        ***
! ***     -1                 T  -1           ***
! ***    A  = forget I + (HZ)  R   HZ        ***
! **********************************************

  CALL PDAF_timeit(10, 'new')

  haveobsA: IF (dim_obs_l > 0) THEN
     ! *** The contribution of observation matrix ist only ***
     ! *** computed for domains with observations          ***

     CALL PDAF_timeit(30, 'new')

     ! *** Compute HZ = [Hx_1 ... Hx_N] T
     ALLOCATE(HZ_l(dim_obs_l, dim_ens))
     IF (allocflag == 0) CALL PDAF_memcount(3, 'r', dim_obs_l * dim_ens)

     CALL PDAF_timeit(46, 'new')

     IF (debug>0) &
          WRITE (*,*) '++ PDAF-debug: ', debug, 'PDAF_letkf_analysis -- call g2l_obs', dim_ens, 'times'

     ENS: DO member = 1, dim_ens
        ! Store member index
        obs_member = member

        ! [Hx_1 ... Hx_N] for local analysis domain
        CALL U_g2l_obs(domain_p, step, dim_obs_f, dim_obs_l, HX_f(:, member), &
             HZ_l(:, member))
     END DO ENS

     CALL PDAF_timeit(46, 'old')

     ! *** Set the value of the forgetting factor  ***
     ! *** Inserted here, because HZ_l is required ***
     CALL PDAF_timeit(51, 'new')
     IF (type_forget == 2) THEN
        CALL PDAF_set_forget_local(domain_p, step, dim_obs_l, dim_ens, HZ_l, &
             HXbar_l, resid_l, obs_l, U_init_n_domains_p, U_init_obsvar_l, &
             forget)
     ENDIF
     DEALLOCATE(HXbar_l)

     ! Subtract ensemble mean: HZ = [Hx_1 ... Hx_N] T
     CALL PDAF_etkf_Tright(dim_obs_l, dim_ens, HZ_l)

     IF (debug>0) &
          WRITE (*,*) '++ PDAF-debug PDAF_letkf_analysis:', debug, '  HXT_l', HZ_l(:, 1:dim_ens-1)

     CALL PDAF_timeit(51, 'old')
     CALL PDAF_timeit(30, 'old')
     CALL PDAF_timeit(31, 'new')


     ! ***                RiHZ = Rinv HZ                
     ! *** This is implemented as a subroutine thus that
     ! *** Rinv does not need to be allocated explicitly.
     IF (debug>0) &
          WRITE (*,*) '++ PDAF-debug: ', debug, 'PDAF_letkf_analysis -- call prodRinvA_l'

     ALLOCATE(RiHZ_l(dim_obs_l, dim_ens))
     IF (allocflag == 0) CALL PDAF_memcount(3, 'r', dim_obs_l * dim_ens)

     CALL PDAF_timeit(48, 'new')
     CALL U_prodRinvA_l(domain_p, step, dim_obs_l, dim_ens, obs_l, HZ_l, RiHZ_l)
     CALL PDAF_timeit(48, 'old')

     IF (debug>0) &
          WRITE (*,*) '++ PDAF-debug PDAF_letkf_analysis:', debug, '  R^-1(HXT_l)', RiHZ_l

     DEALLOCATE(obs_l)
 
     CALL PDAF_timeit(51, 'new')

     ! *** Initialize Ainv = (N-1) I ***
     Ainv_l = 0.0
     DO i = 1, dim_ens
        Ainv_l(i, i) = REAL(dim_ens - 1)
     END DO

     ! ***             T        ***
     ! ***  Compute  HZ  RiHZ   ***

     ALLOCATE(tmp_Ainv_l(dim_ens, dim_ens))
     IF (allocflag == 0) CALL PDAF_memcount(3, 'r', dim_ens**2)

     CALL gemmTYPE('t', 'n', dim_ens, dim_ens, dim_obs_l, &
          1.0, HZ_l, dim_obs_l, RiHZ_l, dim_obs_l, &
          0.0, tmp_Ainv_l, dim_ens)

     DEALLOCATE(HZ_l)
     CALL PDAF_timeit(51, 'old')

  ELSE haveobsA
     ! *** For domains with dim_obs_l=0 there is no ***
     ! *** direct observation-contribution to Ainv  ***

     CALL PDAF_timeit(31, 'new')
     CALL PDAF_timeit(51, 'new')

     ! *** Initialize Ainv = (N-1) I ***
     Ainv_l = 0.0
     DO i = 1, dim_ens
        Ainv_l(i, i) = REAL(dim_ens - 1)
     END DO

     ! No observation-contribution to Ainv from this domain
     ALLOCATE(tmp_Ainv_l(dim_ens, dim_ens))
     IF (allocflag == 0) CALL PDAF_memcount(3, 'r', dim_ens**2)

     tmp_Ainv_l = 0.0

     CALL PDAF_timeit(51, 'old')

  END IF haveobsA

  ! *** Complete computation of Ainv  ***
  ! ***   -1          -1    T         ***
  ! ***  A  = forget A  + HZ RiHZ     ***
  CALL PDAF_timeit(51, 'new')
  Ainv_l = forget * Ainv_l + tmp_Ainv_l
  CALL PDAF_timeit(51, 'old')

  IF (debug>0) &
       WRITE (*,*) '++ PDAF-debug PDAF_letkf_analysis:', debug, '  A^-1_l', Ainv_l

  CALL PDAF_timeit(31, 'old')
  CALL PDAF_timeit(10, 'old')


! ***********************************************
! *** Compute weight for model state update   ***
! ***                                         ***
! ***              T                    f     ***
! ***    w = A RiHZ d  with d = (y - H x )    ***
! ***                                         ***
! ***********************************************

  CALL PDAF_timeit(13, 'new')
  CALL PDAF_timeit(51, 'new')

  ! *** Compute RiHZd = RiHZ^T d ***
  ALLOCATE(RiHZd_l(dim_ens))
  IF (allocflag == 0) CALL PDAF_memcount(3, 'r', dim_ens)

  haveobsC: IF (dim_obs_l > 0) THEN
     ! *** RiHLd_p/=0 only with observations ***

     CALL gemvTYPE('t', dim_obs_l, dim_ens, 1.0, RiHZ_l, &
          dim_obs_l, resid_l, 1, 0.0, RiHZd_l, 1)

     IF (debug>0) &
          WRITE (*,*) '++ PDAF-debug PDAF_letkf_analysis:', debug, '  (HXT_l R^-1)^T d_l', RiHZd_l

     DEALLOCATE(RiHZ_l, resid_l)

  ELSE haveobsC

     RiHZd_l = 0.0

  END IF haveobsC


  ! *** Compute weight vector for state analysis:        ***
  ! ***          w = A RiHZd                             ***
  ! *** Use singular value decomposition of Ainv         ***
  ! ***        Ainv = ASB^T                              ***
  ! *** Then: A = A S^(-1) B                             ***
  ! *** The decomposition is also used for the symmetric ***
  ! *** square-root for the ensemble transformation.     ***

  ! *** Invert Ainv using SVD
  ALLOCATE(svals(dim_ens))
  ALLOCATE(work(3 * dim_ens))
  ldwork = 3 * dim_ens
  IF (allocflag == 0) CALL PDAF_memcount(3, 'r', 3 * dim_ens)

  IF (debug>0) &
       WRITE (*,*) '++ PDAF-debug PDAF_letkf_analysis:', debug, &
       '  Compute eigenvalue decomposition of A^-1_l'

  ! Compute EVD of Ainv
  CALL syevTYPE('v', 'l', dim_ens, Ainv_l, dim_ens, svals, work, ldwork, syev_info)

  DEALLOCATE(work)

  ! *** check if SVD was successful
  IF (syev_info == 0) THEN
     IF (debug>0) &
          WRITE (*,*) '++ PDAF-debug PDAF_letkf_analysis:', debug, '  eigenvalues', svals

     flag = 0
  ELSE
     WRITE (*, '(/5x, a, i10, a/)') &
          'PDAF-ERROR(1): Domain ', domain_p, ' Problem in EVD of inverse of A !!!'
     flag = 1
  END IF

  ! *** Compute w = A RiHZd stored in RiHZd
  check0: IF (flag == 0) THEN

     ALLOCATE(VRiHZd_l(dim_ens))
     IF (allocflag == 0) CALL PDAF_memcount(3, 'r', dim_ens)

     CALL gemvTYPE('t', dim_ens, dim_ens, 1.0, Ainv_l, &
          dim_ens, RiHZd_l, 1, 0.0, VRiHZd_l, 1)
     
     DO row = 1, dim_ens
        VRiHZd_l(row) = VRiHZd_l(row) / svals(row)
     END DO
  
     CALL gemvTYPE('n', dim_ens, dim_ens, 1.0, Ainv_l, &
          dim_ens, VRiHZd_l, 1, 0.0, RiHZd_l, 1)

     DEALLOCATE(VRiHZd_l)

     IF (debug>0) &
          WRITE (*,*) '++ PDAF-debug PDAF_letkf_analysis:', debug, '  A(HXT_l R^-1)^T d_l', RiHZd_l

  END IF check0

  CALL PDAF_timeit(51, 'old')
  CALL PDAF_timeit(13, 'old')


! ************************************************
! ***     Transform state ensemble             ***
! ***              a   _f   f                  ***
! ***             X  = X + X  W                ***
! *** The weight matrix W is stored in Ainv_l. ***
! ************************************************

! *** Prepare weight matrix for ensemble transformation ***

  CALL PDAF_timeit(51, 'new')
  check1: IF (flag == 0) THEN

     IF (mype == 0 .AND. screen > 0 .AND. screenout) THEN
        WRITE (*, '(a, 5x, a)') 'PDAF', 'Perform ensemble transformation'
     END IF

     CALL PDAF_timeit(20, 'new')

     ! Part 1: square-root of A
     DO col = 1, dim_ens
        DO row = 1, dim_ens
           tmp_Ainv_l(row, col) = Ainv_l(row, col) / SQRT(svals(col))
        END DO
     END DO

     ALLOCATE(Asqrt_l(dim_ens, dim_ens))
     IF (allocflag == 0) CALL PDAF_memcount(3, 'r', dim_ens**2)

     sqrtNm1 = SQRT(REAL(dim_ens-1))
     CALL gemmTYPE('n', 't', dim_ens, dim_ens, dim_ens, &
          sqrtNm1, tmp_Ainv_l, dim_ens, Ainv_l, dim_ens, &
          0.0, Asqrt_l, dim_ens)


     ! Part 2 - Optional 
     ! Multiply by orthogonal random matrix with eigenvector (1,...,1)^T
     multrnd: IF (type_trans == 2) THEN
        CALL gemmTYPE('n', 'n', dim_ens, dim_ens, dim_ens, &
             1.0, Asqrt_l, dim_ens, rndmat, dim_ens, &
             0.0, tmp_Ainv_l, dim_ens)
     ELSE
        ! Non-random case
        tmp_Ainv_l = Asqrt_l
     END IF multrnd


     ! Part 3: W = sqrt(A) + w
     DO col = 1, dim_ens
        DO row = 1, dim_ens
           Ainv_l(row, col) = tmp_Ainv_l(row, col) + RiHZd_l(row)
        END DO
     END DO

     DEALLOCATE(tmp_Ainv_l, svals)
     DEALLOCATE(RiHZd_l, Asqrt_l)
      
     ! Part 4: T W
     CALL PDAF_etkf_Tleft(dim_ens, dim_ens, Ainv_l)

     IF (debug>0) &
          WRITE (*,*) '++ PDAF-debug PDAF_letkf_analysis:', debug, '  transform', Ainv_l

     CALL PDAF_timeit(20, 'old')


! *** Perform ensemble transformation ***

     ! Use block formulation for transformation
     maxblksize = 200
     IF (mype == 0 .AND. screen > 0 .AND. screenout) &
          WRITE (*, '(a, 5x, a, i5)') &
          'PDAF', '--- use blocking with size ', maxblksize

     ALLOCATE(ens_blk(maxblksize, dim_ens))
     IF (allocflag == 0) CALL PDAF_memcount(4, 'r', maxblksize * dim_ens)

     blocking: DO blklower = 1, dim_l, maxblksize

        blkupper = MIN(blklower + maxblksize - 1, dim_l)

        ! Store forecast ensemble
        CALL PDAF_timeit(21, 'new')
        DO col = 1, dim_ens
           ens_blk(1 : blkupper - blklower + 1, col) &
                = ens_l(blklower : blkupper, col)
        END DO

        ! Store mean forecast in ensemble matrix
        DO col = 1, dim_ens
           ens_l(blklower : blkupper, col) = state_l(blklower : blkupper)
        END DO
        CALL PDAF_timeit(21, 'old')

        !                        a  _f   f
        ! Transform ensemble:   X = X + X  TW
        CALL PDAF_timeit(22, 'new')

        CALL gemmTYPE('n', 'n', blkupper - blklower + 1, dim_ens, dim_ens, &
             1.0, ens_blk, maxblksize, Ainv_l, dim_ens, &
             1.0, ens_l(blklower, 1), dim_l)

        CALL PDAF_timeit(22, 'old')

     END DO blocking
        
     DEALLOCATE(ens_blk)

  END IF check1

  CALL PDAF_timeit(51, 'old')


! ********************
! *** Finishing up ***
! ********************

  IF (allocflag == 0) allocflag = 1

  ! Store domain index
  lastdomain = domain_p

  IF (debug>0) &
       WRITE (*,*) '++ PDAF-debug: ', debug, 'PDAF_letkf_analysis -- END'

END SUBROUTINE PDAF_letkf_analysis_T
