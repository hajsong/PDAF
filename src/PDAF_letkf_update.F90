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
!$Id$
!BOP
!
! !ROUTINE: PDAF_letkf_update --- Control analysis update of the LETKF
!
! !INTERFACE:
SUBROUTINE  PDAF_letkf_update(step, dim_p, dim_obs_f, dim_ens, &
     state_p, Uinv, ens_p, state_inc_p, &
     U_init_dim_obs, U_obs_op, U_init_obs, U_init_obs_l, U_prodRinvA_l, &
     U_init_n_domains_p, U_init_dim_l, U_init_dim_obs_l, U_g2l_state, U_l2g_state, &
     U_g2l_obs, U_init_obsvar, U_init_obsvar_l, U_prepoststep, screen, &
     subtype, incremental, type_forget, dim_lag, sens_p, cnt_maxlag, flag)

! !DESCRIPTION:
! Routine to control the analysis update of the LETKF.
!
! The analysis is performed by first preparing several
! global quantities on the PE-local domain, like the
! observed part of the state ensemble for all local
! analysis domains on the PE-local state domain.
! Then the analysis (PDAF\_letkf\_analysis) is performed within
! a loop over all local analysis domains in the PE-local 
! state domain. In this loop, the local state and 
! observation dimensions are initialized and the global 
! state ensemble is restricted to the local analysis domain.
! In addition, the routine U\_prepoststep is called prior
! to the analysis and after the resampling outside of
! the loop over the local domains to allow the user
! to access the ensemble information.
!
! Variant for domain decomposition.
!
! !  This is a core routine of PDAF and
!    should not be changed by the user   !
!
! !REVISION HISTORY:
! 2009-07 - Lars Nerger - Initial code
! Later revisions - see svn log
!
! !USES:
  USE mpi
  USE PDAF_timer, &
       ONLY: PDAF_timeit, PDAF_time_temp
  USE PDAF_memcounting, &
       ONLY: PDAF_memcount
  USE PDAF_mod_filter, &
       ONLY: type_trans, filterstr, obs_member, forget, forget_l, &
       inloop, member_save, debug
  USE PDAF_mod_filtermpi, &
       ONLY: mype, dim_ens_l
  USE PDAF_analysis_utils, &
       ONLY: PDAF_print_domain_stats, PDAF_init_local_obsstats, PDAF_incr_local_obsstats, &
       PDAF_print_local_obsstats

  IMPLICIT NONE

! !ARGUMENTS:
! ! Variable naming scheme:
! !   suffix _p: Denotes a full variable on the PE-local domain
! !   suffix _l: Denotes a local variable on the current analysis domain
! !   suffix _f: Denotes a full variable of all observations required for the
! !              analysis loop on the PE-local domain
  INTEGER, INTENT(in) :: step        ! Current time step
  INTEGER, INTENT(in) :: dim_p       ! PE-local dimension of model state
  INTEGER, INTENT(out) :: dim_obs_f  ! PE-local dimension of observation vector
  INTEGER, INTENT(in) :: dim_ens     ! Size of ensemble
  REAL, INTENT(inout) :: state_p(dim_p)        ! PE-local model state
  REAL, INTENT(inout) :: Uinv(dim_ens, dim_ens)      ! Inverse of matrix U
  REAL, INTENT(inout) :: ens_p(dim_p, dim_ens) ! PE-local ensemble matrix
  REAL, INTENT(inout) :: state_inc_p(dim_p)    ! PE-local state analysis increment
  INTEGER, INTENT(in) :: screen      ! Verbosity flag
  INTEGER, INTENT(in) :: subtype     ! Filter subtype
  INTEGER, INTENT(in) :: incremental ! Control incremental updating
  INTEGER, INTENT(in) :: type_forget ! Type of forgetting factor
  INTEGER, INTENT(in) :: dim_lag     ! Number of past time instances for smoother
  REAL, INTENT(inout) :: sens_p(dim_p, dim_ens, dim_lag) ! PE-local smoother ensemble
  INTEGER, INTENT(inout) :: cnt_maxlag ! Count number of past time steps for smoothing
  INTEGER, INTENT(inout) :: flag     ! Status flag

