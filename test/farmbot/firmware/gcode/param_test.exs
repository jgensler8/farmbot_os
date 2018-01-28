defmodule Farmbot.Firmware.Gcode.ParamTest do
  use ExUnit.Case

  test "Pareses a param in integer form" do
    a = Farmbot.Firmware.Gcode.Param.parse_param(13)
    assert(a == :movement_timeout_z)
  end

  test "Parses a param in atom form" do
    a = Farmbot.Firmware.Gcode.Param.parse_param(:movement_timeout_z)
    assert(a == 13)
  end
end
