-- Copyright 2019 Stanford University
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

-- runs-with:
-- [
--   ["pennant.tests/sedovsmall/sedovsmall.pnt",
--    "-npieces", "1", "-fparallelize", "0"],
--   ["pennant.tests/sedov/sedov.pnt",
--    "-npieces", "3", "-ll:cpu", "3", "-fparallelize", "0",
--    "-absolute", "2e-6", "-relative", "1e-8", "-relative_absolute", "1e-10"],
--   ["pennant.tests/leblanc/leblanc.pnt",
--    "-npieces", "2", "-ll:cpu", "2", "-fparallelize", "0"]
-- ]

-- Inspired by https://github.com/losalamos/PENNANT

import "regent"

pennant_parallel = false
require("pennant_common")

local c = regentlib.c

-- #####################################
-- ## Initialization
-- #################

__demand(__parallel, __cuda)
task init_mesh_zones(rz : region(zone))
where
  writes(rz.{zx, zarea, zvol})
do
  for z in rz do
    var v = vec2 {x = 0.0, y = 0.0}
    var zero = 0.0
    rz[z].zx = v
    rz[z].zarea = zero
    rz[z].zvol = zero
  end
end

-- Call calc_centers_full.
-- Call calc_volumes_full.

__demand(__parallel, __cuda)
task init_side_fracs(rz : region(zone), rp : region(point),
                     rs : region(side))
where
  reads(rz.zarea, rs.{mapsz, sarea}),
  writes(rs.smf)
do
  for s in rs do
    var z = rs[s].mapsz
    var sarea = rs[s].sarea
    var zarea = rz[z].zarea
    var v = sarea / zarea

    rs[s].smf = v
  end
end

__demand(__parallel, __cuda)
task init_hydro(rz : region(zone), rinit : double, einit : double,
                rinitsub : double, einitsub : double,
                subregion_x0 : double, subregion_x1 : double,
                subregion_y0 : double, subregion_y1 : double)
where
  reads(rz.{zx, zvol}),
  writes(rz.{zr, ze, zwrate, zm, zetot})
do
  for z in rz do
    var zr = rinit
    var ze = einit

    var eps = 1e-12

    var zzx_x = rz[z].zx.x
    var zzx_y = rz[z].zx.y

    if zzx_x > subregion_x0 - eps and
      zzx_x < subregion_x1 + eps and
      zzx_y > subregion_y0 - eps and
      zzx_y < subregion_y1 + eps
    then
      zr = rinitsub
      ze = einitsub
    end

    var zvol = rz[z].zvol
    var zm = zr * zvol
    var zero = 0.0
    var zetot = ze * zm

    rz[z].zr = zr
    rz[z].ze = ze
    rz[z].zwrate = zero
    rz[z].zm = zm
    rz[z].zetot = zetot
  end
end

__demand(__parallel, __cuda)
task init_radial_velocity(rp : region(point), vel : double)
where
  reads(rp.px),
  writes(rp.pu)
do
  for p in rp do
    if vel == 0.0 then
      var init = vec2 {x = 0.0, y = 0.0}
      rp[p].pu = init
    else
      var px = rp[p].px
      var pmag = length(px)
      var pu = (vel / pmag) * px
      rp[p].pu = pu
    end
  end
end

-- #####################################
-- ## Main simulation loop
-- #################

-- Save off point variable values from previous cycle.
__demand(__parallel, __cuda)
task init_step_points(rp : region(point),
                      enable : bool)
where
  writes(rp.{pmaswt, pf})
do
  if not enable then return end

  -- Initialize fields used in reductions.
  for p in rp do
    var zero = 0.0
    rp[p].pmaswt = zero
    rp[p].pf.x = zero
    rp[p].pf.y = zero
  end
end

--
-- 1. Advance mesh to center of time step.
--
__demand(__cuda, __parallel)
task adv_pos_half(rp : region(point), dt : double,
                  enable : bool)
where
  reads(rp.{px, pu}),
  writes(rp.{px0, pxp, pu0})
do
  if not enable then return end

  var dth = 0.5 * dt

  -- Copy state variables from previous time step and update position.
  for p in rp do
    var px0_x = rp[p].px.x
    var pu0_x = rp[p].pu.x
    rp[p].px0.x = px0_x
    rp[p].pu0.x = pu0_x
    var pxp_x = px0_x + dth * pu0_x
    rp[p].pxp.x = pxp_x
  end
  for p in rp do
    var px0_y = rp[p].px.y
    var pu0_y = rp[p].pu.y
    rp[p].px0.y = px0_y
    rp[p].pu0.y = pu0_y
    var pxp_y = px0_y + dth * pu0_y
    rp[p].pxp.y = pxp_y
  end
end

-- Save off zone variable value from previous cycle.
__demand(__cuda)
task init_step_zones(rz : region(zone), enable : bool)
where
  reads(rz.zvol),
  writes(rz.zvol0)
do
  if not enable then return end

  -- Copy state variables from previous time step.
  for z in rz do
    var zvol = rz[z].zvol
    rz[z].zvol0 = zvol
  end
end

--
-- 1a. Compute new mesh geometry.
--

-- Compute centers of zones and edges.
__demand(__cuda, __parallel)
task calc_centers(rz : region(zone), rp : region(point),
                  rs : region(side),
                  enable : bool)
where
  reads(rz.znump, rp.pxp, rs.{mapsz, mapsp1, mapsp2}),
  writes(rs.exp),
  reads writes(rz.zxp)
