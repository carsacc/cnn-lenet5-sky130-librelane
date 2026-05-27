# Copyright 2025 LibreLane Contributors
#
# Adapted from OpenLane
#
# Copyright 2020-2022 Efabless Corporation
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

source $::env(SCRIPTS_DIR)/openroad/common/io.tcl
source $::env(SCRIPTS_DIR)/openroad/common/set_global_connections.tcl
set_global_connections

set secondary []
foreach vdd $::env(VDD_NETS) gnd $::env(GND_NETS) {
    if { $vdd != $::env(VDD_NET)} {
        lappend secondary $vdd

        set db_net [[ord::get_db_block] findNet $vdd]
        if {$db_net == "NULL"} {
            set net [odb::dbNet_create [ord::get_db_block] $vdd]
            $net setSpecial
            $net setSigType "POWER"
        }
    }

    if { $gnd != $::env(GND_NET)} {
        lappend secondary $gnd

        set db_net [[ord::get_db_block] findNet $gnd]
        if {$db_net == "NULL"} {
            set net [odb::dbNet_create [ord::get_db_block] $gnd]
            $net setSpecial
            $net setSigType "GROUND"
        }
    }
}

set_voltage_domain -name CORE -power $::env(VDD_NET) -ground $::env(GND_NET) \
    -secondary_power $secondary



if { $::env(PDN_MULTILAYER) == 1 } {

    set arg_list [list]
    if { $::env(PDN_ENABLE_PINS) } {
        lappend arg_list -pins "$::env(PDN_VERTICAL_LAYER) $::env(PDN_HORIZONTAL_LAYER)"
    }

    define_pdn_grid \
        -name stdcell_grid \
        -starts_with POWER \
        -voltage_domain CORE \
        {*}$arg_list

    set arg_list [list]
    append_if_equals arg_list PDN_EXTEND_TO "core_ring" -extend_to_core_ring
    append_if_equals arg_list PDN_EXTEND_TO "boundary" -extend_to_boundary

    add_pdn_stripe \
        -grid stdcell_grid \
        -layer $::env(PDN_VERTICAL_LAYER) \
        -width $::env(PDN_VWIDTH) \
        -pitch $::env(PDN_VPITCH) \
        -offset $::env(PDN_VOFFSET) \
        -spacing $::env(PDN_VSPACING) \
        -starts_with POWER \
        {*}$arg_list

    add_pdn_stripe \
        -grid stdcell_grid \
        -layer $::env(PDN_HORIZONTAL_LAYER) \
        -width $::env(PDN_HWIDTH) \
        -pitch $::env(PDN_HPITCH) \
        -offset $::env(PDN_HOFFSET) \
        -spacing $::env(PDN_HSPACING) \
        -starts_with POWER \
        {*}$arg_list

    add_pdn_connect \
        -grid stdcell_grid \
        -layers "$::env(PDN_VERTICAL_LAYER) $::env(PDN_HORIZONTAL_LAYER)"
} else {

    set arg_list [list]
    if { $::env(PDN_ENABLE_PINS) } {
        lappend arg_list -pins "$::env(PDN_VERTICAL_LAYER)"
    }

    define_pdn_grid \
        -name stdcell_grid \
        -starts_with POWER \
        -voltage_domain CORE \
        {*}$arg_list

    set arg_list [list]
    append_if_equals arg_list PDN_EXTEND_TO "core_ring" -extend_to_core_ring
    append_if_equals arg_list PDN_EXTEND_TO "boundary" -extend_to_boundary

    add_pdn_stripe \
        -grid stdcell_grid \
        -layer $::env(PDN_VERTICAL_LAYER) \
        -width $::env(PDN_VWIDTH) \
        -pitch $::env(PDN_VPITCH) \
        -offset $::env(PDN_VOFFSET) \
        -spacing $::env(PDN_VSPACING) \
        -starts_with POWER \
        {*}$arg_list
}

