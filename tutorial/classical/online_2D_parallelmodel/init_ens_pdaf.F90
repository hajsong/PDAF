!$Id: init_ens.F90 1861 2017-12-19 07:38:48Z lnerger $
!BOP
!
! !ROUTINE: init_ens_pdaf --- Initialize ensemble
!
! !INTERFACE:
SUBROUTINE init_ens_pdaf(filtertype, dim_p, dim_ens, state_p, Uinv, &
     ens_p, flag)

! !DESCRIPTION:
! User-supplied routine for PDAF.
! Used in the filters: SEIK/LSEIK/ETKF/LETKF/ESTKF/LESTKF
!
! The routine is called when the filter is
! initialized in PDAF\_filter\_init.  It has
! to initialize an ensemble of dim\_ens states.
! Typically, the ensemble will be directly read from files.
!
! The routine is called by all filter processes and 
! initializes the ensemble for the PE-local domain.
!
! Implementation for the 2D online example
! without parallelization.
!
! !REVISION HISTORY:
! 2013-02 - Lars Nerger - Initial code based on offline_1D
! Later revisions - see svn log
!
! !USES:
  USE mod_model, &
       ONLY: nx, ny, nx_p
  USE mod_parallel_model, &
       ONLY: mype_model
  USE mod_parallel_pdaf, &
       ONLY: mype_filter

  IMPLICIT NONE

! !ARGUMENTS:
  INTEGER, INTENT(in) :: filtertype              ! Type of filter to initialize
  INTEGER, INTENT(in) :: dim_p                   ! PE-local state dimension
  INTEGER, INTENT(in) :: dim_ens                 ! Size of ensemble
  REAL, INTENT(inout) :: state_p(dim_p)          ! PE-local model state
  ! It is not necessary to initialize the array 'state_p' for SEIK. 
  ! It is available here only for convenience and can be used freely.
  REAL, INTENT(inout) :: Uinv(dim_ens-1,dim_ens-1) ! Array not referenced for SEIK
  REAL, INTENT(out)   :: ens_p(dim_p, dim_ens)   ! PE-local state ensemble
  INTEGER, INTENT(inout) :: flag                 ! PDAF status flag

! !CALLING SEQUENCE:
! Called by: PDAF_filter_init    (as U_init_ens)
!EOP

! *** local variables ***
  INTEGER :: i, j, member             ! Counters
  REAL, ALLOCATABLE :: field(:,:)     ! global model field
  CHARACTER(len=2) :: ensstr          ! String for ensemble member


! **********************
! *** INITIALIZATION ***
! **********************

  ! *** Generate full ensemble on filter-PE 0 ***
  IF (mype_filter==0) THEN
     WRITE (*, '(/9x, a)') 'Initialize state ensemble'
     WRITE (*, '(9x, a)') '--- read ensemble from files'
     WRITE (*, '(9x, a, i5)') '--- Ensemble size:  ', dim_ens
  END IF

  ! allocate memory for temporary fields
  ALLOCATE(field(ny, nx))


! ********************************
! *** Read ensemble from files ***
! ********************************

  DO member = 1, dim_ens
     WRITE (ensstr, '(i1)') member
     OPEN(11, file = '../../inputs_online/ens_'//TRIM(ensstr)//'.txt', status='old')

     ! Read global field
     DO i = 1, ny
        READ (11, *) field(i, :)
     END DO

     ! Initialize process-local part of ensemble
     DO j = 1, nx_p
        ens_p(1 + (j-1)*ny : j*ny, member) = field(1:ny, nx_p*mype_model + j)
     END DO

     CLOSE(11)
  END DO


! ****************
! *** clean up ***
! ****************

  DEALLOCATE(field)

END SUBROUTINE init_ens_pdaf
