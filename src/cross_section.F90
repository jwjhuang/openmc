module cross_section

  use algorithm,        only: binary_search
  use constants
  use error,            only: fatal_error
  use list_header,      only: ListElemInt
  use material_header,  only: Material, materials
  use math,             only: faddeeva, w_derivative, broaden_wmp_polynomials
  use multipole_header, only: FORM_RM, FORM_MLBW, MP_EA, RM_RT, RM_RA, RM_RF, &
                              MLBW_RT, MLBW_RX, MLBW_RA, MLBW_RF, FIT_T, FIT_A,&
                              FIT_F, MultipoleArray
  use nuclide_header
  use particle_header,  only: Particle
  use random_lcg,       only: prn, future_prn, prn_set_stream
  use sab_header,       only: SAlphaBeta, sab_tables
  use settings
  use simulation_header
  use tally_header,     only: active_tallies

  implicit none

contains

!===============================================================================
! CALCULATE_XS determines the macroscopic cross sections for the material the
! particle is currently traveling through.
!===============================================================================

  subroutine calculate_xs(p)

    type(Particle), intent(inout) :: p

    integer :: i             ! loop index over nuclides
    integer :: i_nuclide     ! index into nuclides array
    integer :: i_sab         ! index into sab_tables array
    integer :: j             ! index in mat % i_sab_nuclides
    integer :: i_grid        ! index into logarithmic mapping array or material
                             ! union grid
    real(8) :: atom_density  ! atom density of a nuclide
    real(8) :: sab_frac      ! fraction of atoms affected by S(a,b)
    logical :: check_sab     ! should we check for S(a,b) table?

    ! Set all material macroscopic cross sections to zero
    material_xs % total          = ZERO
    material_xs % absorption     = ZERO
    material_xs % fission        = ZERO
    material_xs % nu_fission     = ZERO

    ! Exit subroutine if material is void
    if (p % material == MATERIAL_VOID) return

    associate (mat => materials(p % material))
      ! Find energy index on energy grid
      i_grid = int(log(p % E/energy_min_neutron)/log_spacing)

      ! Determine if this material has S(a,b) tables
      check_sab = (mat % n_sab > 0)

      ! Initialize position in i_sab_nuclides
      j = 1

      ! Add contribution from each nuclide in material
      do i = 1, mat % n_nuclides
        ! ======================================================================
        ! CHECK FOR S(A,B) TABLE

        i_sab = 0
        sab_frac = ZERO

        ! Check if this nuclide matches one of the S(a,b) tables specified.
        ! This relies on i_sab_nuclides being in sorted order
        if (check_sab) then
          if (i == mat % i_sab_nuclides(j)) then
            ! Get index in sab_tables
            i_sab = mat % i_sab_tables(j)
            sab_frac = mat % sab_fracs(j)

            ! If particle energy is greater than the highest energy for the
            ! S(a,b) table, then don't use the S(a,b) table
            if (p % E > sab_tables(i_sab) % data(1) % threshold_inelastic) then
              i_sab = 0
            end if

            ! Increment position in i_sab_nuclides
            j = j + 1

            ! Don't check for S(a,b) tables if there are no more left
            if (j > size(mat % i_sab_tables)) check_sab = .false.
          end if
        end if

        ! ======================================================================
        ! CALCULATE MICROSCOPIC CROSS SECTION

        ! Determine microscopic cross sections for this nuclide
        i_nuclide = mat % nuclide(i)

        ! Calculate microscopic cross section for this nuclide
        if (p % E /= micro_xs(i_nuclide) % last_E &
             .or. p % sqrtkT /= micro_xs(i_nuclide) % last_sqrtkT &
             .or. i_sab /= micro_xs(i_nuclide) % index_sab &
             .or. sab_frac /= micro_xs(i_nuclide) % sab_frac) then
          call calculate_nuclide_xs(i_nuclide, i_sab, p % E, i_grid, &
                                    p % sqrtkT, sab_frac)
        end if

        ! ======================================================================
        ! ADD TO MACROSCOPIC CROSS SECTION

        ! Copy atom density of nuclide in material
        atom_density = mat % atom_density(i)

        ! Add contributions to material macroscopic total cross section
        material_xs % total = material_xs % total + &
             atom_density * micro_xs(i_nuclide) % total

        ! Add contributions to material macroscopic absorption cross section
        material_xs % absorption = material_xs % absorption + &
             atom_density * micro_xs(i_nuclide) % absorption

        ! Add contributions to material macroscopic fission cross section
        material_xs % fission = material_xs % fission + &
             atom_density * micro_xs(i_nuclide) % fission

        ! Add contributions to material macroscopic nu-fission cross section
        material_xs % nu_fission = material_xs % nu_fission + &
             atom_density * micro_xs(i_nuclide) % nu_fission
      end do
    end associate

  end subroutine calculate_xs