! ! External subroutines 
! ! (PDAF-internal names, real names are defined in the call to PDAF)
  EXTERNAL :: U_obs_op, &    ! Observation operator
       U_init_n_domains_p, & ! Provide number of local analysis domains
       U_init_dim_l, &       ! Init state dimension for local ana. domain
       U_init_dim_obs, &     ! Initialize dimension of observation vector
       U_init_dim_obs_l, &   ! Initialize dim. of obs. vector for local ana. domain
       U_init_obs, &         ! Initialize observation vector
       U_init_obs_l, &       ! Init. observation vector on local analysis domain
       U_init_obsvar, &      ! Initialize mean observation error variance
       U_init_obsvar_l, &    ! Initialize local mean observation error variance
       U_g2l_state, &        ! Get state on local ana. domain from global state
       U_l2g_state, &        ! Init full state from state on local analysis domain
       U_g2l_obs, &          ! Restrict full obs. vector to local analysis domain
       U_prodRinvA_l, &      ! Compute product of R^(-1) with HV
       U_prepoststep         ! User supplied pre/poststep routine

! !CALLING SEQUENCE:
! Called by: PDAF_put_state_letkf
! Calls: U_prepoststep
! Calls: U_init_n_domains_p
! Calls: U_init_dim_obs
! Calls: U_obs_op
! Calls: U_init_obs
! Calls: U_init_dim_l
! Calls: U_init_dim_obs_l
! Calls: U_g2l_state
! Calls: U_l2g_state
! Calls: PDAF_set_forget
! Calls: PDAF_generate_rndmat
! Calls: PDAF_letkf_analysis
! Calls: PDAF_timeit
! Calls: PDAF_memcount
! Calls: MPI_reduce
!EOP

! *** local variables ***
  INTEGER :: i, j, member, row     ! Counters
  INTEGER :: domain_p              ! Counter for local analysis domain
  INTEGER, SAVE :: allocflag = 0   ! Flag whether first time allocation is done
  REAL    :: invdimens             ! Inverse global ensemble size
  INTEGER :: minusStep             ! Time step counter
  INTEGER :: n_domains_p           ! number of PE-local analysis domains
  REAL    :: forget_ana_l          ! forgetting factor supplied to analysis routine
  REAL    :: forget_ana            ! Possibly globally adaptive forgetting factor
  LOGICAL :: storerndmat = .FALSE. ! Store and reuse random rotation matrix
  REAL, ALLOCATABLE :: HX_f(:,:)   ! HX for PE-local ensemble
  REAL, ALLOCATABLE :: HXbar_f(:)  ! PE-local observed mean state
  REAL, ALLOCATABLE :: obs_f(:)    ! PE-local observation vector
  REAL, ALLOCATABLE :: rndmat(:,:) ! random rotation matrix for ensemble trans.
  REAL, SAVE, ALLOCATABLE :: rndmat_save(:,:) ! Stored rndmat
  ! Variables on local analysis domain
  INTEGER :: dim_l                 ! State dimension on local analysis domain
  INTEGER :: dim_obs_l             ! Observation dimension on local analysis domain
  REAL, ALLOCATABLE :: ens_l(:,:)  ! State ensemble on local analysis domain
  REAL, ALLOCATABLE :: state_l(:)  ! Mean state on local analysis domain
  REAL, ALLOCATABLE :: stateinc_l(:)  ! State increment on local analysis domain
  REAL, ALLOCATABLE :: Uinv_l(:,:) ! thread-local matrix Uinv
  REAL :: state_inc_p_dummy        ! Dummy variable to avoid compiler warning
 

