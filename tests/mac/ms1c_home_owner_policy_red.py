#!/usr/bin/env python3
"""RED, UNREGISTERED: bind the owner-approved MS1c whole-HOME policy.

The production differ must keep the complete canonical before/after census and
emit every delta exactly once in original-byte order.  Complete unrelated churn
is AMBIENT/0, while bundle-owned paths, the exact Saved Application State
subtree, and every crash report beyond one D-attributed missing-dylib control
are FAIL/2.  Incomplete or unverifiable evidence remains INCONCLUSIVE/3.  In
particular, DiagnosticReports directory metadata is ambient only as the bounded
companion of the permitted control report; standing alone it is unverifiable.

This oracle extracts and executes ``HOME_DIFF_PY`` from the real gate, then
drives the real gate at its fake-host execution boundary.  It is deliberately
absent from ``build.zig`` until its red is reviewed.  The compact retained-run
fixtures contain the exact kind/path sets from MS1c run ``733135f6`` and bind
the source snapshot, leg-log and full-delta hashes.  Intel has 172 deltas and
one permitted control report; arm64 has 222 deltas and one control plus the
unexpected product report ``160541.ips``.

No path-family, application-name, ``Library`` or ``com.apple.*`` allowlist is
part of this policy.  Every ordinary delta remains evidence, including the
DiagnosticReports directory metadata and the permitted control report itself.
"""

from __future__ import annotations

import base64
import binascii
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from typing import Dict, Iterable, List, Mapping, Optional, Sequence, Tuple
import zlib


HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
GATE = HERE / "ms1c_app_gate.sh"
SELFTEST = HERE / "ms1c_app_gate_selftest.sh"
PROTECTED = HERE / "ms1c_home_protected_paths.txt"
APP_ID = b"com.cosmichq.zigBrowser"
DIAG = b"Library/Logs/DiagnosticReports"
problems: List[str] = []


SOURCE_HASHES = {
    "x86_64": {
        "home.before": "813cb95525a2997084aa8aa092d77c3913953575ec6dc4156b3f732e4ad96cf8",
        "home.after": "e6f96ac65f4c2655771cfd5db93be4b67a6e93c8ad12381130da90354c232bbf",
        "leg.log": "55c793a83a96efd12a07a817a16e782dd27aa2589161245a166266742f102991",
        "full-deltas": "7b4314b8f30a1bf0272bb3d3ccc9c33eadfd0a6c206c1e9167c8e4d77860f99b",
        "compact-deltas": "a5f56b57bf9b5449a7133117bf6ba225b7a36c61d3effb0c5af5b325ab30817c",
    },
    "arm64": {
        "home.before": "4000a190adffae9eb98ac2c1512dc33733db2dc449c479fee402d6aad59dc206",
        "home.after": "028d69ac1ea77bc6a2183a6acf667dce1ef6e1d4893dc308560b89eea5d9020f",
        "leg.log": "31bb77b0394b108e9ce3111dbf5f54ba34769e57dee96209f6c24570c8564b47",
        "full-deltas": "7747bcef6c8740659110a32e59e6e393c37e341ef5bc7e2a5375f33e632e54fc",
        "compact-deltas": "7fa611dcd10af8fb572e5be29e363b8140998778f4f855b13ce6dbde56253616",
    },
}

