use Mix.Config

unless File.exists?("config/host/auth_secret.exs") do
  Mix.raise(
    "You need to configure your dev environment. See `config/host/auth_secret_template.exs` for an example.\r\n"
  )
end

import_config("auth_secret.exs")

config :farmbot, data_path: "tmp/"

# Configure your our system.
# Default implementation needs no special stuff.
config :farmbot, :init, [
  Farmbot.Host.Bootstrap.Configurator,
  Farmbot.Host.TargetConfiguratorTest.Supervisor,
  Farmbot.System.Debug
]

# Transports.
config :farmbot, :transport, [
  Farmbot.BotState.Transport.AMQP,
  Farmbot.BotState.Transport.HTTP,
]

repos = [Farmbot.Repo.A, Farmbot.Repo.B, Farmbot.System.ConfigStorage]
config :farmbot, ecto_repos: repos

for repo <- [Farmbot.Repo.A, Farmbot.Repo.B] do
  config :farmbot, repo,
    adapter: Sqlite.Ecto2,
    loggers: [],
    database: "tmp/#{repo}_dev.sqlite3",
    pool_size: 1
end

config :farmbot, Farmbot.System.ConfigStorage,
  adapter: Sqlite.Ecto2,
  loggers: [],
  database: "tmp/#{Farmbot.System.ConfigStorage}_dev.sqlite3",
  pool_size: 1

# config :farmbot, :farmware, first_part_farmware_manifest_url: nil


# Configure Farmbot Behaviours.
# Default Authorization behaviour.
# SystemTasks for host mode.
config :farmbot, :behaviour,
  authorization: Farmbot.Bootstrap.Authorization,
  system_tasks: Farmbot.Host.SystemTasks,
  update_handler: Farmbot.Host.UpdateHandler
  # firmware_handler: Farmbot.Firmware.UartHandler

config :farmbot, :uart_handler, tty: "/dev/ttyACM1"

config :farmbot, :logger, [
  # backends: [Elixir.Logger.Backends.Farmbot]
]
