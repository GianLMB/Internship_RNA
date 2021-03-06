!This is the main program for Molecular dynamics code with OPEP
!
! Copyright Normand Mousseau January 2006


!******************************************************************************
!> @brief  Initialises various parameters as well as the velocities.
!******************************************************************************
subroutine initialise_md(restart_time,conformation)
  use defs
  use random
  use md_defs
  use geometric_corrections
  use writetofile
  use md_initialise
  use restart_module
  use md_utils
  use md_statistics
  use constraints

  implicit none

  logical :: success
  integer :: i, ierror, id
  real(8) :: temperature
  real(8) :: energyscale

  integer(8), intent(out) :: restart_time
  type (t_conformations), intent(inout) :: conformation

  character(len=100) :: fname

  character(30) :: lpath
  lpath = conformation%path
  open(501, file=trim(lpath)//"std_out", position="APPEND")
      
  ! Initialise - parameters and velocities
  id      = conformation%id
  logfile = conformation%logfile 
  energyscale = conformation%energyscale
  call initialise(conformation)

!!!!##############################       metadynamics      ####################################

  ! begin PLUMED 
!!!RL  if(meta_on) call initialise_metadynamics(lpath,logfile,meta_filename)
  ! end PLUMED 

  ! Minimize the structure until the force threshold is reached
  if (restart .ne. 'restart') then
    fname = trim(conformation%path) // 'energies.log'
    open(unit=62,file=fname,status='replace')
    write(62,'(14(a10, 1x))') "#  bond" , "angle", "torsion", "Eelec",&
     "evdw", "ehhb", "ehbr", "Ecoop", "Estak", "Econst", "nFconst",&
     "Etot", "Etot*scal", "Esaxs"
    write(62,*) "# Minimization"

    ! We define the initial configuration as the reference configuration
    posref = pos
    call initialise_minimization()
    posref = pos

    call calcforce(energyscale,pos,force,total_energy)
    
    posref = pos

    fname = trim(conformation%path) // 'relaxation.pdb'
    i = 0
    do
       if(MINIMIZATION_TYPE=='MIN_damped') then
          call min_converge(success,logfile,fname)        
       else
          if(use_ics)then
             call bodies
          endif
          call min_converge1(success,logfile,fname)
       endif
       if (success) exit ! SHOULD CALL SOME FINALIZATION DEALLOCATING EVERYTHING, MAYBEil bandito e il campione
       if (i .eq. 10 ) then
          open(unit=FLOG,file=LOGFILE,status='unknown',action='write',position='append',iostat=ierror)
          write(FLOG,*) 'Minimization failed after 10 calls.'
          close(flog)
          exit
       endif
       i = i + 1
    enddo
    posref =pos
    fname = trim(conformation%path) // 'relaxed_conformation.pdb'
    call write_to_file('relaxe',id,natoms,pos,posref,ndigits_filename,fname, i,temperature, & 
                       total_energy,.true.,singlefile)
     
    close(62)
    ! If we have set up constraints or restraints, we define them and compute their
    ! value at the initial minimum
    if (constrained_fragments.or.restrained_fragments) then
        call set_harmonic_constraints(natoms,posref)
        call harmonic_constraints(natoms,pos,force,total_energy)
    end if
      
    ! Copy the positions and other values to the conformation structure - necessary 
    ! for replica
    conformation%pos(:) = pos(:)
    conformation%vel(:) = vel(:)
    conformation%posref(:) = posref(:)
    conformation%energy = total_energy
    conformation%counter = mincounter
  else
    call calcforce(energyscale,pos,force,total_energy)
  endif
  
  ! Copy the temperature to each replica
  allocate(conformation%temperatures(n_steps_thermalization))
  conformation%temperatures(:) = temperatures(:)
  restart_time = restart_simulation_time
  
  if (restart .ne. 'restart') call finilise_minimization()

  return
end subroutine initialise_md

!******************************************************************************
!> @brief   Thermalizes the configurations by heating by stages.
!******************************************************************************
subroutine thermalize_md(conformation)
  use defs
  use random
  use md_defs
  use geometric_corrections
  use writetofile
  use md_initialise
  use restart_module
  use md_utils
  use md_statistics
  use constraints

  implicit none

  logical :: decrease_k_spring = .false.
  logical :: flag_header = .true.
  integer :: ierror, ithermalize, id
  integer(8) :: nstep
  real(8) :: temperature
  real(8) :: constrained_energy
  real(8) :: decrease_factor, energyscale
  type (t_conformations), intent(inout) :: conformation

  character(len=100) :: fname
  character(len=20)  :: thermal_bath
  character(len=20)  :: status_average = 'average'
  character(len=20)  :: status_accumulate = 'accumulate'
  character(len=20)  :: status_initialise = 'initialise'

  open(501, file=trim(conformation%path)//"std_out", position="APPEND")

  fname = trim(conformation%path) // 'energies.log'
  open(unit=62,file=fname,status='old',position='append')
  write(62,*) "# Thermalization"

  energyscale = conformation%energyscale

  ! Remove the Center of mass, total and angular momentum
  call center_of_mass(natoms,pos,mass)  !!!RL
  call remove_total_momentum(natoms,vel,mass)
  call remove_rotation(natoms,pos,vel,mass)

  ! Initialise the constrained energy
  constrained_energy = 0.0d0

  !
  ! We now start the MD simulations to equilibrate
  !
  LOGFILE = conformation%logfile 
  id = conformation%id
  ! Make sure that the statistics are at zero
  open(unit=FLOG,file=LOGFILE,status='unknown',action='write',position='append',iostat=ierror)

  ! We use a rescaled velocity during the thermalization
  thermal_bath = 'rescale_vel'

  !
  ! Loop on temperature, when we need to thermalize slowly
  !
  temperatures(:) = conformation%temperatures(:) ! Copy back to local
  do ithermalize=1, n_steps_thermalization

     ! If we have fixed restrained_fragments, then we slowly release the constraint
     ! during the last thermalization. The spring constant is reduced to zero, linearly
     ! in the first half of the simulation
     if (restrained_fragments .and. (ithermalize .eq. n_steps_thermalization)) then
             decrease_k_spring = .true.
             decrease_factor = k_spring / (0.95d0 * n_equilibration)                 
     end if 

     ! Copy the actual value of temperature
     temperature = temperatures(ithermalize)  

     ! We then rescale the velocities
     call scale_velocities(thermal_bath, temperature)

     ! And set the counters at zero
     nstep = 0
     write(FLOG,*) 'Thermalization at T=', temperature
     call statistics(nstep, status_initialise, constrained_energy, flag_header)     

     do nstep =1, n_equilibration
        ! Rescale the spring constant associated with the constraint if the 
        ! restrained option has been selected
        if (decrease_k_spring) k_spring = max(0.0d0, k_spring -decrease_factor )
       
        ! If we have set-up a sphere, apply the confining condition
        if (confining_sphere .and. mod(nstep,25).eq.0)  call confine_in_sphere()


        ! If requested, remove center of mass and total momentum
        if (n_correct_com .gt. 0) then
           if( mod(nstep,n_correct_com).eq.0) then
              call center_of_mass(natoms,pos,mass) !!!RL
              call remove_total_momentum(natoms,vel,mass)
           endif
        endif

        ! Remove also, if requested, the rotation
        if (n_correct_rotation.gt.0) then 
           if( mod(nstep,n_correct_rotation).eq.0) then
              if (.not.(constrained_fragments.or.restrained_fragments)) then
                 call remove_rotation(natoms,pos,vel,mass)
              end if
           end if
        endif

        ! Rescale velocities if needed
        if (mod(nstep,n_rescale_v_equil) .eq. 0) then
            call scale_velocities(thermostat, temperature)
        endif

        ! Performs a velocity Verlet step
        call integrate_log(energyscale, constrained_energy, (mod(nstep,n_stats) .eq. 0), 0.0d0)
        ! We now compute the statistics
        if ( mod(nstep,n_stats) .eq. 0 ) then
          call statistics(nstep,status_accumulate, constrained_energy)
        endif
 
     end do

     ! The positions at the end of thermalization are considered the reference point for RMSD calculations
!     posref = pos
     ! Write the statistics 
     call statistics(nstep,status_average)
     call statistics(nstep,status_initialise) 
     fname =  trim(conformation%path) //'thermalize_'
     call write_to_file('thermalize',id,natoms,pos,posref,ndigits_filename,fname, &
    &  ithermalize,temperature, total_energy,save_unrotated_structures,singlefile)

     fname =  trim(conformation%path) // COUNTER
     open(unit=FCOUNTER,file=fname,status='unknown',action='write',iostat=ierror)
     write(FCOUNTER,'(A13,I6)') 'filecounter: ', conformation%counter
     close(FCOUNTER)     
  enddo
  ! End of loop on temperature for thermalizing
 
  write(FLOG,*) 'End of thermalization'
  write(FLOG,*) '****************************************************************************'
  write(FLOG,*) ' '
  write(FLOG,*) ' '
  write(FLOG,*) 'Begin production run'
  write(FLOG,*) '****************************************************************************'

  ! Save information for a restart
  call save_restart(restart_simulation_time,conformation)
  
  ! Copy back the data into the shared space
  conformation%pos(:) = pos(:)
  conformation%vel(:) = vel(:)
  conformation%posref(:) = posref(:)
  conformation%energy = total_energy

  write(62,*) "# Production"
  close(62)
  return
end subroutine thermalize_md

!******************************************************************************
!> @brief  Main MD production loop
!******************************************************************************
subroutine run_md(current_step, final_step, conformation)
  use fileio
  use defs
  use random
  use md_defs
  use geometric_corrections
  use writetofile
  use md_initialise
  use restart_module
  use md_utils
  use md_statistics
  use constraints
  use energies
  use RNAnb

  implicit none

  logical :: flag_header = .true.
  integer :: ierror, id
  real(8) :: temperature
  real(8) :: runtime, total_runtime, constrained_energy
  real(8) :: energyscale
  logical :: logener

  integer, intent(in) :: current_step
  type (t_conformations), intent(inout) :: conformation

  integer(8) :: nstep, init_step, final_step
  character(len=100) :: fname
  character(len=20)  :: status_average = 'average'
  character(len=20)  :: status_accumulate = 'accumulate'
  character(len=20)  :: status_initialise = 'initialise'

  ! Opens the std-out file for saving some useful information in case of problems
  character(30) :: lpath
  lpath = conformation%path
!  open(501, file=trim(lpath)//"std_out", position="APPEND")
 
!!!!##############################       metadynamics      ####################################
   
  !begin PLUMED 
!!!RL   if(meta_on) meta_start = .true.
  !end PLUMED 

  ! Initialise the constrained energy
  constrained_energy = 0.0d0
  
  ! Copy the data on the conformation from the central storing place
  id = conformation%id
  pos(:) = conformation%pos(:)
  vel(:) = conformation%vel(:)
  posref(:) = conformation%posref(:)
  temperature = conformation%temperature
  logfile = conformation%logfile 
  energyscale = conformation%energyscale

  open(unit=FLOG,file=LOGFILE,status='unknown',action='write',position='append',iostat=ierror)
  
  ! ... set the counters at zero
!  if(N_REPLICA.gt.1) then   !!! RL
!    call statistics(nstep,status_initialise, constrained_energy, flag_header)
!  else
!    call statistics(nstep,status_initialise, constrained_energy, flag_header)
!  endif

  init_step = current_step +1


!  Remove the Center of mass, total and angular momentum
  call center_of_mass(natoms,pos,mass)
  call remove_total_momentum(natoms,vel,mass) !!!RL
  call remove_rotation(natoms,pos,vel,mass) !!!RL

  fname = trim(conformation%path) // 'energies.log'
  !testf(fname)
  open(unit=62,file=fname,status='unknown',position='append')

  !
  ! Main loop for production
  ! 

  ! Titration
  do nstep = init_step, final_step
   
     flag_tit=0                          !Br2 flag for titration time
     if(mod(nstep,n_steps_tit) .eq. 0) then
        flag_tit=1
     endif

     ! Rescale velocities if needed
     if(thermo)  call scale_velocities(thermostat,temperature)

     ! SAXS variables for serial calculation
     calc_SAXS_force =.false.
     calc_SAXS_modul = .false. 
     !PRINT*, nstep
     if (saxs_serial_step .gt. 0) then
        if (modulate_saxs_serial) then
            if (nstep .le. SAXS_wave) then
                if (nstep .gt. 0) then
                    calc_SAXS_force = .true.
                    calc_SAXS_modul = .true.
                    SAXS_modstep = nstep / SAXS_wave
                    SAXS_onoff = nstep / saxs_serial_step
                else
                    calc_SAXS_force = .true.
                endif
            endif
        else
            calc_SAXS_force = (mod(nstep, saxs_serial_step) .eq. 0)
        endif
     endif
     !calc_SAXS_force = (saxs_serial_step .gt. 0) .and. (mod(nstep, saxs_serial_step) .eq. 0)
     logener = (mod(nstep,n_stats) .eq. 0)

     ! Perform the integration 
     call integrate_log(energyscale, constrained_energy, logener, nstep*timestep*timeunit/1.0e6)
!     call integrate(energyscale, constrained_energy)
    
     ! If we have set-up a sphere, applying the confining condition
     ! confine_in_sphere preserves the value of the momentum of the atoms to be bounced
     ! but does not preserve the total momentum of the system
     if (confining_sphere .and.  mod(nstep,25).eq.0)  call confine_in_sphere()
    

     !Remove center of mass displacement, total momentum and the unwanted rotation
     if (n_correct_com .gt.0) then
         if( mod(nstep,n_correct_com).eq.0) then
            call center_of_mass(natoms,pos,mass) !!!RL
            call remove_total_momentum(natoms,vel,mass)
         endif
     endif
     if (n_correct_rotation .gt. 0) then
        if( mod(nstep,n_correct_rotation).eq.0) then
           if (.not.constrained_fragments) call remove_rotation(natoms,pos,vel,mass)
        endif
     endif

#ifdef IMD_SIMULATION
     if (is_imd) then
        ! Interactive Molecular Dynamics
        call interactor_synchronize(pos, imd_forces, &
        natoms, nstep, total_energy, &
        conformation%temperature / 0.59227 * 298, ehhb, Estak, evdw)
     endif
#endif

     if (use_tit) then 
        if(flag_tit .eq. 1) then
 !          print *, 'titration step',  nstep
           call titration(nstep)
        endif
     endif

     ! We now compute the statistics
     if ( mod(nstep,n_stats_average) .eq. 0 ) then
        call statistics(nstep,status_accumulate, constrained_energy)
        call statistics(nstep,status_average)
        call statistics(nstep,status_initialise, constrained_energy, flag_header)        
      else if (  mod(nstep,n_stats) .eq. 0  ) then
        call statistics(nstep,status_accumulate, constrained_energy)
      endif

     if (mod(nstep,n_save_configs) .eq.0) then
        runtime=nstep*timestep*timeunit/1.0e6
        total_runtime = runtime + initial_simulation_time
        fname =  trim(conformation%path) // FINAL
        call write_to_file('production',id,natoms,pos,posref,ndigits_filename,fname,conformation%counter,&
             total_runtime, total_energy,save_unrotated_structures,singlefile)
        
        conformation%counter = conformation%counter+1
        fname =  trim(conformation%path) // COUNTER
        open(unit=FCOUNTER,file=fname,status='unknown',action='write',iostat=ierror)
        write(FCOUNTER,'(A13,I6)') 'filecounter: ', conformation%counter
        close(FCOUNTER)
        ! temperature = target_temperature
        if (temperature .ne. conformation%temperature) write(*,*) 'temperature !!!!: ', temperature
     endif

     ! If this is a serial simulation, we must save the restart information in this 
     ! loop. If this is a replica simulation, restart info is saved in the replica loop.
     if( (mod(nstep,n_save_restarts) .eq. 0) .and. (SIMULATION_TYPE .eq. 'serial')  ) then
       conformation%pos(:) = pos(:)
       conformation%vel(:) = vel(:)
       conformation%posref(:) = posref(:)
       conformation%energy = total_energy
       call save_restart(nstep,conformation)
     endif
  end do

  close(FLOG)
  close(FTIT)
  close(FTITpc)
  close(HBFILE)
  close(62)

  conformation%pos(:) = pos(:)
  conformation%vel(:) = vel(:)
  conformation%posref(:) = posref(:)
  conformation%energy = total_energy
  return
end subroutine run_md

!!!!#####################################    metadynamics       #######################

 ! begin PLUMED 
!!!RL subroutine initialise_metadynamics(path_dir,log_file,meta_input) 
!!!RL    use md_defs
!!!RL    implicit none
!!!RL    real(8) :: ddt 
!!!RL    integer :: pbc_opep,nrepl
!!!RL    real(8) :: rte0,rteio
!!!RL    character(len=30) :: path_dir
!!!RL    character(len=20) :: log_file
!!!RL    character(len=20) :: meta_input 
 
!!!RL    ddt = timeunit * timestep 
!!!RL    if(PBC) then
!!!RL     pbc_opep = 1
!!!RL    else
!!!RL     pbc_opep = 0
!!!RL    endif
 
!!!RL    if(ntasks.eq.1) then
!!!RL      nrepl = 1
!!!RL      rte0  = target_Temperature * 298 / 0.59227
!!!RL      rteio = rte0 
!!!RL    else
!!!RL      nrepl = N_REPLICA 
!!!RL      rte0  = T_replica(1) * 298 / 0.59227
!!!RL      rteio = T_replica(taskid+1) * 298 / 0.59227
!!!RL    endif
   
!!!RL    allocate(meta_force(3*natoms))
!!!RL    call init_metadyn(natoms,ddt,pbc_opep,taskid,nrepl,rte0,rteio,mass,trim(path_dir)//char(0),trim(log_file)//char(0),trim(meta_input)//char(0))
 
!!!RL  end subroutine initialise_metadynamics 
! end PLUMED 