# zlib(level=9), then Base85, of exactly ``HOME-DELTA<TAB>kind<TAB>b64:path``
# plus LF for every retained delta, in its original raw-byte order.
RETAINED_B85 = {
    "x86_64": """
c-rk<*>l>?vVK1If4Nm!(5<6el?Q_spfp2CXn#YJW6(mVAOzB1f4&iT!9P1Ei6yWTKR93`G(D}JUcc^)XGHy9MK$c3e~rdBR9BUMMgKSWe}i|M(4RJjz%K*AtrmsM$Az_wRx(+5(>m~{lEG>FSU+q6LE{#lyqjp0kH^C*UYnIA$W<sDa)YDa;zBONxvYj>xJ<kQ_dnyyuZh1^kx*_zpM1IU`sMMy(lWaFawS@<Wg<x9xX|_sJ?BD)VvS{P2>83MeI@2q>GDHwI(9Ty2|W4@pJ#z@E&WEl5>1Kez8n5Xc`{C_xY*t~x?9IW-XyxaOGZN*baCOe=;Ez9@T4Zz<vP)59*Aze@Ga>&v?O_uQ!Wyx%TRDC$9F66hJrr)?$+;-Cd1oQi9g*1-u{x$Zye|JTi{uFoLyDEpXj0X{9p6j+Y4RGaL<d;Fc+jM0S%#^fdAz#5|eG{S?katyHKB$v9K(!wRR$C+rHKg1i3Vd_Ve6W(|sgb+l7~WOM0}4udX?gm$-&3e99TP-`i=JZX$sPPhs=@A)n|@6$@?yeO*OsQW1{oGu3RU9hcPB^x25xtTa~*XTn=fP*P5<XHKXPWvNhA(+y$De1{VE{vOwI8tHi+J>O43VHaGcgE@S@UW~2mPuN4d{#;_uXB*C?6go7I#Ub?PVG{~VE*wcCJm(TV4CtbK<Uyb2)HeO$e(p(nB;fh)Kj8CR59>(K(nQaN&@(?e{gqY7Y2s5F39vV{G!8s|6BSAO`yaNqdFW}`!jsmvCueW>$===me4N4WA7F26eIfKGA6ZZS^d9~KJ^2bR@*QHJE#pJzNonX0xA55t?7s|e{;>Uwa9#y&7vPyiy0e3h;X?1ge3(2cXpZm0e-9xWd}d^b3*l4Wx)x%L1iCi<c)a*HHt=WY|EM<bclP#?Y~b(guX`IPQsj0>W$A7a`0f@l$uJ(@?4X;G<I$iG+>Gh!Hb<swtH7tZ!Q(q4DGTo20Szm@S?Jt*phJ9n9_4`!4t91K`J}bC$#}X6L@N&;={efXTHfMy8IAre()30k>D`_-cvUi<Hj}<-nMP|Xk6JtL?r<M7V!6OVuHg@O3(plHuWqa}Ub*lS4v=$gYvA+{#n}^u42XRvQJV;)J2`rdRy%-S0=wocJY1LItZ8l&cr5?$K$nPf%uzdQXyb6S0d3vUB}D~j67yY9cP_Kf@7<vsT4nrZU*?$Od%KT!x=$@DkuLM0T5fPYAK$Bdjx*Wj%?zJ@i_A-|mvm55d01~83Gy0#R%Hsyx_u5DWVq1yXl&wdTDoXIW3TR43ui8v%S$3?#Y_+LP{{<MoBT`<B)_@2CQa}$to(MwXA6JwUg$tvf_$?-&2dIb_zB3l-gQOWnU5S6F7lgGd{#n7C+i>D`8nz<1^nhQt7p*f?AoxU9kmVbuz}yvK|c0nIuVn#e#pXuA1|Ep@$2E1<s|!9FCI@T?2%jeAz}^}K90mePcuH{@k(YfL+wM4<6Pxkt{-`Mid=gW2_a{&`U7OZ(IFdavy40~y}urL*j2~+<2TmtM4!M%wU&_aJch4&CVLrQ1x3CMT}qu=R$Cp$A$Pr=F5`7pIn0&_Zsv?(GYhvq#)Hr9QIrDHji_7fVE-NXwK?;NEu1M=mo=O@{LuQ=AGY~$gX57GpseoH{HgnTmJ2CEpSC^*{GdJPWpVSmx4q{S^5y1HZf%fb@fWO~;#)&T3(hutFvKh?>C6vug**e@oaG}=10VOeALg&Aj90A2Tb^|2*%=O6-78h_57=7UmY!$l+z}}F>+W1VFGDxkuv$-|p4Uh|dGW{#=EueGRU?Oo-N^Z9&Xw@tYxtsjs>BUxOcAfb%nk+=pBZzmp^CX9%234n15Mla-|)UBqrskxC#7Kz3;ez}(wluUI=)7y*C4%N*Q4&#)*yFL&2x+o$p7r#9$Wt4*%YvKBH1M;e&6%h*7FtWvGwg-KGs0rjF;(zh8MpVkKGmclo~#>;T9jTXD<v&Vw>!l96l=DhJfowJY-iY7GC^e`ETG{N1n`u^ZUIdps#10^WXP0aW%_yL<_O0wtj7I58p@bJQ)w6cjWqHL%Q?@-^D)OUgv+)K1|q%0&5&|*!!#MymMNf`{+fROA(KD%-k`%5sT)<>HQ5m$l-i0Z?9laew)_0+}tAe2|eD1U%rLCEJ-sFiDHVRi4QY{?1@ckco-7$z2y_z`$yQ}MCbR{SQA*j969!?Jr7RK_}^cgum&#9w_sl;zixwG{BGy5<CSRdIqvM5b|Gv|xt^>&=jI2deg1EODxqek@qmoD0d+`iz@H(?q@3A_N>}(>6Ap=;al~;r=%B0Y^{uf`BDhPIgNyIJd~EtxFW3otGML#;J+tpb)HdqYR-_Y&yn8!=TD`|3CLSu-KNonoC;Lt_;b>+GGgiBF)Pbd<rm5r_9r2@?6F@$fx@lA0QUcz}EQPF2IhXT1$oJ$Qd73i6b;D&ec5??f<fO<`T*q=NPQ<ypP(?jSoJ#SS)oytBMsk+0oFR*o*YprE%<jC48p?;<cL(*I*Y@oUXcmr$Lk@;LK`onL-%hKKP*da#$5P=7HH0G#QQZ-(U)(qH>W2z7xAwI=n|NuOyRd~8kGzw1J03zuSqjT_v)sPvT7j+0Dd<4lDm~!w5mPPOxX6=g<PK5G%u`l7?S+Oyt`_)ST$D}U_cwqCTR1H5=B|NXkep-uj`Qo*Pp)&FY~K&R1=OhVzQs*=hmP_~zqD3`XFc$b^`0uq<stxnDkxz8Mf!E2%Pd!X%vs)jxdvURhs%4c5A4iQ-^6^2P5&C*`!?pgq3au~`^Bf6>N}z72`19)g-@=N_bRtf?q8XweL3Qgi^i546>X2kuJ?7}V_ABR=i2rxNqw(3XXnoC_uM^Q&k^!^;aD5UZiRX;@?pSPFs!6`fwiAta$QgQ9u>0K*PeY&b39hxP?>*zkSrZoH&<5BYsPABT>HD(=h`hk%Vs%8*!GU_Hovr97e3k#)`PDiAeVaV?dve_@T+U~=OYEj*tjv;wU0Rpi`91L{8#2b-Rmf~(6)(ps-d|S>u=nm-iADqa~-;%!`k|?&U`nyzC2Ct0Q!?>_(b3pfrkxq=r>mPKJ^w#`{3>Z&rAb`16Y=$PwV#LV?JVRwqJU_KX3&H<mN4go7UlXWUcR3^Fvo#vUsFP5R2n%@Ih`#vF;9!H7SVzpZVSC(O2n!M*B%WN3XX2EwsWHRTm7m#p+J$?7cnjkHAAa@fZ&6s5dX+`@qM*THyo6!32iJ5#2Sz%CvD%W{sE~x#rq^+RdM*p+7qcObK+4Rw9qd>;d|#kvHM)<50SXPx$B$uFmk}JW*~M<S@CJoz+B9FG(Ns9XF88)`lXl{t{il!XOW>++2{ZWre)(2{$yTB9_DP_7zZGdure8Nppu@kW2)2ytx=nJO!U}=thd(J7(*()q>U6$Js0NnZUMZ`~~TI?047P-J<RNe}#9ciGF~|pl8}ny{A^&QxlCIWDETWX3csiW{Sh){Xm-DW&X&Qagw*MD#h=>0joUlzwY)_AG+_MXkO@{5P=7iD9dk}z3Y#&oQEmMtY2`Dj9xmMjx@7@T~pp_r%}5B9c-q{L%tlbEN~Ew0lf-(M3zT0yvOU}hwEtecH8py^}DezUC_~mjrjo`z6SZhHGT5@$r`=$^=z%4dDkb;F2Sqrcy!)_>^}A&Bc`n3vlOg%0J@0jZ`imT@$CV<6B^=Mr+T2TaJQk4IvcQ5=#_hdtLiEjbP+l`$RYhSodt9}hx{D+;X+nB=UM+;hqBWF9T%0a4eM=eXXTA#;nd4`Y1w&=hJNJ&{SLSOu||E7=l_rOdVbDgh*^lqWn}wotuFS39IVLtlXKLICFYxL0v_`=*!;Wkd0ps6QM$Wxbz9_Xb3LsRbV$c5AXb!#VA$%ORowB)!)vceEp6g4>12ntAmtXicay?l=&A<O{n{>9bL}=QDn~@MpOg3iQ^e36Kf({PAn44m?`gXc+n-bgBHY=*8)e<mJA#Toy#8&kGy?GvwcR84^pTRJH#HDkds?%f0U`^NH_{9!(#gO`Cz!w|XK$B|7G3#c#JqQgdf2tniB3dx<F&{G)}0rQ-D7rOg=z-N9;16IQjdttXQ+wO_fH)y&*=YE3A{4(qkH@>SH>rdm;-tveP6OzaHb43Y6s;^4Ha|6ai)Vl1I&3aQ>QeW36Geku~PLw8#?;r0^@?wsDh=2Ba<`tKvCguCXhMm9^XU68V?MIszg;qvq^?DLna4Za?hv5{LS3U4i+>lwG+*7Ou=%1Yf`}_;6P_~ECDO1A@&!*Ro+sT+VlATujU*+N1ed76kH<`&H?Ah-dgcMiA@!7r?wmwSsqw9d#cjWr`(-!Pb8@cEV3#<?s(c_A63bka|2ut>|=o3PSDI$6}hrRe?Gh8lXE}KxfKxKX)IWZ%AuoEBn}-KkXf3lrD;zN1m8opRxp8XL>H)J+MhD|yPTFE@|KJjpImIY$W8W^s!GIG8^f6n;Uj~KcOtkbSt<0SgKT)FsivI`C}&FK)4#jtoWN#voXZjZRqa27AC_`Apo*)&bHn?P^`3BM7C=gH##9G=4ok(fLmjitRA{jMCm)V{Fq-MewA~T<Kp;D;HhG5=btANW1MMjb4(KHiAxoT<1p=bce|R2$HUBuOS{XD_nt&HEPi%N@iYWlgkGkL#y%?~99MveMA)p89U_SGC|8Cv|dy|8HVw&5YYR5i^iD1I(MO}5zddbjRhIqkc$gIQcQ}&+o53@Ejb>^6jff_#gw^+PYTO)o*o1w-cSj>9l884|qc=9QGPk0yVkgdJh1QPmfbeb}M3{e<jRgz}t%gF{-2EM6;w^%RZ-6!vUn|CW2@(5qVzH6WtYqQZbqs4UGm1btC$S|UBZK_jsf-H*(Ohfj`>)+?~t8v3$&Bqt~-(SvF^TYZHHo58YUYK7g0pHlX`Tx^+?Y__EVFSywMpZ&&^8_O?-jODNop3Nu6cJS#usIRP(IM0CuxJZ*8M8&vn>av3k699?(8;{Lf6&_YN9VU=>)4mzXskZP^|IEv+zpYHWHZq=Y!(}<b7S5r5KAt{=Af~@zs{e_`TA<&wR61oxDRJCSw)}Wapo)gp0zpQo=;e(j^?TSm?q$Z-Q@zaf`N-Wo!^V_0@%|-m3Y`A`qpFCJFcU~JkEKB4`TCpqRZ_6=`1{)9Ue1`G~gW|8~w{8dh;}fRk_4I2eD3er}>r)gIRa8zlV7S)#LmD{y2NKt2*|7UE@^0{ttM7ok0
""",
    "arm64": """
c-rk<TbG(l*1n$kFW*`mWLB89av^e12g(oRAlwP0TLF!e_5l3)c{XZd_ayIhqS)HWMJJx9+O_MnYwu@2)gM{f|EZekcK_DvcbTE7e~bUo`KQVIbu<~)rcln3g}e!c+03k@r&wUKxF^?BL$9K-yqN}Un;OL?vOj+Od;daZjpaNR(@kv1v#4)vrc1VsA6qVeE^TAOzGNMIVwBr3aB6e0s$-$kX4#uqDD$5xpDS14ayUzt`PQB&yVxkQaN?{`)}tr-yTp*Iv?nW(;Z)It)%HT(PAl1sMZXFKzcy=6u+*r>vPd^wMPv0~%~VSmjXBA7BgkNtBTd(>I^41Pv9#td%i;wq8*IX0nBnueIbomUpB+Q5YlE6B^m?ifi{`!ISEjgHMclB$7@#sAtXdOU*6moTwRSv5b;caeRHtWpn&f2GdgR$P)2xog+0sa}IdiEzO(%?NLDqgO$jjL9wze><Vu3GA&MBgW&c}WG<CW{fXXq!PD3aaBx2wD2|4m~qUg%HPmccP}G0xK}oG72C6Q{5RJ)7dUk)d;;|Dk*nd5W|M^VIe|Hbc3EDLAv#&>t-O`hDaWzJN8U7-++78c6v-XGJ11lp)o(B#RlWw&`SuwPtsH9ZhCj6iD?nkT;Nt!}En%cXyWR?O2c2_~iOB@rwV}V|k1|iYBun(y-17GcN5b^+a&Cp=fO)%>76x3v+>e+5fOJ7ufR*zY_&c9?qqwXc84M_KbU!8GT<e6(h5Ho4&tD8@TfSoj2GME+%{R3$|Wc@{6gMR+5B0j!T2#YsSyc%EHomqqV~|<P7WR<BN5zNc$*fk)pozbGYC)@nW@&1^-K8@Y^V0crUGDL)wH32XdF6r^0NtUkCA5y=_}O(b>XAT*9tC)pKRJU2!yiBiR-h4}x4xE5)Yr$=-y%x#J#kZF#)@5U>3TGGx)jy1G8Rg};l%AvX=A<-pK4QBN5;-tJc9SWg!?lP#oK+`ay~=;1t;2nEitikss1VUQkdjBfo_<M*pfOY7U~;zMcGI7`(QhqGeEvd41dhSkV^L!B+zgM%@hEQ=k^hPlaqwHqHS*W#=?shMimSaUl#ukJ=__v*6x{oxF9HscO*XRu{gX+OWd9D+apwpM-+Ef-}qcBKDx+?~pVe>L|8WHN<;#Ii(Uh9{cApboR{8m}d5%yq)R5=>X?SgtY~1<`z@YCHB~Jl<_P#xnL~r})%;XYJ|n`E)XPk8Of~4`=$xuz+2%o;LR4;~UR&*+~PL3q5`o)B6{CzX5sPVDJ6r6WaTTuHuU^<Ap57*rOuBgKtdQra13JMq1dFgfjvUKQZ?f^@=U|RWKh|hCMHDvuu;Yc}rNYTC!=sS5MpH^`uUWM?vai-t4AE!9~~c8NRH45(UG)r~7Icu+J2G!85Z-t+ibD)qJEUbxJq~r&y<+9zDbvU|-g-DK}}4>~fup&Z?g^XTT6=z)O??J6DPq%*7hION7}r?Mc+WI_+LYMpM9eA4{{OuRKL#_z7UMnpBs8-wQfNeuD(({t&-UMCu=JL*FH$eVO{jrhO05qMSwN_^K8-BLv<y6y$Z%_c@H;nqpXc`9JWMHZ&Y<K>NF7aT;&BcE_qIX2djm&i6)|uUVX~I&P%cnYIln_9gJBYmGYD(=?#*A!o6`ZNg@Zd5}S-I2r7H2j8ck({p@Pw;_L1|DpdIA6K%#`OA<wjJf5s@8o7aT+!Z&xX&gL{WbRWjmI+u<7XJ>5qx}peNQ@w`hJ1A-$}3z+*|*>ko`s9IeY}W=Tl!Pk|p(<?gbiO#7lpOXVz|@Z^#Z#9`9?;CH*1d>5QAg{}*-dSoWT505`xV9Q>{Z;`Dhsiv#$QoA=)PX;(pKq{ipWV&M#b=*_i@?1%OJwMkTPb}d&C;u`lVx5;6R(~6C=kl|xvgDB9k{$ZR=Zgl+?;j3ImMKZrr`{DKSzhC>|2RgV5`{8x6zc2gY2W`F!`{6aR-=qETEA6@m`{9?`b>sHKkJ@zW_QNaWZqt5fa9ROABkV0lbMi2T1=uu3DS1XY`xN;3Uw*e_WlVlR*IL8pv%WQ%QsE4Y=RqdO!X=fgML{%6gL2;|J!y#eDP%35fTw{?&?PM8L3WQ~!5sFb`CHa~Hvah{GNkAEr2nT34)%E`AY6O6^x^v(N@k9=3$dNpkG6#0g#EUTVFN@O{Nqho<SS>zIB1?-MGIhpGyeG;6pCtkc;16A6LtmWAF%OU<M*Az$5>EYA3o0W<0Qv6iomi5`Wo#dTa`-|Mb_X4j%_{IoG1tDk^W=?0}mX5Xk|$S%tLLtA#Yv4#`&QfJfe^bzlaO$ae=oX|Fu71Gm7EFd)(6&@yD9EglQOH9n4Dx9Q^t66q~S;>rcQ`Tyk8e2EY5|GWIdr`rPLc!+8QuFCPm9clz25e9R>pYub71>QB^j)>`?!dW8M!NJo5TE}uV7zSfZ<?v)}2Agfc@E!3C5YA?cx|3tYNhnUd*e_z%pHuM&Cn!+A$X~HHv>+EqU8RjwveD)f17&$=vcX1qT$VGPJKs(0GR`s>@@|X3urIY8es_f7wc@&g5$9l)#Y5VuSLb)iP5C<gO@!2t}Uz0%#1Ah&S+8Eec+82lMBHB*Gu)44ud5Sd$nB^Uw<)W8y0vG4|o>Z`4$fGY{TO9hW9`H^*s7B)t{Ky*shiKO}H{fk=sIuBotlClS%u$)^)wbuAj$8B`_pu(ilvCy#R!$f}U16%PJ8mvo++b(B-O8>9!pQA%ze5{M4mcv@(Xo1{Sgyu7xuZD9QDa%Svs_QK)IxPstF&@YaMZBlWRIfb4SRT9JDJ8q2E$Q3l=TQne8YAV;4Qlw*j<=UW${Oc=j+hqkk`m1e{|ZSPLJ;+*ZcTKzb)t&{*7tS`J>zRbPF3tU&VzyM-EK=N6**MvndQWgzYC^X(R$aKbD%$r{~~T+vx-70J?G?MdoSbBiLD9$gymOUMYG^#b2)X>>R$yEZMQ#f*$Q1b8VdP9q7yw@LXk67QL#K)K9jn>o?X$apYOjNcC0tUwJ!2|L0!i<dj*FNH%A8m<Ju;H^{{o;Hj#ZtKk`~wChx}@tNf@Wu$4~7NDH`1kZ-T@6bk+UpbyeIWv-@<~z&@!E%T2QF|qG^`6CfJ4d5&Q)reNO2|>E?Hr%Eg<*5P&T?NFsgb&`ljanBPqlrkHp^Y=@W$=HccIf8wgcaXes9wbd{4T)WjpZQ>iLfBK*@56XJ}AC&y;J*A^*IzT}K(Ye$N31(MWylI4b(bje545!oG&>?S`<mb7a&aLrQ%VYz`buZlS>z<ekhGe}^`j9L8Ukix?jrjLp)<xMei1I2-2%4`USPi#$>pHy~RZ=a(U3{ji)>4`baDZFkVIbByI|h;vGzpsbyf4{mioze^q7xQ+BKbb7-!()-ZwZQ4lhNw>FbBfVQaU(rSaUarB>t%yT1+;fm!AciUfQ-=0{p9VOXXZ`9fWc0bU$2%eB4D1UZY3o&!2SBe4=OHo%z_Ja_#BTgphIlW-24fHH1-1zoIAGh0M6i!?aq*<P^?`q;oKnI?je(Jl&&WwexkXIeOd9mRbkOG#^bS41m*}{P0l(~eq<P@w<TxiARN%U#@w8@jq1zlH+is+TqouRQP-);wD(1)|u0D-rH*9dH3SsMk&u94l$USpjj_aGrJeHq-p7S(b(U-~DWAhE$qyyVUYZ3TNdBgE^#dNW5xC!cmAHL$?TUUC_r88CtzSBqG=yU=2z~l2xo;EOCRPXQDev$Y$h$HrUe6L+qy#o!{nbO0lUIDsUCH5jhJTuQ;kKCEU=Dcocn&4<&2U?=n&o%I3CjSO49`7-f$mIu4S?1%Veg6EXTo~<;3!^ny9m0_Jz$x+tdvG-stv1Wv+P)JK_R}@MrLth3UGxihOSVaYwg&u`@J!I91^gA2-*deo@l>p_2YqQ%F6?tF*a+aXL%zbYu)%#ubL=z9{q{TFAG>GZyM7=CY=DAZH#rjV0c&;+$MH|qQ^~WmKYJkCU?M8$1HzFx4NvVv0CrfHF|LP=4e<8z%(jHv4>2F2GtNC1lSe$s3B3Hc@W)<jW8qubm8=}v<0gIQDb@YWo>QmOYMq$l+LU;uh(~Few^`SK@-RJtq3`@ni}kp~DdK>$1Z%Z`vS#6;z#8I6ZPs~`bLz*7^@i>dxNv<B$2Hrb^F+VUVw{;K9P%WVL;6kgzKuGYvxvXn|1N>u|GB!(%RTw4y1?_g#F?wwbBN)rf96^5XX`o#tN(+#_W0n*VSnGBwT&sT!KU{um$u<-H7FmX;o<!FCNc>7T<xpX?aPX<&yH(sfSf1(z}d9+F?aFaZSu=6Kd%3$Ojv_$=pu*Rig7=<syq&Ie$s&Y#W|5-xUU<WWGCOBtZ{a`GJy*lIZ~8|_7wRi{K7}xuB9?>vwqA`)U)2({*#N(j|KL>JX~NLT;87eR(1s+o<Y7n%F)KzC~)Rz;}_GTym~r+F&;J?)+2xJ_lsTR>HGB{r@XYa+mdZ}zI?@rt=FE7bdH?J^+is~0(`vi*?qEasgH>h9~>CqK}+}>*Q0;)^6`-XK8pQ*(xz=oK4HplJ#Y+4$TNapB1o6ylb{@SU^CjXU0z*x3${$1_KAyur#J-SE>ce1>UOZN*Ao>kKC!jG<<ln8$hF`r(trucJ4_8rcKLPo`?58*d4Vy|?4i<&9AC~N3~z?}1F}c{S~86dd5y8U&-tCphr7c*fNL1?xK;%W4bR-91D#z(9*=UeJ*<zg|5EJh*yC4}=MNv=scgV84}fRRAs1q0s&^gPPB<I<K>E_~+dkJB_}-DL4crni>%hGyEy{J^rP3Pyj;H5i$)ntC+(Ut=Sr&?;ZkuCiua8vloBwTkkNpGwLdror<f;0*Xm2Z>=8%KSe^8_E5U(8YxbIDDO~&W`AmoZl6wl>ObOwESkijlTYJ&MU5ZM_ytB#1fq$b_R7qLATJR#vo9gfCDS7`2Q8B1&EXBSSA4fF<CCH4vY)M4$N`mQbHy*4@5$k*SvlY-%y2j<Jf6Y>P!Z}`Ea71<IduPAPgJxXZq`fFl|@P}pzxTe9EaPqvxn>lP~a4bwQe&R(z=ZZ&Kd)S=A9Wh+RdfeJlHT>oKKQ{r_L%BVN6ZHprSti75+>@TiK5-t#oIAu)D4ur8i`&H6>RXWm;|p;Lwjw@Sj6LOQvhCx;AFo)~cC0(h?MX-O`5k_{Y&g}fH7*Wv?Bnxn*vMfteiPyXUN`ccvEJdXCBzm=vMUS3JqqHRNsS1;2oC#EQKWQd)S0%_YwI}2W+HzQ`EMgbo>QE<`QKyXJx_|f!Eb@t`1P^#%JR21KRo7~pYj?}`z}@YetZNtyDS<GIlSgq_#U_&;({q^6I>;@hXrd`cWq_PgQX^GiY4Nnn`VBWDTg)<^d-h6)`TKE-t+TvKD<5(`j@3v@;@+YdU#F*TTb=7Wj6lDt*I^;susoWEhVta?@91ey8XskLKvCq*?F%gk324dUFgFng>~Ry^V8TPu0X8KK5_oUTC~Et%z?kANOGO0J2L3=Bair3j)>*ySu(6~hi*;#DPh0D$2)C<KzxX$M17aw4gt&suJN7Q_u3wZ?((4VMm7!Zxf}BELxDHndME8U4=;0DZ6VvzIg5+)w%P+f(30KpSUcWhTPnD3u`;s(IJ@3cTi65E>+C+;Q?63jE$nDhYbov*_wRS_{IB-VT43LITjs~M3~~QE$@1%Q$=hnrI~i+V+f(Fs+ZK_1iTERLmw#B>wDLaN;;eCQKjB#i9&&#^Z>w+6jsoZB#!r0kO`O*61QzgN-}u*<ig6F$X{$EZYh?O2<fuq4d*X1(yn}mAbLrOPnE;a#wl}X{Bi9pgR-2i<+23tA>)~1AJ}i>klB?hNtlF~^e?_KY)Sf)2xVGo_{q66d-1ymG`y4|eXM1jKX$gPz3jWk5!g-(E(`ZJMVh4`LhGTeqyz{OPpI^ZmTnz9@gg-vu5#UFkAV&ye0Wle@OQivPUyYbBwMzk?@8_ub{D}FMi*)Hcq?uMtUf7ZoZm2m~UQv#@=^-~u1GZdMboj(2JGV;2dJW671;=H`I|sU({{TK-o8omH#($uAOKmQWW$ymy{8~C+wz@uDRo~F_3Vt@ar+JGz<vDP3mR9j%T`s8I$lc?R$2aFH+s%oS9<e@eO<Y{goYyRG0PchVVvvY$bMSfA8b{ACRj2!@CEV}*wah<y`zgI~v2a)GsfGJ&#?14D2G;|>U_`!6ieqs@!m%}RmUv<RS!@6F$M3cd|59K4S)=b-r+2!37x{iJM_<q1(YJDHn=pz(<ImZEqu^ghy&+zAp|id(q`FKzOb=i0q1JQ`7@G$>cZ?BoW}*8v_&7DY;y6q5aA$qd1IH8kCM>~0pj#YpTXm{VY76}VZUpsFoYajkdUJ`pt^f2*JAKolZ~Yeg<n)aF<NXr4v0NQIXKBxLhv4$?uwMeTIOY{_aTum&gIfdqWEo)rHPO+V{jwxpTg(5@_*L%Pez^nvo@tLXc~HmPk~45tFUmP^e)yeK-{-N}gaf)j&iKoEp533AH}@y%hx-#%>N~pYk}%27^1bo{j`9Ncy8op-xYLU`OMurz&NBP_J+6d{)wR&;J!VhewBD}&zGIZ1j$5u1{&!$Pk!RX=J+oa{Ni)LHrZj&MA3uA{p5D8~<32B;G^Z0AoHp_ncHz3=7V1d?5bA3un}IX3D_Wklw!sI%#@Nfimt=wio3KaV`{seb2L2jcNSv>Jy(4Zc5k~vV-~R(%7&e3
""",
}


