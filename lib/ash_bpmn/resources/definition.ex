# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Resources.Definition do
  @moduledoc """
  Resource macro for BPMN process definitions.

  Builds an immutable, versioned definition resource.  The host supplies at
  minimum `domain:` and `repo:` options.

  ## Options

    * `:domain` — **required**.  The Ash domain this resource belongs to.
    * `:repo` — **required**.  The `AshPostgres.Repo` for this resource.
    * `:table` — table name (default `"bpmn_definitions"`).
    * `:tenant?` — set `true` to add `organization_id` multitenancy (default `false`).

  ## Code interfaces (generated on the host module)

    * `publish!/1` — draft → published (errors must be `[]`).
    * `retire!/1` — published → retired.
    * `save_xml!/2` — update XML on a draft definition.
    * `by_key_version/2` — fetch by identity (returns single or `nil`).
    * `latest_published/1` — returns list (callers take `hd/1`).

  ## Host injection

  An optional `do` block is spliced after the generated DSL, allowing hosts to
  inject policies or other extensions.
  """

  defmacro __using__(opts) do
    domain = Keyword.fetch!(opts, :domain)
    repo = Keyword.fetch!(opts, :repo)
    table = Keyword.get(opts, :table, "bpmn_definitions")
    tenant? = Keyword.get(opts, :tenant?, false)
    do_block = Keyword.get(opts, :do, nil)

    quote do
      use Ash.Resource,
        domain: unquote(domain),
        data_layer: AshPostgres.DataLayer,
        authorizers: [Ash.Policy.Authorizer]

      @ash_bpmn_kind :definition

      def ash_bpmn_kind, do: @ash_bpmn_kind

      postgres do
        table unquote(table)
        repo unquote(repo)

        custom_indexes do
          index [:key, :status], unique: true, where: "status = 'draft'"
        end
      end

      if unquote(tenant?) do
        multitenancy do
          strategy :attribute
          attribute :organization_id
          global? true
        end
      end

      attributes do
        uuid_primary_key :id

        attribute :key, :string do
          allow_nil? false
          public? true
        end

        attribute :name, :string do
          allow_nil? false
          public? true
        end

        attribute :version, :integer do
          allow_nil? false
          public? true
        end

        attribute :status, :atom do
          constraints one_of: [:draft, :published, :retired]
          default :draft
          allow_nil? false
          public? true
        end

        attribute :xml, :string do
          allow_nil? false
          sensitive? true
        end

        attribute :graph, :map do
          public? true
        end

        attribute :errors, {:array, :map} do
          default []
          public? true
        end

        attribute :content_hash, :string do
          allow_nil? false
          public? true
        end

        if unquote(tenant?) do
          attribute :organization_id, :uuid do
            allow_nil? false
            public? true
            writable? false
          end
        end

        timestamps()
      end

      identities do
        identity :unique_key_version, [:key, :version]
      end

      actions do
        read :read do
          primary? true
        end

        read :latest_published do
          argument :key, :string do
            allow_nil? false
          end

          filter expr(status == :published and key == ^arg(:key))
          sort version: :desc
          limit 1
        end

        create :create do
          accept [:key, :name, :xml]
          require_atomic? false

          change AshBpmn.Resources.Definition.AssignVersion
          change AshBpmn.Resources.Definition.ComputeHash
          validate AshBpmn.Resources.Definition.UniqueDraftCheck
        end

        update :save_xml do
          accept [:xml]
          require_atomic? false

          validate attribute_equals(:status, :draft) do
            message "can only save XML on a draft definition"
          end

          change AshBpmn.Resources.Definition.ComputeHash
        end

        update :publish do
          accept []

          validate attribute_equals(:status, :draft) do
            message "can only publish a draft definition"
          end

          validate AshBpmn.Resources.Definition.ErrorsEmpty
          change set_attribute(:status, :published)
        end

        update :retire do
          accept []

          validate attribute_equals(:status, :published) do
            message "can only retire a published definition"
          end

          change set_attribute(:status, :retired)
        end
      end

      code_interface do
        define :publish!, action: :publish
        define :retire!, action: :retire
        define :save_xml!, action: :save_xml, args: [:xml]
        define :by_key_version, action: :read, get_by: [:key, :version], get?: true
        define :latest_published, action: :latest_published, args: [:key]
      end

      unquote(do_block)
    end
  end
end

defmodule AshBpmn.Resources.Definition.AssignVersion do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    key = Ash.Changeset.get_attribute(changeset, :key)
    resource = changeset.resource

    if is_nil(key) do
      changeset
    else
      max_version = fetch_max_version(resource, key)

      Ash.Changeset.change_attribute(changeset, :version, max_version + 1)
    end
  end

  defp fetch_max_version(resource, key) do
    resource
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(key == ^key)
    |> Ash.Query.sort(version: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(authorize?: false)
    |> case do
      nil -> 0
      record -> record.version
    end
  rescue
    _ -> 0
  end
end

defmodule AshBpmn.Resources.Definition.ComputeHash do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    xml = Ash.Changeset.get_attribute(changeset, :xml)

    if is_nil(xml) do
      changeset
    else
      hash =
        :crypto.hash(:sha256, xml)
        |> Base.encode16(case: :lower)

      Ash.Changeset.change_attribute(changeset, :content_hash, hash)
    end
  end
end

defmodule AshBpmn.Resources.Definition.ErrorsEmpty do
  @moduledoc false
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    errors = Ash.Changeset.get_attribute(changeset, :errors)

    if errors == [] do
      :ok
    else
      {:error, field: :errors, message: "cannot publish a definition with compile errors"}
    end
  end
end

defmodule AshBpmn.Resources.Definition.UniqueDraftCheck do
  @moduledoc false
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    key = Ash.Changeset.get_attribute(changeset, :key)
    resource = changeset.resource

    if is_nil(key) do
      :ok
    else
      exists =
        resource
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(key == ^key and status == :draft)
        |> Ash.read_one!(authorize?: false)
        |> case do
          nil -> false
          _ -> true
        end
      rescue
        _ -> false
      end

      if exists do
        {:error, field: :key, message: "a draft already exists for this key"}
      else
        :ok
      end
    end
  end
end
