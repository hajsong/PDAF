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
! !ROUTINE: PDAF_put_state_lestkf_si --- Interface to transfer state to PDAF
!
! !INTERFACE:
SUBROUTINE PDAF_put_state_lestkf_si(outflag)

! !DESCRIPTION:
! Interface routine called from the model after the 
! forecast of each ensemble state to transfer data
! from the model to PDAF. 
!
! This routine provides the simplified interface
! where names of user-provided subroutines are
! fixed. It simply calls the routine with the
! full interface using pre-defined routine names.
!
! Variant for LESTKF with domain decomposition.
!
! !  This is a core routine of PDAF and
!    should not be changed by the user   !
!
! !REVISION HISTORY:
! 2011-09 - Lars Nerger - Initial code
! Later revisions - see svn log
!
! !USES:
  IMPLICIT NONE
  
! !ARGUMENTS:
  INTEGER, INTENT(inout) :: outflag ! Status flag

! ! Names of external subroutines 
  EXTERNAL :: collect_state_pdaf, & ! Routine to collect a state vector
       obs_op_f_pdaf, &             ! Full observation operator
       init_n_domains_pdaf, &       ! Provide number of local analysis domains
       init_dim_l_pdaf, &           ! Init state dimension for local ana. domain
       init_dim_obs_f_pdaf, &       ! Initialize dimension of full observation vector
       init_dim_obs_l_pdaf, &       ! Initialize local dimimension of obs. vector
       init_obs_f_pdaf, &           ! Initialize full observation vector
       init_obs_l_pdaf, &           ! Initialize local observation vector
       init_obsvar_pdaf, &          ! Initialize mean observation error variance
       init_obsvar_l_pdaf, &        ! Initialize local mean observation error variance
       g2l_state_pdaf, &            ! Get state on local ana. domain from full state
       l2g_state_pdaf, &            ! Init full state from local state
       g2l_obs_pdaf, &              ! Restrict full obs. vector to local analysis domain
       prodRinvA_l_pdaf, &          ! Provide product R^-1 A on local analysis domain
       prepoststep_pdaf             ! User supplied pre/poststep routine

! !CALLING SEQUENCE:
! Called by: model code  
! Calls: PDAF_put_state_lestkf
!EOP


! **************************************************
! *** Call the full put_state interface routine  ***
! **************************************************

  CALL PDAF_put_state_lestkf(collect_state_pdaf, init_dim_obs_f_pdaf, &
       obs_op_f_pdaf, init_obs_f_pdaf, init_obs_l_pdaf, prepoststep_pdaf, &
       prodRinvA_l_pdaf, init_n_domains_pdaf, init_dim_l_pdaf, &
       init_dim_obs_l_pdaf, g2l_state_pdaf, l2g_state_pdaf, &
       g2l_obs_pdaf, init_obsvar_pdaf, init_obsvar_l_pdaf, outflag)
  
END SUBROUTINE PDAF_put_state_lestkf_si