! ***********************************************************
! *** For fixed error space basis compute ensemble states ***
! ***********************************************************

  IF (debug>0) &
       WRITE (*,*) '++ PDAF-debug: ', debug, 'PDAF_letkf_update -- START'

  ! Initialize variable to prevent compiler warning
  state_inc_p_dummy = state_inc_p(1)

  CALL PDAF_timeit(51, 'new')

  fixed_basis: IF (subtype == 2 .OR. subtype == 3) THEN
     ! *** Add mean/central state to ensemble members ***
     DO j = 1, dim_ens
        DO i = 1, dim_p
           ens_p(i, j) = ens_p(i, j) + state_p(i)
        END DO
     END DO
  END IF fixed_basis

  CALL PDAF_timeit(51, 'old')


! *************************************
! *** Prestep for forecast ensemble ***
! *************************************

  CALL PDAF_timeit(5, 'new')
  minusStep = - step  ! Indicate forecast by negative time step number
  IF (mype == 0 .AND. screen > 0) THEN
     WRITE (*, '(a, 5x, a, i7)') 'PDAF', 'Call pre-post routine after forecast; step ', step
  ENDIF
  CALL U_prepoststep(minusStep, dim_p, dim_ens, dim_ens_l, dim_obs_f, &
       state_p, Uinv, ens_p, flag)
  CALL PDAF_timeit(5, 'old')

  IF (mype == 0 .AND. screen > 0) THEN
     IF (screen > 1) THEN
        WRITE (*, '(a, 5x, a, F10.3, 1x, a)') &
             'PDAF ', '--- duration of prestep:', PDAF_time_temp(5), 's'
     END IF
     WRITE (*, '(a, 55a)') 'PDAF Analysis ', ('-', i = 1, 55)
  END IF


! **************************************
! *** Preparation for local analysis ***
! **************************************

#ifndef PDAF_NO_UPDATE
  CALL PDAF_timeit(3, 'new')
  CALL PDAF_timeit(4, 'new')

  IF (debug>0) THEN
     WRITE (*,*) '++ PDAF-debug PDAF_letkf_update', debug, &
          'Configuration: param_int(3) dim_lag     ', dim_lag
     WRITE (*,*) '++ PDAF-debug PDAF_letkf_update', debug, &
          'Configuration: param_int(4) -not used-  '
     WRITE (*,*) '++ PDAF-debug PDAF_letkf_update', debug, &
          'Configuration: param_int(5) type_forget ', type_forget
     WRITE (*,*) '++ PDAF-debug PDAF_letkf_update', debug, &
          'Configuration: param_int(6) type_trans  ', type_trans

     WRITE (*,*) '++ PDAF-debug PDAF_letkf_update', debug, &
          'Configuration: param_real(1) forget     ', forget
  END IF

  IF (debug>0) &
       WRITE (*,*) '++ PDAF-debug: ', debug, 'PDAF_letkf_update -- call init_n_domains'

  ! Query number of analysis domains for the local analysis
  ! in the PE-local domain
  CALL PDAF_timeit(42, 'new')
  CALL U_init_n_domains_p(step, n_domains_p)
  CALL PDAF_timeit(42, 'old')

  IF (debug>0) &
       WRITE (*,*) '++ PDAF-debug PDAF_letkf_update:', debug, '  n_domains_p', n_domains_p
  
  IF (screen > 0) THEN
     IF (mype == 0) THEN
        IF (subtype == 0 .OR. subtype == 2) THEN
           WRITE (*, '(a, i7, 3x, a)') &
                'PDAF ', step, 'Assimilating observations - LETKF analysis using T-matrix'
        ELSE IF (subtype == 1) THEN
           WRITE (*, '(a, i7, 3x, a)') &
                'PDAF ', step, 'Assimilating observations - LETKF following Hunt et al. (2007)'
        ELSE IF (subtype == 3) THEN
           WRITE (*, '(a, i7, 3x, a)') &
                'PDAF ', step, 'LETKF analysis for fixed covariance matrix'
        END IF
     END IF
     IF (screen<3) THEN
        CALL PDAF_print_domain_stats(n_domains_p)
     ELSE
        WRITE (*, '(a, 5x, a, i6, a, i10)') &
             'PDAF', '--- PE-domain:', mype, ' number of analysis domains:', n_domains_p
     END IF
  END IF