# Adds the standard cell rails if enabled.
if { $::env(PDN_ENABLE_RAILS) == 1 } {
    add_pdn_stripe \
        -grid stdcell_grid \
        -layer $::env(PDN_RAIL_LAYER) \
        -width $::env(PDN_RAIL_WIDTH) \
        -followpins

    add_pdn_connect \
        -grid stdcell_grid \
        -layers "$::env(PDN_RAIL_LAYER) $::env(PDN_VERTICAL_LAYER)"
}


# Adds the core ring if enabled.
if { $::env(PDN_CORE_RING) == 1 } {
    if { $::env(PDN_MULTILAYER) == 1 } {
        set arg_list [list]
        append_if_flag arg_list PDN_CORE_RING_ALLOW_OUT_OF_DIE -allow_out_of_die
        # Pad-to-ring bridges are added after pdngen by the wrapper below.
        # Keep OpenROAD's automatic -connect_to_pads disabled for this custom flow.
        append_if_equals arg_list PDN_EXTEND_TO "boundary" -extend_to_boundary

        set pdn_core_vertical_layer $::env(PDN_VERTICAL_LAYER)
        set pdn_core_horizontal_layer $::env(PDN_HORIZONTAL_LAYER)

        if { [info exists ::env(PDN_CORE_VERTICAL_LAYER)] } {
            set pdn_core_vertical_layer $::env(PDN_CORE_VERTICAL_LAYER)
        }

        if { [info exists ::env(PDN_CORE_HORIZONTAL_LAYER)] } {
            set pdn_core_horizontal_layer $::env(PDN_CORE_HORIZONTAL_LAYER)
        }

        add_pdn_ring \
            -grid stdcell_grid \
            -layers "$pdn_core_vertical_layer $pdn_core_horizontal_layer" \
            -widths "$::env(PDN_CORE_RING_VWIDTH) $::env(PDN_CORE_RING_HWIDTH)" \
            -spacings "$::env(PDN_CORE_RING_VSPACING) $::env(PDN_CORE_RING_HSPACING)" \
            -core_offset "$::env(PDN_CORE_RING_VOFFSET) $::env(PDN_CORE_RING_HOFFSET)" \
            {*}$arg_list

        if { [info exists ::env(PDN_CORE_VERTICAL_LAYER)] } {
            add_pdn_connect \
                -grid stdcell_grid \
                -layers "$::env(PDN_CORE_VERTICAL_LAYER) $::env(PDN_HORIZONTAL_LAYER)"
        }

        if { [info exists ::env(PDN_CORE_HORIZONTAL_LAYER)] } {
            add_pdn_connect \
                -grid stdcell_grid \
                -layers "$::env(PDN_CORE_HORIZONTAL_LAYER) $::env(PDN_VERTICAL_LAYER)"
        }

        if { [info exists ::env(PDN_CORE_VERTICAL_LAYER)] && [info exists ::env(PDN_CORE_HORIZONTAL_LAYER)] } {
            add_pdn_connect \
                -grid stdcell_grid \
                -layers "$::env(PDN_CORE_VERTICAL_LAYER) $::env(PDN_CORE_HORIZONTAL_LAYER)"
        }

    } else {
        throw APPLICATION "PDN_CORE_RING cannot be used when PDN_MULTILAYER is set to false."
    }
}

define_pdn_grid \
    -macro \
    -default \
    -name macro \
    -starts_with POWER \
    -halo "$::env(PDN_HORIZONTAL_HALO) $::env(PDN_VERTICAL_HALO)"

add_pdn_connect \
    -grid macro \
    -layers "$::env(PDN_VERTICAL_LAYER) $::env(PDN_HORIZONTAL_LAYER)"


# -----------------------------------------------------------------------------
# Manual sky130 pad-to-core-ring bridges.
# Integrated from pad_pdn_stripes.tcl so PDN_CFG is self-contained.
# -----------------------------------------------------------------------------

proc _bridge_snap_value_to_grid {value grid} {
      if {$grid < 1} {
          return [expr {int(round($value))}]
      }
      return [expr {int(round(double($value) / double($grid))) * $grid}]
  }


