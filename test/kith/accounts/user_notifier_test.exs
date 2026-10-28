defmodule Kith.Accounts.UserNotifierTest do
  use ExUnit.Case, async: false

  import Swoosh.TestAssertions

  alias Kith.Accounts.UserNotifier

  defmodule FailingAdapter do
    @moduledoc false
    use Swoosh.Adapter

    @impl Swoosh.Adapter
    def deliver(_email, _config), do: {:error, :delivery_failed}
  end

  @user %{email: "person@example.com", locale: "en"}

  test "confirmation delivers HTML and plain text with the original subject and recipient" do
    url = "https://kith.example/users/confirm/confirmation-token"

    assert {:ok, email} = UserNotifier.deliver_confirmation_instructions(@user, url)
    assert email.subject == "Confirm your Kith account"
    assert email.to == [{"", @user.email}]
    assert_email_sent(email)
    assert_branded_multipart(email, url)
    assert email.html_body =~ "7 days"
    assert email.text_body =~ "7 days"
  end

  test "password reset delivers the reset URL and one-hour validity" do
    url = "https://kith.example/users/reset-password/reset-token"

    assert {:ok, email} = UserNotifier.deliver_reset_password_instructions(@user, url)
    assert email.subject == "Reset your Kith password"
    assert email.to == [{"", @user.email}]
    assert_email_sent(email)
    assert_branded_multipart(email, url)
    assert email.html_body =~ "1 hour"
    assert email.text_body =~ "1 hour"
  end

  test "email change delivers to the new address with the original subject" do
    user = %{@user | email: "new-address@example.com"}
    url = "https://kith.example/users/settings/confirm-email/change-token"

    assert {:ok, email} = UserNotifier.deliver_update_email_instructions(user, url)
    assert email.subject == "Update email instructions"
    assert email.to == [{"", user.email}]
    assert_email_sent(email)
    assert_branded_multipart(email, url)
    assert email.html_body =~ "7 days"
    assert email.text_body =~ "7 days"
  end

  test "invitation maps the inviter, role and account into the branded template" do
    url = "https://kith.example/invitations/invitation-token"

    assert {:ok, email} =
             UserNotifier.deliver_invitation("invitee@example.com", %{
               account_name: "Family <&> Friends",
               invited_by_name: "Alex <script>alert(1)</script>",
               role: "editor",
               url: url
             })

    assert email.to == [{"", "invitee@example.com"}]
    assert email.subject == "You've been invited to join Family <&> Friends on Kith"
    assert_email_sent(email)
    assert_branded_multipart(email, url)
    assert email.html_body =~ "Family &lt;&amp;&gt; Friends"
    assert email.html_body =~ "Alex &lt;script&gt;alert(1)&lt;/script&gt;"
    refute email.html_body =~ "<script>"
    assert String.downcase(email.html_body) =~ "editor"
    assert email.text_body =~ "editor"
    assert email.text_body =~ "Alex <script>alert(1)</script>"
    assert email.html_body =~ "7 days"
    assert email.text_body =~ "7 days"
    refute email.html_body =~ "because you have a Kith account"
    refute email.text_body =~ "because you have a Kith account"
  end

  test "adapter errors propagate without reporting successful delivery" do
    original = Application.get_env(:kith, Kith.Mailer, [])
    Application.put_env(:kith, Kith.Mailer, Keyword.put(original, :adapter, FailingAdapter))
    on_exit(fn -> Application.put_env(:kith, Kith.Mailer, original) end)

    assert {:error, :delivery_failed} =
             UserNotifier.deliver_confirmation_instructions(
               @user,
               "https://kith.example/users/confirm/token"
             )

    refute_email_sent()
  end

  defp assert_branded_multipart(email, url) do
    assert email.html_body =~ "Kith"
    assert email.html_body =~ "#d25900"
    assert email.html_body =~ url
    assert email.text_body =~ url
    assert [logo] = email.attachments
    assert logo.type == :inline
    assert logo.content_type == "image/png"
    assert email.html_body =~ "cid:#{logo.cid || logo.filename}"
    refute email.html_body =~ "data:image"
  end
end
