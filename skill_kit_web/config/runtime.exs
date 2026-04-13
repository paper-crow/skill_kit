import Config

if config_env() in [:dev, :test] do
  Dotenvy.source!(
    [
      Path.expand("../../.env", __DIR__)
    ],
    side_effect: fn vars ->
      Enum.each(vars, fn {key, value} -> System.put_env(key, value) end)
    end
  )
end
