defmodule Farmbot.System.Updates do
  @moduledoc "Handles over the air updates."
  use Supervisor

  @data_path Application.get_env(:farmbot, :data_path)
  @current_version Farmbot.Project.version()
  @target Farmbot.Project.target()
  @current_commit Farmbot.Project.commit()
  @env Farmbot.Project.env()
  use Farmbot.Logger

  @handler Application.get_env(:farmbot, :behaviour)[:update_handler]
  @handler || Mix.raise("Please configure update_handler")

  alias Farmbot.System.ConfigStorage

  @doc "Overwrite os update server field"
  def override_update_server(url) do
    ConfigStorage.update_config_value(:bool, "settings", "beta_opt_in", true)
    ConfigStorage.update_config_value(:string, "settings", "os_update_server_overwrite", url)
  end

  @doc "Force check updates."
  def check_updates(reboot) do
    if @handler.requires_reboot? do
      if reboot do
        Logger.info 1, "Farmbot applied an update. Rebooting."
        Farmbot.System.reboot("Update reboot required")
      else
        Logger.info 1, "Farmbot already applied an update. Please reboot."
        :ok
      end
    else
      token = ConfigStorage.get_config_value(:string, "authorization", "token")
      if token do
        case Farmbot.Jwt.decode(token) do
          {:ok, %Farmbot.Jwt{os_update_server: normal_update_server, beta_os_update_server: beta_update_server}} ->
            override = ConfigStorage.get_config_value(:string, "settings", "os_update_server_overwrite")
            if ConfigStorage.get_config_value(:bool, "settings", "beta_opt_in") do
              do_check_updates_http(override || beta_update_server, reboot)
            else
              do_check_updates_http(override || normal_update_server, reboot)
            end
          _ -> no_token()
        end
      else
        no_token()
      end
    end
  end

  defp no_token do
    Logger.debug 3, "Not checking for updates. (No token)"
    :ok
  end

  defp do_check_updates_http(url, reboot) do
    Logger.info 3, "Checking: #{url} for updates."
    with {:ok, %{body: body, status_code: 200}} <- Farmbot.HTTP.get(url),
    {:ok, data} <- Poison.decode(body),
    {:ok, prerelease} <- Map.fetch(data, "prerelease"),
    {:ok, new_commit} <- Map.fetch(data, "target_commitish"),
    {:ok, cl} <- Map.fetch(data, "body"),
    {:ok, false} <- Map.fetch(data, "draft"),
    {:ok, "v" <> new_version_str} <- Map.fetch(data, "tag_name"),
    {:ok, new_version} <- Version.parse(new_version_str),
    {:ok, current_version} <- Version.parse(@current_version),
    {:ok, fw_url} <- find_fw_url(data, new_version) do
      needs_update = if prerelease do
        val = new_commit == @current_commit
        Logger.info 1, "Checking prerelease commits: current_commit: #{@current_commit} new_commit: #{new_commit} #{val}"
        !val
      else
        case Version.compare(current_version, new_version) do
          s when s in [:gt, :eq] ->
            Logger.success 2, "Farmbot is up to date."
            false
          :lt ->
            Logger.busy 1, "New Farmbot firmware update: #{new_version}"
            true
        end

      end


      if should_apply_update(@env, prerelease, needs_update) do
        Logger.busy 1, "Downloading FarmbotOS over the air update"
        IO.puts cl
        # Logger.info 1, "Downloading update. Here is the release notes"
        # Logger.info 1, cl
        do_download_and_apply(fw_url, new_version, reboot)
      else
        :no_update
      end
    else
      :error ->
        msg = "Unexpected release HTTP response or wrong formated `tag_name`"
        Logger.error 2, msg

      {:error, :no_fw_url} ->
        Logger.error 2, "No firmware in update asssets."

      {:error, reason} ->
        Logger.error 1, "Failed to fetch update data: #{inspect reason}"

      {:ok, %{body: body, status_code: code}} ->
        reason = case Poison.decode(body) do
          {:ok, res} -> res
          _ -> body
        end
        Logger.error 1, "OS Update HTTP error: #{code}: #{inspect reason}"
    end
  end

  defp find_fw_url(%{"assets" => assets}, version) do
    expected_name = "farmbot-#{@target}-#{version}.fw"
    res = Enum.find_value(assets, fn(asset) ->
      case asset do
        %{"browser_download_url" => fw_url, "name" => ^expected_name} -> fw_url
        _ -> nil
      end
    end)

    if res do
      {:ok, res}
    else
      {:error, :no_fw_url}
    end
  end

  defp should_apply_update(env, prerelease?, needs_update?)
  defp should_apply_update(_, _, false), do: false
  defp should_apply_update(:prod, true, _) do
    if ConfigStorage.get_config_value(:bool, "settings", "beta_opt_in") do
      Logger.info 3, "Applying beta update for production firmware"
      true
    else
      Logger.info 3, "Not applying prerelease update for production firmware"
      false
    end
  end

  defp should_apply_update(_env, true, _) do
    Logger.info 3, "Applying prerelease firmware."
    true
  end

  defp should_apply_update(_, _, true) do
    true
  end

  defp do_download_and_apply(dl_url, new_version, reboot) do
    dl_fun = Farmbot.BotState.download_progress_fun("FBOS_OTA")
    dl_path = Path.join(@data_path, "#{new_version}.fw")
    case Farmbot.HTTP.download_file(dl_url, dl_path, dl_fun, "", []) do
      {:ok, path} ->
        apply_firmware(path, reboot)
      {:error, reason} ->
        Logger.error 1, "Failed to download update file: #{inspect reason}"
        {:error, reason}
    end
  end

  @doc "Apply an OS (fwup) firmware."
  def apply_firmware(file_path, reboot) do
    Logger.busy 1, "Applying #{@target} OS update"
    before_update()
    case @handler.apply_firmware(file_path) do
      :ok ->
        Logger.success 1, "OS Firmware updated!"
        if reboot do
          Logger.warn 1, "Farmbot going down for OS update."
          Farmbot.System.reboot("OS Firmware Update.")
        end
      {:error, reason} ->
        Logger.error 1, "Failed to apply update: #{inspect reason}"
        {:error, reason}
    end
  end

  defp before_update do
    File.write!(update_file(), @current_version)
  end

  defp maybe_post_update do
    case File.read(update_file()) do
      {:ok, @current_version} -> :ok
      {:ok, old_version} ->
        Logger.info 1, "Updating from #{old_version} to #{@current_version}"
        @handler.post_update()
      {:error, :enoent} ->
        Logger.info 1, "Updating to #{@current_version}"
      {:error, err} -> raise err
    end
    before_update()
  end

  defp update_file do
    Path.join(@data_path, "update")
  end

  @doc false
  def start_link do
    Supervisor.start_link(__MODULE__, [], [name: __MODULE__])
  end

  def init([]) do
    case @handler.setup(@env) do
      :ok ->
        maybe_post_update()
        children = [
          worker(Farmbot.System.UpdateTimer, [])
        ]
        opts = [strategy: :one_for_one]
        supervise(children, opts)
      {:error, reason} ->
        {:stop, reason}
    end
  end
end
