defmodule Kith.Accounts.UserNotifier do
  import Swoosh.Email, only: [put_to: 2, subject: 2]

  alias Kith.{Emails, Mailer}

  @doc "Deliver instructions to confirm a new account."
  def deliver_confirmation_instructions(user, url) do
    user
    |> Emails.email_verification(url)
    |> put_to(user.email)
    |> subject("Confirm your Kith account")
    |> deliver()
  end

  @doc "Deliver instructions to reset a user password."
  def deliver_reset_password_instructions(user, url) do
    user
    |> Emails.password_reset(url)
    |> put_to(user.email)
    |> subject("Reset your Kith password")
    |> deliver()
  end

  @doc "Deliver instructions to update a user email."
  def deliver_update_email_instructions(user, url) do
    user
    |> Emails.email_change(url)
    |> put_to(user.email)
    |> subject("Update email instructions")
    |> deliver()
  end

  @doc "Deliver an invitation to join an account."
  def deliver_invitation(email, %{
        account_name: account_name,
        invited_by_name: invited_by_name,
        role: role,
        url: url
      }) do
    email
    |> Emails.invitation(%{
      account_name: account_name,
      inviter_name: invited_by_name,
      role: role,
      accept_url: url
    })
    |> put_to(email)
    |> subject("You've been invited to join #{account_name} on Kith")
    |> deliver()
  end

  defp deliver(email) do
    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end
end