! *** Local analysis: initialize global quantities ***

  IF (debug>0) &
       WRITE (*,*) '++ PDAF-debug: ', debug, 'PDAF_letkf_update -- call init_dim_obs'

  ! Get observation dimension for all observations required 
  ! for the loop of local analyses on the PE-local domain.
  CALL PDAF_timeit(43, 'new')
  CALL U_init_dim_obs(step, dim_obs_f)
  CALL PDAF_timeit(43, 'old')

  IF (screen > 2) THEN
     WRITE (*, '(a, 5x, a, i6, a, i10)') &
          'PDAF', '--- PE-Domain:', mype, &
          ' dimension of PE-local full obs. vector', dim_obs_f
  END IF

  ! HX = [Hx_1 ... Hx_(r+1)] for full DIM_OBS_F region on PE-local domain
  ALLOCATE(HX_f(dim_obs_f, dim_ens))
  IF (allocflag == 0) CALL PDAF_memcount(3, 'r', dim_obs_f * dim_ens)

  CALL PDAF_timeit(44, 'new')

  IF (debug>0) &
       WRITE (*,*) '++ PDAF-debug: ', debug, 'PDAF_letkf_update -- call obs_op', dim_ens, 'times'

  ENS: DO member = 1,dim_ens
     ! Store member index to make it accessible with PDAF_get_obsmemberid
     obs_member = member

     ! Call observation operator
     CALL U_obs_op(step, dim_p, dim_obs_f, ens_p(:, member), HX_f(:, member))
  END DO ENS

  CALL PDAF_timeit(44, 'old')

  CALL PDAF_timeit(51, 'new')
  CALL PDAF_timeit(11, 'new')

  ! *** Compute mean forecast state
  state_p = 0.0
  invdimens = 1.0 / REAL(dim_ens)
  DO member = 1, dim_ens
     DO row = 1, dim_p
        state_p(row) = state_p(row) + invdimens * ens_p(row, member)
     END DO
  END DO

  CALL PDAF_timeit(11, 'old')

  ! *** Compute mean state of ensemble on PE-local observation space 
  ALLOCATE(HXbar_f(dim_obs_f))
  IF (allocflag == 0) CALL PDAF_memcount(3, 'r', dim_obs_f)

  HXbar_f = 0.0
  invdimens = 1.0 / REAL(dim_ens)
  DO member = 1, dim_ens
     DO row = 1, dim_obs_f
        HXbar_f(row) = HXbar_f(row) + invdimens * HX_f(row, member)
     END DO
  END DO
  CALL PDAF_timeit(51, 'old')

  ! Set forgetting factor globally
  forget_ana = forget
  IF (type_forget == 1) THEN
     ALLOCATE(obs_f(dim_obs_f))
     IF (allocflag == 0) CALL PDAF_memcount(3, 'r', dim_obs_f)

     ! get observation vector
     CALL PDAF_timeit(50, 'new')
     CALL U_init_obs(step, dim_obs_f, obs_f)
     CALL PDAF_timeit(50, 'old')

     ! Set FORGET
     CALL PDAF_set_forget(step, filterstr, dim_obs_f, dim_ens, HX_f, &
          HXbar_f, obs_f, U_init_obsvar, forget, forget_ana)
     
     DEALLOCATE(obs_f)
  ENDIF


  ! *** Initialize random transformation matrix
  CALL PDAF_timeit(51, 'new')
  CALL PDAF_timeit(33, 'new')
  ALLOCATE(rndmat(dim_ens, dim_ens))
  IF (allocflag == 0) CALL PDAF_memcount(3, 'r', dim_ens**2)

  rnd_store: IF (.NOT. storerndmat .OR. (storerndmat .AND. allocflag == 0)) THEN

     IF (type_trans == 2) THEN
        ! Initialize random matrix
        CALL PDAF_generate_rndmat(dim_ens, rndmat, 2)

        IF (debug>0) &
             WRITE (*,*) '++ PDAF-debug PDAF_letkf_update:', debug, '  rndmat', rndmat

     ELSE
        rndmat = 0.0
     END IF

     IF (storerndmat) THEN
        ALLOCATE(rndmat_save(dim_ens, dim_ens))
        IF (allocflag == 0) CALL PDAF_memcount(3, 'r', dim_ens**2)
        rndmat_save = rndmat
     END IF

  ELSE rnd_store
     ! Re-use stored rndmat
     if (mype == 0 .AND. screen > 0) &
          write (*,'(a, 5x, a)') 'PDAF', '--- Use stored random rotation matrix'
     rndmat = rndmat_save

     IF (debug>0) &
          WRITE (*,*) '++ PDAF-debug PDAF_letkf_update:', debug, '  rndmat', rndmat

  END IF rnd_store

  CALL PDAF_timeit(33, 'old')
  CALL PDAF_timeit(51, 'old')

  CALL PDAF_timeit(4, 'old')


