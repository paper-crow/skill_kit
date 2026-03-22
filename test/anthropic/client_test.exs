defmodule Anthropic.ClientTest do
  use ExUnit.Case, async: true

  alias Anthropic.Client

  describe "new/1" do
    test "creates client with required fields" do
      client = Client.new(api_key: "sk-test", endpoint: "https://api.anthropic.com")
      assert client.api_key == "sk-test"
      assert client.endpoint == "https://api.anthropic.com"
    end

    test "uses default endpoint when not provided" do
      client = Client.new(api_key: "sk-test")
      assert client.endpoint == "https://api.anthropic.com"
    end

    test "raises when api_key is missing" do
      assert_raise KeyError, fn -> Client.new([]) end
    end
  end
end