do
  if not enable then return end

  for z in rz do
    var init = vec2 {x = 0.0, y = 0.0}
    rz[z].zxp = init
  end

  for s in rs do
    var z  = rs[s].mapsz
    var p1 = rs[s].mapsp1
    var p2 = rs[s].mapsp2

    var p1_pxp = rp[p1].pxp
    var p2_pxp = rp[p2].pxp
    var exp = 0.5 * (p1_pxp + p2_pxp)

    rs[s].exp = exp

    var znump = rz[z].znump
    var zxp = (1 / double(znump)) * p1_pxp

    rz[z].zxp += zxp
  end
end

-- Compute volumes of zones and sides.
-- Compute edge lengths.
__demand(__cuda, __parallel)
task calc_volumes(rz : region(zone), rp : region(point),
                  rs : region(side),
                  enable : bool)
where
  reads(rz.{zxp, znump}, rp.pxp, rs.{mapsz, mapsp1, mapsp2}),
  writes(rs.{sareap, elen}),
  reads writes(rz.{zareap, zvolp})
do
  if not enable then return end

  for z in rz do
    var zero = 0.0
    rz[z].zareap = zero
    rz[z].zvolp = zero
  end

  var num_negative_sv = 0
  for s in rs do
    var z  = rs[s].mapsz
    var p1 = rs[s].mapsp1
    var p2 = rs[s].mapsp2

    var p1_pxp = rp[p1].pxp
    var p2_pxp = rp[p2].pxp
    var zxp = rz[z].zxp
    var sa = 0.5 * cross(p2_pxp - p1_pxp, zxp - p1_pxp)
    var sv = sa * (p1_pxp.x + p2_pxp.x + zxp.x)
    rs[s].sareap = sa
    -- s.svolp = sv
    var elen = length(p2_pxp - p1_pxp)
    rs[s].elen = elen

    rz[z].zareap += sa
    var zvolp = (1.0 / 3.0) * sv
    rz[z].zvolp += zvolp

    if sv <= 0.0 then
      num_negative_sv += 1
    end
  end
  regentlib.assert(num_negative_sv == 0, "sv negative")
end

-- Compute zone characteristic lengths.
__demand(__cuda, __parallel)
task calc_char_len(rz : region(zone), rp : region(point),
                   rs : region(side),
                   enable : bool)
where
  reads(rz.znump, rs.{mapsz, sareap, elen}),
  reads writes(rz.zdl)
do
  if not enable then return end

  for z in rz do
    var init = [double](1.0e99)
    rz[z].zdl = init
  end

  for s in rs do
    var z = rs[s].mapsz

    var area = rs[s].sareap
    var base = rs[s].elen
    var fac = 0.0
    var znump = rz[z].znump
    if znump == 3 then
      fac = 3.0
    else
      fac = 4.0
    end
    var sdl = fac * area / base

    rz[z].zdl min= sdl
  end
end

--
-- 2. Compute point masses.
--

-- Compute zone densities.
__demand(__cuda, __parallel)
task calc_rho_half(rz : region(zone), enable : bool)
where
  reads(rz.{zvolp, zm}),
  writes(rz.zrp)
do
  if not enable then return end

  for z in rz do
    var zm = rz[z].zm
    var zvolp = rz[z].zvolp
    var zrp = zm / zvolp
    rz[z].zrp = zrp
  end
end

-- Reduce masses into points.
__demand(__cuda, __parallel)
task sum_point_mass(rz : region(zone), rp : region(point),
                    rs : region(side),
                    enable : bool)
where
  reads(rz.{zareap, zrp}, rs.{mapsz, mapsp1, mapss3, smf}),
  reduces+(rp.pmaswt)
do
  if not enable then return end

  for s in rs do
    var z  = rs[s].mapsz
    var p1 = rs[s].mapsp1
    var s3 = rs[s].mapss3

    var zrp = rz[z].zrp
    var zareap = rz[z].zareap
    var s_smf = rs[s].smf
    var s3_smf = rs[s3].smf
    var m = zrp * zareap * 0.5 * (s_smf + s3_smf)

    rp[p1].pmaswt += m
  end
end

--
-- 3. Compute material state (half-advanced).
--

__demand(__cuda)
task calc_state_at_half(rz : region(zone),
                        gamma : double, ssmin : double, dt : double,
                        enable : bool)
where
  reads(rz.{zvol0, zvolp, zm, zr, ze, zwrate}),
  writes(rz.{zp, zss})
do
  if not enable then return end

  var gm1 = gamma - 1.0
  var ss2 = max(ssmin * ssmin, 1e-99)
  var dth = 0.5 * dt

  for z in rz do
    var rx = rz[z].zr
    var ze = rz[z].ze
    var ex = max(ze, 0.0)
    var px = gm1 * rx * ex
    var prex = gm1 * ex
    var perx = gm1 * rx
    var csqd = max(ss2, prex + perx * px / (rx * rx))
    var z0per = perx
    var zss = sqrt(csqd)

    rz[z].zss = zss

    var zm = rz[z].zm
    var zminv = 1.0 / zm
    var zvolp = rz[z].zvolp
    var zvol0 = rz[z].zvol0
    var dv = (zvolp - zvol0) * zminv
    var zr = rx
    var bulk = zr * zss * zss
    var denom = 1.0 + 0.5 * z0per * dv

    var zwrate = rz[z].zwrate

    var src = zwrate * dth * zminv
    var zp = px + (z0per * src - zr * bulk * dv) / denom

    rz[z].zp = zp
  end
