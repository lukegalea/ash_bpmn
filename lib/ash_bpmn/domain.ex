# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Domain do
  @moduledoc """
  The `callables` section: the host actions a diagram may call, declared once.

      use Ash.Domain, extensions: [AshBpmn.Domain]

      callables do
        callable :approve_payout, MyApp.Finance.Payout, :approve do
          description "Approves a payout after maker-checker"   # optional, shown in the designer
        end
      end

  ## Compile-time verification

  Declaring a callable is verified when the domain compiles:

    * the resource belongs to the declaring domain,
    * the action exists on the resource,
    * the name is unique within the domain.

  A diagram therefore cannot publish against a callable that is not there — the same
  publish-time promise the decision resolver's `exists?/1` makes, enforced one step
  earlier.

  ## The reference spelling

  In diagrams, a callable is spelled `"Domain.name"` — e.g.
  `"MyApp.Bpmn.approve_payout"`. Aliases are resolved at DSL definition; a diagram never
  contains module aliases beyond the domain's own name.

  ## Introspection

    * `callables/1` — the declared callables, in declaration order. This is the
      designer dropdown's data source.
    * `callable?/2` — whether a `"Domain.name"` ref resolves. This is the
      publish-time check.
  """

  # The DSL pieces (the `callables` section and its builder macros) live in a child
  # extension, `AshBpmn.Domain.Dsl`, which hosts get automatically when they list this
  # module. The child owns the `defmacro callables(body)` the DSL needs; this module
  # owns the `def callables(domain)` introspection is. Same name, two natures — Elixir
  # does not let a defmacro and a def of the same name share a module, so they cannot
  # both live here, and TRD §3 pins both spellings: the `callables do ... end` block on
  # the domain and `AshBpmn.Domain.callables(domain)` for introspection.
  use Spark.Dsl.Extension,
    sections: [],
    add_extensions: [AshBpmn.Domain.Dsl]

  alias Spark.Dsl.Extension

  defmodule Callable do
    @moduledoc """
    A callable declared in a domain's `callables` block.

    `:name` is what diagrams spell inside `"Domain.name"`; `:resource` and `:action` are
    what actually gets invoked; `:description` is designer copy.
    """

    defstruct [:name, :resource, :action, :description, :__spark_metadata__]

    @type t :: %__MODULE__{
            name: atom(),
            resource: module(),
            action: atom(),
            description: String.t() | nil,
            __spark_metadata__: Spark.Dsl.Entity.spark_meta()
          }
  end

  defmodule Dsl do
    @moduledoc false

    @callable %Spark.Dsl.Entity{
      name: :callable,
      describe: """
      Declares a host action a diagram may call by name.

      The reference a diagram spells is `"Domain.name"`, where `Domain` is this domain's
      own module name. The declaration is verified when the domain compiles: the resource
      must belong to this domain, the action must exist on it, and the name must be unique
      within the domain.
      """,
      examples: [
        "callable :approve_payout, MyApp.Finance.Payout, :approve",
        """
        callable :approve_payout, MyApp.Finance.Payout, :approve do
          description "Approves a payout after maker-checker"
        end
        """
      ],
      target: AshBpmn.Domain.Callable,
      args: [:name, :resource, :action],
      schema: [
        name: [
          type: :atom,
          required: true,
          doc: "The callable's name — the part diagrams spell after the domain."
        ],
        resource: [
          type: {:spark, Ash.Resource},
          required: true,
          doc: "The Ash resource the action lives on. Must be registered in this domain."
        ],
        action: [
          type: :atom,
          required: true,
          doc: "The action to invoke on the resource. Must exist at compile time."
        ],
        description: [
          type: :string,
          doc: "Shown in the designer when an author picks the callable."
        ]
      ]
    }

    @callables %Spark.Dsl.Section{
      name: :callables,
      describe: "The host actions diagrams in this domain may call.",
      examples: [
        """
        callables do
          callable :approve_payout, MyApp.Finance.Payout, :approve do
            description "Approves a payout after maker-checker"
          end
        end
        """
      ],
      entities: [@callable]
    }

    use Spark.Dsl.Extension,
      sections: [@callables],
      verifiers: [AshBpmn.Domain.Verifiers.VerifyCallables]
  end

  @doc """
  Returns the callables declared by `domain`, in declaration order.

  Each element is an `AshBpmn.Domain.Callable` struct: `%{name, resource, action,
  description}`. This is the designer dropdown's data source.
  """
  @spec callables(Spark.Dsl.t() | Ash.Domain.t()) :: [Callable.t()]
  def callables(domain) do
    Extension.get_entities(domain, [:callables])
  end

  @doc """
  Whether `ref` names a callable that exists.

  `ref` is the diagram spelling — `"Domain.name"`, e.g. `"MyApp.Bpmn.approve_payout"`.
  The domain part is resolved to its module the way the runtime resolves domains from job
  args (`to_existing_atom` under the module's `Elixir.`-prefixed name — a stale ref fails
  rather than leaks an atom), and the name is looked up in that domain's `callables`.

  The first argument is the domain asking, and constrains the answer:

    * a module (or its name as a string) — the ref must resolve *within that domain*;
      a ref pointing at any other domain is false, because diagrams never contain module
      aliases beyond the domain's own name.
    * `nil` — the ref's own domain part decides.

  A ref may also be spelled `"name"` (no domain part); then the first argument is required
  and used as the domain. Every failure — unknown domain, unknown name, domain mismatch —
  is `false`, never a raise. This is the publish-time check `ash:call` verification uses.
  """
  @spec callable?(Ash.Domain.t() | String.t() | nil, String.t()) :: boolean()
  def callable?(domain, ref) when is_binary(ref) do
    with {:ok, ref_domain, name} <- split_ref(ref),
         {:ok, resolved} <- resolve_domain(ref_domain, domain),
         {:ok, name_atom} <- existing_name(name) do
      callables(resolved)
      |> Enum.any?(&(&1.name == name_atom))
    else
      _error -> false
    end
  end

  defp split_ref(ref) do
    case String.split(ref, ".") do
      [name] ->
        {:ok, nil, name}

      parts ->
        {:ok, Enum.drop(parts, -1) |> Enum.join("."), List.last(parts)}
    end
  end

  defp resolve_domain(nil, hint) do
    case hint_domain(hint) do
      {:ok, nil} -> {:error, :no_domain}
      other -> other
    end
  end

  defp resolve_domain(domain_string, hint) when is_binary(domain_string) do
    with {:ok, module} <- existing_module(domain_string),
         {:ok, module} <- domain_or_error(module),
         {:ok, hint_module} <- hint_domain(hint),
         :ok <- same_domain?(module, hint_module) do
      {:ok, module}
    end
  end

  defp hint_domain(nil), do: {:ok, nil}

  defp hint_domain(module) when is_atom(module), do: domain_or_error(module)

  defp hint_domain(name) when is_binary(name) do
    with {:ok, module} <- existing_module(name) do
      domain_or_error(module)
    end
  end

  defp hint_domain(_other), do: {:error, :not_a_domain}

  defp domain_or_error(module) do
    if Spark.Dsl.is?(module, Ash.Domain) do
      {:ok, module}
    else
      {:error, :not_a_domain}
    end
  end

  defp same_domain?(_module, nil), do: :ok
  defp same_domain?(module, module), do: :ok
  defp same_domain?(_module, _other), do: {:error, :domain_mismatch}

  # Refs come from XML and job args, so the domain arrives as a string.
  # Module atoms are aliases -- their real names carry the `Elixir.` prefix -- so the
  # lookup must spell it. `to_existing_atom` rather than `to_atom`: the module is
  # compiled into the release running this check, and if it is not -- a stale diagram
  # naming a domain that has since been deleted -- that is a `false`, not a leaked atom.
  defp existing_module(string) do
    {:ok, String.to_existing_atom("Elixir." <> string)}
  rescue
    ArgumentError -> :error
  end

  defp existing_name(string) do
    {:ok, String.to_existing_atom(string)}
  rescue
    ArgumentError -> :error
  end
end
