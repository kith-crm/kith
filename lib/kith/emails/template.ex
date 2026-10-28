defmodule Kith.Emails.Template do
  @moduledoc "Shared, inline-styled email components using Kith's light theme."

  # sRGB equivalents of the light theme tokens in assets/css/app.css.
  @colors %{
    accent: "#d25900",
    accent_subtle: "#fef8e5",
    surface: "#fbfaf7",
    sunken: "#f6f4f0",
    card: "#ffffff",
    text: "#1c1917",
    secondary: "#57534d",
    tertiary: "#79716b",
    border: "#d6d3d0",
    subtle_border: "#e5e3e1"
  }

  @wrap "word-break:break-word;overflow-wrap:anywhere;"

  def colors, do: @colors

  def escape(nil), do: ""

  def escape(value) do
    value |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
  end

  def heading(text) do
    """
    <h1 style="margin:0 0 18px;font-size:28px;font-weight:600;line-height:1.3;
      letter-spacing:-0.8px;color:#{@colors.text};#{@wrap}">#{escape(text)}</h1>
    """
  end

  def paragraph(text) do
    """
    <p style="margin:0;color:#{@colors.secondary};font-size:14px;line-height:1.8;#{@wrap}">#{escape(text)}</p>
    """
  end

  def note(text) do
    """
    <p style="margin:20px 0 0;color:#{@colors.tertiary};font-size:12px;
      line-height:1.8;#{@wrap}">#{escape(text)}</p>
    """
  end

  def eyebrow(text) do
    """
    <p style="margin:0 0 16px;color:#{@colors.accent};font-size:11px;font-weight:600;
      letter-spacing:1px;line-height:1.5;#{@wrap}">#{escape(text)}</p>
    """
  end

  def panel(label, title, detail) do
    """
    <table role="presentation" width="100%" cellspacing="0" cellpadding="0"
      style="margin:24px 0 0;background:#{@colors.sunken};border:1px solid #{@colors.subtle_border};
      border-radius:6px;table-layout:fixed;"><tr><td style="padding:20px;#{@wrap}">
      <p style="margin:0 0 9px;color:#{@colors.tertiary};font-size:11px;
        font-weight:700;letter-spacing:1px;#{@wrap}">#{escape(label)}</p>
      <p style="margin:0;color:#{@colors.text};font-size:19px;font-weight:600;
        line-height:1.4;#{@wrap}">#{escape(title)}</p>
      <p style="margin:9px 0 0;color:#{@colors.secondary};font-size:13px;
        line-height:1.7;#{@wrap}">#{escape(detail)}</p>
    </td></tr></table>
    """
  end

  def steps(steps) do
    rows =
      steps
      |> Enum.with_index(1)
      |> Enum.map_join(fn {{title, detail}, index} ->
        number = index |> to_string() |> String.pad_leading(2, "0")

        """
        <tr><td width="34" valign="top" style="padding:16px 0;color:#{@colors.accent};font-size:11px;">
          #{number}</td><td style="padding:14px 0;#{@wrap}">
          <p style="margin:0;color:#{@colors.text};font-size:14px;font-weight:600;
            #{@wrap}">#{escape(title)}</p>
          <p style="margin:5px 0 0;color:#{@colors.secondary};font-size:13px;
            line-height:1.6;#{@wrap}">#{escape(detail)}</p>
        </td></tr>
        """
      end)

    """
    <p style="margin:28px 0 14px;color:#{@colors.tertiary};font-size:11px;
      letter-spacing:1px;font-weight:700;text-transform:uppercase;">Getting Started</p>
    <table role="presentation" width="100%" cellspacing="0" cellpadding="0"
      style="table-layout:fixed;">#{rows}</table>
    """
  end

  def button(label, url) do
    # Explicit width keeps Outlook's table sizing bounded; max-width lets narrow
    # clients shrink the button, and long contact names wrap inside the label.
    width = min(280, String.length(to_string(label)) * 8 + 40)

    """
    <table role="presentation" width="#{width}" cellspacing="0" cellpadding="0"
      style="margin:26px 0 0;width:#{width}px;max-width:100%;table-layout:fixed;">
      <tr><td bgcolor="#{@colors.accent}" style="border-radius:6px;text-align:center;#{@wrap}">
        <a href="#{escape(url)}" style="display:block;padding:14px 20px;box-sizing:border-box;max-width:100%;
          border:1px solid #{@colors.accent};border-radius:6px;font-size:13px;line-height:18px;
          font-weight:600;color:#ffffff;text-decoration:none;#{@wrap}">#{escape(label)}</a>
      </td></tr>
    </table>
    """
  end

  def fallback_link(url) do
    """
    <p style="margin:20px 0 0;font-size:11px;line-height:1.7;color:#{@colors.tertiary};">
      Button not working? Copy this link into your browser:<br>
      <a href="#{escape(url)}" style="color:#{@colors.secondary};text-decoration:underline;
        word-break:break-all;overflow-wrap:anywhere;">#{escape(url)}</a>
    </p>
    """
  end

  @doc "Wraps trusted component HTML; escapes preheader and footer text."
  def render(content, opts \\ []) do
    preheader = escape(Keyword.get(opts, :preheader, ""))
    footer = escape(Keyword.get(opts, :footer, "Sent by Kith for your account."))

    """
    <!DOCTYPE html>
    <html lang="en"><head><meta charset="utf-8">
      <meta name="viewport" content="width=device-width,initial-scale=1"></head>
    <body style="margin:0;padding:0;background:#{@colors.surface};color:#{@colors.text};
      font-family:Arial,Helvetica,sans-serif;">
      <div style="display:none;max-height:0;overflow:hidden;opacity:0;mso-hide:all;">#{preheader}</div>
      <table role="presentation" width="100%" cellspacing="0" cellpadding="0"
        style="background:#{@colors.surface};table-layout:fixed;">
        <tr><td align="center" style="padding:28px 12px;">
        <!--[if mso]><table role="presentation" width="560" cellspacing="0" cellpadding="0">
          <tr><td><![endif]-->
        <table role="presentation" width="100%" cellspacing="0" cellpadding="0"
          style="max-width:560px;width:100%;background:#{@colors.card};border:1px solid #{@colors.border};
          border-radius:8px;table-layout:fixed;">
          <tr><td style="padding:24px 24px 22px;border-bottom:1px solid #{@colors.subtle_border};">
            <table role="presentation" cellspacing="0" cellpadding="0"><tr><td width="53">
              <img src="cid:kith-logo.png" alt="Kith logo" width="47" height="32"
                style="display:block;border:0;"></td>
              <td style="font-size:27px;letter-spacing:-1.2px;font-weight:700;
                color:#{@colors.text};">Kith</td></tr></table>
          </td></tr>
          <tr><td style="padding:28px 24px 26px;#{@wrap}">#{content}</td></tr>
        </table>
        <!--[if mso]></td></tr></table><![endif]-->
        <table role="presentation" width="100%" cellspacing="0" cellpadding="0"
          style="max-width:560px;table-layout:fixed;">
          <tr><td style="padding:18px 18px 0;text-align:center;#{@wrap}">
          <p style="margin:0;font-size:11px;line-height:1.8;color:#{@colors.tertiary};#{@wrap}">#{footer}</p>
        </td></tr></table>
      </td></tr></table>
    </body></html>
    """
  end
end