end

--
-- 4. Compute forces.
--

-- Compute PolyGas and TTS forces.
__demand(__cuda)
task calc_force_pgas_tts(rz : region(zone), rp : region(point),
                         rs : region(side),
                         alfa : double, ssmin : double,
                         enable : bool)
where
  reads(rz.{zxp, zareap, zrp, zss, zp}, rs.{mapsz, sareap, smf, exp}),
  writes(rs.{sfp, sft})
do
  if not enable then return end

  for s in rs do
    var z = rs[s].mapsz

    -- Compute surface vectors of sides.
    var exp = rs[s].exp
    var zxp = rz[z].zxp
    var ssurfp = rotateCCW(exp - zxp)

    -- Compute PolyGas forces.
    var zp = rz[z].zp
    var sfx = (-zp) * ssurfp
    rs[s].sfp = sfx

    -- Compute TTS forces.
    var zareap = rz[z].zareap
    var sareap = rs[s].sareap

    var svfacinv = zareap / sareap

    var zrp = rz[z].zrp
    var smf = rs[s].smf

    var srho = zrp * smf * svfacinv

    var zss = rz[z].zss

    var sstmp = max(zss, ssmin)
    sstmp = alfa * sstmp * sstmp

    var sdp = sstmp * (srho - zrp)
    var sqq = (-sdp) * ssurfp

    var sft = sfx + sqq

    rs[s].sft = sft
  end
end

__demand(__cuda)
task qcs_zone_center_velocity(rz : region(zone), rp : region(point),
                              rs : region(side),
                              enable : bool)
where
  reads(rz.znump, rp.pu, rs.{mapsz, mapsp1}),
  reads writes(rz.zuc)
do
  if not enable then return end

  for z in rz do
    var init = vec2 { x = 0.0, y = 0.0 }
    rz[z].zuc = init
  end

  for s in rs do
    var z = rs[s].mapsz
    var p1 = rs[s].mapsp1

    var znump = rz[z].znump
    var pu = rp[p1].pu

    var zuc = (1.0 / [double](znump)) * pu

    rz[z].zuc += zuc
  end
end

__demand(__cuda)
task qcs_corner_divergence(rz : region(zone), rp : region(point),
                           rs : region(side),
                           enable : bool)
where
  reads(rz.{zxp, zuc}, rp.{pxp, pu},
        rs.{mapsz, mapsp1, mapsp2, mapss3, exp, elen}),
  writes(rs.{carea, ccos, cdiv, cevol, cdu})
do
  if not enable then return end

  for s2 in rs do
    var s  = rs[s2].mapss3
    var z  = rs[s ].mapsz
    var p  = rs[s ].mapsp2
    var p1 = rs[s ].mapsp1
    var p2 = rs[s2].mapsp2

    -- var e1 = s
    -- var e2 = s2

    -- velocities and positions
    -- point p
    var up0 = rp[p].pu
    var xp0 = rp[p].pxp
    -- edge e2
    var p_pu = up0
    var p2_pu = rp[p2].pu
    var up1 = 0.5 * (p_pu + p2_pu)
    var xp1 = rs[s2].exp
    -- zone center z
    var up2 = rz[z].zuc
    var xp2 = rz[z].zxp
    -- edge e1
    var p1_pu = rp[p1].pu
    var up3 = 0.5 * (p1_pu + up0)
    var xp3 = rs[s].exp

    -- compute 2d cartesian volume of corner
    var cvolume = 0.5 * cross(xp2 - xp0, xp3 - xp1)
    rs[s2].carea = cvolume

    -- compute cosine angle
    var v1 = xp3 - xp0
    var v2 = xp1 - xp0
    var de1 = rs[s].elen
    var de2 = rs[s2].elen
    var minelen = min(de1, de2)
    var ccos = 0.0
    if minelen >= 1e-12 then
      ccos = 4.0 * dot(v1, v2) / (de1 * de2)
    end
    rs[s2].ccos =ccos

    -- compute divergence of corner
    var cdiv = (cross(up2 - up0, xp3 - xp1) -
                cross(up3 - up1, xp2 - xp0)) / (2.0 * cvolume)
    rs[s2].cdiv = cdiv

    -- compute evolution factor
    var dxx1 = 0.5 * (((xp1 + xp2) - xp0) - xp3)
    var dxx2 = 0.5 * (((xp2 + xp3) - xp0) - xp1)
    var dx1 = length(dxx1)
    var dx2 = length(dxx2)

    -- average corner-centered velocity
    var duav = 0.25 * (((up0 + up1) + up2) + up3)

    var test1 = abs(dot(dxx1, duav) * dx2)
    var test2 = abs(dot(dxx2, duav) * dx1)
    var num = 0.0
    var den = 0.0
    if test1 > test2 then
      num = dx1
      den = dx2
    else
      num = dx2
      den = dx1
    end
    var r = num / den
    var evol = min(sqrt(4.0 * cvolume * r), 2.0 * minelen)

    -- compute delta velocity
    var dv1 = length(((up1 + up2) - up0) - up3)
    var dv2 = length(((up2 + up3) - up0) - up1)
    var du = max(dv1, dv2)

    var cevol = 0.0
    var cdu = 0.0
    if cdiv < 0.0 then
      cevol = evol
      cdu = du
    end
    rs[s2].cevol = cevol
    rs[s2].cdu = cdu
  end
end