def bad(label: str, detail: str) -> None:
    problems.append("%s: %s" % (label, detail))


def ok(label: str) -> None:
    print("ok   %s" % label)


def field(raw: bytes) -> str:
    return "b64:" + base64.urlsafe_b64encode(raw).decode("ascii")


def decode_field(value: str) -> bytes:
    if not value.startswith("b64:") or not value.isascii():
        raise ValueError("not canonical")
    raw = base64.b64decode(value[4:].encode("ascii"), altchars=b"-_", validate=True)
    if field(raw) != value:
        raise ValueError("not canonical")
    return raw


def ensure_private_namespaces() -> None:
    keys = ("user", "net", "pid", "mnt")
    if os.environ.get("ZB_C_OWNER_INNER") == "1":
        for key in keys:
            outer = os.environ.get("ZB_C_OWNER_OUTER_%s" % key.upper(), "")
            now = os.readlink("/proc/self/ns/%s" % key)
            if not outer or now == outer:
                print("FAIL\tms1c-home-owner-policy-red\tprivate %s namespace not established" % key)
                raise SystemExit(1)
        return
    env = os.environ.copy()
    env["ZB_C_OWNER_INNER"] = "1"
    for key in keys:
        env["ZB_C_OWNER_OUTER_%s" % key.upper()] = os.readlink("/proc/self/ns/%s" % key)
    os.execvpe(
        "unshare",
        ["unshare", "--user", "--map-current-user", "--net", "--pid", "--fork", "--mount-proc",
         sys.executable, os.path.realpath(__file__)],
        env,
    )