! ************************
! *** Perform analysis ***
! ************************

  CALL PDAF_timeit(6, 'new')

  ! Initialize counters for statistics on local observations
  CALL PDAF_init_local_obsstats()

!$OMP PARALLEL default(shared) private(dim_l, dim_obs_l, ens_l, state_l, stateinc_l, Uinv_l, flag, forget_ana_l)

  forget_ana_l = forget_ana

  ! Allocate ensemble transform matrix
  ALLOCATE(Uinv_l(dim_ens, dim_ens))
  IF (allocflag == 0) CALL PDAF_memcount(3, 'r', dim_ens**2)
  Uinv_l = 0.0

  IF (debug>0 .and. n_domains_p>0) &
       WRITE (*,*) '++ PDAF-debug: ', debug, 'PDAF_letkf_update -- Enter local analysis loop'

!$OMP BARRIER
!$OMP DO firstprivate(cnt_maxlag) lastprivate(cnt_maxlag) schedule(runtime)
  localanalysis: DO domain_p = 1, n_domains_p

     ! Set flag that we are in the local analysis loop
     inloop = .true.

     ! Set forgetting factor to global standard value
     forget_l = forget_ana

     IF (debug>0) THEN
        WRITE (*,*) '++ PDAF-debug: ', debug, &
             'PDAF_letkf_update -- local analysis for domain_p', domain_p
        WRITE (*,*) '++ PDAF-debug: ', debug, 'PDAF_letkf_update -- call init_dim_l'
     END IF

     ! local state dimension
     CALL PDAF_timeit(45, 'new')
     CALL U_init_dim_l(step, domain_p, dim_l)
     CALL PDAF_timeit(45, 'old')

     IF (debug>0) THEN
        WRITE (*,*) '++ PDAF-debug PDAF_letkf_update:', debug, '  dim_l', dim_l
        WRITE (*,*) '++ PDAF-debug: ', debug, 'PDAF_letkf_update -- call init_dim_obs_l'
     END IF

     ! Get observation dimension for local domain
     CALL PDAF_timeit(9, 'new')
     dim_obs_l = 0
     CALL U_init_dim_obs_l(domain_p, step, dim_obs_f, dim_obs_l)
     CALL PDAF_timeit(9, 'old')

     IF (debug>0) &
          WRITE (*,*) '++ PDAF-debug PDAF_letkf_update:', debug, '  dim_obs_l', dim_obs_l

     CALL PDAF_timeit(51, 'new')

     ! Gather statistical information on local observations
     CALL PDAF_incr_local_obsstats(dim_obs_l)
     
     ! Allocate arrays for local analysis domain
     ALLOCATE(ens_l(dim_l, dim_ens))
     ALLOCATE(state_l(dim_l))
     ALLOCATE(stateinc_l(dim_l))
     CALL PDAF_timeit(51, 'old')

     CALL PDAF_timeit(15, 'new')

     ! state ensemble and mean state on current analysis domain
     DO member = 1, dim_ens
        ! Store member index to make it accessible with PDAF_get_memberid
        member_save = member

        IF (debug>0) then
           WRITE (*,*) '++ PDAF-debug: ', debug, &
                'PDAF_letkf_update -- call g2l_state for ensemble member', member
           if (member==1) &
                WRITE (*,*) '++ PDAF-debug: ', debug, &
                'PDAF_letkf_update --    Note: if ens_l is incorrect check user-defined indices in g2l_state!'
        END IF

        CALL U_g2l_state(step, domain_p, dim_p, ens_p(:, member), dim_l, &
             ens_l(:, member))

        IF (debug>0) &
             WRITE (*,*) '++ PDAF-debug PDAF_letkf_update:', debug, '  ens_l', ens_l(:,member)
     END DO

     ! Store member index to make it accessible with PDAF_get_memberid
     member_save = 0

     IF (debug>0) &
          WRITE (*,*) '++ PDAF-debug: ', debug, &
          'PDAF_letkf_update -- call g2l_state for ensemble mean'

     CALL U_g2l_state(step, domain_p, dim_p, state_p, dim_l, &
          state_l)

     IF (debug>0) &
          WRITE (*,*) '++ PDAF-debug PDAF_letkf_update:', debug, '  meanens_l', state_l

     CALL PDAF_timeit(15, 'old')

     CALL PDAF_timeit(7, 'new')

     ! Reset forget (can be reset with PDAF_reset_forget)
     IF (type_forget == 0) forget_ana_l = forget_l

     ! ETKF analysis
     IF (subtype == 0 .OR. subtype == 2) THEN
        ! *** LETKF analysis using T-matrix ***
        CALL PDAF_letkf_analysis_T(domain_p, step, dim_l, dim_obs_f, dim_obs_l, &
             dim_ens, state_l, Uinv_l, ens_l, HX_f, &
             HXbar_f, stateinc_l, rndmat, forget_ana_l, U_g2l_obs, &
             U_init_obs_l, U_prodRinvA_l, U_init_obsvar_l, U_init_n_domains_p, &
             screen, incremental, type_forget, flag)
     ELSE IF (subtype == 1) THEN
        ! *** ETKF analysis following Hunt et al. (2007) ***
        CALL PDAF_letkf_analysis(domain_p, step, dim_l, dim_obs_f, dim_obs_l, &
             dim_ens, state_l, Uinv_l, ens_l, HX_f, &
             HXbar_f, stateinc_l, rndmat, forget_ana_l, U_g2l_obs, &
             U_init_obs_l, U_prodRinvA_l, U_init_obsvar_l, U_init_n_domains_p, &
             screen, incremental, type_forget, flag)
     ELSE IF (subtype == 3) THEN
        ! Analysis with state update but no ensemble transformation
        CALL PDAF_letkf_analysis_fixed(domain_p, step, dim_l, dim_obs_f, dim_obs_l, &
             dim_ens, state_l, Uinv_l, ens_l, HX_f, &
             HXbar_f, stateinc_l, forget_ana_l, U_g2l_obs, &
             U_init_obs_l, U_prodRinvA_l, U_init_obsvar_l, U_init_n_domains_p, &
             screen, incremental, type_forget, flag)
     END IF

     CALL PDAF_timeit(7, 'old')
     CALL PDAF_timeit(16, 'new')
 
     ! re-initialize full state ensemble on PE and mean state from local domain
     DO member = 1, dim_ens
        member_save = member

        IF (debug>0) then
           WRITE (*,*) '++ PDAF-debug: ', debug, &
                'PDAF_letkf_update -- call l2g_state for ensemble member', member
           WRITE (*,*) '++ PDAF-debug PDAF_letkf_update:', debug, '  ens_l', ens_l(:,member)
        END IF

        CALL U_l2g_state(step, domain_p, dim_l, ens_l(:, member), dim_p, ens_p(:,member))
     END DO
     IF (subtype == 3) THEN
        ! Initialize global state for ETKF with fixed covariance matrix
        member_save = 0

        IF (debug>0) THEN
           WRITE (*,*) '++ PDAF-debug: ', debug, &
                'PDAF_letkf_update -- call l2g_state for ensemble mean'
           WRITE (*,*) '++ PDAF-debug PDAF_letkf_update:', debug, '  meanens_l', state_l
        END IF

        CALL U_l2g_state(step, domain_p, dim_l, state_l, dim_p, state_p)
     END IF
    
     ! Initialize global state increment