__demand(__cuda)
task qcs_qcn_force(rz : region(zone), rp : region(point),
                   rs : region(side),
                   gamma : double, q1 : double, q2 : double,
                   enable : bool)
where
  reads(rz.{zrp, zss}, rp.pu,
        rs.{mapsz, mapsp1, mapsp2, mapss3, elen, cdiv, cdu, cevol}),
  writes(rs.{cqe1, cqe2})
do
  if not enable then return end

  var gammap1 = gamma + 1.0

  for s4 in rs do
    -- var c = s4
    var z = rs[s4].mapsz

    var cdu = rs[s4].cdu
    var ztmp2 = q2 * 0.25 * gammap1 * cdu

    var zss = rz[z].zss
    var ztmp1 = q1 * zss

    var zkur = ztmp2 + sqrt(ztmp2 * ztmp2 + ztmp1 * ztmp1)

    var zrp = rz[z].zrp
    var cevol = rs[s4].cevol
    var rmu = zkur * zrp * cevol

    var cdiv = rs[s4].cdiv
    if cdiv > 0.0 then
      rmu = 0.0
    end

    var s = rs[s4].mapss3
    var p = rs[s].mapsp2
    var p1 = rs[s].mapsp1
    -- var e1 = s
    var p2 = rs[s4].mapsp2
    -- var e2 = s4

    var e1_elen = rs[s].elen
    var p_pu = rp[p].pu
    var p1_pu = rp[p1].pu
    var cqe1 = rmu / e1_elen * (p_pu - p1_pu)

    var e2_elen = rs[s4].elen
    var p2_pu = rp[p2].pu
    var cqe2 = rmu / e2_elen * (p2_pu - p_pu)

    rs[s4].cqe1 = cqe1
    rs[s4].cqe2 = cqe2
  end
end

__demand(__cuda)
task qcs_force(rz : region(zone), rp : region(point),
               rs : region(side),
               enable : bool)
where
  reads(rs.{mapss4, elen, carea, ccos, cqe1, cqe2}),
  writes(rs.sfq)
do
  if not enable then return end

  for s in rs do
    -- var c1 = s
    var c2 = rs[s].mapss4
    -- var e = s
    var el = rs[s].elen

    var c1_ccos = rs[s].ccos
    var c1sin2 = 1.0 - c1_ccos * c1_ccos
    var c1w = 0.0
    var c1cos = 0.0
    if c1sin2 >= 1e-4 then
      var carea = rs[s].carea
      c1w = carea / c1sin2
      c1cos = c1_ccos
    end

    var c2_ccos = rs[c2].ccos
    var c2sin2 = 1.0 - c2_ccos * c2_ccos
    var c2w = 0.0
    var c2cos = 0.0
    if c2sin2 >= 1e-4 then
      var carea = rs[c2].carea
      c2w = carea / c2sin2
      c2cos = c2_ccos
    end

    var c1_cqe2 = rs[s].cqe2
    var c1_cqe1 = rs[s].cqe1
    var c2_cqe1 = rs[c2].cqe1
    var c2_cqe2 = rs[c2].cqe2
    var sfq = (1.0 / el) * (c1w * (c1_cqe2 + c1cos * c1_cqe1) +
                            c2w * (c2_cqe1 + c2cos * c2_cqe2))
    rs[s].sfq = sfq
  end
end

__demand(__cuda)
task qcs_vel_diff(rz : region(zone), rp : region(point),
                  rs : region(side),
                  q1 : double, q2 : double,
                  enable : bool)
where
  reads(rz.{zss, z0tmp}, rp.{pxp, pu},
        rs.{mapsp1, mapsp2, mapsz, elen}),
  writes(rz.{zdu, z0tmp})
do
  if not enable then return end

  for z in rz do
    var zero = 0.0
    rz[z].z0tmp = zero
  end

  for s in rs do
    var p1 = rs[s].mapsp1
    var p2 = rs[s].mapsp2
    var z  = rs[s].mapsz
    -- var e = s

    var p2_pxp = rp[p2].pxp
    var p1_pxp = rp[p1].pxp
    var dx = p2_pxp - p1_pxp

    var p2_pu = rp[p2].pu
    var p1_pu = rp[p1].pu
    var du = p2_pu - p1_pu

    var lenx = rs[s].elen
    var dux = 0.0
    if lenx > 0.0 then
      dux = abs(dot(du, dx)) / lenx
    end
    rz[z].z0tmp max= dux
  end

  for z in rz do
    var zss = rz[z].zss
    var z0tmp = rz[z].z0tmp
    var zdu = q1 * zss + 2.0 * q2 * z0tmp
    rz[z].zdu = zdu
  end
end

-- Reduce forces into points.
__demand(__cuda)
task sum_point_force(rz : region(zone), rp : region(point),
                     rs : region(side),
                     enable : bool)
where
  reads(rz.znump, rs.{mapsz, mapsp1, mapss3, sfq, sft}),
  reduces+(rp.pf.{x, y})
do
  if not enable then return end

  for s in rs do
    var p1 = rs[s].mapsp1
    var s3 = rs[s].mapss3

    var s_sfq = rs[s].sfq
    var s_sft = rs[s].sft
    var s3_sfq = rs[s3].sfq
    var s3_sft = rs[s3].sft
    var f = (s_sfq + s_sft) - (s3_sfq + s3_sft)

    var f_x = f.x
    var f_y = f.y

    rp[p1].pf.x += f_x
    rp[p1].pf.y += f_y
  end
