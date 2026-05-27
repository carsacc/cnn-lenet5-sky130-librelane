include RBA

layout = Layout::new
layout.read("/home/carsacc/.ciel/ciel/sky130/versions/8afc8346a57fe1ab7934ba5a6056ea8b43078e71/sky130A/libs.ref/sky130_fd_io/gds/sky130_fd_io.gds")
dbu = layout.dbu

layer_defs = [
  ["met3", 70, 20],
  ["via3", 70, 44],
  ["met4", 71, 20],
  ["via4", 71, 44],
  ["met5", 72, 20],
]

def mkbox(coords, dbu)
  return nil if coords.nil?
  Box::new((coords[0] / dbu).round, (coords[1] / dbu).round, (coords[2] / dbu).round, (coords[3] / dbu).round)
end

def fmt(bb, dbu)
  format("(%.3f,%.3f)-(%.3f,%.3f)", bb.left * dbu, bb.bottom * dbu, bb.right * dbu, bb.top * dbu)
end

windows = [
  ["whole", nil],
  ["bottom_0_15", [0.0, 0.0, 75.0, 15.0]],
  ["bottom_0_40", [0.0, 0.0, 75.0, 40.0]],
  ["left_0_25_y0_15", [0.0, 0.0, 25.0, 15.0]],
  ["right_50_75_y0_15", [50.0, 0.0, 75.0, 15.0]],
  ["left_0_25_y0_40", [0.0, 0.0, 25.0, 40.0]],
  ["right_50_75_y0_40", [50.0, 0.0, 75.0, 40.0]],
]

%w[sky130_fd_io__top_power_lvc_wpad sky130_fd_io__top_ground_lvc_wpad].each do |cell_name|
  cell = layout.cell(cell_name)
  puts
  puts "CELL #{cell_name} bbox=#{fmt(cell.bbox, dbu)}"

  windows.each do |wname, coords|
    win = mkbox(coords, dbu)
    puts "  WINDOW #{wname} #{coords ? coords.inspect : 'whole'}"

    layer_defs.each do |lname, lnum, dnum|
      li = nil
      layout.layer_indices.each do |idx|
        info = layout.get_info(idx)
        if info.layer == lnum && info.datatype == dnum
          li = idx
          break
        end
      end
      next if li.nil?

      count = 0
      samples = []
      it = cell.begin_shapes_rec(li)
      while !it.at_end?
        bb = it.shape.bbox.transformed(it.trans)
        if win.nil? || bb.overlaps?(win)
          count += 1
          samples << bb if samples.length < 5
        end
        it.next
      end
      next if count == 0
      puts "    #{lname} L#{lnum}/#{dnum} count=#{count}"
      samples.each { |bb| puts "      #{fmt(bb, dbu)}" }
    end
  end
end
