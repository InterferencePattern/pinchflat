defmodule Pinchflat.CacheTest do
  use ExUnit.Case, async: false

  alias Pinchflat.Cache

  @test_key_1 :cache_test_key_1
  @test_key_2 :cache_test_key_2

  setup do
    Cache.delete(@test_key_1)
    Cache.delete(@test_key_2)
    :ok
  end

  describe "get/2" do
    test "returns the cached value when the key exists" do
      Cache.put(@test_key_1, "cached_value")

      assert Cache.get(@test_key_1, fn -> "fallback" end) == "cached_value"
    end

    test "calls and returns the fallback_fn when the key is missing" do
      assert Cache.get(@test_key_1, fn -> "fallback_result" end) == "fallback_result"
    end

    test "does NOT call the fallback_fn when the key exists" do
      Cache.put(@test_key_1, "present")

      result =
        Cache.get(@test_key_1, fn ->
          raise "fallback_fn should not have been called"
        end)

      assert result == "present"
    end
  end

  describe "put/2" do
    test "stores a value retrievable by subsequent get/2 calls" do
      assert Cache.put(@test_key_1, 42) == :ok
      assert Cache.get(@test_key_1, fn -> :missing end) == 42
    end

    test "overwrites an existing value" do
      Cache.put(@test_key_1, "old")
      Cache.put(@test_key_1, "new")

      assert Cache.get(@test_key_1, fn -> :missing end) == "new"
    end
  end

  describe "delete/1" do
    test "removes a key so the next get/2 calls the fallback" do
      Cache.put(@test_key_1, "value")
      assert Cache.delete(@test_key_1) == :ok
      assert Cache.get(@test_key_1, fn -> :fallback_called end) == :fallback_called
    end

    test "is a no-op when the key does not exist" do
      assert Cache.delete(@test_key_1) == :ok
    end
  end
end