end

--
-- 4a. Apply boundary conditions.
--

__demand(__cuda)
task apply_boundary_conditions(rp : region(point),
                               enable : bool)
where
  reads(rp.{has_bcx, has_bcy}),
  reads writes(rp.{pu0, pf})
do
  if not enable then return end

  var vfixx = vec2 {x = 1.0, y = 0.0}
  var vfixy = vec2 {x = 0.0, y = 1.0}
  for p in rp do
    if p.has_bcx then
      var p_pu0 = rp[p].pu0
      var p_pf = rp[p].pf
      var pu0 = project(p_pu0, vfixx)
      var pf = project(p_pf, vfixx)
      rp[p].pu0 = pu0
      rp[p].pf = pf
    end
    if p.has_bcy then
      var p_pu0 = rp[p].pu0
      var p_pf = rp[p].pf
      var pu0 = project(p_pu0, vfixy)
      var pf = project(p_pf, vfixy)
      rp[p].pu0 = pu0
      rp[p].pf = pf
    end
  end
end

--
-- 5. Compute accelerations.
--

-- Fused into adv_pos_full.

--
-- 6. Advance mesh to end of time step.
--

__demand(__cuda)
task adv_pos_full(rp : region(point), dt : double,
                  enable : bool)
where
  reads(rp.{px0, pu0, pf, pmaswt}),
  writes(rp.{px, pu})
do
  if not enable then return end

  var fuzz = 1e-99
  var dth = 0.5 * dt
  for p in rp do
    var pmaswt = rp[p].pmaswt
    var fac = 1.0 / max(pmaswt, fuzz)
    var pf = rp[p].pf
    var pap_x = fac * pf.x
    var pap_y = fac * pf.y

    var p_pu0_x = rp[p].pu0.x
    var p_px0_x = rp[p].px0.x

    var pu_x = p_pu0_x + dt * pap_x
    rp[p].pu.x = pu_x

    var px_x = p_px0_x + dth * (pu_x + p_pu0_x)
    rp[p].px.x = px_x

    var p_pu0_y = rp[p].pu0.y
    var p_px0_y = rp[p].px0.y

    var pu_y = p_pu0_y + dt * pap_y
    rp[p].pu.y = pu_y

    var px_y = p_px0_y + dth * (pu_y + p_pu0_y)
    rp[p].px.y = px_y
  end
end

--
-- 6a. Compute new mesh geometry.
--

-- FIXME: This is a duplicate of calc_centers but with different
-- code. Struct slicing ought to make it possible to use the same code
-- in both cases.
__demand(__cuda, __parallel)
task calc_centers_full(rz : region(zone), rp : region(point),
                       rs : region(side),
                       enable : bool)
where
  reads(rz.znump, rp.px, rs.{mapsz, mapsp1, mapsp2}),
  writes(rs.ex),
  reads writes(rz.zx)
do
  if not enable then return end

  for z in rz do
    var init = vec2 {x = 0.0, y = 0.0}
    rz[z].zx = init
  end

  for s in rs do
    var z  = rs[s].mapsz
    var p1 = rs[s].mapsp1
    var p2 = rs[s].mapsp2
    -- var e = s

    var p1_px = rp[p1].px
    var p2_px = rp[p2].px
    var ex = 0.5 * (p1_px + p2_px)
    rs[s].ex = ex

    var znump = rz[z].znump
    var zx = (1 / double(znump)) * p1_px
    rz[z].zx += zx
  end
end

-- FIXME: This is a duplicate of calc_volumes but with different
-- code. Struct slicing ought to make it possible to use the same code
-- in both cases.
__demand(__cuda, __parallel)
task calc_volumes_full(rz : region(zone), rp : region(point),
                       rs : region(side),
                       enable : bool)
where
  reads(rz.{zx, znump}, rp.px, rs.{mapsz, mapsp1, mapsp2}),
  writes(rs.{sarea}),
  reads writes(rz.{zarea, zvol})
do
  if not enable then return end

  for z in rz do
    var zero = 0.0
    rz[z].zarea = zero
    rz[z].zvol = zero
  end

  var num_negative_sv = 0
  for s in rs do
    var z  = rs[s].mapsz
    var p1 = rs[s].mapsp1
    var p2 = rs[s].mapsp2

    var p1_px = rp[p1].px
    var p2_px = rp[p2].px
    var zx = rz[z].zx
    var sa = 0.5 * cross(p2_px - p1_px, zx - p1_px)
    var sv = sa * (p1_px.x + p2_px.x + zx.x)
    rs[s].sarea = sa
    -- s.svol = sv

    rz[z].zarea += sa

    var zvol = (1.0 / 3.0) * sv
    rz[z].zvol += zvol

    if sv <= 0.0 then
      num_negative_sv += 1
    end
  end
  regentlib.assert(num_negative_sv == 0, "sv negative")
end

--
-- 7. Compute work
--

__demand(__cuda)
task calc_work(rz : region(zone), rp : region(point),
               rs : region(side),
               dt : double,
               enable : bool)
where
  reads(rz.znump, rp.{pxp, pu0, pu},
        rs.{mapsz, mapsp1, mapsp2, sfp, sfq}),
  reads writes(rz.{zw, zetot})