def extract_home_diff() -> str:
    source = GATE.read_text(encoding="utf-8")
    start_marker = "HOME_DIFF_PY='\n"
    end_marker = "\n'\ntake() {"
    if source.count(start_marker) != 1:
        raise ValueError("HOME_DIFF_PY assignment is not unique")
    start = source.index(start_marker) + len(start_marker)
    end = source.index(end_marker, start)
    code = source[start:end]
    mutant = os.environ.get("ZB_MS1C_HOME_OWNER_MUTANT", "")
    if mutant:
        if mutant != "ignore-diagnostic-directory-metadata":
            raise ValueError("unknown owner-policy mutant %r" % mutant)
        anchor = "for rel in sorted(set(a) | set(b)):\n"
        if code.count(anchor) != 1:
            raise ValueError("owner-policy mutant anchor count is %d" % code.count(anchor))
        code = code.replace(anchor, anchor + "    if rel == diag_raw:\n        continue\n")
    return code


FILE_A = "f 600 501 20 1 11 100 100 110 %s -"
FILE_B = "f 600 501 20 1 17 200 200 110 %s -"
DIR_A = "d 700 501 20 2 64 100 100 120 - -"
DIR_B = "d 700 501 20 3 96 200 200 120 - -"
ROOT_META = "d 700 501 20 8 256 50 50 100 - -"


def digest_for(path: bytes, version: bytes) -> str:
    return hashlib.sha256(path + b"\0" + version).hexdigest()


def file_meta(path: bytes, version: bytes, digest: Optional[str] = None) -> str:
    value = digest if digest is not None else digest_for(path, version)
    return (FILE_A if version == b"before" else FILE_B) % value


def link_meta(path: bytes, target: bytes, version: bytes) -> str:
    stamp = "100" if version == b"before" else "200"
    return "l 777 501 20 1 %d %s %s 130 - %s" % (len(target), stamp, stamp, field(target))