!===============================================================================
! CALCULATE_NUCLIDE_XS determines microscopic cross sections for a nuclide of a
! given index in the nuclides array at the energy of the given particle
!===============================================================================

  subroutine calculate_nuclide_xs(i_nuclide, i_sab, E, i_log_union, sqrtkT, &
                                  sab_frac)
    integer, intent(in) :: i_nuclide   ! index into nuclides array
    integer, intent(in) :: i_sab       ! index into sab_tables array
    real(8), intent(in) :: E           ! energy
    integer, intent(in) :: i_log_union ! index into logarithmic mapping array or
                                       ! material union energy grid
    real(8), intent(in) :: sqrtkT      ! square root of kT, material dependent
    real(8), intent(in) :: sab_frac    ! fraction of atoms affected by S(a,b)

    logical :: use_mp ! true if XS can be calculated with windowed multipole
    integer :: i_temp ! index for temperature
    integer :: i_grid ! index on nuclide energy grid
    integer :: i_low  ! lower logarithmic mapping index
    integer :: i_high ! upper logarithmic mapping index
    integer :: i_rxn  ! reaction index
    integer :: j      ! index in DEPLETION_RX
    real(8) :: f      ! interp factor on nuclide energy grid
    real(8) :: kT     ! temperature in eV
    real(8) :: sig_t, sig_a, sig_f ! Intermediate multipole variables

    ! Initialize cached cross sections to zero
    micro_xs(i_nuclide) % elastic         = CACHE_INVALID
    micro_xs(i_nuclide) % thermal         = ZERO
    micro_xs(i_nuclide) % thermal_elastic = ZERO

    associate (nuc => nuclides(i_nuclide))
      ! Check to see if there is multipole data present at this energy
      use_mp = .false.
      if (nuc % mp_present) then
        if (E >= nuc % multipole % start_E .and. &
             E <= nuc % multipole % end_E) then
          use_mp = .true.
        end if
      end if

      ! Evaluate multipole or interpolate
      if (use_mp) then
        ! Call multipole kernel
        call multipole_eval(nuc % multipole, E, sqrtkT, sig_t, sig_a, sig_f)

        micro_xs(i_nuclide) % total = sig_t
        micro_xs(i_nuclide) % absorption = sig_a
        micro_xs(i_nuclide) % fission = sig_f

        if (nuc % fissionable) then
          micro_xs(i_nuclide) % nu_fission = sig_f * nuc % nu(E, EMISSION_TOTAL)
        else
          micro_xs(i_nuclide) % nu_fission = ZERO
        end if

        if (need_depletion_rx) then
          ! Initialize all reaction cross sections to zero
          micro_xs(i_nuclide) % reaction(:) = ZERO

          ! Only non-zero reaction is (n,gamma)
          micro_xs(i_nuclide) % reaction(4) = sig_a - sig_f
        end if

        ! Ensure these values are set
        ! Note, the only time either is used is in one of 4 places:
        ! 1. physics.F90 - scatter - For inelastic scatter.
        ! 2. physics.F90 - sample_fission - For partial fissions.
        ! 3. tally.F90 - score_general - For tallying on MTxxx reactions.
        ! 4. cross_section.F90 - calculate_urr_xs - For unresolved purposes.
        ! It is worth noting that none of these occur in the resolved
        ! resonance range, so the value here does not matter.  index_temp is
        ! set to -1 to force a segfault in case a developer messes up and tries
        ! to use it with multipole.
        micro_xs(i_nuclide) % index_temp    = -1
        micro_xs(i_nuclide) % index_grid    = 0
        micro_xs(i_nuclide) % interp_factor = ZERO

      else
        ! Find the appropriate temperature index.
        kT = sqrtkT**2
        select case (temperature_method)
        case (TEMPERATURE_NEAREST)
          i_temp = minloc(abs(nuclides(i_nuclide) % kTs - kT), dim=1)

        case (TEMPERATURE_INTERPOLATION)
          ! Find temperatures that bound the actual temperature
          do i_temp = 1, size(nuc % kTs) - 1
            if (nuc % kTs(i_temp) <= kT .and. kT < nuc % kTs(i_temp + 1)) exit
          end do

          ! Randomly sample between temperature i and i+1
          f = (kT - nuc % kTs(i_temp)) / &
               (nuc % kTs(i_temp + 1) - nuc % kTs(i_temp))
          if (f > prn()) i_temp = i_temp + 1
        end select

        associate (grid => nuc % grid(i_temp), xs => nuc % xs(i_temp))
          ! Determine the energy grid index using a logarithmic mapping to
          ! reduce the energy range over which a binary search needs to be
          ! performed

          if (E < grid % energy(1)) then
            i_grid = 1
          elseif (E > grid % energy(size(grid % energy))) then
            i_grid = size(grid % energy) - 1
          else
            ! Determine bounding indices based on which equal log-spaced
            ! interval the energy is in
            i_low  = grid % grid_index(i_log_union)
            i_high = grid % grid_index(i_log_union + 1) + 1

            ! Perform binary search over reduced range
            i_grid = binary_search(grid % energy(i_low:i_high), &
                 i_high - i_low + 1, E) + i_low - 1
          end if

          ! check for rare case where two energy points are the same
          if (grid % energy(i_grid) == grid % energy(i_grid + 1)) &
               i_grid = i_grid + 1

          ! calculate interpolation factor
          f = (E - grid % energy(i_grid)) / &
               (grid % energy(i_grid + 1) - grid % energy(i_grid))

          micro_xs(i_nuclide) % index_temp    = i_temp
          micro_xs(i_nuclide) % index_grid    = i_grid
          micro_xs(i_nuclide) % interp_factor = f

          ! Calculate microscopic nuclide total cross section
          micro_xs(i_nuclide) % total = (ONE - f) * xs % value(XS_TOTAL,i_grid) &
               + f * xs % value(XS_TOTAL,i_grid + 1)

          ! Calculate microscopic nuclide absorption cross section
          micro_xs(i_nuclide) % absorption = (ONE - f) * xs % value(XS_ABSORPTION, &
               i_grid) + f * xs % value(XS_ABSORPTION,i_grid + 1)

          if (nuc % fissionable) then
            ! Calculate microscopic nuclide total cross section
            micro_xs(i_nuclide) % fission = (ONE - f) * xs % value(XS_FISSION,i_grid) &
                 + f * xs % value(XS_FISSION,i_grid + 1)

            ! Calculate microscopic nuclide nu-fission cross section
            micro_xs(i_nuclide) % nu_fission = (ONE - f) * xs % value(XS_NU_FISSION, &
                 i_grid) + f * xs % value(XS_NU_FISSION,i_grid + 1)
          else
            micro_xs(i_nuclide) % fission         = ZERO
            micro_xs(i_nuclide) % nu_fission      = ZERO
          end if
        end associate

        ! Depletion-related reactions
        if (need_depletion_rx) then
          do j = 1, 6
            ! Initialize reaction xs to zero
            micro_xs(i_nuclide) % reaction(j) = ZERO

            ! If reaction is present and energy is greater than threshold, set
            ! the reaction xs appropriately
            i_rxn = nuc % reaction_index(DEPLETION_RX(j))
            if (i_rxn > 0) then
              associate (xs => nuc % reactions(i_rxn) % xs(i_temp))
                if (i_grid >= xs % threshold) then
                  micro_xs(i_nuclide) % reaction(j) = (ONE - f) * &
                       xs % value(i_grid - xs % threshold + 1) + &
                       f * xs % value(i_grid - xs % threshold + 2)
                end if
              end associate
            end if
          end do
        end if

      end if

      ! Initialize sab treatment to false
      micro_xs(i_nuclide) % index_sab = NONE
      micro_xs(i_nuclide) % sab_frac = ZERO

      ! Initialize URR probability table treatment to false
      micro_xs(i_nuclide) % use_ptable = .false.

      ! If there is S(a,b) data for this nuclide, we need to set the sab_scatter
      ! and sab_elastic cross sections and correct the total and elastic cross
      ! sections.

      if (i_sab > 0) then
        call calculate_sab_xs(i_nuclide, i_sab, E, sqrtkT, sab_frac)
      end if

      ! If the particle is in the unresolved resonance range and there are
      ! probability tables, we need to determine cross sections from the table

      if (urr_ptables_on .and. nuc % urr_present .and. .not. use_mp) then
        if (E > nuc % urr_data(i_temp) % energy(1) .and. E < nuc % &
             urr_data(i_temp) % energy(nuc % urr_data(i_temp) % n_energy)) then
          call calculate_urr_xs(i_nuclide, i_temp, E)
        end if
      end if

      micro_xs(i_nuclide) % last_E = E
      micro_xs(i_nuclide) % last_sqrtkT = sqrtkT
    end associate

  end subroutine calculate_nuclide_xs

