use Mix.Config

# You should copy this file to config/host/auth_secret.exs
# And make sure to configure the credentials to something that makes sense.

config :farmbot, :authorization,
  email: System.get_env("FARMBOT_EMAIL"),
  password: System.get_env("FARMBOT_PASSWORD"),
  server: "https://my.farmbot.io"

