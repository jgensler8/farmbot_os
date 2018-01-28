defmodule Farmbot.Bootstrap.AuthorizationTest do
  @moduledoc "Tests the default authorization implementation"
  alias Farmbot.Bootstrap.Authorization, as: Auth
  use ExUnit.Case

  @moduletag :farmbot_api

  setup do
    email =
      Application.get_env(:farmbot, :authorization)[:email] ||
        raise Auth.Error, "No email provided."

    pass =
      Application.get_env(:farmbot, :authorization)[:password] ||
        raise Auth.Error, "No password provided."

    server =
      Application.get_env(:farmbot, :authorization)[:server] ||
        raise Auth.Error, "No server provided."

    [email: email, password: pass, server: server]
  end

  test "Authorizes with the farmbot web api.", ctx do
    Farmbot.System.ConfigStorage.update_config_value(:bool, "settings", "first_boot", true)
    res = Auth.authorize(ctx.email, ctx.password, ctx.server)
    assert match?({:ok, _}, res)
    {:ok, bin_tkn} = res
    Farmbot.Jwt.decode!(bin_tkn)
    Farmbot.System.ConfigStorage.update_config_value(:bool, "settings", "first_boot", false)
  end

  test "gives a nice error on bad credentials.", ctx do
    res = Auth.authorize(ctx.email, ctx.password, "https://your.farmbot.io/")
    assert match?({:error, _}, res)

    res = Auth.authorize("yolo@mtv.org", "123password", ctx.server)
    assert match?({:error, _}, res)
  end
end