!      IF (incremental == 1) THEN
!         CALL U_l2g_state(step, domain_p, dim_l, stateinc_l, dim_p, state_inc_p)
!      END IF

     CALL PDAF_timeit(16, 'old')
     CALL PDAF_timeit(17, 'new')
     CALL PDAF_timeit(51, 'new')

     ! *** Perform smoothing of past ensembles ***
     CALL PDAF_smoother_local(domain_p, step, dim_p, dim_l, dim_ens, &
          dim_lag, Uinv_l, ens_l, sens_p, cnt_maxlag, &
          U_g2l_state, U_l2g_state, forget_ana, screen)

     CALL PDAF_timeit(17, 'old')

     ! clean up
     DEALLOCATE(ens_l, state_l, stateinc_l)
     CALL PDAF_timeit(51, 'old')

  END DO localanalysis

  IF (debug>0 .and. n_domains_p>0) &
       WRITE (*,*) '++ PDAF-debug: ', debug, 'PDAF_letkf_update -- End of local analysis loop'

  ! Set flag that we are not in the local analysis loop
  inloop = .false.

  CALL PDAF_timeit(51, 'new')

!$OMP CRITICAL
  ! Set Uinv - required for subtype=3
  Uinv = Uinv_l
!$OMP END CRITICAL

  DEALLOCATE(Uinv_l)
