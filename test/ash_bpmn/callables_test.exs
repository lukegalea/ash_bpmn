# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.CallablesTest do
  use ExUnit.Case, async: true

  require Spark.Test

  @domain AshBpmn.Test.CallablesDomain
  @resource AshBpmn.Test.CallablesResource
  @full_ref "AshBpmn.Test.CallablesDomain.approve_payout"

  describe "callables/1" do
    test "returns the declared set, in declaration order" do
      assert [approve, reject] = AshBpmn.Domain.callables(@domain)

      assert %{name: :approve_payout, resource: @resource, action: :approve} = approve
      assert approve.description == "Approves a payout after maker-checker"

      assert %{name: :reject_payout, resource: @resource, action: :reject} = reject
      assert reject.description == nil
    end

    test "a domain without the section has no callables" do
      assert AshBpmn.Domain.callables(AshBpmn.Test.Domain) == []
    end
  end

  describe "callable?/2" do
    test "resolves a full ref against the domain module" do
      assert AshBpmn.Domain.callable?(@domain, @full_ref)
      assert AshBpmn.Domain.callable?(@domain, "AshBpmn.Test.CallablesDomain.reject_payout")
    end

    test "resolves a full ref when the domain is given as a string" do
      assert AshBpmn.Domain.callable?("AshBpmn.Test.CallablesDomain", @full_ref)
    end

    test "resolves a bare name against the given domain" do
      assert AshBpmn.Domain.callable?(@domain, "approve_payout")
    end

    test "resolves with a nil domain when the ref names its own domain" do
      assert AshBpmn.Domain.callable?(nil, @full_ref)
    end

    test "unknown callable names are false" do
      refute AshBpmn.Domain.callable?(@domain, "AshBpmn.Test.CallablesDomain.nope")
      refute AshBpmn.Domain.callable?(@domain, "nope")
    end

    test "unknown domains are false, never a raise" do
      refute AshBpmn.Domain.callable?(nil, "AshBpmn.Test.NoSuchDomain.approve_payout")
      refute AshBpmn.Domain.callable?(@domain, "NotEvenAModule.approve_payout")
    end

    test "a ref pointing at another domain is false when a domain is given" do
      refute AshBpmn.Domain.callable?(AshBpmn.Test.Domain, @full_ref)
    end

    test "a first argument that is not a domain is false" do
      refute AshBpmn.Domain.callable?(String, "approve_payout")
    end

    test "a bare name with no domain to resolve against is false" do
      refute AshBpmn.Domain.callable?(nil, "approve_payout")
    end

    test "actions on the resource itself are not callable names" do
      refute AshBpmn.Domain.callable?(@domain, "AshBpmn.Test.CallablesDomain.approve")
    end
  end

  describe "compile-time verification" do
    # Spark (this version) reports verifier errors from its `@after_verify` hook as
    # collected data rather than raised exceptions, so the assertions go through
    # `Spark.Test.assert_dsl_error/2` instead of `assert_raise/2`.
    test "duplicate names fail compilation" do
      error =
        Spark.Test.assert_dsl_error %Spark.Error.DslError{path: [:callables, :approve_payout]} do
          defmodule Module.concat(["AshBpmn.Test.BadCallables#{unique()}"]) do
            use Ash.Domain, extensions: [AshBpmn.Domain]

            resources do
              resource AshBpmn.Test.CallablesResource
            end

            callables do
              callable(:approve_payout, AshBpmn.Test.CallablesResource, :approve)
              callable(:approve_payout, AshBpmn.Test.CallablesResource, :reject)
            end
          end
        end

      assert error.message =~ "is used 2 times"
    end

    test "an action that does not exist fails compilation" do
      error =
        Spark.Test.assert_dsl_error %Spark.Error.DslError{
          path: [:callables, :approve_payout]
        } do
          defmodule Module.concat(["AshBpmn.Test.BadCallables#{unique()}"]) do
            use Ash.Domain, extensions: [AshBpmn.Domain]

            resources do
              resource AshBpmn.Test.CallablesResource
            end

            callables do
              callable(:approve_payout, AshBpmn.Test.CallablesResource, :does_not_exist)
            end
          end
        end

      assert error.message =~ "has no action :does_not_exist"
    end

    test "a resource outside the domain fails compilation" do
      error =
        Spark.Test.assert_dsl_error %Spark.Error.DslError{path: [:callables, :record_risk]} do
          defmodule Module.concat(["AshBpmn.Test.BadCallables#{unique()}"]) do
            use Ash.Domain, extensions: [AshBpmn.Domain]

            resources do
              resource AshBpmn.Test.CallablesResource
            end

            callables do
              callable(:record_risk, AshBpmn.Test.CatalogueResource, :record_risk)
            end
          end
        end

      assert error.message =~ "is not in this domain's `resources` block"
    end

    defp unique, do: System.unique_integer([:positive])
  end
end