def snapshot_bytes(
    root: bytes,
    rows: Mapping[bytes, str],
    side: str,
    markers: Sequence[Tuple[bytes, str]] = (),
    errors: Sequence[Tuple[bytes, str]] = (),
) -> bytes:
    exclude = root + b"/zb-gate-owner-red"
    out = ["ROOT\t%s\t%s" % (field(root), field(exclude))]
    for path in sorted(rows):
        out.append("%s\t%s" % (field(path), rows[path]))
    for path, reason in sorted(markers, key=lambda item: item[0]):
        out.append("SKIPPED-PROTECTED\t%s\tHOME\t%s\t%s" % (side, field(path), reason))
    for path, reason in errors:
        out.append("ERROR\t%s\t%s" % (field(path), reason))
    out.append("END\t%d" % len(rows))
    return ("\n".join(out) + "\n").encode("ascii")


def report_row(name: bytes, digest: str, kind: str, pid: int, proc_path: bytes) -> str:
    return "CRASHREPORT\t%s\t%s\t%s\t%s\t%s" % (
        field(name), digest, kind, pid if pid >= 0 else "-", field(proc_path) if proc_path else "-"
    )


def derive_deltas(root: bytes, before: Mapping[bytes, str], after: Mapping[bytes, str]) -> List[str]:
    result = []
    for rel in sorted(set(before) | set(after)):
        if rel in before and rel in after and before[rel] == after[rel]:
            continue
        kind = "ADDED" if rel not in before else "DELETED" if rel not in after else "CHANGED"
        path = root if rel == b"." else root + b"/" + rel
        result.append("HOME-DELTA\t%s\t%s\t%s\t%s" % (
            kind, field(path), before.get(rel, "-"), after.get(rel, "-")))
    return result


def bundle_reason(rel: bytes, kind: str, crash_kinds: Mapping[bytes, str]) -> Optional[str]:
    if rel.startswith(DIAG + b"/") and rel.endswith(b".ips"):
        if kind in ("CHANGED", "DELETED"):
            return "crash-report"
        report_kind = crash_kinds.get(rel.rsplit(b"/", 1)[1])
        if report_kind == "CONTROL":
            return None
        if report_kind in ("PRODUCT", "OTHER"):
            return "crash-report"
        return None
    components = rel.split(b"/")
    saved = (b"Library", b"Saved Application State", APP_ID + b".savedState")
    if tuple(components[:3]) == saved:
        return "saved-state"
    if any(component == APP_ID or component.startswith(APP_ID + b".") for component in components):
        return "bundle-id"
    return None


def expected_lines(
    root: bytes,
    before: Mapping[bytes, str],
    after: Mapping[bytes, str],
    crash_kinds: Mapping[bytes, str],
) -> Tuple[int, List[str]]:
    deltas = derive_deltas(root, before, after)
    attrs = []
    for line in deltas:
        _tag, kind, encoded, _old, _new = line.split("\t", 4)
        absolute = decode_field(encoded)
        rel = b"." if absolute == root else absolute[len(root) + 1:]
        reason = bundle_reason(rel, kind, crash_kinds)
        if reason:
            attrs.append("HOME-ATTRIBUTABLE\t%s\t%s\t%s" % (kind, encoded, reason))
    if attrs:
        return 2, deltas + attrs + ["HOMEAUDIT\tFAIL\t%d" % len(attrs)]
    if deltas:
        return 0, deltas + ["HOMEAUDIT\tAMBIENT\t%d" % len(deltas)]
    return 0, ["HOMEAUDIT\tCLEAN\t0"]


class Differ:
    def __init__(self, code: str, work: Path) -> None:
        self.code = code
        self.work = work
        self.serial = 0
        self.python = "/usr/bin/python3" if Path("/usr/bin/python3").is_file() else sys.executable
        self.home = work / "home"
        self.tmp = work / "tmp"
        self.xdg = work / "xdg"
        for path in (self.home, self.tmp, self.xdg):
            path.mkdir()

    def run(
        self,
        before: Mapping[bytes, str],
        after: Mapping[bytes, str],
        reports: Sequence[str] = (),
        before_markers: Sequence[Tuple[bytes, str]] = (),
        after_markers: Sequence[Tuple[bytes, str]] = (),
        before_errors: Sequence[Tuple[bytes, str]] = (),
        after_errors: Sequence[Tuple[bytes, str]] = (),
        raw_before: Optional[bytes] = None,
        raw_after: Optional[bytes] = None,
    ) -> subprocess.CompletedProcess:
        self.serial += 1
        case = self.work / ("case-%03d" % self.serial)
        case.mkdir()
        root = b"/Users/owner"
        (case / "before").write_bytes(raw_before if raw_before is not None else snapshot_bytes(
            root, before, "BEFORE", before_markers, before_errors))
        (case / "after").write_bytes(raw_after if raw_after is not None else snapshot_bytes(
            root, after, "AFTER", after_markers, after_errors))
        (case / "reports").write_text("\n".join(reports) + ("\n" if reports else ""), encoding="ascii")
        env = {
            "PATH": "/usr/bin:/bin",
            "HOME": str(self.home),
            "TMPDIR": str(self.tmp),
            "XDG_DATA_HOME": str(self.xdg / "data"),
            "XDG_CACHE_HOME": str(self.xdg / "cache"),
            "XDG_CONFIG_HOME": str(self.xdg / "config"),
            "XDG_RUNTIME_DIR": str(self.xdg / "runtime"),
            "LC_ALL": "C",
        }
        return subprocess.run(
            [self.python, "-I", "-B", "-X", "utf8", "-c", self.code,
             str(case / "before"), str(case / "after"), os.fsdecode(root),
             os.fsdecode(DIAG), "/private/control/zigBrowser", str(PROTECTED), str(case / "reports")],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, text=True, timeout=20,
        )


def base_rows() -> Dict[bytes, str]:
    return {b".": ROOT_META}


def pair_for(
    kind: str,
    path: bytes,
    link_target: Optional[bytes] = None,
    directory: bool = False,
) -> Tuple[Dict[bytes, str], Dict[bytes, str]]:
    before, after = base_rows(), base_rows()
    if directory:
        old, new = DIR_A, DIR_B
    else:
        old = link_meta(path, link_target, b"before") if link_target is not None else file_meta(path, b"before")
        new = link_meta(path, link_target, b"after") if link_target is not None else file_meta(path, b"after")
    if kind != "ADDED":
        before[path] = old
    if kind != "DELETED":
        after[path] = new
    return before, after


def check_complete(
    differ: Differ,
    label: str,
    before: Mapping[bytes, str],
    after: Mapping[bytes, str],
    reports: Sequence[str] = (),
    crash_kinds: Optional[Mapping[bytes, str]] = None,
) -> None:
    expected_rc, expected = expected_lines(b"/Users/owner", before, after, crash_kinds or {})
    result = differ.run(before, after, reports)
    actual = result.stdout.splitlines()
    if result.returncode == expected_rc and actual == expected and not result.stderr:
        ok(label)
    else:
        bad(label, "rc=%s want=%s; got=%r; want-tail=%r; stderr=%r" % (
            result.returncode, expected_rc, actual[-4:], expected[-4:], result.stderr[-300:]))


def check_inconclusive(
    differ: Differ,
    label: str,
    before: Mapping[bytes, str],
    after: Mapping[bytes, str],
    reports: Sequence[str] = (),
    **kwargs: object,
) -> None:
    result = differ.run(before, after, reports, **kwargs)
    lines = result.stdout.splitlines()
    valid = (
        result.returncode == 3 and len(lines) == 1
        and lines[0].startswith("HOMEAUDIT\tINCONCLUSIVE\t")
        and len(lines[0].encode("utf-8")) <= 1000
        and "HOME-DELTA\t" not in result.stdout
        and "HOME-ATTRIBUTABLE\t" not in result.stdout
        and "HOMEAUDIT\tCLEAN\t" not in result.stdout
        and "HOMEAUDIT\tAMBIENT\t" not in result.stdout
        and "HOMEAUDIT\tFAIL\t" not in result.stdout
        and "Traceback" not in result.stderr
    )
    if valid:
        ok(label)
    else:
        bad(label, "not one bounded fail-closed verdict: rc=%s out=%r err=%r" % (
            result.returncode, lines[-5:], result.stderr[-300:]))


def retained_blob(arch: str) -> bytes:
    encoded = "".join(RETAINED_B85[arch].split()).encode("ascii")
    data = zlib.decompress(base64.b85decode(encoded))
    if hashlib.sha256(data).hexdigest() != SOURCE_HASHES[arch]["compact-deltas"]:
        raise ValueError("%s compact retained fixture digest mismatch" % arch)
    return data


