defmodule Farmbot.CeleryScript.AST.Node.Nothing do
  @moduledoc false
  use Farmbot.CeleryScript.AST.Node
  allow_args []

  return_self()
end