proc _bridge_create_sbox_rect {swire layer x1 y1 x2 y2 shape_type} {
      set block [ord::get_db_block]
      set dbu   [$block getDefUnits]
      set grid  [expr {int(round(0.005 * $dbu))}]

      set sx1 [_bridge_snap_value_to_grid $x1 $grid]
      set sy1 [_bridge_snap_value_to_grid $y1 $grid]
      set sx2 [_bridge_snap_value_to_grid $x2 $grid]
      set sy2 [_bridge_snap_value_to_grid $y2 $grid]

      set lx [expr {min($sx1, $sx2)}]
      set ly [expr {min($sy1, $sy2)}]
      set ux [expr {max($sx1, $sx2)}]
      set uy [expr {max($sy1, $sy2)}]

      # dbSBox stores rectangles as centerline plus width. Keep spans even so
      # the centerline stays on an integer DBU and the DEF writer keeps them.
      if {[expr {($ux - $lx) % 2}] != 0} {
          if {[expr {$ux - $lx}] > $grid} {
              set ux [expr {$ux - $grid}]
          } else {
              set ux [expr {$ux + $grid}]
          }
      }
      if {[expr {($uy - $ly) % 2}] != 0} {
          if {[expr {$uy - $ly}] > $grid} {
              set uy [expr {$uy - $grid}]
          } else {
              set uy [expr {$uy + $grid}]
          }
      }

      return [odb::dbSBox_create \
          $swire $layer \
          $lx $ly \
          $ux $uy \
          $shape_type]
  }


proc _bridge_via_array_pitch {
      swire via
      x1 y1 x2 y2
      pitch_x_nm pitch_y_nm
      margin_x_nm margin_y_nm
  } {
      set block [ord::get_db_block]
      set dbu   [$block getDefUnits]
      set grid  [expr {int(round(0.005 * $dbu))}]

      set pitch_x  [expr {int(round(($pitch_x_nm / 1000.0) * $dbu))}]
      set pitch_y  [expr {int(round(($pitch_y_nm / 1000.0) * $dbu))}]
      set margin_x [expr {int(round(($margin_x_nm / 1000.0) * $dbu))}]
      set margin_y [expr {int(round(($margin_y_nm / 1000.0) * $dbu))}]

      set vx1 [expr {$x1 + $margin_x}]
      set vx2 [expr {$x2 - $margin_x}]
      set vy1 [expr {$y1 + $margin_y}]
      set vy2 [expr {$y2 - $margin_y}]

      if {$vx1 > $vx2} {
          set vx1 [_bridge_snap_value_to_grid [expr {int(($x1 + $x2) / 2)}] $grid]
          set vx2 $vx1
      }
      if {$vy1 > $vy2} {
          set vy1 [_bridge_snap_value_to_grid [expr {int(($y1 + $y2) / 2)}] $grid]
          set vy2 $vy1
      }

      set nx [expr {int(floor(double($vx2 - $vx1) / double($pitch_x))) + 1}]
      set ny [expr {int(floor(double($vy2 - $vy1) / double($pitch_y))) + 1}]

      if {$nx < 1} { set nx 1 }
      if {$ny < 1} { set ny 1 }

      set used_x [expr {($nx - 1) * $pitch_x}]
      set used_y [expr {($ny - 1) * $pitch_y}]

      set start_x [_bridge_snap_value_to_grid [expr {int(round(($vx1 + $vx2 - $used_x) / 2.0))}] $grid]
      set start_y [_bridge_snap_value_to_grid [expr {int(round(($vy1 + $vy2 - $used_y) / 2.0))}] $grid]

      set created {}
      for {set iy 0} {$iy < $ny} {incr iy} {
          set y [_bridge_snap_value_to_grid [expr {$start_y + $iy * $pitch_y}] $grid]
          for {set ix 0} {$ix < $nx} {incr ix} {
              set x [_bridge_snap_value_to_grid [expr {$start_x + $ix * $pitch_x}] $grid]
              lappend created [odb::dbSBox_create $swire $via $x $y "STRIPE"]
          }
      }

      return $created
  }