def retained_pair(arch: str) -> Tuple[bytes, Dict[bytes, str], Dict[bytes, str], Dict[bytes, str], List[str]]:
    blob = retained_blob(arch)
    rows = blob.decode("ascii").splitlines()
    expected_count = 172 if arch == "x86_64" else 222
    expected_kinds = ({"CHANGED": 153, "ADDED": 10, "DELETED": 9}
                      if arch == "x86_64" else {"CHANGED": 214, "ADDED": 4, "DELETED": 4})
    if len(rows) != expected_count:
        raise ValueError("%s retained fixture count" % arch)
    parsed: List[Tuple[str, bytes]] = []
    kinds: Dict[str, int] = {}
    for line in rows:
        tag, kind, encoded = line.split("\t")
        path = decode_field(encoded)
        if tag != "HOME-DELTA" or kind not in ("ADDED", "CHANGED", "DELETED"):
            raise ValueError("bad retained row")
        kinds[kind] = kinds.get(kind, 0) + 1
        parsed.append((kind, path))
    if kinds != expected_kinds or [path for _kind, path in parsed] != sorted(path for _kind, path in parsed):
        raise ValueError("%s retained kind/order contract" % arch)
    root = b"/Users/maceojourdan" if arch == "x86_64" else b"/Users/laroncha"
    if any(not path.startswith(root + b"/") for _kind, path in parsed):
        raise ValueError("%s retained root" % arch)
    paths = {path for _kind, path in parsed}
    before, after = {b".": ROOT_META}, {b".": ROOT_META}
    for kind, absolute in parsed:
        rel = absolute[len(root) + 1:]
        is_dir = any(other.startswith(absolute + b"/") for other in paths) or absolute == root + b"/" + DIAG
        old = DIR_A if is_dir else file_meta(rel, b"before")
        new = DIR_B if is_dir else file_meta(rel, b"after")
        if absolute.endswith(b"zigBrowser-2026-10-24-155223.ips"):
            new = file_meta(rel, b"after", "55a497f17d8b40ce501ac2465fa3c60b490a48aa196bf4a56936a8e1a726126d")
        if absolute.endswith(b"zigBrowser-2026-10-24-160515.ips"):
            new = file_meta(rel, b"after", "5c28369e19a58b4f2d4dc40a90f0f98fead2a3a9ecbf0b915ff51436270bf0ec")
        if absolute.endswith(b"zigBrowser-2026-10-24-160541.ips"):
            new = file_meta(rel, b"after", "ed0266139ae1ac83416e7d2ee54a7ed817ffeb2dc4008fc8ba4d3575b8c72e13")
        if kind != "ADDED":
            before[rel] = old
        if kind != "DELETED":
            after[rel] = new
    control_name = (b"zigBrowser-2026-10-24-155223.ips" if arch == "x86_64"
                    else b"zigBrowser-2026-10-24-160515.ips")
    control_sha = ("55a497f17d8b40ce501ac2465fa3c60b490a48aa196bf4a56936a8e1a726126d"
                   if arch == "x86_64" else "5c28369e19a58b4f2d4dc40a90f0f98fead2a3a9ecbf0b915ff51436270bf0ec")
    control_path = b"/private/run/control/zigBrowser.app/Contents/MacOS/zigBrowser"
    reports = [report_row(control_name, control_sha, "CONTROL", 9006, control_path)]
    crash_kinds = {control_name: "CONTROL"}
    if arch == "arm64":
        product_name = b"zigBrowser-2026-10-24-160541.ips"
        reports.append(report_row(product_name,
                                  "ed0266139ae1ac83416e7d2ee54a7ed817ffeb2dc4008fc8ba4d3575b8c72e13",
                                  "PRODUCT", 9005,
                                  b"/private/run/app/zigBrowser.app/Contents/MacOS/zigBrowser"))
        crash_kinds[product_name] = "PRODUCT"
    return root, before, after, crash_kinds, reports


def run_retained(differ: Differ, arch: str) -> None:
    root, before, after, crash_kinds, reports = retained_pair(arch)
    expected_rc, expected = expected_lines(root, before, after, crash_kinds)
    # Differ.run has a fixed synthetic root, so run this case directly with the
    # retained account root while preserving the same production invocation.
    differ.serial += 1
    case = differ.work / ("retained-%s" % arch)
    case.mkdir()
    (case / "before").write_bytes(snapshot_bytes(root, before, "BEFORE"))
    (case / "after").write_bytes(snapshot_bytes(root, after, "AFTER"))
    (case / "reports").write_text("\n".join(reports) + "\n", encoding="ascii")
    env = {"PATH": "/usr/bin:/bin", "HOME": str(differ.home), "TMPDIR": str(differ.tmp), "LC_ALL": "C"}
    result = subprocess.run(
        [differ.python, "-I", "-B", "-X", "utf8", "-c", differ.code,
         str(case / "before"), str(case / "after"), os.fsdecode(root), os.fsdecode(DIAG),
         "/private/control/zigBrowser", str(PROTECTED), str(case / "reports")],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, text=True, timeout=30,
    )
    actual = result.stdout.splitlines()
    delta_actual = [line for line in actual if line.startswith("HOME-DELTA\t")]
    delta_expected = [line for line in expected if line.startswith("HOME-DELTA\t")]
    attr_actual = [line for line in actual if line.startswith("HOME-ATTRIBUTABLE\t")]
    attr_expected = [line for line in expected if line.startswith("HOME-ATTRIBUTABLE\t")]
    wanted_final = ("HOMEAUDIT\tAMBIENT\t172" if arch == "x86_64" else "HOMEAUDIT\tFAIL\t1")
    valid = (
        result.returncode == expected_rc and delta_actual == delta_expected
        and attr_actual == attr_expected and actual[-1:] == [wanted_final]
        and not result.stderr
    )
    if valid:
        ok("C-provenance-%s: exact retained delta set and owner verdict" % arch)
    else:
        bad("C-provenance-%s" % arch,
            "rc=%s/%s deltas=%s/%s attrs=%r/%r final=%r stderr=%r source-hashes=%r" % (
                result.returncode, expected_rc, len(delta_actual), len(delta_expected),
                attr_actual, attr_expected, actual[-1:] if actual else [], result.stderr[-200:], SOURCE_HASHES[arch]))


GATE_SUFFIX = r'''
cp -f -- "$ROOT/tests/mac/ms1c_home_protected_paths.txt" "$R/tests/mac/ms1c_home_protected_paths.txt" \
  && "${GIT[@]}" add -- tests/mac/ms1c_home_protected_paths.txt \
  && "${GIT[@]}" -c user.name=selftest -c user.email=selftest@invalid commit -q -m protected-data \
  || { bad "C owner policy: could not add protected-path data"; exit 1; }
TREE=$("${GIT[@]}" rev-parse 'HEAD^{tree}')
COMMITSHA=$("${GIT[@]}" rev-parse HEAD)

owner_clean() {
  local role
  for role in intel arm; do
    rm -f "$X/hosts/$role/Library/Preferences/owner-ambient.plist"
    printf seed > "$X/hosts/$role/Library/Preferences/com.cosmichq.zigBrowser.owner.plist"
  done
}
home_log() { if [ "$1" = intel ]; then printf '%s/x86_64/evidence/leg.log' "$EV"; else printf '%s/arm64/evidence/leg.log' "$EV"; fi; }
evidence_ok() { [ -f "$EV/manifest.sha256" ] && (cd "$EV" && sha256sum -c --quiet manifest.sha256); }
home_contract() { # role verdict number delta-count attr-count
  local log
  log=$(home_log "$1")
  [ "$(grep -c "^HOME-DELTA${TB}" "$log" 2>/dev/null)" -eq "$4" ] \
    && [ "$(grep -c "^HOME-ATTRIBUTABLE${TB}" "$log" 2>/dev/null)" -eq "$5" ] \
    && grep -qxF "HOMEAUDIT${TB}$2${TB}$3" "$log"
}

# G1: the one exact control report is retained as ordinary ambient HOME evidence.
owner_clean; run_gate c-owner-control
if [ "$rc" -eq 0 ] && leg_is x86_64 PASS && leg_is arm64 PASS \
   && home_contract intel AMBIENT 2 2 0 && home_contract arm AMBIENT 2 2 0 && evidence_ok; then
  ok "C-gate-control: AMBIENT/0 preserves both prior leg verdicts and records both deltas"
else bad "C-gate-control: rc=$rc $(tailout)"; fi

# G2: unrelated churn remains evidence but no longer makes the leg inconclusive.
owner_clean; run_gate c-owner-ambient owner_ambient.intel
if [ "$rc" -eq 0 ] && leg_is x86_64 PASS && leg_is arm64 PASS \
   && home_contract intel AMBIENT 3 3 0 && home_contract arm AMBIENT 2 2 0 && evidence_ok; then
  ok "C-gate-ambient: unrelated HOME delta is recorded and preserves PASS"
else bad "C-gate-ambient: rc=$rc $(tailout)"; fi

# G3: one exact dotted bundle component maps classifier rc 2 to product FAIL.
owner_clean; run_gate c-owner-bundle owner_bundle.intel
if [ "$rc" -eq 1 ] && leg_is x86_64 FAIL && leg_is arm64 PASS && no_pass \
   && home_contract intel FAIL 1 3 1 && home_contract arm AMBIENT 2 2 0 \
   && grep -q "^FAIL${TB}home-audit${TB}" "$(home_log intel)" && evidence_ok; then
  ok "C-gate-fail: bundle delta maps to named product failure"
else bad "C-gate-fail: rc=$rc $(tailout)"; fi

# G4: malformed after evidence maps rc 3 to audit-incomplete, with no partial verdict.
owner_clean; run_gate c-owner-incomplete lock_after.intel
ilog=$(home_log intel)
if [ "$rc" -eq 2 ] && leg_is x86_64 INCONCLUSIVE && leg_is arm64 PASS && no_pass \
   && [ "$(grep -c "^HOMEAUDIT${TB}INCONCLUSIVE${TB}" "$ilog")" -eq 1 ] \
   && ! grep -qE "^HOME-(DELTA|ATTRIBUTABLE)${TB}|^HOMEAUDIT${TB}(CLEAN|AMBIENT|FAIL)${TB}" "$ilog" \
   && [ -f "$EV/x86_64/evidence/home.after" ] && evidence_ok; then
  ok "C-gate-inconclusive: incomplete after snapshot stays fail closed"
else bad "C-gate-inconclusive: rc=$rc $(tailout)"; fi

# G5: an independent audit's incompleteness wins overall, but D and C product evidence survives.
owner_clean; run_gate c-owner-precedence owner_product.intel var_unreadable.intel
ilog=$(home_log intel)
if [ "$rc" -eq 2 ] && leg_is x86_64 INCONCLUSIVE && leg_is arm64 PASS && no_pass \
   && home_contract intel FAIL 1 3 1 \
   && grep -q "^PRODUCT-FAIL${TB}crash-report${TB}" "$ilog" \
   && grep -q "^VARFOLDERS${TB}INCONCLUSIVE${TB}" "$ilog" \
   && [ -f "$EV/x86_64/evidence/home.after" ] && evidence_ok; then
  ok "C-gate-precedence: other incomplete audit wins while product finding remains copied"
else bad "C-gate-precedence: rc=$rc $(tailout)"; fi

if [ "$fails" -eq 0 ]; then
  printf 'PASS\tms1c-home-owner-policy-red\tthree verdicts, exact deltas, retained provenance and gate mapping\n'
else
  printf 'FAIL\tms1c-home-owner-policy-red\t%s gate contract rows failed\n' "$fails"
  exit 1
fi
'''


