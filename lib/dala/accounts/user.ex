defmodule Dala.Accounts.User do
  use Ash.Resource,
    otp_app: :dala,
    domain: Dala.Accounts,
    data_layer: AshSqlite.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAuthentication]

  sqlite do
    table "users"
    repo Dala.Repo
  end

  authentication do
    add_ons do
      log_out_everywhere do
        apply_on_password_change? true
      end
    end

    tokens do
      enabled? true
      token_resource Dala.Accounts.Token
      signing_secret Dala.Secrets
      store_all_tokens? true
      require_token_presence_for_authentication? true
      # Match the persistent session cookie (endpoint @session_options
      # max_age): stay signed in for 60 days; sign-out still revokes.
      token_lifetime {60, :days}
    end

    strategies do
      remember_me :remember_me

      password :password do
        identity_field :email
        hash_provider AshAuthentication.BcryptProvider
        # Accounts are pre-seeded from DALA_USERS; there is no self-registration
        # and no password reset (no resettable block).
        registration_enabled? false
      end
    end
  end

  actions do
    defaults [:read]

    read :get_by_subject do
      description "Get a user by the subject claim in a JWT"
      argument :subject, :string, allow_nil?: false
      get? true
      prepare AshAuthentication.Preparations.FilterBySubject
    end

    read :get_by_email do
      description "Looks up a user by their email"
      get_by :email
    end

    create :seed_user do
      description "Create or update a pre-configured account (used by boot seeding)."

      argument :password, :string do
        allow_nil? false
        constraints min_length: 8
        sensitive? true
      end

      accept [:email]
      upsert? true
      upsert_identity :unique_email
      upsert_fields [:hashed_password]

      change {AshAuthentication.Strategy.Password.HashPasswordChange, strategy_name: :password}
    end

    update :change_password do
      # Use this action to allow users to change their password by providing
      # their current password and a new password.

      require_atomic? false
      accept []
      argument :current_password, :string, sensitive?: true, allow_nil?: false

      argument :password, :string,
        sensitive?: true,
        allow_nil?: false,
        constraints: [min_length: 8]

      argument :password_confirmation, :string, sensitive?: true, allow_nil?: false

      validate confirm(:password, :password_confirmation)

      validate {AshAuthentication.Strategy.Password.PasswordValidation,
                strategy_name: :password, password_argument: :current_password}

      change {AshAuthentication.Strategy.Password.HashPasswordChange, strategy_name: :password}
    end

    read :sign_in_with_password do
      description "Attempt to sign in using a email and password."
      get? true

      argument :email, :ci_string do
        description "The email to use for retrieving the user."
        allow_nil? false
      end

      argument :password, :string do
        description "The password to check for the matching user."
        allow_nil? false
        sensitive? true
      end

      # validates the provided email and password and generates a token
      prepare AshAuthentication.Strategy.Password.SignInPreparation

      metadata :token, :string do
        description "A JWT that can be used to authenticate the user."
        allow_nil? false
      end
    end

    read :sign_in_with_token do
      # In the generated sign in components, we validate the
      # email and password directly in the LiveView
      # and generate a short-lived token that can be used to sign in over
      # a standard controller action, exchanging it for a standard token.

      description "Attempt to sign in using a short-lived sign in token."
      get? true

      argument :token, :string do
        description "The short-lived sign in token."
        allow_nil? false
        sensitive? true
      end

      # validates the provided sign in token and generates a token
      prepare AshAuthentication.Strategy.Password.SignInWithTokenPreparation

      metadata :token, :string do
        description "A JWT that can be used to authenticate the user."
        allow_nil? false
      end
    end
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :email, :ci_string do
      allow_nil? false
      public? true
    end

    attribute :hashed_password, :string do
      sensitive? true
    end
  end

  identities do
    identity :unique_email, [:email]
  end
end
