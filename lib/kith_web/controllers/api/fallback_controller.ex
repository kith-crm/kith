defmodule KithWeb.API.FallbackController do
  @moduledoc """
  Translates controller action results into API responses.

  Used via `action_fallback KithWeb.API.FallbackController` in API controllers.
  Handles standard error tuples and renders RFC 7807 Problem Details JSON.
  """

  use KithWeb, :controller

  alias KithWeb.API.ErrorJSON

  # Ecto changeset validation errors → 422
  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(422)
    |> put_resp_content_type("application/problem+json")
    |> json(ErrorJSON.changeset_error(changeset, conn.request_path))
  end

  # Not found → 404
  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(404)
    |> put_resp_content_type("application/problem+json")
    |> json(ErrorJSON.render(404, "Resource not found.", conn.request_path))
  end

  # Unauthorized → 401
  def call(conn, {:error, :unauthorized}) do
    conn
    |> put_status(401)
    |> put_resp_content_type("application/problem+json")
    |> json(ErrorJSON.render(401, "Missing or invalid API token.", conn.request_path))
  end

  # Forbidden → 403
  def call(conn, {:error, :forbidden}) do
    conn
    |> put_status(403)
    |> put_resp_content_type("application/problem+json")
    |> json(
      ErrorJSON.render(
        403,
        "You do not have permission to perform this action.",
        conn.request_path
      )
    )
  end

  def call(conn, {:error, :feature_disabled, feature}) do
    problem =
      ErrorJSON.render(403, "This feature is disabled for this workspace.", conn.request_path)
      |> Map.merge(%{code: "feature_disabled", feature: feature})

    conn
    |> put_status(403)
    |> put_resp_content_type("application/problem+json")
    |> json(problem)
  end

  # Conflict → 409
  def call(conn, {:error, :conflict, detail}) do
    conn
    |> put_status(409)
    |> put_resp_content_type("application/problem+json")
    |> json(ErrorJSON.render(409, detail, conn.request_path))
  end

  # Bad request → 400
  def call(conn, {:error, :bad_request, detail}) do
    conn
    |> put_status(400)
    |> put_resp_content_type("application/problem+json")
    |> json(ErrorJSON.render(400, detail, conn.request_path))
  end

  # Not implemented → 501
  def call(conn, {:error, :not_implemented, detail}) do
    conn
    |> put_status(501)
    |> put_resp_content_type("application/problem+json")
    |> json(ErrorJSON.render(501, detail, conn.request_path))
  end

  # Generic error with status code
  def call(conn, {:error, status, detail}) when is_integer(status) do
    conn
    |> put_status(status)
    |> put_resp_content_type("application/problem+json")
    |> json(ErrorJSON.render(status, detail, conn.request_path))
  end
end