def gate_driver(work: Path) -> subprocess.CompletedProcess:
    source = SELFTEST.read_text(encoding="utf-8")
    marker = "# ── Base run ──\n"
    if source.count(marker) != 1:
        raise ValueError("base gate fixture boundary is not unique")
    prefix = source.split(marker, 1)[0]
    ambient_needle = ('    on home_write && { mkdir -p "\\$REAL/Library/Caches/zigBrowser"; '
                      'echo db > "\\$REAL/Library/Caches/zigBrowser/cache.db"; }')
    if prefix.count(ambient_needle) != 1:
        raise ValueError("workload execution seam is not unique")
    prefix = prefix.replace(
        ambient_needle,
        ambient_needle
        + '\n    on owner_ambient && echo bbbb > "\\$REAL/Library/Preferences/keep.plist"'
        + '\n    on owner_bundle && echo owned > "\\$REAL/Library/Preferences/com.cosmichq.zigBrowser.owner.plist"',
    )
    product_needle = "  if on control_rc0; then control_terminal=0; printf 'CONTROL_RC\\t0\\n'; else"
    if prefix.count(product_needle) != 1:
        raise ValueError("control execution seam is not unique")
    product_injection = r'''  if on owner_product; then
    product="\$REAL/Library/Logs/DiagnosticReports/unrelated-name.ips"
    printf '{"app_name":"zigBrowser","timestamp":"2026-10-24 16:05:41.00 -0400","slice_uuid":"PRODUCT-733135F6","bundleID":"com.cosmichq.zigBrowser","bug_type":"309","os_version":"macOS 15.7.1","name":"zigBrowser","incident_id":"PRODUCT-733135F6"}\n' > "\$product"
    printf '{"pid":%s,"procName":"zigBrowser","procPath":"%s","bundleInfo":{"CFBundleIdentifier":"com.cosmichq.zigBrowser"},"exception":{"type":"EXC_BREAKPOINT","signal":"SIGTRAP"},"termination":{"namespace":"SIGNAL","indicator":"Trace/BPT trap: 5"}}\n' "\$((base + 5))" "\$app" >> "\$product"
  fi
'''
    prefix = prefix.replace(product_needle, product_injection + product_needle)
    driver = work / "gate-driver.sh"
    driver.write_text(prefix + GATE_SUFFIX, encoding="utf-8")
    driver.chmod(0o700)
    env = {
        "PATH": "/usr/bin:/bin",
        "HOME": str(work / "driver-home"),
        "TMPDIR": str(work / "driver-tmp"),
        "XDG_DATA_HOME": str(work / "driver-xdg-data"),
        "XDG_CACHE_HOME": str(work / "driver-xdg-cache"),
        "XDG_CONFIG_HOME": str(work / "driver-xdg-config"),
        "XDG_RUNTIME_DIR": str(work / "driver-xdg-runtime"),
        "LC_ALL": "C",
    }
    for name in ("HOME", "TMPDIR", "XDG_DATA_HOME", "XDG_CACHE_HOME", "XDG_CONFIG_HOME", "XDG_RUNTIME_DIR"):
        Path(env[name]).mkdir()
    return subprocess.run(
        ["bash", str(driver), str(ROOT)], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, env=env, timeout=300,
    )