proc _bridge_met3_window_to_met5_ring_horizontal {
      swire met3 met4 via34 via45
      side
      x1 x2 y1 y2
      ring_center_y
      ring_width_um
  } {
      set block [ord::get_db_block]
      set dbu [$block getDefUnits]

      set ring_half [expr {int(round($ring_width_um * $dbu / 2.0))}]
      set ring_top_y [expr {$ring_center_y + $ring_half}]
      set ring_bottom_y [expr {$ring_center_y - $ring_half}]
      set outside_near [expr {int(round(1.0 * $dbu))}]
      set outside_far  [expr {int(round(3.0 * $dbu))}]

      if {$side == "N"} {
          set via34_y1 [expr {$y1 - $outside_far}]
          set via34_y2 [expr {$y1 - $outside_near}]
          set met3_y1 $via34_y1
          set met3_y2 $y2
          set ring_edge_y $ring_top_y
      } elseif {$side == "S"} {
          set via34_y1 [expr {$y2 + $outside_near}]
          set via34_y2 [expr {$y2 + $outside_far}]
          set met3_y1 $y1
          set met3_y2 $via34_y2
          set ring_edge_y $ring_bottom_y
      } else {
          error "horizontal bridge side must be N or S"
      }

      set met4_y1 [expr {min($ring_edge_y, $via34_y1)}]
      set met4_y2 [expr {max($ring_edge_y, $via34_y2)}]

      # Only met3 enters the pad. Via stacks are moved outside the pad bbox.
      _bridge_create_sbox_rect $swire $met3 $x1 $met3_y1 $x2 $met3_y2 "STRIPE"

      _bridge_create_sbox_rect $swire $met4 \
          $x1 $met4_y1 \
          $x2 $met4_y2 \
          "STRIPE"

      _bridge_create_sbox_rect $swire $met4 $x1 $ring_bottom_y $x2 $ring_top_y "STRIPE"

      set vias34 [_bridge_via_array_pitch \
          $swire $via34 \
          $x1 $via34_y1 $x2 $via34_y2 \
          800 800 \
          1000 1000]

      set vias45 [_bridge_via_array_pitch \
          $swire $via45 \
          $x1 $ring_bottom_y $x2 $ring_top_y \
          2000 2000 \
          1000 1000]

      puts "$side horizontal pad_met3=($x1,$y1)-($x2,$y2) via34_ext=($x1,$via34_y1)-($x2,$via34_y2) M3M4_ext=[llength $vias34] M4M5_ring=[llength $vias45]"
  }


