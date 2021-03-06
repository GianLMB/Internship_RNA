MODULE MOD_NONBONDED
  USE PREC_HIRE
  USE NBDEFS
  
  CONTAINS
   
   SUBROUTINE E_NONBONDED(NOPT, X, F, EHHB, ESTAK, EVDW)
     USE UTILS_IO, ONLY: GETUNIT
     USE MOD_HBONDS, ONLY: RNA_BB
     USE MOD_EXCLV, ONLY: ENERGY_EXCLV
     USE MOD_BASESTACKING, ONLY: RNA_STACKV
     USE MOD_BASESTACKING, ONLY: RNA_STACKV2
     USE NAPARAMS, ONLY: BOCC, BTYPE, BLIST, &
                         RCUT2_CACA_SCSC_IN, RCUT2_CACA_SCSC_OUT
     USE VAR_DEFS, ONLY: NRES, RESSTART, RESFINAL, RESTYPES, IAC
     IMPLICIT NONE
     
     INTEGER, INTENT(IN) :: NOPT                   !should be 3*NATOMS
     REAL(KIND = REAL64), INTENT(IN) :: X(NOPT)    !input coordinates
     REAL(KIND = REAL64), INTENT(OUT) :: F(NOPT)   !force 
     REAL(KIND = REAL64), INTENT(OUT) :: EHHB, ESTAK, EVDW 
     
     INTEGER :: I, J           !Iteration variables - residue indices
     INTEGER :: K, L           !Atom indices 
     INTEGER :: TYPEI, TYPEJ   !Type of residue (RNA, DNA, protein, ...)
     INTEGER :: TI, TJ         !ID of residue (A, G, ...)
     INTEGER :: TK, TL         !Atom type
     REAL(KIND = REAL64) :: A(3), DA2, DF, DX(3)
     REAL(KIND = REAL64) :: THIS_EHB, THIS_ESTAK, THIS_EVDW, NB
     LOGICAL :: HBEXIST
   
#ifdef FOR_ANALYSIS
     INTEGER :: HBUNIT, STACKUNIT
     HBUNIT = GETUNIT()
     OPEN(HBUNIT, FILE="Hbonding.dat", STATUS='UNKNOWN')
     STACKUNIT = GETUNIT()
     OPEN(STACKUNIT, FILE="Stacking.dat", STATUS='UNKNOWN')
#endif    
     EHHB = 0.0D0
     ESTAK = 0.0D0
     EVDW = 0.0D0
     F(1:NOPT) = 0.0D0
     BOCC(1:NRES) = 0

     DO I=1,NRES-1
        DO J=I+1,NRES
    
        !QUERY: Why are we using first to last here?
           ! Wouldn't it be better to use the distance first to first or last to last?
           !K = BLIST(I)
           !L = BLIST(J-1)+1
           !replaced Blist with RESSTART and RESFINAL to get first and last atom id for all res
           
           K = RESFINAL(I)
           L = RESSTART(J)
           A(1:3) = X(3*K-2:3*K) - X(3*L-2:3*L)
           DA2 = DOT_PRODUCT(A,A)
           !QUERY: This really should be a variable, not a magic number!
           !Check residues are close enough for interactions
           IF (DA2 .GT. 400) THEN
              CYCLE
           ENDIF
           !Now calculate interactions between residues
           TYPEI = RESTYPES(I)
           TYPEJ = RESTYPES(J)
           TI = BTYPE(I)
           TJ = BTYPE(J)

           !If restype is 0 for both this is RNA-RNA 
           IF ((TYPEI.EQ.0).AND.(TYPEJ.EQ.0)) THEN
              !Hydrogen bonding between nucleotides
              CALL RNA_BB(I, J, NOPT, X, F, THIS_EHB, HBEXIST)
              EHHB = EHHB + THIS_EHB                       
              !Stacking energy
!              CALL RNA_STACKV(NOPT, BLIST(I),BLIST(J),TI,TJ,F,X,THIS_ESTAK)
!           IF ((I.EQ.2).AND.(J.EQ.3)) THEN                                          ! test
              CALL RNA_STACKV2(NOPT, BLIST(I),BLIST(J),TI,TJ,F,X,THIS_ESTAK)
              ESTAK = ESTAK + THIS_ESTAK
!           ENDIF
#ifdef FOR_ANALYSIS
              IF (ABS(THIS_EHB) .GT. 0.3D0) THEN
                 WRITE(HBUNIT,'(I6,I6,F15.7)') I, J, THIS_EHB
              ENDIF

              IF (ABS(THIS_ESTAK) .GT. 0.1D0) THEN
                 WRITE(STACKUNIT,'(I6,I6,F15.7)') I, J, THIS_ESTAK
              ENDIF
#endif
           !If restype is 1 for both this is DNA-DNA
           ELSEIF ((TYPEI.EQ.1).AND.(TYPEJ.EQ.1)) THEN
              CYCLE
           !If restype is 2 for both this is protein-protein
           ELSEIF ((TYPEI.EQ.2).AND.(TYPEJ.EQ.2)) THEN 
              CYCLE
           ELSE
              CYCLE
           ENDIF
           !Now calculate excluded volume interactions
           DO K = RESSTART(I),RESFINAL(I)
              DO L = RESSTART(J),RESFINAL(J)
                 TK = IAC(K)
                 TL = IAC(L)
                 !make sure we skip the bonded particles for neighbouring res
                 IF ((J-I).EQ.1) THEN
                    IF ((TYPEI.EQ.0).AND.(TYPEJ.EQ.0)) THEN
                       !For RNA ignore CA-P
                       IF ((TK.EQ.4).AND.(TL.EQ.3)) CYCLE
                    ELSEIF ((TYPEI.EQ.1).AND.(TYPEJ.EQ.1)) THEN
                       !For DNA do the same
                       IF ((TK.EQ.4).AND.(TL.EQ.3)) CYCLE
                    ENDIF                  
                 ENDIF
                 A(1:3) = X(3*K-2:3*K) - X(3*L-2:3*L)
                 DA2 = DOT_PRODUCT(A,A) 
                 !Skip if the distance is too large
                 IF (DA2.GT.RCUT2_CACA_SCSC_OUT) CYCLE
                 CALL ENERGY_EXCLV(DA2, THIS_EVDW, DF, NBCT2(TK,TL), &
                        RCUT2_CACA_SCSC_IN, RCUT2_CACA_SCSC_OUT)
                 NB = GET_NBCOEF(K,L)
                 EVDW = EVDW + THIS_EVDW*NB 
                 DX(1:3) = DF*NB*A(1:3)    
                 F((3*K-2):(3*K)) = F((3*K-2):(3*K)) - DX(1:3)
                 F((3*L-2):(3*L)) = F((3*L-2):(3*L)) + DX(1:3)     
              ENDDO
           ENDDO                
        ENDDO
     ENDDO
#ifdef FOR_ANALYSIS
     CLOSE(HBUNIT)
     CLOSE(STACKUNIT)
#endif  

   END SUBROUTINE E_NONBONDED
   
END MODULE MOD_NONBONDED