do
  if not enable then return end

  for z in rz do
    var zero = 0.0
    rz[z].zw = zero
  end

  for s in rs do
    var z  = rs[s].mapsz
    var p1 = rs[s].mapsp1
    var p2 = rs[s].mapsp2

    var sfp = rs[s].sfp
    var sfq = rs[s].sfq
    var sftot = sfp + sfq

    var p1_pu0 = rp[p1].pu0
    var p1_pu = rp[p1].pu
    var sd1 = dot(sftot, p1_pu0 + p1_pu)

    var p2_pu0 = rp[p2].pu0
    var p2_pu = rp[p2].pu
    var sd2 = dot(-1.0 * sftot, p2_pu0 + p2_pu)

    var p1_pxp_x = rp[p1].pxp.x
    var p2_pxp_x = rp[p2].pxp.x
    var dwork = -0.5 * dt * (sd1 * p1_pxp_x + sd2 * p2_pxp_x)

    rz[z].zetot += dwork
    rz[z].zw += dwork
  end
end

--
-- 7a. Compute work rate.
-- 8. Update state variables.
--

__demand(__cuda)
task calc_work_rate_energy_rho_full(rz : region(zone), dt : double,
                                    enable : bool)
where
  reads(rz.{zvol0, zvol, zm, zw, zp, zetot}),
  writes(rz.{zwrate, ze, zr})
do
  if not enable then return end

  var dtiny = 1.0 / dt
  var fuzz = 1e-99

  for z in rz do
    var zvol = rz[z].zvol
    var zvol0 = rz[z].zvol0
    var dvol = zvol - zvol0

    var zw = rz[z].zw
    var zp = rz[z].zp
    var zwrate = (zw + zp * dvol) * dtiny
    rz[z].zwrate = zwrate

    var zetot = rz[z].zetot
    var zm = rz[z].zm

    var ze = zetot / (zm + fuzz)
    rz[z].ze = ze

    var zr = zm / zvol
    rz[z].zr = zr
  end
end

--
-- 9. Compute timstep for next cycle.
--

--[[
task calc_dt_courant(rz : region(zone), dtmax : double, cfl : double) : double
where
  reads(rz.{zdl, zss, zdu})
do
  var fuzz = 1e-99
  var dtnew = dtmax
  for z in rz do
    var cdu = max(z.zdu, max(z.zss, fuzz))
    var zdthyd = z.zdl * cfl / cdu

    dtnew min= zdthyd
  end

  return dtnew
end

task calc_dt_volume(rz : region(zone), dtlast : double, cflv : double) : double
where
  reads(rz.{zvol0, zvol})
do
  var dvovmax = 1e-99
  for z in rz do
    var zdvov = abs((z.zvol - z.zvol0) / z.zvol0)
    dvovmax max= zdvov
  end
  return dtlast * cflv / dvovmax
end
]]

__demand(__cuda)
task calc_dt_hydro(rz : region(zone), dtlast : double, dtmax : double,
                   cfl : double, cflv : double, enable : bool) : double
where
  reads(rz.{zdl, zvol0, zvol, zss, zdu})
do
  var dthydro = dtmax

  if not enable then return dthydro end

  -- dthydro min= min(calc_dt_courant(rz, dtmax, cfl),
  --                  calc_dt_volume(rz, dtlast, cflv))

  -- Hack: manually inline calc_dt_courant
  do
    var fuzz = 1e-99
    for z in rz do
      var zdu = rz[z].zdu
      var zss = rz[z].zss
      var cdu = max(zdu, max(zss, fuzz))
      var zdl = rz[z].zdl
      var zdthyd = zdl * cfl / cdu

      dthydro min= zdthyd
    end
  end

  -- Hack: manually inline calc_dt_volume
  do
    for z in rz do
      var zvol = rz[z].zvol
      var zvol0 = rz[z].zvol0
      var zdvov = abs((zvol - zvol0) / zvol0)
      var zdthyd = dtlast * cflv / zdvov
      dthydro min= zdthyd
    end
  end

  return dthydro
end

--__demand(__inline)
task calc_global_dt(dt : double, dtfac : double, dtinit : double,
                    dtmax : double, dthydro : double,
                    time : double, tstop : double, cycle : int64) : double
  var dtlast = dt

  dt = dtmax

  if cycle == 0 then
    dt = min(dt, dtinit)
  else
    var dtrecover = dtfac * dtlast
    dt = min(dt, dtrecover)
  end

  dt = min(dt, tstop - time)
  dt = min(dt, dthydro)

  return dt
end

-- XXX: this triggers different behavior: __demand(__inline)
task continue_simulation(cycle : int64, cstop : int64,
                         time : double, tstop : double)
  return (cycle < cstop and time < tstop)
end