!===============================================================================
! CALCULATE_SAB_XS determines the elastic and inelastic scattering
! cross-sections in the thermal energy range. These cross sections replace a
! fraction of whatever data were taken from the normal Nuclide table.
!===============================================================================

  subroutine calculate_sab_xs(i_nuclide, i_sab, E, sqrtkT, sab_frac)
    integer, intent(in) :: i_nuclide ! index into nuclides array
    integer, intent(in) :: i_sab     ! index into sab_tables array
    real(8), intent(in) :: E         ! energy
    real(8), intent(in) :: sqrtkT    ! temperature
    real(8), intent(in) :: sab_frac  ! fraction of atoms affected by S(a,b)

    integer :: i_grid    ! index on S(a,b) energy grid
    integer :: i_temp    ! temperature index
    real(8) :: f         ! interp factor on S(a,b) energy grid
    real(8) :: inelastic ! S(a,b) inelastic cross section
    real(8) :: elastic   ! S(a,b) elastic cross section
    real(8) :: kT

    ! Set flag that S(a,b) treatment should be used for scattering
    micro_xs(i_nuclide) % index_sab = i_sab

    ! Determine temperature for S(a,b) table
    kT = sqrtkT**2
    if (temperature_method == TEMPERATURE_NEAREST) then
      ! If using nearest temperature, do linear search on temperature
      do i_temp = 1, size(sab_tables(i_sab) % kTs)
        if (abs(sab_tables(i_sab) % kTs(i_temp) - kT) < &
             K_BOLTZMANN*temperature_tolerance) exit
      end do
    else
      ! Find temperatures that bound the actual temperature
      do i_temp = 1, size(sab_tables(i_sab) % kTs) - 1
        if (sab_tables(i_sab) % kTs(i_temp) <= kT .and. &
             kT < sab_tables(i_sab) % kTs(i_temp + 1)) exit
      end do

      ! Randomly sample between temperature i and i+1
      f = (kT - sab_tables(i_sab) % kTs(i_temp)) / &
           (sab_tables(i_sab) % kTs(i_temp + 1) &
           - sab_tables(i_sab) % kTs(i_temp))
      if (f > prn()) i_temp = i_temp + 1
    end if


    ! Get pointer to S(a,b) table
    associate (sab => sab_tables(i_sab) % data(i_temp))

      ! Get index and interpolation factor for inelastic grid
      if (E < sab % inelastic_e_in(1)) then
        i_grid = 1
        f = ZERO
      else
        i_grid = binary_search(sab % inelastic_e_in, sab % n_inelastic_e_in, E)
        f = (E - sab%inelastic_e_in(i_grid)) / &
             (sab%inelastic_e_in(i_grid+1) - sab%inelastic_e_in(i_grid))
      end if

      ! Calculate S(a,b) inelastic scattering cross section
      inelastic = (ONE - f) * sab % inelastic_sigma(i_grid) + &
           f * sab % inelastic_sigma(i_grid + 1)

      ! Check for elastic data
      if (E < sab % threshold_elastic) then
        ! Determine whether elastic scattering is given in the coherent or
        ! incoherent approximation. For coherent, the cross section is
        ! represented as P/E whereas for incoherent, it is simply P

        if (sab % elastic_mode == SAB_ELASTIC_EXACT) then
          if (E < sab % elastic_e_in(1)) then
            ! If energy is below that of the lowest Bragg peak, the elastic
            ! cross section will be zero
            elastic = ZERO
          else
            i_grid = binary_search(sab % elastic_e_in, &
                 sab % n_elastic_e_in, E)
            elastic = sab % elastic_P(i_grid) / E
          end if
        else
          ! Determine index on elastic energy grid
          if (E < sab % elastic_e_in(1)) then
            i_grid = 1
          else
            i_grid = binary_search(sab % elastic_e_in, &
                 sab % n_elastic_e_in, E)
          end if

          ! Get interpolation factor for elastic grid
          f = (E - sab%elastic_e_in(i_grid))/(sab%elastic_e_in(i_grid+1) - &
               sab%elastic_e_in(i_grid))

          ! Calculate S(a,b) elastic scattering cross section
          elastic = (ONE - f) * sab % elastic_P(i_grid) + &
               f * sab % elastic_P(i_grid + 1)
        end if
      else
        ! No elastic data
        elastic = ZERO
      end if
    end associate

    ! Store the S(a,b) cross sections.
    micro_xs(i_nuclide) % thermal = sab_frac * (elastic + inelastic)
    micro_xs(i_nuclide) % thermal_elastic = sab_frac * elastic

    ! Calculate free atom elastic cross section
    call calculate_elastic_xs(i_nuclide)

    ! Correct total and elastic cross sections
    micro_xs(i_nuclide) % total = micro_xs(i_nuclide) % total &
         + micro_xs(i_nuclide) % thermal &
         - sab_frac *  micro_xs(i_nuclide) % elastic
    micro_xs(i_nuclide) % elastic = micro_xs(i_nuclide) % thermal &
         + (ONE - sab_frac) * micro_xs(i_nuclide) % elastic

    ! Save temperature index and thermal fraction
    micro_xs(i_nuclide) % index_temp_sab = i_temp
    micro_xs(i_nuclide) % sab_frac = sab_frac

  end subroutine calculate_sab_xs

