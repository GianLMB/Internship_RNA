! Module in which to put file reading/writing routines and functions

module fileio
  implicit none
  
  contains

  subroutine testfile(fname, ex)
    implicit none

    logical :: file_exists, tex
    logical, intent(in), optional :: ex
    character(*), intent(in) :: fname

    if(present(ex)) then
      tex = ex
    else
      tex = .false.
    endif
    
    inquire(file=fname, exist=file_exists)
    if(.not. file_exists) then
      write(*,*) "The file " // trim(fname) // " does not exists."
      if(tex .eqv. .true.) then
        stop
      endif
    endif

  end subroutine testfile

  logical function testf(fname)
    implicit none

    logical :: file_exists
    character(*), intent(in) :: fname

    inquire(file=fname, exist=file_exists)
    if(.not. file_exists) then
      testf = .true.
    else
      testf = .false.
    endif

    return
  end function testf

end module fileio
