defmodule DalaWeb.AuthOverrides do
  @moduledoc """
  Styles the ash_authentication_phoenix sign-in pages to match Dala's dark,
  terminal-first design (see assets/css/app.css tokens).
  """

  use AshAuthentication.Phoenix.Overrides

  alias AshAuthentication.Phoenix.Components

  @input_class """
  block w-full rounded-md border border-[#24272c] bg-[#0b0c0e] px-3 py-2
  font-mono text-sm text-[#e6e8eb] placeholder-[#5b626b] outline-none
  transition-colors focus:border-[#4cc38a]/60 focus:ring-0
  """

  @submit_class """
  mt-4 w-full rounded-md bg-[#4cc38a] px-4 py-2 text-sm font-medium text-black
  transition-all hover:brightness-110 disabled:opacity-50
  """

  override AshAuthentication.Phoenix.SignInLive do
    set :root_class, "grid min-h-screen place-items-center bg-[#0b0c0e]"
  end

  override AshAuthentication.Phoenix.SignOutLive do
    set :root_class, "grid min-h-screen place-items-center bg-[#0b0c0e]"
  end

  override Components.SignIn do
    set :root_class, """
    mx-4 w-full max-w-sm rounded-2xl border border-[#24272c] bg-[#121417]
    px-8 pb-8 pt-6 shadow-2xl
    """

    set :strategy_class, "w-full"
    set :authentication_error_container_class, "text-center"
    set :authentication_error_text_class, "text-sm text-[#f0716e]"
    set :strategy_display_order, :forms_first
  end

  override Components.SignOut do
    set :root_class, """
    mx-4 flex w-full max-w-sm flex-col items-center rounded-2xl border
    border-[#24272c] bg-[#121417] px-8 py-8 shadow-2xl
    """

    set :h2_class, "font-mono text-sm font-semibold tracking-widest text-[#e6e8eb]"
    set :h2_text, "DALA"
    set :info_text, "Are you sure you want to sign out?"
    set :info_text_class, "mb-4 mt-2 text-sm text-[#8f96a0]"
    set :form_class, "w-full"
    set :button_text, "Sign out"
    set :button_class, @submit_class
  end

  override Components.Banner do
    set :root_class, "flex w-full justify-center pb-1 pt-2"
    set :href_class, "no-underline"
    set :href_url, "/"
    set :image_url, nil
    set :dark_image_url, nil
    set :text, "DALA"

    set :text_class, """
    font-mono text-lg font-semibold tracking-[0.3em] text-[#e6e8eb]
    after:ml-2 after:inline-block after:h-2 after:w-2 after:rounded-full
    after:bg-[#4cc38a] after:content-['']
    """
  end

  override Components.Password do
    set :root_class, "mb-2 mt-2"
    set :interstitial_class, "hidden"
    set :hide_class, "hidden"
  end

  override Components.Password.SignInForm do
    set :root_class, nil
    set :label_class, "mb-1 mt-1 text-center text-xs text-[#8f96a0]"
    set :label_text, "sign in to your terminal"
    set :form_class, nil
    set :slot_class, "my-2"
    set :button_text, "Sign in"
    set :disable_button_text, "Signing in…"
  end

  override Components.Password.Input do
    set :field_class, "mb-3 mt-2"

    set :label_class,
        "mb-1 block text-[11px] uppercase tracking-wider text-[#8f96a0]"

    set :input_class, @input_class
    set :input_class_with_error, @input_class <> " border-[#f0716e]/70"
    set :submit_class, @submit_class
    set :password_input_label, "Password"
    set :identity_input_label, "Email"
    set :error_ul, "my-2 text-xs text-[#f0716e]"
    set :error_li, nil
    set :input_debounce, 350
    set :remember_me_class, "mb-1 mt-3 flex items-center gap-2"

    set :checkbox_class,
        "h-3.5 w-3.5 rounded border-[#24272c] bg-[#0b0c0e] accent-[#4cc38a]"

    set :checkbox_label_class, "text-xs text-[#8f96a0]"
    set :remember_me_input_label, "Remember me"
  end

  override Components.Flash do
    set :root_class, "mb-2 w-full"

    set :message_class_info,
        "rounded-md border border-[#24272c] bg-[#1b1e23] px-3 py-2 text-center text-xs text-[#e6e8eb]"

    set :message_class_error,
        "rounded-md border border-[#f0716e]/40 bg-[#1b1e23] px-3 py-2 text-center text-xs text-[#f0716e]"
  end

  override Components.HorizontalRule do
    set :root_class, "hidden"
  end
end