!===============================================================================
! CALCULATE_URR_XS determines cross sections in the unresolved resonance range
! from probability tables
!===============================================================================

  subroutine calculate_urr_xs(i_nuclide, i_temp, E)
    integer, intent(in) :: i_nuclide ! index into nuclides array
    integer, intent(in) :: i_temp    ! temperature index
    real(8), intent(in) :: E         ! energy

    integer :: i_energy     ! index for energy
    integer :: i_low        ! band index at lower bounding energy
    integer :: i_up         ! band index at upper bounding energy
    real(8) :: f            ! interpolation factor
    real(8) :: r            ! pseudo-random number
    real(8) :: elastic      ! elastic cross section
    real(8) :: capture      ! (n,gamma) cross section
    real(8) :: fission      ! fission cross section
    real(8) :: inelastic    ! inelastic cross section

    micro_xs(i_nuclide) % use_ptable = .true.

    associate (nuc => nuclides(i_nuclide), urr => nuclides(i_nuclide) % urr_data(i_temp))
      ! determine energy table
      i_energy = 1
      do
        if (E < urr % energy(i_energy + 1)) exit
        i_energy = i_energy + 1
      end do

      ! determine interpolation factor on table
      f = (E - urr % energy(i_energy)) / &
           (urr % energy(i_energy + 1) - urr % energy(i_energy))

      ! sample probability table using the cumulative distribution

      ! Random numbers for xs calculation are sampled from a separated stream.
      ! This guarantees the randomness and, at the same time, makes sure we reuse
      ! random number for the same nuclide at different temperatures, therefore
      ! preserving correlation of temperature in probability tables.
      call prn_set_stream(STREAM_URR_PTABLE)
      r = future_prn(int(i_nuclide, 8))
      call prn_set_stream(STREAM_TRACKING)

      i_low = 1
      do
        if (urr % prob(i_energy, URR_CUM_PROB, i_low) > r) exit
        i_low = i_low + 1
      end do
      i_up = 1
      do
        if (urr % prob(i_energy + 1, URR_CUM_PROB, i_up) > r) exit
        i_up = i_up + 1
      end do

      ! determine elastic, fission, and capture cross sections from probability
      ! table
      if (urr % interp == LINEAR_LINEAR) then
        elastic = (ONE - f) * urr % prob(i_energy, URR_ELASTIC, i_low) + &
             f * urr % prob(i_energy + 1, URR_ELASTIC, i_up)
        fission = (ONE - f) * urr % prob(i_energy, URR_FISSION, i_low) + &
             f * urr % prob(i_energy + 1, URR_FISSION, i_up)
        capture = (ONE - f) * urr % prob(i_energy, URR_N_GAMMA, i_low) + &
             f * urr % prob(i_energy + 1, URR_N_GAMMA, i_up)
      elseif (urr % interp == LOG_LOG) then
        ! Get logarithmic interpolation factor
        f = log(E / urr % energy(i_energy)) / &
             log(urr % energy(i_energy + 1) / urr % energy(i_energy))

        ! Calculate elastic cross section/factor
        elastic = ZERO
        if (urr % prob(i_energy, URR_ELASTIC, i_low) > ZERO .and. &
             urr % prob(i_energy + 1, URR_ELASTIC, i_up) > ZERO) then
          elastic = exp((ONE - f) * log(urr % prob(i_energy, URR_ELASTIC, &
               i_low)) + f * log(urr % prob(i_energy + 1, URR_ELASTIC, &
               i_up)))
        end if

        ! Calculate fission cross section/factor
        fission = ZERO
        if (urr % prob(i_energy, URR_FISSION, i_low) > ZERO .and. &
             urr % prob(i_energy + 1, URR_FISSION, i_up) > ZERO) then
          fission = exp((ONE - f) * log(urr % prob(i_energy, URR_FISSION, &
               i_low)) + f * log(urr % prob(i_energy + 1, URR_FISSION, &
               i_up)))
        end if

        ! Calculate capture cross section/factor
        capture = ZERO
        if (urr % prob(i_energy, URR_N_GAMMA, i_low) > ZERO .and. &
             urr % prob(i_energy + 1, URR_N_GAMMA, i_up) > ZERO) then
          capture = exp((ONE - f) * log(urr % prob(i_energy, URR_N_GAMMA, &
               i_low)) + f * log(urr % prob(i_energy + 1, URR_N_GAMMA, &
               i_up)))
        end if
      end if

      ! Determine treatment of inelastic scattering
      inelastic = ZERO
      if (urr % inelastic_flag > 0) then
        ! Get index on energy grid and interpolation factor
        i_energy = micro_xs(i_nuclide) % index_grid
        f = micro_xs(i_nuclide) % interp_factor

        ! Determine inelastic scattering cross section
        associate (xs => nuc % reactions(nuc % urr_inelastic) % xs(i_temp))
          if (i_energy >= xs % threshold) then
            inelastic = (ONE - f) * xs % value(i_energy - xs % threshold + 1) + &
                 f * xs % value(i_energy - xs % threshold + 2)
          end if
        end associate
      end if

      ! Multiply by smooth cross-section if needed
      if (urr % multiply_smooth) then
        call calculate_elastic_xs(i_nuclide)
        elastic = elastic * micro_xs(i_nuclide) % elastic
        capture = capture * (micro_xs(i_nuclide) % absorption - &
             micro_xs(i_nuclide) % fission)
        fission = fission * micro_xs(i_nuclide) % fission
      end if

      ! Check for negative values
      if (elastic < ZERO) elastic = ZERO
      if (fission < ZERO) fission = ZERO
      if (capture < ZERO) capture = ZERO

      ! Set elastic, absorption, fission, and total cross sections. Note that the
      ! total cross section is calculated as sum of partials rather than using the
      ! table-provided value
      micro_xs(i_nuclide) % elastic = elastic
      micro_xs(i_nuclide) % absorption = capture + fission
      micro_xs(i_nuclide) % fission = fission
      micro_xs(i_nuclide) % total = elastic + inelastic + capture + fission

      ! Determine nu-fission cross section
      if (nuc % fissionable) then
        micro_xs(i_nuclide) % nu_fission = nuc % nu(E, EMISSION_TOTAL) * &
             micro_xs(i_nuclide) % fission
      end if
    end associate

  end subroutine calculate_urr_xs