!$OMP END PARALLEL

  ! *** Print statistics for local analysis to the screen ***
  CALL PDAF_print_local_obsstats(screen)

  IF (mype == 0 .AND. screen > 0) THEN
     IF (screen > 1) THEN
        WRITE (*, '(a, 5x, a, F10.3, 1x, a)') &
             'PDAF', '--- analysis/re-init duration:', PDAF_time_temp(3), 's'
     END IF
  END IF

  CALL PDAF_timeit(51, 'old')
  CALL PDAF_timeit(6, 'old')
  CALL PDAF_timeit(3, 'old')

! *** Clean up from local analysis update ***
  DEALLOCATE(HX_f, HXbar_f, rndmat)
#else
  WRITE (*,'(/5x,a/)') &
       '!!! PDAF WARNING: ANALYSIS STEP IS DEACTIVATED BY PDAF_NO_UPDATE !!!'
#endif

! *** Poststep for analysis ensemble ***
  CALL PDAF_timeit(5, 'new')
  IF (mype == 0 .AND. screen > 0) THEN
     WRITE (*, '(a, 5x, a)') 'PDAF', 'Call pre-post routine after analysis step'
  ENDIF
  CALL U_prepoststep(step, dim_p, dim_ens, dim_ens_l, dim_obs_f, &
       state_p, Uinv, ens_p, flag)
  CALL PDAF_timeit(5, 'old')
  
  IF (mype == 0 .AND. screen > 0) THEN
     IF (screen > 1) THEN
        WRITE (*, '(a, 5x, a, F10.3, 1x, a)') &
             'PDAF', '--- duration of poststep:', PDAF_time_temp(5), 's'
     END IF
     WRITE (*, '(a, 55a)') 'PDAF Forecast ', ('-', i = 1, 55)
  END IF


! ********************
! *** Finishing up ***
! ********************

  IF (allocflag == 0) allocflag = 1

  IF (debug>0) &
       WRITE (*,*) '++ PDAF-debug: ', debug, 'PDAF_letkf_update -- END'

END SUBROUTINE PDAF_letkf_update