--[[
task simulate(rz : region(zone),
              rp : region(point),
              rs : region(side),
              conf : config)
where
  reads writes(rz, rp, rs)
do
  var alfa = conf.alfa
  var cfl = conf.cfl
  var cflv = conf.cflv
  var cstop = conf.cstop
  var dtfac = conf.dtfac
  var dtinit = conf.dtinit
  var dtmax = conf.dtmax
  var gamma = conf.gamma
  var q1 = conf.q1
  var q2 = conf.q2
  var qgamma = conf.qgamma
  var ssmin = conf.ssmin
  var tstop = conf.tstop
  var uinitradial = conf.uinitradial
  var vfix = vec2 {x = 0.0, y = 0.0}

  var enable = conf.enable

  var interval = 10
  var start_time = c.legion_get_current_time_in_micros()/1.e6
  var last_time = start_time

  var time = 0.0
  var cycle : int64 = 0
  var dt = dtmax
  var dthydro = dtmax
  while continue_simulation(cycle, cstop, time, tstop) do
    init_step_points(rp, enable)

    init_step_zones(rz, enable)

    dt = calc_global_dt(dt, dtfac, dtinit, dtmax, dthydro, time, tstop, cycle)

    if cycle > 0 and cycle % interval == 0 then
      var current_time = c.legion_get_current_time_in_micros()/1.e6
      c.printf("cycle %4ld    sim time %.3e    dt %.3e    time %.3e (per iteration) %.3e (total)\n",
               cycle, time, dt, (current_time - last_time)/interval, current_time - start_time)
      last_time = current_time
    end

    adv_pos_half(rp, dt, enable)

    calc_centers(rz, rp, rs, enable)

    calc_volumes(rz, rp, rs, enable)

    calc_char_len(rz, rp, rs, enable)

    calc_rho_half(rz, enable)

    sum_point_mass(rz, rp, rs, enable)

    calc_state_at_half(rz, gamma, ssmin, dt, enable)

    calc_force_pgas_tts(rz, rp, rs, alfa, ssmin, enable)

    qcs_zone_center_velocity(rz, rp, rs, enable)

    qcs_corner_divergence(rz, rp, rs, enable)

    qcs_qcn_force(rz, rp, rs, gamma, q1, q2, enable)

    qcs_force(rz, rp, rs, enable)

    qcs_vel_diff(rz, rp, rs, q1, q2, enable)

    sum_point_force(rz, rp, rs, enable)

    apply_boundary_conditions(rp, enable)

    adv_pos_full(rp, dt, enable)

    calc_centers_full(rz, rp, rs, enable)

    calc_volumes_full(rz, rp, rs, enable)

    calc_work(rz, rp, rs, dt, enable)

    calc_work_rate_energy_rho_full(rz, dt, enable)

    dthydro = dtmax
    dthydro min= calc_dt_hydro(rz, dt, dtmax, cfl, cflv, enable)

    cycle += 1
    time += dt
  end
end
]]

--[[
__demand(__inline)
task initialize(rz : region(zone),
                rp : region(point),
                rs : region(side),
                conf : config)
where
  reads writes(rz, rp, rs)
do
  var einit = conf.einit
  var einitsub = conf.einitsub
  var rinit = conf.rinit
  var rinitsub = conf.rinitsub
  var subregion = conf.subregion
  var uinitradial = conf.uinitradial

  var enable = true

  init_mesh_zones(rz)

  calc_centers_full(rz, rp, rs, enable)

  calc_volumes_full(rz, rp, rs, enable)

  init_side_fracs(rz, rp, rs)

  init_hydro(rz,
             rinit, einit, rinitsub, einitsub,
             subregion[0], subregion[1], subregion[2], subregion[3])

  init_radial_velocity(rp, uinitradial)
end
]]

task dummy(rz : region(zone)) : int
where reads(rz) do
  return 1
end

terra wait_for(x : int)
  return x
end

task read_input_sequential(rz : region(zone),
                           rp : region(point),
                           rs : region(side),
                           conf : config)
where reads writes(rz, rp, rs) do
  return read_input(
    __runtime(), __context(),
    __physical(rz), __fields(rz),
    __physical(rp), __fields(rp),
    __physical(rs), __fields(rs),
    conf)
end

task validate_output_sequential(rz : region(zone),
                                rp : region(point),
                                rs : region(side),
                                conf : config)
where reads(rz, rp, rs) do
  validate_output(
    __runtime(), __context(),
    __physical(rz), __fields(rz),
    __physical(rp), __fields(rp),
    __physical(rs), __fields(rs),
    conf)
end

terra unwrap(x : mesh_colorings) return x end

