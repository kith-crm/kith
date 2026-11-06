defmodule Kith.SentryFilterTest do
  use ExUnit.Case, async: true

  alias Kith.SentryFilter

  test "expected routing, missing-record and auth failures stay excluded" do
    assert SentryFilter.exclude_exception?(%Phoenix.Router.NoRouteError{}, :plug)
    assert SentryFilter.exclude_exception?(%Ecto.NoResultsError{}, :oban)

    for status <- [401, 403, 404] do
      assert SentryFilter.exclude_exception?(
               %Plug.Conn.WrapperError{conn: %Plug.Conn{status: status}},
               :plug
             )
    end
  end

  test "unexpected failures remain reportable" do
    refute SentryFilter.exclude_exception?(%RuntimeError{message: "failure"}, :oban)

    refute SentryFilter.exclude_exception?(
             %Plug.Conn.WrapperError{conn: %Plug.Conn{status: 500}},
             :plug
           )
  end
end