proc _bridge_met3_window_to_met4_ring_vertical {
      swire met3 met4 met5 via34 via45
      side
      x1 x2 y1 y2
      ring_center_x
      ring_width_um
  } {
      set block [ord::get_db_block]
      set dbu [$block getDefUnits]

      set ring_half [expr {int(round($ring_width_um * $dbu / 2.0))}]
      set ring_left_x  [expr {$ring_center_x - $ring_half}]
      set ring_right_x [expr {$ring_center_x + $ring_half}]
      set outside_near [expr {int(round(2.0 * $dbu))}]
      set outside_far  [expr {int(round(4.0 * $dbu))}]

      if {$side == "E"} {
          set via34_x1 [expr {$x1 - $outside_far}]
          set via34_x2 [expr {$x1 - $outside_near}]
          set met3_x1 $via34_x1
          set met3_x2 $x2
      } elseif {$side == "W"} {
          set via34_x1 [expr {$x2 + $outside_near}]
          set via34_x2 [expr {$x2 + $outside_far}]
          set met3_x1 $x1
          set met3_x2 $via34_x2
      } else {
          error "vertical bridge side must be E or W"
      }

      set bridge_x1 [expr {min($ring_left_x, $via34_x1)}]
      set bridge_x2 [expr {max($ring_right_x, $via34_x2)}]

      # Only met3 enters the pad. M3M4/M4M5 vias stay outside the pad bbox.
      _bridge_create_sbox_rect $swire $met3 $met3_x1 $y1 $met3_x2 $y2 "STRIPE"
      _bridge_create_sbox_rect $swire $met4 $via34_x1 $y1 $via34_x2 $y2 "STRIPE"

      # Lateral bridge in met5, not met4, to avoid shorting adjacent vertical rings.
      _bridge_create_sbox_rect $swire $met5 \
          $bridge_x1 $y1 \
          $bridge_x2 $y2 \
          "STRIPE"

      # Met4 landing only on the selected target ring.
      _bridge_create_sbox_rect $swire $met4 \
          $ring_left_x $y1 \
          $ring_right_x $y2 \
          "STRIPE"

      set vias34 [_bridge_via_array_pitch \
          $swire $via34 \
          $via34_x1 $y1 $via34_x2 $y2 \
          800 800 \
          1000 1000]

      set vias45_ext [_bridge_via_array_pitch \
          $swire $via45 \
          $via34_x1 $y1 $via34_x2 $y2 \
          2000 2000 \
          1000 1000]

      set vias45_ring [_bridge_via_array_pitch \
          $swire $via45 \
          $ring_left_x $y1 $ring_right_x $y2 \
          2000 2000 \
          1000 1000]

      puts "$side vertical pad_met3=($x1,$y1)-($x2,$y2) via34_ext=($via34_x1,$y1)-($via34_x2,$y2)"
      puts "$side target ring x=($ring_left_x,$ring_right_x)"
      puts "$side M3M4_ext=[llength $vias34] M4M5_ext=[llength $vias45_ext] M4M5_ring=[llength $vias45_ring]"
  }
proc bridge_sky130_power_pad_to_ring {
      net_name
      inst_name
      pin_type
      side
      ring_center
      sigtype
      {which both}
      {ring_width_um 5}
  } {
      set block [ord::get_db_block]
      set tech  [ord::get_db_tech]

      set net [$block findNet $net_name]
      if {$net == "NULL"} { error "No net $net_name" }

      set inst [$block findInst $inst_name]
      if {$inst == "NULL"} { error "No inst $inst_name" }

      set bbox [$inst getBBox]
      set ix1 [$bbox xMin]
      set iy1 [$bbox yMin]
      set ix2 [$bbox xMax]
      set iy2 [$bbox yMax]

      set met3  [$tech findLayer met3]
      set met4  [$tech findLayer met4]
      set met5  [$tech findLayer met5]
      set via34 [$tech findVia M3M4_PR_M]
      set via45 [$tech findVia M4M5_PR_M]

      if {$met3 == "NULL"}  { error "No met3" }
      if {$met4 == "NULL"}  { error "No met4" }
      if {$met5 == "NULL"}  { error "No met5" }
      if {$via34 == "NULL"} { error "No M3M4_PR_M" }
      if {$via45 == "NULL"} { error "No M4M5_PR_M" }

      switch -- $pin_type {
          VCCD { set depth 6900 }
          VSSD { set depth 39565 }
          default { error "pin_type must be VCCD or VSSD" }
      }

      switch -- $which {
          left  { set windows {left} }
          right { set windows {right} }
          both  { set windows {left right} }
          default { error "which must be left, right, or both" }
      }

      $net setSpecial
      $net setSigType $sigtype

      set swire [odb::dbSWire_create $net "ROUTED"]

      foreach w $windows {
          if {$w == "left"} {
              set a1 1670
              set a2 24244
          } else {
              set a1 50500
              set a2 72830
          }

          switch -- $side {
              N {
                  set x1 [expr {$ix1 + $a1}]
                  set x2 [expr {$ix1 + $a2}]
                  set y1 [expr {$iy1 - 35}]
                  set y2 [expr {$iy1 + $depth - 35}]

                  _bridge_met3_window_to_met5_ring_horizontal \
                      $swire $met3 $met4 $via34 $via45 \
                      N $x1 $x2 $y1 $y2 \
                      $ring_center $ring_width_um
              }

              S {
                  set x1 [expr {$ix1 + $a1}]
                  set x2 [expr {$ix1 + $a2}]
                  set y1 [expr {$iy2 - $depth + 35}]
                  set y2 [expr {$iy2 + 35}]

                  _bridge_met3_window_to_met5_ring_horizontal \
                      $swire $met3 $met4 $via34 $via45 \
                      S $x1 $x2 $y1 $y2 \
                      $ring_center $ring_width_um
              }

              E {
                  set x1 [expr {$ix1 - 35}]
                  set x2 [expr {$ix1 + $depth - 35}]
                  set y1 [expr {$iy1 + $a1}]
                  set y2 [expr {$iy1 + $a2}]

                  _bridge_met3_window_to_met4_ring_vertical \
                      $swire $met3 $met4 $met5 $via34 $via45 \
                      E $x1 $x2 $y1 $y2 \
                      $ring_center $ring_width_um
              }

              W {
                  set x1 [expr {$ix2 - $depth + 35}]
                  set x2 [expr {$ix2 + 35}]
                  set y1 [expr {$iy1 + $a1}]
                  set y2 [expr {$iy1 + $a2}]

                  _bridge_met3_window_to_met4_ring_vertical \
                      $swire $met3 $met4 $met5 $via34 $via45 \
                      W $x1 $x2 $y1 $y2 \
                      $ring_center $ring_width_um
              }

              default {
                  error "side must be N, S, E, or W"
              }
          }
      }
  }