!===============================================================================
! CALCULATE_ELASTIC_XS precalculates the free atom elastic scattering cross
! section. Normally it is not needed until a collision actually occurs in a
! material. However, in the thermal and unresolved resonance regions, we have to
! calculate it early to adjust the total cross section correctly.
!===============================================================================

  subroutine calculate_elastic_xs(i_nuclide)
    integer, intent(in) :: i_nuclide

    integer :: i_temp
    integer :: i_grid
    real(8) :: f

    ! Get temperature index, grid index, and interpolation factor
    i_temp =  micro_xs(i_nuclide) % index_temp
    i_grid =  micro_xs(i_nuclide) % index_grid
    f      =  micro_xs(i_nuclide) % interp_factor

    if (i_temp > 0) then
      associate (xs => nuclides(i_nuclide) % reactions(1) % xs(i_temp) % value)
        micro_xs(i_nuclide) % elastic = (ONE - f)*xs(i_grid) + f*xs(i_grid + 1)
      end associate
    else
      ! For multipole, elastic is total - absorption
      micro_xs(i_nuclide) % elastic = micro_xs(i_nuclide) % total - &
           micro_xs(i_nuclide) % absorption
    end if
  end subroutine calculate_elastic_xs

!===============================================================================
! MULTIPOLE_EVAL evaluates the windowed multipole equations for cross
! sections in the resolved resonance regions
!===============================================================================

  subroutine multipole_eval(multipole, E, sqrtkT, sig_t, sig_a, sig_f)
    type(MultipoleArray), intent(in) :: multipole ! The windowed multipole
                                                  !  object to process.
    real(8), intent(in)              :: E         ! The energy at which to
                                                  !  evaluate the cross section
    real(8), intent(in)              :: sqrtkT    ! The temperature in the form
                                                  !  sqrt(kT), at which
                                                  !  to evaluate the XS.
    real(8), intent(out)             :: sig_t     ! Total cross section
    real(8), intent(out)             :: sig_a     ! Absorption cross section
    real(8), intent(out)             :: sig_f     ! Fission cross section
    complex(8) :: psi_chi  ! The value of the psi-chi function for the
                           !  asymptotic form
    complex(8) :: c_temp   ! complex temporary variable
    complex(8) :: w_val    ! The faddeeva function evaluated at Z
    complex(8) :: Z        ! sqrt(atomic weight ratio / kT) * (sqrt(E) - pole)
    complex(8) :: sig_t_factor(multipole % num_l)
    real(8) :: broadened_polynomials(multipole % fit_order + 1)
    real(8) :: sqrtE       ! sqrt(E), eV
    real(8) :: invE        ! 1/E, eV
    real(8) :: dopp        ! sqrt(atomic weight ratio / kT) = 1 / (2 sqrt(xi))
    real(8) :: temp        ! real temporary value
    integer :: i_pole      ! index of pole
    integer :: i_poly      ! index of curvefit
    integer :: i_window    ! index of window
    integer :: startw      ! window start pointer (for poles)
    integer :: endw        ! window end pointer

    ! ==========================================================================
    ! Bookkeeping

    ! Define some frequently used variables.
    sqrtE = sqrt(E)
    invE = ONE / E

    ! Locate us.
    i_window = floor((sqrtE - sqrt(multipole % start_E)) / multipole % spacing &
         + ONE)
    startw = multipole % w_start(i_window)
    endw = multipole % w_end(i_window)

    ! Fill in factors.
    if (startw <= endw) then
      call compute_sig_t_factor(multipole, sqrtE, sig_t_factor)
    end if

    ! Initialize the ouptut cross sections.
    sig_t = ZERO
    sig_a = ZERO
    sig_f = ZERO

    ! ==========================================================================
    ! Add the contribution from the curvefit polynomial.

    if (sqrtkT /= ZERO .and. multipole % broaden_poly(i_window) == 1) then
      ! Broaden the curvefit.
      dopp = multipole % sqrtAWR / sqrtkT
      call broaden_wmp_polynomials(E, dopp, multipole % fit_order + 1, &
           broadened_polynomials)
      do i_poly = 1, multipole % fit_order+1
        sig_t = sig_t + multipole % curvefit(FIT_T, i_poly, i_window) &
             * broadened_polynomials(i_poly)
        sig_a = sig_a + multipole % curvefit(FIT_A, i_poly, i_window) &
             * broadened_polynomials(i_poly)
        if (multipole % fissionable) then
          sig_f = sig_f + multipole % curvefit(FIT_F, i_poly, i_window) &
               * broadened_polynomials(i_poly)
        end if
      end do
    else ! Evaluate as if it were a polynomial
      temp = invE
      do i_poly = 1, multipole % fit_order+1
        sig_t = sig_t + multipole % curvefit(FIT_T, i_poly, i_window) * temp
        sig_a = sig_a + multipole % curvefit(FIT_A, i_poly, i_window) * temp
        if (multipole % fissionable) then
          sig_f = sig_f + multipole % curvefit(FIT_F, i_poly, i_window) * temp
        end if
        temp = temp * sqrtE
      end do
    end if

    ! ==========================================================================
    ! Add the contribution from the poles in this window.

    if (sqrtkT == ZERO) then
      ! If at 0K, use asymptotic form.
      do i_pole = startw, endw
        psi_chi = -ONEI / (multipole % data(MP_EA, i_pole) - sqrtE)
        c_temp = psi_chi / E
        if (multipole % formalism == FORM_MLBW) then
          sig_t = sig_t + real(multipole % data(MLBW_RT, i_pole) * c_temp * &
                               sig_t_factor(multipole % l_value(i_pole))) &
                        + real(multipole % data(MLBW_RX, i_pole) * c_temp)
          sig_a = sig_a + real(multipole % data(MLBW_RA, i_pole) * c_temp)
          if (multipole % fissionable) then
            sig_f = sig_f + real(multipole % data(MLBW_RF, i_pole) * c_temp)
          end if
        else if (multipole % formalism == FORM_RM) then
          sig_t = sig_t + real(multipole % data(RM_RT, i_pole) * c_temp * &
                               sig_t_factor(multipole % l_value(i_pole)))
          sig_a = sig_a + real(multipole % data(RM_RA, i_pole) * c_temp)
          if (multipole % fissionable) then
            sig_f = sig_f + real(multipole % data(RM_RF, i_pole) * c_temp)
          end if
        end if
      end do
    else
      ! At temperature, use Faddeeva function-based form.
      dopp = multipole % sqrtAWR / sqrtkT
      if (endw >= startw) then
        do i_pole = startw, endw
          Z = (sqrtE - multipole % data(MP_EA, i_pole)) * dopp
          w_val = faddeeva(Z) * dopp * invE * SQRT_PI
          if (multipole % formalism == FORM_MLBW) then
            sig_t = sig_t + real((multipole % data(MLBW_RT, i_pole) * &
                            sig_t_factor(multipole % l_value(i_pole)) + &
                            multipole % data(MLBW_RX, i_pole)) * w_val)
            sig_a = sig_a + real(multipole % data(MLBW_RA, i_pole) * w_val)
            if (multipole % fissionable) then
              sig_f = sig_f + real(multipole % data(MLBW_RF, i_pole) * w_val)
            end if
          else if (multipole % formalism == FORM_RM) then
            sig_t = sig_t + real(multipole % data(RM_RT, i_pole) * w_val * &
                                 sig_t_factor(multipole % l_value(i_pole)))
            sig_a = sig_a + real(multipole % data(RM_RA, i_pole) * w_val)
            if (multipole % fissionable) then
              sig_f = sig_f + real(multipole % data(RM_RF, i_pole) * w_val)
            end if
          end if
        end do
      end if
    end if
  end subroutine multipole_eval

