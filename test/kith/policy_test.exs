defmodule Kith.PolicyTest do
  use ExUnit.Case, async: true

  alias Kith.Accounts.User
  alias Kith.Policy

  describe "can?/3 for :oban resource" do
    test "admin can manage Oban" do
      assert Policy.can?(%User{role: "admin"}, :manage, :oban)
      assert Policy.can?(%User{role: "admin"}, :read, :oban)
    end

    test "editor cannot access Oban" do
      refute Policy.can?(%User{role: "editor"}, :manage, :oban)
      refute Policy.can?(%User{role: "editor"}, :read, :oban)
    end

    test "viewer cannot access Oban" do
      refute Policy.can?(%User{role: "viewer"}, :manage, :oban)
      refute Policy.can?(%User{role: "viewer"}, :read, :oban)
    end

    test "unknown role cannot access Oban" do
      refute Policy.can?(%User{role: "ghost"}, :manage, :oban)
    end
  end
end