proc _sky130_pad_side_from_orient {orient} {
      switch -- $orient {
          MY    { return N }
          R180  { return S }
          R270  { return E }
          MYR90 { return W }
          default {
              error "Unsupported pad orient '$orient'; expected MY, R180, R270, or MYR90"
          }
      }
  }

proc _sky130_find_ring_center {net_name side} {
      set block [ord::get_db_block]

      set net [$block findNet $net_name]
      if {$net == "NULL"} { error "No net $net_name" }

      switch -- $side {
          N {
              set target_layer met5
              set axis y
              set pick max
          }
          S {
              set target_layer met5
              set axis y
              set pick min
          }
          E {
              set target_layer met4
              set axis x
              set pick max
          }
          W {
              set target_layer met4
              set axis x
              set pick min
          }
          default {
              error "side must be N, S, E, or W"
          }
      }

      set found 0
      set best 0

      foreach swire [$net getSWires] {
          foreach sbox [$swire getWires] {
              if {[$sbox isVia]} {
                  continue
              }
              if {[$sbox getWireShapeType] != "RING"} {
                  continue
              }

              set layer [$sbox getTechLayer]
              if {$layer == "NULL"} {
                  continue
              }
              if {[$layer getName] != $target_layer} {
                  continue
              }

              set cx [expr {int(([$sbox xMin] + [$sbox xMax]) / 2)}]
              set cy [expr {int(([$sbox yMin] + [$sbox yMax]) / 2)}]

              if {$axis == "x"} {
                  set value $cx
              } else {
                  set value $cy
              }

              if {!$found} {
                  set best $value
                  set found 1
              } elseif {$pick == "max" && $value > $best} {
                  set best $value
              } elseif {$pick == "min" && $value < $best} {
                  set best $value
              }
          }
      }

      if {!$found} {
          error "No $target_layer SHAPE RING found for net $net_name side $side"
      }

      return $best
  }

proc bridge_sky130_power_pad_to_ring_auto {
      net_name
      inst_name
      pin_type
      ring_center
      sigtype
      {which both}
      {ring_width_um 5}
  } {
      set block [ord::get_db_block]

      set inst [$block findInst $inst_name]
      if {$inst == "NULL"} { error "No inst $inst_name" }

      set orient [$inst getOrient]
      set side [_sky130_pad_side_from_orient $orient]

      if {$ring_center == "auto" || $ring_center == "AUTO"} {
          set ring_center [_sky130_find_ring_center $net_name $side]
      }

      puts "$inst_name orient=$orient inferred_side=$side ring_center=$ring_center"

      bridge_sky130_power_pad_to_ring \
          $net_name \
          $inst_name \
          $pin_type \
          $side \
          $ring_center \
          $sigtype \
          $which \
          $ring_width_um
  }