!===============================================================================
! MULTIPOLE_DERIV_EVAL evaluates the windowed multipole equations for the
! derivative of cross sections in the resolved resonance regions with respect to
! temperature.
!===============================================================================

  subroutine multipole_deriv_eval(multipole, E, sqrtkT, sig_t, sig_a, sig_f)
    type(MultipoleArray), intent(in) :: multipole ! The windowed multipole
                                                  !  object to process.
    real(8), intent(in)              :: E         ! The energy at which to
                                                  !  evaluate the cross section
    real(8), intent(in)              :: sqrtkT    ! The temperature in the form
                                                  !  sqrt(kT), at which to
                                                  !  evaluate the XS.
    real(8), intent(out)             :: sig_t     ! Total cross section
    real(8), intent(out)             :: sig_a     ! Absorption cross section
    real(8), intent(out)             :: sig_f     ! Fission cross section
    complex(8) :: w_val    ! The faddeeva function evaluated at Z
    complex(8) :: Z        ! sqrt(atomic weight ratio / kT) * (sqrt(E) - pole)
    complex(8) :: sig_t_factor(multipole % num_l)
    real(8) :: sqrtE       ! sqrt(E), eV
    real(8) :: invE        ! 1/E, eV
    real(8) :: dopp        ! sqrt(atomic weight ratio / kT)
    integer :: i_pole      ! index of pole
    integer :: i_window    ! index of window
    integer :: startw      ! window start pointer (for poles)
    integer :: endw        ! window end pointer
    real(8) :: T

    ! ==========================================================================
    ! Bookkeeping

    ! Define some frequently used variables.
    sqrtE = sqrt(E)
    invE = ONE / E
    T = sqrtkT**2 / K_BOLTZMANN

    if (sqrtkT == ZERO) call fatal_error("Windowed multipole temperature &
         &derivatives are not implemented for 0 Kelvin cross sections.")

    ! Locate us
    i_window = floor((sqrtE - sqrt(multipole % start_E)) / multipole % spacing &
         + ONE)
    startw = multipole % w_start(i_window)
    endw = multipole % w_end(i_window)

    ! Fill in factors.
    if (startw <= endw) then
      call compute_sig_t_factor(multipole, sqrtE, sig_t_factor)
    end if

    ! Initialize the ouptut cross sections.
    sig_t = ZERO
    sig_a = ZERO
    sig_f = ZERO

    ! TODO Polynomials: Some of the curvefit polynomials Doppler broaden so
    ! rigorously we should be computing the derivative of those.  But in
    ! practice, those derivatives are only large at very low energy and they
    ! have no effect on reactor calculations.

    ! ==========================================================================
    ! Add the contribution from the poles in this window.

    dopp = multipole % sqrtAWR / sqrtkT
    if (endw >= startw) then
      do i_pole = startw, endw
        Z = (sqrtE - multipole % data(MP_EA, i_pole)) * dopp
        w_val = -invE * SQRT_PI * HALF * w_derivative(Z, 2)
        if (multipole % formalism == FORM_MLBW) then
          sig_t = sig_t + real((multipole % data(MLBW_RT, i_pole) * &
                          sig_t_factor(multipole%l_value(i_pole)) + &
                          multipole % data(MLBW_RX, i_pole)) * w_val)
          sig_a = sig_a + real(multipole % data(MLBW_RA, i_pole) * w_val)
          if (multipole % fissionable) then
            sig_f = sig_f + real(multipole % data(MLBW_RF, i_pole) * w_val)
          end if
        else if (multipole % formalism == FORM_RM) then
          sig_t = sig_t + real(multipole % data(RM_RT, i_pole) * w_val * &
                               sig_t_factor(multipole % l_value(i_pole)))
          sig_a = sig_a + real(multipole % data(RM_RA, i_pole) * w_val)
          if (multipole % fissionable) then
            sig_f = sig_f + real(multipole % data(RM_RF, i_pole) * w_val)
          end if
        end if
      end do
      sig_t = -HALF*multipole % sqrtAWR / sqrt(K_BOLTZMANN) * T**(-1.5) * sig_t
      sig_a = -HALF*multipole % sqrtAWR / sqrt(K_BOLTZMANN) * T**(-1.5) * sig_a
      sig_f = -HALF*multipole % sqrtAWR / sqrt(K_BOLTZMANN) * T**(-1.5) * sig_f
    end if
  end subroutine multipole_deriv_eval

!===============================================================================
! COMPUTE_SIG_T_FACTOR calculates the sig_t_factor, a factor inside of the sig_t
! equation not present in the sig_a and sig_f equations.
!===============================================================================

  subroutine compute_sig_t_factor(multipole, sqrtE, sig_t_factor)
    type(MultipoleArray), intent(in)  :: multipole
    real(8),              intent(in)  :: sqrtE
    complex(8),           intent(out) :: sig_t_factor(multipole % num_l)

    integer :: iL
    real(8) :: twophi(multipole % num_l)
    real(8) :: arg

    do iL = 1, multipole % num_l
      twophi(iL) = multipole % pseudo_k0RS(iL) * sqrtE
      if (iL == 2) then
        twophi(iL) = twophi(iL) - atan(twophi(iL))
      else if (iL == 3) then
        arg = 3.0_8 * twophi(iL) / (3.0_8 - twophi(iL)**2)
        twophi(iL) = twophi(iL) - atan(arg)
      else if (iL == 4) then
        arg = twophi(iL) * (15.0_8 - twophi(iL)**2) &
             / (15.0_8 - 6.0_8 * twophi(iL)**2)
        twophi(iL) = twophi(iL) - atan(arg)
      end if
    end do

    twophi = 2.0_8 * twophi
    sig_t_factor = cmplx(cos(twophi), -sin(twophi), KIND=8)
  end subroutine compute_sig_t_factor

!===============================================================================
! 0K_ELASTIC_XS determines the microscopic 0K elastic cross section
! for a given nuclide at the trial relative energy used in resonance scattering
!===============================================================================

  pure function elastic_xs_0K(E, nuc) result(xs_out)
    real(8),       intent(in) :: E      ! trial energy
    type(Nuclide), intent(in) :: nuc    ! target nuclide at temperature
    real(8)                   :: xs_out ! 0K xs at trial energy

    integer :: i_grid ! index on nuclide energy grid
    integer :: n_grid
    real(8) :: f      ! interp factor on nuclide energy grid

    ! Determine index on nuclide energy grid
    n_grid = size(nuc % energy_0K)
    if (E < nuc % energy_0K(1)) then
      i_grid = 1
    elseif (E > nuc % energy_0K(n_grid)) then
      i_grid = n_grid - 1
    else
      i_grid = binary_search(nuc % energy_0K, n_grid, E)
    end if

    ! check for rare case where two energy points are the same
    if (nuc % energy_0K(i_grid) == nuc % energy_0K(i_grid+1)) then
      i_grid = i_grid + 1
    end if

    ! calculate interpolation factor
    f = (E - nuc % energy_0K(i_grid)) &
         & / (nuc % energy_0K(i_grid + 1) - nuc % energy_0K(i_grid))

    ! Calculate microscopic nuclide elastic cross section
    xs_out = (ONE - f) * nuc % elastic_0K(i_grid) &
         & + f * nuc % elastic_0K(i_grid + 1)

  end function elastic_xs_0K

end module cross_section