task toplevel()
  c.printf("Running test (t=%.1f)...\n", c.legion_get_current_time_in_micros()/1.e6)

  var conf : config = read_config()

  if not conf.seq_init then
    c.printf("Enabling sequential initialization\n")
  end
  if conf.par_init then
    c.printf("Disabling parallel initialization\n")
  end
  conf.seq_init = true
  conf.par_init = false

  var rz = region(ispace(ptr, conf.nz), zone)
  var rp = region(ispace(ptr, conf.np), point)
  var rs = region(ispace(ptr, conf.ns), side)

  var colorings : mesh_colorings

  if conf.seq_init then
    -- Hack: This had better run on the same node...
    colorings = unwrap(read_input_sequential(
      rz, rp, rs, conf))

    -- c.legion_coloring_destroy(colorings.rz_all_c)
    c.legion_coloring_destroy(colorings.rz_spans_c)
    c.legion_coloring_destroy(colorings.rp_all_c)
    c.legion_coloring_destroy(colorings.rp_all_private_c)
    c.legion_coloring_destroy(colorings.rp_all_ghost_c)
    c.legion_coloring_destroy(colorings.rp_all_shared_c)
    c.legion_coloring_destroy(colorings.rp_spans_c)
    c.legion_coloring_destroy(colorings.rs_all_c)
    c.legion_coloring_destroy(colorings.rs_spans_c)
  end

  var rz_p = partition(disjoint, rz, colorings.rz_all_c)
  var rz_c = rz_p.colors
  var rs_p = preimage(rs, rz_p, rs.mapsz)
  var rp_p = partition(equal, rp, rz_c)

  var rp_p_img = image(rp, rs_p, rs.mapsp1) | image(rp, rs_p, rs.mapsp2)

  c.printf("Initializing (t=%.1f)...\n", c.legion_get_current_time_in_micros()/1.e6)
  __parallelize_with rz_p, rz_c, rs_p, rp_p, image(rz, rs_p, rs.mapsz) <= rz_p,
                     image(rp, rs_p, rs.mapsp1) <= rp_p_img,
                     image(rp, rs_p, rs.mapsp2) <= rp_p_img
  do
    -- Hack: Manually inline this call to make parallelizer happy
    -- initialize(rz, rp, rs, conf)
    var einit = conf.einit
    var einitsub = conf.einitsub
    var rinit = conf.rinit
    var rinitsub = conf.rinitsub
    var subregion = conf.subregion
    var uinitradial = conf.uinitradial

    var enable = true

    init_mesh_zones(rz)

    calc_centers_full(rz, rp, rs, enable)

    calc_volumes_full(rz, rp, rs, enable)

    init_side_fracs(rz, rp, rs)

    init_hydro(rz,
               rinit, einit, rinitsub, einitsub,
               subregion[0], subregion[1], subregion[2], subregion[3])

    init_radial_velocity(rp, uinitradial)
  end
  -- Hack: Force main task to wait for initialization to finish.
  wait_for(dummy(rz))

  c.printf("Starting simulation (t=%.1f)...\n", c.legion_get_current_time_in_micros()/1.e6)
  var start_time = c.legion_get_current_time_in_micros()/1.e6
  __parallelize_with rz_p, rz_c, rs_p, rp_p, image(rz, rs_p, rs.mapsz) <= rz_p,
                     image(rp, rs_p, rs.mapsp1) <= rp_p_img,
                     image(rp, rs_p, rs.mapsp2) <= rp_p_img
  do
    -- Hack: Manually inline this call to make parallelizer happy
    -- simulate(rz, rp, rs, conf)
    var alfa = conf.alfa
    var cfl = conf.cfl
    var cflv = conf.cflv
    var cstop = conf.cstop
    var dtfac = conf.dtfac
    var dtinit = conf.dtinit
    var dtmax = conf.dtmax
    var gamma = conf.gamma
    var q1 = conf.q1
    var q2 = conf.q2
    var qgamma = conf.qgamma
    var ssmin = conf.ssmin
    var tstop = conf.tstop
    var uinitradial = conf.uinitradial
    var vfix = vec2 {x = 0.0, y = 0.0}

    var enable = conf.enable

    var interval = 10
    var start_time = c.legion_get_current_time_in_micros()/1.e6
    var last_time = start_time

    var time = 0.0
    var cycle : int64 = 0
    var dt = dtmax
    var dthydro = dtmax
    while continue_simulation(cycle, cstop, time, tstop) do
      init_step_points(rp, enable)

      init_step_zones(rz, enable)

      dt = calc_global_dt(dt, dtfac, dtinit, dtmax, dthydro, time, tstop, cycle)

      if cycle > 0 and cycle % interval == 0 then
        var current_time = c.legion_get_current_time_in_micros()/1.e6
        c.printf("cycle %4ld    sim time %.3e    dt %.3e    time %.3e (per iteration) %.3e (total)\n",
                 cycle, time, dt, (current_time - last_time)/interval, current_time - start_time)
        last_time = current_time
      end

      adv_pos_half(rp, dt, enable)

      calc_centers(rz, rp, rs, enable)

      calc_volumes(rz, rp, rs, enable)

      calc_char_len(rz, rp, rs, enable)

      calc_rho_half(rz, enable)

      sum_point_mass(rz, rp, rs, enable)

      calc_state_at_half(rz, gamma, ssmin, dt, enable)

      calc_force_pgas_tts(rz, rp, rs, alfa, ssmin, enable)

      qcs_zone_center_velocity(rz, rp, rs, enable)

      qcs_corner_divergence(rz, rp, rs, enable)

      qcs_qcn_force(rz, rp, rs, gamma, q1, q2, enable)

      qcs_force(rz, rp, rs, enable)

      qcs_vel_diff(rz, rp, rs, q1, q2, enable)

      sum_point_force(rz, rp, rs, enable)

      apply_boundary_conditions(rp, enable)

      adv_pos_full(rp, dt, enable)

      calc_centers_full(rz, rp, rs, enable)

      calc_volumes_full(rz, rp, rs, enable)

      calc_work(rz, rp, rs, dt, enable)

      calc_work_rate_energy_rho_full(rz, dt, enable)

      dthydro = dtmax
      dthydro min= calc_dt_hydro(rz, dt, dtmax, cfl, cflv, enable)

      cycle += 1
      time += dt
    end
  end
  -- Hack: Force main task to wait for simulation to finish.
  wait_for(dummy(rz))
  var stop_time = c.legion_get_current_time_in_micros()/1.e6
  c.printf("Elapsed time = %.6e\n", stop_time - start_time)

  if conf.seq_init then
    validate_output_sequential(rz, rp, rs, conf)
  else
    c.printf("Warning: Skipping sequential validation\n")
  end

  -- write_output(conf, rz, rp, rs)
end

if os.getenv('SAVEOBJ') == '1' then
  local root_dir = arg[0]:match(".*/") or "./"
  local link_flags = {"-L" .. root_dir, "-lpennant"}
  local exe = os.getenv('OBJNAME') or "pennant_sequential"
  regentlib.saveobj(toplevel, exe, "executable", cpennant.register_mappers, link_flags)
else
  regentlib.start(toplevel, cpennant.register_mappers)
end
