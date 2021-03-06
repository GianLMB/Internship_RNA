!Deallocation of data
SUBROUTINE FINISH()
   USE MOD_BONDS, ONLY: DEALLOC_BONDS
   USE MOD_ANGLES, ONLY: DEALLOC_ANGLES
   USE MOD_DIHEDRALS, ONLY: DEALLOC_DIHS
   USE MOD_RESTRAINTS, ONLY: NRESTS, NPOSRES, DEALLOC_DISTRESTR, DEALLOC_POSRESTR
   USE FILL_PARAMS, ONLY: DEALLOC_NAPARAMS
   USE SAXS_DEFS, ONLY: compute_SAXS_serial,SAXSs, SAXSc
   USE HB_DEFS, ONLY: DO_HB, HBDAT
   
   CALL DEALLOC_BONDS()
   CALL DEALLOC_ANGLES()
   CALL DEALLOC_DIHS()
   CALL DEALLOC_NAPARAMS()
   IF (NRESTS.GT.0) CALL DEALLOC_DISTRESTR()
   IF (NPOSRES.GT.0) CALL DEALLOC_POSRESTR()

   IF (compute_SAXS_serial) THEN
      CLOSE(SAXSs)
      CLOSE(SAXSc)
   ENDIF

   IF (DO_HB) CLOSE(HBDAT)
END SUBROUTINE FINISH