proc bridge_sky130_power_pad_to_ring_fully_auto {
      net_name
      inst_name
      pin_type
      sigtype
      {which both}
      {ring_width_um 5}
  } {
      set block [ord::get_db_block]

      set inst [$block findInst $inst_name]
      if {$inst == "NULL"} { error "No inst $inst_name" }

      set orient [$inst getOrient]
      set side [_sky130_pad_side_from_orient $orient]
      set ring_center [_sky130_find_ring_center $net_name $side]

      puts "$inst_name orient=$orient inferred_side=$side inferred_ring_center=$ring_center"

      bridge_sky130_power_pad_to_ring \
          $net_name \
          $inst_name \
          $pin_type \
          $side \
          $ring_center \
          $sigtype \
          $which \
          $ring_width_um
  }

proc _sky130_transform_master_rect_to_inst {
      inst
      lx ly ux uy
  } {
      set bbox [$inst getBBox]
      set ix1 [$bbox xMin]
      set iy1 [$bbox yMin]
      set ix2 [$bbox xMax]
      set iy2 [$bbox yMax]
      set orient [$inst getOrient]

      switch -- $orient {
          MY {
              set ax1 [expr {$ix2 - $ux}]
              set ax2 [expr {$ix2 - $lx}]
              set ay1 [expr {$iy1 + $ly}]
              set ay2 [expr {$iy1 + $uy}]
          }
          R180 {
              set ax1 [expr {$ix2 - $ux}]
              set ax2 [expr {$ix2 - $lx}]
              set ay1 [expr {$iy2 - $uy}]
              set ay2 [expr {$iy2 - $ly}]
          }
          R270 {
              set ax1 [expr {$ix1 + $ly}]
              set ax2 [expr {$ix1 + $uy}]
              set ay1 [expr {$iy2 - $ux}]
              set ay2 [expr {$iy2 - $lx}]
          }
          MYR90 {
              set ax1 [expr {$ix2 - $uy}]
              set ax2 [expr {$ix2 - $ly}]
              set ay1 [expr {$iy2 - $ux}]
              set ay2 [expr {$iy2 - $lx}]
          }
          default {
              error "Unsupported pad orient '$orient'; expected MY, R180, R270, or MYR90"
          }
      }

      return [list \
          [expr {min($ax1, $ax2)}] \
          [expr {min($ay1, $ay2)}] \
          [expr {max($ax1, $ax2)}] \
          [expr {max($ay1, $ay2)}]]
  }

proc _sky130_add_pad_ring_bridges_after_pdngen {} {
      bridge_sky130_power_pad_to_ring_fully_auto vccd1 pad_vccd1_n VCCD POWER both
      bridge_sky130_power_pad_to_ring_fully_auto vccd1 pad_vccd1_e VCCD POWER both
      bridge_sky130_power_pad_to_ring_fully_auto vccd1 pad_vccd1_w VCCD POWER both

      bridge_sky130_power_pad_to_ring_fully_auto vssd1 pad_vssd1_n VSSD GROUND both
      bridge_sky130_power_pad_to_ring_fully_auto vssd1 pad_vssd1_e VSSD GROUND both
      bridge_sky130_power_pad_to_ring_fully_auto vssd1 pad_vssd1_w VSSD GROUND both
  }

if {[llength [info commands __orig_pdngen_without_pad_bridges]] == 0} {
      if {[llength [info commands pdngen]] == 0} {
          error "pdngen command not found while installing pad bridge wrapper"
      }

      rename pdngen __orig_pdngen_without_pad_bridges

      proc pdngen {args} {
          set rc [catch {
              uplevel 1 __orig_pdngen_without_pad_bridges {*}$args
          } result opts]

          if {$rc} {
              return -options $opts $result
          }

          _sky130_add_pad_ring_bridges_after_pdngen

          return $result
      }
  }