def main() -> int:
    ensure_private_namespaces()
    required = (GATE, SELFTEST, PROTECTED)
    missing = [str(path) for path in required if not path.is_file()]
    if missing:
        print("FAIL\tms1c-home-owner-policy-red\tmissing inputs %r" % missing)
        return 1
    scratch = Path(os.environ.get("TMPDIR", ""))
    if not scratch.is_dir():
        print("FAIL\tms1c-home-owner-policy-red\tTMPDIR must name private scratch")
        return 1
    work = Path(tempfile.mkdtemp(prefix="home-owner-policy-red-", dir=str(scratch)))
    try:
        try:
            differ = Differ(extract_home_diff(), work)
            retained_blob("x86_64")
            retained_blob("arm64")
        except (OSError, ValueError, binascii.Error, zlib.error) as exc:
            print("FAIL\tms1c-home-owner-policy-red\tSETUP %s" % exc)
            return 1

        # C0-C1: exact clean output and mixed unrelated add/change/delete in raw-byte order.
        rows = base_rows()
        check_complete(differ, "C0-clean", rows, rows)
        before, after = base_rows(), base_rows()
        before[b"Library/Application Support/Discord/old"] = file_meta(b"discord", b"before")
        before[b"Library/Preferences/com.apple.owner.plist"] = file_meta(b"apple", b"before")
        after[b"Library/Preferences/com.apple.owner.plist"] = file_meta(b"apple", b"after")
        after[b"Library/Caches/Chrome/new"] = file_meta(b"chrome", b"after")
        check_complete(differ, "C1-ambient-add-change-delete-order", before, after)
        before, after = base_rows(), base_rows()
        for raw_name in (b"\x02-ambient", b"a-ambient", b"\xff-ambient"):
            after[b"Library/Caches/" + raw_name] = file_meta(raw_name, b"after")
        check_complete(differ, "C1-ambient-original-byte-order", before, after)

        # C2: both component forms, all six representative locations, all delta kinds.
        locations = (
            b"Library/Caches", b"Library/WebKit", b"Library/HTTPStorages",
            b"Library/Containers", b"Library/Application Support", b"Library/Preferences",
        )
        for parent in locations:
            for component in (APP_ID, APP_ID + b".owner.plist"):
                path = parent + b"/" + component + b"/state.bin"
                for kind in ("ADDED", "CHANGED", "DELETED"):
                    before, after = pair_for(kind, path)
                    check_complete(differ, "C2-%s-%s-%s" % (
                        parent.decode().replace(" ", "_"), component.decode(), kind.lower()), before, after)
        for kind in ("ADDED", "CHANGED", "DELETED"):
            path = b"Library/Preferences/" + APP_ID + b".plist"
            before, after = pair_for(kind, path)
            check_complete(differ, "C2-exact-plist-component-%s" % kind.lower(), before, after)

        # C3: the exact Saved Application State subtree, both its root and descendants.
        saved = b"Library/Saved Application State/" + APP_ID + b".savedState"
        for path in (saved, saved + b"/windows.plist"):
            for kind in ("ADDED", "CHANGED", "DELETED"):
                before, after = pair_for(kind, path, directory=(path == saved))
                check_complete(differ, "C3-saved-%s-%s" % (
                    "root" if path == saved else "child", kind.lower()), before, after)

        # C4: near misses and link-target/raw-text decoys are ambient for every delta kind.
        near = (
            b"com.cosmichq.zigBrowser2", b"com.cosmichq.zigBrowserish",
            b"prefix-com.cosmichq.zigBrowser", b"Com.CosmicHQ.zigBrowser",
            b"com.cosmichq.ZIGBROWSER",
        )
        for component in near:
            for kind in ("ADDED", "CHANGED", "DELETED"):
                before, after = pair_for(kind, b"Library/Caches/" + component + b"/state")
                check_complete(differ, "C4-near-%s-%s" % (component.decode(), kind.lower()), before, after)
        before, after = pair_for("CHANGED", b"Library/Caches/unrelated-link",
                                 b"../com.cosmichq.zigBrowser/control\x02\xff")
        check_complete(differ, "C4-link-target-substring-is-ambient", before, after)
        for path in (b"Library/Caches/zigBrowser/state", b"Library/Caches/browser-9005/state"):
            before, after = pair_for("CHANGED", path)
            check_complete(differ, "C4-process-or-app-name-is-ambient-%s" % path.rsplit(b"/", 2)[-2].decode(),
                           before, after)

        # C5: consume D records.  The HOME differ never guesses from report names or bodies.
        diag_meta_before, diag_meta_after = DIR_A, DIR_B
        control = b"control.ips"
        product = b"innocent-name.ips"
        control_sha = "1" * 64
        product_sha = "2" * 64
        ctl_path = b"/private/run/control/zigBrowser.app/Contents/MacOS/zigBrowser"
        app_path = b"/private/run/app/zigBrowser.app/Contents/MacOS/zigBrowser"

        before, after = base_rows(), base_rows()
        before[DIAG], after[DIAG] = diag_meta_before, diag_meta_after
        after[DIAG + b"/" + control] = file_meta(control, b"after", control_sha)
        reports = [report_row(control, control_sha, "CONTROL", 7006, ctl_path)]
        check_complete(differ, "C5-one-control-is-ambient", before, after, reports, {control: "CONTROL"})

        before, after = base_rows(), base_rows()
        before[DIAG], after[DIAG] = diag_meta_before, diag_meta_after
        after[DIAG + b"/" + product] = file_meta(product, b"after", product_sha)
        reports = [report_row(product, product_sha, "PRODUCT", 7005, app_path)]
        check_complete(differ, "C5-product-only-fails", before, after, reports, {product: "PRODUCT"})

        before, after = base_rows(), base_rows()
        before[DIAG], after[DIAG] = diag_meta_before, diag_meta_after
        after[DIAG + b"/" + control] = file_meta(control, b"after", control_sha)
        after[DIAG + b"/" + product] = file_meta(product, b"after", product_sha)
        reports = [report_row(control, control_sha, "CONTROL", 7006, ctl_path),
                   report_row(product, product_sha, "PRODUCT", 7005, app_path)]
        check_complete(differ, "C5-control-plus-delayed-product-fails-once", before, after, reports,
                       {control: "CONTROL", product: "PRODUCT"})

        second = b"second-control.ips"
        second_sha = "3" * 64
        before, after = base_rows(), base_rows()
        before[DIAG], after[DIAG] = diag_meta_before, diag_meta_after
        after[DIAG + b"/" + control] = file_meta(control, b"after", control_sha)
        after[DIAG + b"/" + second] = file_meta(second, b"after", second_sha)
        reports = [report_row(control, control_sha, "CONTROL", 7006, ctl_path),
                   report_row(second, second_sha, "PRODUCT", 7006, ctl_path)]
        check_complete(differ, "C5-second-control-is-product", before, after, reports,
                       {control: "CONTROL", second: "PRODUCT"})

        other = b"Other-application.ips"
        other_sha = "4" * 64
        before, after = base_rows(), base_rows()
        before[DIAG], after[DIAG] = diag_meta_before, diag_meta_after
        after[DIAG + b"/" + other] = file_meta(other, b"after", other_sha)
        reports = [report_row(other, other_sha, "OTHER", 7999, b"/Applications/Other.app/Contents/MacOS/Other")]
        check_complete(differ, "C5-noncontrol-report-is-policy-failure", before, after, reports, {other: "OTHER"})

        for kind in ("CHANGED", "DELETED"):
            before, after = pair_for(kind, DIAG + b"/pre-existing.ips")
            check_complete(differ, "C5-preexisting-report-%s" % kind.lower(), before, after)

        # The directory metadata is ambient only beside one verified control.
        # Standing alone it cannot be attributed to that bounded exception.
        before, after = base_rows(), base_rows()
        before[DIAG], after[DIAG] = DIR_A, DIR_B
        check_inconclusive(differ, "C5-standalone-diagnostic-directory-is-unverifiable", before, after)

        # Missing/unreadable/malformed or disagreeing D attribution is fail closed, never guessed.
        before, after = base_rows(), base_rows()
        before[DIAG], after[DIAG] = DIR_A, DIR_B
        after[DIAG + b"/unverified.ips"] = file_meta(b"unverified", b"after", "5" * 64)
        check_inconclusive(differ, "C5-missing-attribution", before, after)
        for d_kind in ("MALFORMED", "UNREADABLE", "UNVERIFIED"):
            row = report_row(b"unverified.ips", "5" * 64 if d_kind != "UNREADABLE" else "-",
                             d_kind, -1, b"")
            check_inconclusive(differ, "C5-%s-attribution" % d_kind.lower(), before, after, [row])
        mismatch = report_row(b"unverified.ips", "6" * 64, "CONTROL", 7006, ctl_path)
        check_inconclusive(differ, "C5-control-digest-disagreement", before, after, [mismatch])

        # C6: retain codec, protected-marker and incomplete-snapshot fail-closed contracts.
        protected_rel = PROTECTED.read_bytes().splitlines()[0]
        before, after = base_rows(), base_rows()
        before[protected_rel] = after[protected_rel] = DIR_A
        check_inconclusive(differ, "C6-protected-marker-transition", before, after,
                           before_markers=[(protected_rel, "EACCES")], after_markers=[])
        check_inconclusive(differ, "C6-unlisted-error", base_rows(), base_rows(),
                           before_errors=[(b"Library/unlisted", "EACCES")])
        good = snapshot_bytes(b"/Users/owner", base_rows(), "BEFORE")
        invalid = good.replace(field(b".").encode("ascii"), b".", 1)
        check_inconclusive(differ, "C6-noncanonical-field", base_rows(), base_rows(), raw_before=invalid)

        run_retained(differ, "x86_64")
        run_retained(differ, "arm64")

        try:
            gate = gate_driver(work)
            expected = "PASS\tms1c-home-owner-policy-red\tthree verdicts, exact deltas, retained provenance and gate mapping"
            if gate.returncode == 0 and expected in gate.stdout.splitlines() and not gate.stderr:
                ok("C7-real-gate-integration")
            else:
                failures = [line for line in gate.stdout.splitlines() if line.startswith("FAIL")]
                bad("C7-real-gate-integration", "rc=%s failures=%r stderr=%r" % (
                    gate.returncode, failures[-10:], gate.stderr[-600:]))
        except (OSError, ValueError, subprocess.TimeoutExpired) as exc:
            bad("C7-real-gate-integration", "SETUP/timeout %s" % exc)

        mutant_mode = os.environ.get("ZB_MS1C_HOME_OWNER_MUTANT", "")
        if not problems and not mutant_mode:
            mutant_env = os.environ.copy()
            mutant_env["ZB_MS1C_HOME_OWNER_MUTANT"] = "ignore-diagnostic-directory-metadata"
            try:
                mutant = subprocess.run(
                    [sys.executable, os.path.realpath(__file__)],
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                    env=mutant_env, timeout=300,
                )
            except subprocess.TimeoutExpired:
                bad("M-diagnostic-directory-blanket-ignore", "mutant timed out")
            else:
                causal = any(
                    line.startswith("FAIL\tms1c-home-owner-policy-red\tC5-one-control-is-ambient:")
                    or line.startswith(
                        "FAIL\tms1c-home-owner-policy-red\t"
                        "C5-standalone-diagnostic-directory-is-unverifiable:"
                    )
                    for line in mutant.stdout.splitlines()
                )
                if mutant.returncode == 0 or not causal or mutant.stderr or "SETUP" in mutant.stdout:
                    bad("M-diagnostic-directory-blanket-ignore",
                        "mutant was not causally red: rc=%s causal=%s stderr=%r tail=%r" % (
                            mutant.returncode, causal, mutant.stderr[-300:], mutant.stdout.splitlines()[-5:]))
                else:
                    ok("M-diagnostic-directory-blanket-ignore: field-isolated mutant is red")

        if problems:
            for problem in problems:
                print("FAIL\tms1c-home-owner-policy-red\t%s" % problem)
            print("FAIL\tms1c-home-owner-policy-red\t%d contract rows failed" % len(problems))
            return 1
        print("PASS\tms1c-home-owner-policy-red\towner HOME policy and retained provenance")
        return 0
    finally:
        shutil.rmtree(work)


if __name__ == "__main__":
    raise SystemExit(main())
