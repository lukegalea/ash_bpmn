# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.CompilerTest do
  use ExUnit.Case, async: true

  alias AshBpmn.Compiler

  @fixtures Path.join(__DIR__, "../../test/fixtures")

  # ── Fixture helpers ──────────────────────────────────────────────────────

  defp read_fixture(name) do
    Path.join(@fixtures, name) |> File.read!()
  end

  # ── Linear fixture ───────────────────────────────────────────────────────

  describe "linear.bpmn" do
    test "compiles successfully" do
      xml = read_fixture("linear.bpmn")
      assert {:ok, _graph} = Compiler.compile(xml)
    end

    test "has correct process_id" do
      xml = read_fixture("linear.bpmn")
      {:ok, graph} = Compiler.compile(xml)
      assert graph["process_id"] == "Process_linear"
    end

    test "has correct start node" do
      xml = read_fixture("linear.bpmn")
      {:ok, graph} = Compiler.compile(xml)
      assert graph["start"] == "Start_1"
    end

    test "has 3 nodes" do
      xml = read_fixture("linear.bpmn")
      {:ok, graph} = Compiler.compile(xml)
      assert map_size(graph["nodes"]) == 3
    end

    test "has correct node types" do
      xml = read_fixture("linear.bpmn")
      {:ok, graph} = Compiler.compile(xml)
      assert graph["nodes"]["Start_1"]["type"] == "startEvent"
      assert graph["nodes"]["Service_1"]["type"] == "serviceTask"
      assert graph["nodes"]["End_1"]["type"] == "endEvent"
    end

    test "service task has correct action" do
      xml = read_fixture("linear.bpmn")
      {:ok, graph} = Compiler.compile(xml)
      assert graph["nodes"]["Service_1"]["action"] == "do_something"
    end

    test "has 2 flows" do
      xml = read_fixture("linear.bpmn")
      {:ok, graph} = Compiler.compile(xml)
      assert map_size(graph["flows"]) == 2
    end

    test "flows are unconditional" do
      xml = read_fixture("linear.bpmn")
      {:ok, graph} = Compiler.compile(xml)

      Enum.each(graph["flows"], fn {_id, flow} ->
        assert flow["condition"] == nil
      end)
    end

    test "no joins" do
      xml = read_fixture("linear.bpmn")
      {:ok, graph} = Compiler.compile(xml)
      assert graph["joins"] == %{}
    end
  end

  # ── Exclusive gateway fixture ────────────────────────────────────────────

  describe "exclusive.bpmn" do
    test "compiles successfully" do
      xml = read_fixture("exclusive.bpmn")
      assert {:ok, _graph} = Compiler.compile(xml)
    end

    test "has correct node count" do
      xml = read_fixture("exclusive.bpmn")
      {:ok, graph} = Compiler.compile(xml)
      # Start + Gateway + Task_A + Task_B + End = 5
      assert map_size(graph["nodes"]) == 5
    end

    test "gateway has default_flow" do
      xml = read_fixture("exclusive.bpmn")
      {:ok, graph} = Compiler.compile(xml)
      assert graph["nodes"]["Gateway_1"]["default_flow"] == "Flow_default"
    end

    test "conditional flow has parsed condition" do
      xml = read_fixture("exclusive.bpmn")
      {:ok, graph} = Compiler.compile(xml)
      # Flow_cond has the condition from conditionExpression
      assert graph["flows"]["Flow_cond"]["condition"] != nil
    end

    test "default flow has nil condition" do
      xml = read_fixture("exclusive.bpmn")
      {:ok, graph} = Compiler.compile(xml)
      assert graph["flows"]["Flow_default"]["condition"] == nil
    end
  end

  # ── Parallel gateway fixture ──────────────────────────────────────────────

  describe "parallel.bpmn" do
    test "compiles successfully" do
      xml = read_fixture("parallel.bpmn")
      assert {:ok, _graph} = Compiler.compile(xml)
    end

    test "has correct node count" do
      xml = read_fixture("parallel.bpmn")
      {:ok, graph} = Compiler.compile(xml)
      # Start + Fork + Task_A + Task_B + Join + End = 6
      assert map_size(graph["nodes"]) == 6
    end

    test "has one join entry" do
      xml = read_fixture("parallel.bpmn")
      {:ok, graph} = Compiler.compile(xml)
      assert map_size(graph["joins"]) == 1
    end

    test "join waits_for correct nodes" do
      xml = read_fixture("parallel.bpmn")
      {:ok, graph} = Compiler.compile(xml)
      waits_for = graph["joins"]["Join_1"]["waits_for"]
      assert Enum.sort(waits_for) == ["Task_A", "Task_B"]
    end

    test "fork has no join entry" do
      xml = read_fixture("parallel.bpmn")
      {:ok, graph} = Compiler.compile(xml)
      assert Map.has_key?(graph["joins"], "Fork_1") == false
    end
  end

  # ── Access request fixture ───────────────────────────────────────────────

  describe "access_request.bpmn" do
    test "compiles successfully" do
      xml = read_fixture("access_request.bpmn")
      assert {:ok, _graph} = Compiler.compile(xml)
    end

    test "has correct process_id" do
      xml = read_fixture("access_request.bpmn")
      {:ok, graph} = Compiler.compile(xml)
      assert graph["process_id"] == "Process_access_request"
    end

    test "has correct start node" do
      xml = read_fixture("access_request.bpmn")
      {:ok, graph} = Compiler.compile(xml)
      assert graph["start"] == "Start_1"
    end

    test "has correct node count" do
      xml = read_fixture("access_request.bpmn")
      {:ok, graph} = Compiler.compile(xml)
      # Start_1 + Validate + PrivilegedGateway + SecurityApproval + ManagerApproval
      # + MgrDecision + End_rejected + Join_1 + Provision + End_approved = 10
      assert map_size(graph["nodes"]) == 10
    end

    test "service tasks have correct actions" do
      xml = read_fixture("access_request.bpmn")
      {:ok, graph} = Compiler.compile(xml)
      assert graph["nodes"]["Validate"]["action"] == "validate_request"
      assert graph["nodes"]["Provision"]["action"] == "provision_access"
    end

    test "user tasks have candidates and outcomes" do
      xml = read_fixture("access_request.bpmn")
      {:ok, graph} = Compiler.compile(xml)

      security = graph["nodes"]["SecurityApproval"]
      assert length(security["candidates"]) == 1
      assert hd(security["candidates"])["kind"] == "role"
      assert security["outcomes"] == ["approved", "rejected"]

      manager = graph["nodes"]["ManagerApproval"]
      assert length(manager["candidates"]) == 1
      assert hd(manager["candidates"])["kind"] == "manager_of"
      assert manager["exclusions"] == [%{"who" => "subject.created_by_id"}]
      assert manager["outcomes"] == ["approved", "rejected"]
    end

    test "timers are normalized to minutes" do
      xml = read_fixture("access_request.bpmn")
      {:ok, graph} = Compiler.compile(xml)

      security_timers = graph["nodes"]["SecurityApproval"]["timers"]
      assert %{"kind" => "remind", "minutes" => 720} in security_timers
      assert %{"kind" => "escalate", "minutes" => 1440} in security_timers
      assert %{"kind" => "expire", "minutes" => 4320} in security_timers

      manager_timers = graph["nodes"]["ManagerApproval"]["timers"]
      assert %{"kind" => "remind", "minutes" => 1440} in manager_timers
      assert %{"kind" => "escalate", "minutes" => 2880} in manager_timers
      assert %{"kind" => "expire", "minutes" => 10_080} in manager_timers
    end

    test "exclusive gateways have correct defaults" do
      xml = read_fixture("access_request.bpmn")
      {:ok, graph} = Compiler.compile(xml)
      assert graph["nodes"]["PrivilegedGateway"]["default_flow"] == "Flow_NotPriv"
      assert graph["nodes"]["MgrDecision"]["default_flow"] == "Flow_MgrRej"
    end

    test "join waits_for correct nodes" do
      xml = read_fixture("access_request.bpmn")
      {:ok, graph} = Compiler.compile(xml)
      waits_for = graph["joins"]["Join_1"]["waits_for"]
      # waits_for holds the join's incoming SOURCE node ids (DESIGN §5) --
      # MgrDecision is the gateway on the manager branch feeding Join_1.
      assert Enum.sort(waits_for) == ["MgrDecision", "SecurityApproval"]
    end

    test "has correct flow count" do
      xml = read_fixture("access_request.bpmn")
      {:ok, graph} = Compiler.compile(xml)
      # Flow_1 + Flow_2 + Flow_Sec + Flow_NotPriv + Flow_SecOut + Flow_MgrOut
      # + Flow_MgrApp + Flow_MgrRej + Flow_JoinOut + Flow_Done = 10
      assert map_size(graph["flows"]) == 10
    end
  end

  # ── compile!/1 ────────────────────────────────────────────────────────────

  describe "compile!/1" do
    test "returns graph on success" do
      xml = read_fixture("linear.bpmn")
      graph = Compiler.compile!(xml)
      assert is_map(graph)
      assert graph["process_id"] == "Process_linear"
    end

    test "raises on error" do
      xml = ~s(<bpmn2:definitions xmlns:bpmn2="http://www.omg.org/spec/BPMN/20100524/MODEL">
        <bpmn2:process id="P" isExecutable="false">
          <bpmn2:startEvent id="S"><bpmn2:outgoing>F</bpmn2:outgoing></bpmn2:startEvent>
          <bpmn2:endEvent id="E"><bpmn2:incoming>F</bpmn2:incoming></bpmn2:endEvent>
          <bpmn2:sequenceFlow id="F" sourceRef="S" targetRef="E"/>
        </bpmn2:process>
      </bpmn2:definitions>)

      assert_raise RuntimeError, ~r/BPMN compilation failed/, fn ->
        Compiler.compile!(xml)
      end
    end
  end

  # ── Error fixtures ────────────────────────────────────────────────────────

  describe "error: unsupported element" do
    test "rejects unsupported BPMN element type" do
      xml = ~s(<bpmn2:definitions xmlns:bpmn2="http://www.omg.org/spec/BPMN/20100524/MODEL"
                   xmlns:ash="https://github.com/lukegalea/ash_bpmn/ns">
        <bpmn2:process id="P" isExecutable="true">
          <bpmn2:startEvent id="S"><bpmn2:outgoing>F</bpmn2:outgoing></bpmn2:startEvent>
          <bpmn2:scriptTask id="Bad" name="Bad task">
            <bpmn2:incoming>F</bpmn2:incoming>
            <bpmn2:outgoing>F2</bpmn2:outgoing>
          </bpmn2:scriptTask>
          <bpmn2:endEvent id="E"><bpmn2:incoming>F2</bpmn2:incoming></bpmn2:endEvent>
          <bpmn2:sequenceFlow id="F" sourceRef="S" targetRef="Bad"/>
          <bpmn2:sequenceFlow id="F2" sourceRef="Bad" targetRef="E"/>
        </bpmn2:process>
      </bpmn2:definitions>)

      assert {:error, errors} = Compiler.compile(xml)

      assert Enum.any?(errors, fn e ->
               String.contains?(e.message, "'Bad'") and
                 String.contains?(e.message, "not supported")
             end)
    end
  end

  describe "error: two start events" do
    test "rejects multiple start events" do
      xml = ~s(<bpmn2:definitions xmlns:bpmn2="http://www.omg.org/spec/BPMN/20100524/MODEL"
                   xmlns:ash="https://github.com/lukegalea/ash_bpmn/ns">
        <bpmn2:process id="P" isExecutable="true">
          <bpmn2:startEvent id="S1"><bpmn2:outgoing>F1</bpmn2:outgoing></bpmn2:startEvent>
          <bpmn2:startEvent id="S2"><bpmn2:outgoing>F2</bpmn2:outgoing></bpmn2:startEvent>
          <bpmn2:endEvent id="E"><bpmn2:incoming>F1</bpmn2:incoming><bpmn2:incoming>F2</bpmn2:incoming></bpmn2:endEvent>
          <bpmn2:sequenceFlow id="F1" sourceRef="S1" targetRef="E"/>
          <bpmn2:sequenceFlow id="F2" sourceRef="S2" targetRef="E"/>
        </bpmn2:process>
      </bpmn2:definitions>)

      assert {:error, errors} = Compiler.compile(xml)
      assert Enum.any?(errors, fn e -> String.contains?(e.message, "multiple start events") end)
    end
  end

  describe "error: dangling flow (references non-existent node)" do
    test "rejects flow with non-existent target" do
      xml = ~s(<bpmn2:definitions xmlns:bpmn2="http://www.omg.org/spec/BPMN/20100524/MODEL"
                   xmlns:ash="https://github.com/lukegalea/ash_bpmn/ns">
        <bpmn2:process id="P" isExecutable="true">
          <bpmn2:startEvent id="S"><bpmn2:outgoing>F</bpmn2:outgoing></bpmn2:startEvent>
          <bpmn2:endEvent id="E"/>
          <bpmn2:sequenceFlow id="F" sourceRef="S" targetRef="NonExistent"/>
        </bpmn2:process>
      </bpmn2:definitions>)

      assert {:error, errors} = Compiler.compile(xml)
      assert Enum.any?(errors, fn e -> String.contains?(e.message, "non-existent target") end)
    end
  end

  describe "error: unconditioned exclusive branches without default" do
    test "rejects exclusive gateway with unconditioned branches and no default" do
      xml = ~s(<bpmn2:definitions xmlns:bpmn2="http://www.omg.org/spec/BPMN/20100524/MODEL"
                   xmlns:ash="https://github.com/lukegalea/ash_bpmn/ns">
        <bpmn2:process id="P" isExecutable="true">
          <bpmn2:startEvent id="S"><bpmn2:outgoing>F1</bpmn2:outgoing></bpmn2:startEvent>
          <bpmn2:exclusiveGateway id="GW">
            <bpmn2:incoming>F1</bpmn2:incoming>
            <bpmn2:outgoing>F2</bpmn2:outgoing>
            <bpmn2:outgoing>F3</bpmn2:outgoing>
          </bpmn2:exclusiveGateway>
          <bpmn2:endEvent id="E1"><bpmn2:incoming>F2</bpmn2:incoming></bpmn2:endEvent>
          <bpmn2:endEvent id="E2"><bpmn2:incoming>F3</bpmn2:incoming></bpmn2:endEvent>
          <bpmn2:sequenceFlow id="F1" sourceRef="S" targetRef="GW"/>
          <bpmn2:sequenceFlow id="F2" sourceRef="GW" targetRef="E1"/>
          <bpmn2:sequenceFlow id="F3" sourceRef="GW" targetRef="E2"/>
        </bpmn2:process>
      </bpmn2:definitions>)

      assert {:error, errors} = Compiler.compile(xml)

      assert Enum.any?(errors, fn e ->
               String.contains?(e.message, "outgoing flows without conditions")
             end)
    end
  end

  describe "error: mixed parallel gateway" do
    test "rejects parallel gateway that is both fork and join" do
      xml = ~s(<bpmn2:definitions xmlns:bpmn2="http://www.omg.org/spec/BPMN/20100524/MODEL"
                   xmlns:ash="https://github.com/lukegalea/ash_bpmn/ns">
        <bpmn2:process id="P" isExecutable="true">
          <bpmn2:startEvent id="S"><bpmn2:outgoing>F1</bpmn2:outgoing></bpmn2:startEvent>
          <bpmn2:parallelGateway id="Mixed">
            <bpmn2:incoming>F1</bpmn2:incoming>
            <bpmn2:incoming>F2</bpmn2:incoming>
            <bpmn2:outgoing>F3</bpmn2:outgoing>
            <bpmn2:outgoing>F4</bpmn2:outgoing>
          </bpmn2:parallelGateway>
          <bpmn2:serviceTask id="T1" name="T1">
            <bpmn2:extensionElements><ash:taskConfig action="t1"/></bpmn2:extensionElements>
            <bpmn2:incoming>F3</bpmn2:incoming>
            <bpmn2:outgoing>F5</bpmn2:outgoing>
          </bpmn2:serviceTask>
          <bpmn2:serviceTask id="T2" name="T2">
            <bpmn2:extensionElements><ash:taskConfig action="t2"/></bpmn2:extensionElements>
            <bpmn2:incoming>F4</bpmn2:incoming>
            <bpmn2:outgoing>F6</bpmn2:outgoing>
          </bpmn2:serviceTask>
          <bpmn2:parallelGateway id="Join">
            <bpmn2:incoming>F5</bpmn2:incoming>
            <bpmn2:incoming>F6</bpmn2:incoming>
            <bpmn2:outgoing>F7</bpmn2:outgoing>
          </bpmn2:parallelGateway>
          <bpmn2:endEvent id="E"><bpmn2:incoming>F7</bpmn2:incoming></bpmn2:endEvent>
          <bpmn2:sequenceFlow id="F1" sourceRef="S" targetRef="Mixed"/>
          <bpmn2:sequenceFlow id="F2" sourceRef="Join" targetRef="Mixed"/>
          <bpmn2:sequenceFlow id="F3" sourceRef="Mixed" targetRef="T1"/>
          <bpmn2:sequenceFlow id="F4" sourceRef="Mixed" targetRef="T2"/>
          <bpmn2:sequenceFlow id="F5" sourceRef="T1" targetRef="Join"/>
          <bpmn2:sequenceFlow id="F6" sourceRef="T2" targetRef="Join"/>
          <bpmn2:sequenceFlow id="F7" sourceRef="Join" targetRef="E"/>
        </bpmn2:process>
      </bpmn2:definitions>)

      assert {:error, errors} = Compiler.compile(xml)

      assert Enum.any?(errors, fn e ->
               String.contains?(e.message, "both a fork") and
                 String.contains?(e.message, "and a join")
             end)
    end
  end

  describe "error: bad expression in conditionExpression" do
    test "rejects unparseable condition expression" do
      xml = ~s(<bpmn2:definitions xmlns:bpmn2="http://www.omg.org/spec/BPMN/20100524/MODEL"
                   xmlns:ash="https://github.com/lukegalea/ash_bpmn/ns">
        <bpmn2:process id="P" isExecutable="true">
          <bpmn2:startEvent id="S"><bpmn2:outgoing>F1</bpmn2:outgoing></bpmn2:startEvent>
          <bpmn2:exclusiveGateway id="GW" default="F2">
            <bpmn2:incoming>F1</bpmn2:incoming>
            <bpmn2:outgoing>F2</bpmn2:outgoing>
            <bpmn2:outgoing>F3</bpmn2:outgoing>
          </bpmn2:exclusiveGateway>
          <bpmn2:endEvent id="E1"><bpmn2:incoming>F2</bpmn2:incoming></bpmn2:endEvent>
          <bpmn2:endEvent id="E2"><bpmn2:incoming>F3</bpmn2:incoming></bpmn2:endEvent>
          <bpmn2:sequenceFlow id="F1" sourceRef="S" targetRef="GW"/>
          <bpmn2:sequenceFlow id="F2" sourceRef="GW" targetRef="E1"/>
          <bpmn2:sequenceFlow id="F3" sourceRef="GW" targetRef="E2">
            <bpmn2:conditionExpression xsi:type="bpmn2:tFormalExpression">((( ???</bpmn2:conditionExpression>
          </bpmn2:sequenceFlow>
        </bpmn2:process>
      </bpmn2:definitions>)

      assert {:error, errors} = Compiler.compile(xml)

      assert Enum.any?(errors, fn e ->
               String.contains?(e.message, "conditionExpression parse error")
             end)
    end

    # BPMN lets a formal expression declare its language, and the corpus is full of documents
    # written against JUEL and Groovy. Ignoring the attribute would publish such a document and
    # then evaluate it as FEEL -- which is the quiet way a diagram and a system come to be
    # about different processes.
    test "rejects a conditionExpression declaring a language that is not FEEL" do
      xml = ~s(<bpmn2:definitions xmlns:bpmn2="http://www.omg.org/spec/BPMN/20100524/MODEL"
                   xmlns:ash="https://github.com/lukegalea/ash_bpmn/ns">
        <bpmn2:process id="P" isExecutable="true">
          <bpmn2:startEvent id="S"><bpmn2:outgoing>F1</bpmn2:outgoing></bpmn2:startEvent>
          <bpmn2:exclusiveGateway id="GW" default="F2">
            <bpmn2:incoming>F1</bpmn2:incoming>
            <bpmn2:outgoing>F2</bpmn2:outgoing>
            <bpmn2:outgoing>F3</bpmn2:outgoing>
          </bpmn2:exclusiveGateway>
          <bpmn2:endEvent id="E1"><bpmn2:incoming>F2</bpmn2:incoming></bpmn2:endEvent>
          <bpmn2:endEvent id="E2"><bpmn2:incoming>F3</bpmn2:incoming></bpmn2:endEvent>
          <bpmn2:sequenceFlow id="F1" sourceRef="S" targetRef="GW"/>
          <bpmn2:sequenceFlow id="F2" sourceRef="GW" targetRef="E1"/>
          <bpmn2:sequenceFlow id="F3" sourceRef="GW" targetRef="E2">
            <bpmn2:conditionExpression xsi:type="bpmn2:tFormalExpression"
              language="http://www.java.com/products/juel">amount &gt; 100</bpmn2:conditionExpression>
          </bpmn2:sequenceFlow>
        </bpmn2:process>
      </bpmn2:definitions>)

      assert {:error, errors} = Compiler.compile(xml)

      assert Enum.any?(errors, fn e ->
               String.contains?(e.message, "is not supported") and
                 String.contains?(e.message, "FEEL")
             end)
    end

    test "accepts a conditionExpression that declares FEEL explicitly" do
      xml = ~s(<bpmn2:definitions xmlns:bpmn2="http://www.omg.org/spec/BPMN/20100524/MODEL"
                   xmlns:ash="https://github.com/lukegalea/ash_bpmn/ns">
        <bpmn2:process id="P" isExecutable="true">
          <bpmn2:startEvent id="S"><bpmn2:outgoing>F1</bpmn2:outgoing></bpmn2:startEvent>
          <bpmn2:exclusiveGateway id="GW" default="F2">
            <bpmn2:incoming>F1</bpmn2:incoming>
            <bpmn2:outgoing>F2</bpmn2:outgoing>
            <bpmn2:outgoing>F3</bpmn2:outgoing>
          </bpmn2:exclusiveGateway>
          <bpmn2:endEvent id="E1"><bpmn2:incoming>F2</bpmn2:incoming></bpmn2:endEvent>
          <bpmn2:endEvent id="E2"><bpmn2:incoming>F3</bpmn2:incoming></bpmn2:endEvent>
          <bpmn2:sequenceFlow id="F1" sourceRef="S" targetRef="GW"/>
          <bpmn2:sequenceFlow id="F2" sourceRef="GW" targetRef="E1"/>
          <bpmn2:sequenceFlow id="F3" sourceRef="GW" targetRef="E2">
            <bpmn2:conditionExpression xsi:type="bpmn2:tFormalExpression"
              language="feel">subject.amount &gt; 100</bpmn2:conditionExpression>
          </bpmn2:sequenceFlow>
        </bpmn2:process>
      </bpmn2:definitions>)

      assert {:ok, graph} = Compiler.compile(xml)

      # The snapshot stores the source text, not a parsed tree: an instance pinned to this
      # definition must keep evaluating it across engine upgrades, and text pins nothing.
      assert %{"language" => "feel", "text" => "subject.amount > 100"} =
               graph["flows"]["F3"]["condition"]
    end
  end

  describe "error: missing taskConfig on serviceTask" do
    test "rejects serviceTask without taskConfig" do
      xml = ~s(<bpmn2:definitions xmlns:bpmn2="http://www.omg.org/spec/BPMN/20100524/MODEL"
                   xmlns:ash="https://github.com/lukegalea/ash_bpmn/ns">
        <bpmn2:process id="P" isExecutable="true">
          <bpmn2:startEvent id="S"><bpmn2:outgoing>F</bpmn2:outgoing></bpmn2:startEvent>
          <bpmn2:serviceTask id="T" name="No config">
            <bpmn2:incoming>F</bpmn2:incoming>
            <bpmn2:outgoing>F2</bpmn2:outgoing>
          </bpmn2:serviceTask>
          <bpmn2:endEvent id="E"><bpmn2:incoming>F2</bpmn2:incoming></bpmn2:endEvent>
          <bpmn2:sequenceFlow id="F" sourceRef="S" targetRef="T"/>
          <bpmn2:sequenceFlow id="F2" sourceRef="T" targetRef="E"/>
        </bpmn2:process>
      </bpmn2:definitions>)

      assert {:error, errors} = Compiler.compile(xml)

      assert Enum.any?(errors, fn e ->
               String.contains?(e.message, "must have an ash:taskConfig")
             end)
    end
  end

  describe "error: empty action on serviceTask" do
    test "rejects serviceTask with empty action" do
      xml = ~s(<bpmn2:definitions xmlns:bpmn2="http://www.omg.org/spec/BPMN/20100524/MODEL"
                   xmlns:ash="https://github.com/lukegalea/ash_bpmn/ns">
        <bpmn2:process id="P" isExecutable="true">
          <bpmn2:startEvent id="S"><bpmn2:outgoing>F</bpmn2:outgoing></bpmn2:startEvent>
          <bpmn2:serviceTask id="T" name="Empty action">
            <bpmn2:extensionElements>
              <ash:taskConfig action=""/>
            </bpmn2:extensionElements>
            <bpmn2:incoming>F</bpmn2:incoming>
            <bpmn2:outgoing>F2</bpmn2:outgoing>
          </bpmn2:serviceTask>
          <bpmn2:endEvent id="E"><bpmn2:incoming>F2</bpmn2:incoming></bpmn2:endEvent>
          <bpmn2:sequenceFlow id="F" sourceRef="S" targetRef="T"/>
          <bpmn2:sequenceFlow id="F2" sourceRef="T" targetRef="E"/>
        </bpmn2:process>
      </bpmn2:definitions>)

      assert {:error, errors} = Compiler.compile(xml)
      assert Enum.any?(errors, fn e -> String.contains?(e.message, "non-empty action") end)
    end
  end

  describe "error: unknown ash attribute" do
    test "rejects unknown ash: attribute on taskConfig" do
      xml = ~s(<bpmn2:definitions xmlns:bpmn2="http://www.omg.org/spec/BPMN/20100524/MODEL"
                   xmlns:ash="https://github.com/lukegalea/ash_bpmn/ns">
        <bpmn2:process id="P" isExecutable="true">
          <bpmn2:startEvent id="S"><bpmn2:outgoing>F</bpmn2:outgoing></bpmn2:startEvent>
          <bpmn2:serviceTask id="T" name="Bad attr">
            <bpmn2:extensionElements>
              <ash:taskConfig action="do_it" ash:badattr="oops"/>
            </bpmn2:extensionElements>
            <bpmn2:incoming>F</bpmn2:incoming>
            <bpmn2:outgoing>F2</bpmn2:outgoing>
          </bpmn2:serviceTask>
          <bpmn2:endEvent id="E"><bpmn2:incoming>F2</bpmn2:incoming></bpmn2:endEvent>
          <bpmn2:sequenceFlow id="F" sourceRef="S" targetRef="T"/>
          <bpmn2:sequenceFlow id="F2" sourceRef="T" targetRef="E"/>
        </bpmn2:process>
      </bpmn2:definitions>)

      assert {:error, errors} = Compiler.compile(xml)
      assert Enum.any?(errors, fn e -> String.contains?(e.message, "Unknown ash: attribute") end)
    end
  end

  describe "error: isExecutable not true" do
    test "rejects process with isExecutable false" do
      xml = ~s(<bpmn2:definitions xmlns:bpmn2="http://www.omg.org/spec/BPMN/20100524/MODEL">
        <bpmn2:process id="P" isExecutable="false">
          <bpmn2:startEvent id="S"><bpmn2:outgoing>F</bpmn2:outgoing></bpmn2:startEvent>
          <bpmn2:endEvent id="E"><bpmn2:incoming>F</bpmn2:incoming></bpmn2:endEvent>
          <bpmn2:sequenceFlow id="F" sourceRef="S" targetRef="E"/>
        </bpmn2:process>
      </bpmn2:definitions>)

      assert {:error, errors} = Compiler.compile(xml)

      assert Enum.any?(errors, fn e ->
               String.contains?(e.message, "isExecutable must be true")
             end)
    end
  end

  describe "error: no end events" do
    test "rejects process with no end events" do
      xml = ~s(<bpmn2:definitions xmlns:bpmn2="http://www.omg.org/spec/BPMN/20100524/MODEL"
                   xmlns:ash="https://github.com/lukegalea/ash_bpmn/ns">
        <bpmn2:process id="P" isExecutable="true">
          <bpmn2:startEvent id="S"/>
          <bpmn2:serviceTask id="T" name="T">
            <bpmn2:extensionElements><ash:taskConfig action="t"/></bpmn2:extensionElements>
          </bpmn2:serviceTask>
        </bpmn2:process>
      </bpmn2:definitions>)

      assert {:error, errors} = Compiler.compile(xml)
      assert Enum.any?(errors, fn e -> String.contains?(e.message, "at least one end event") end)
    end
  end

  describe "error: node unreachable from start" do
    test "rejects node not reachable from start" do
      xml = ~s(<bpmn2:definitions xmlns:bpmn2="http://www.omg.org/spec/BPMN/20100524/MODEL"
                   xmlns:ash="https://github.com/lukegalea/ash_bpmn/ns">
        <bpmn2:process id="P" isExecutable="true">
          <bpmn2:startEvent id="S"><bpmn2:outgoing>F</bpmn2:outgoing></bpmn2:startEvent>
          <bpmn2:endEvent id="E"><bpmn2:incoming>F</bpmn2:incoming></bpmn2:endEvent>
          <bpmn2:serviceTask id="Orphan" name="Orphan">
            <bpmn2:extensionElements><ash:taskConfig action="orphan"/></bpmn2:extensionElements>
          </bpmn2:serviceTask>
          <bpmn2:sequenceFlow id="F" sourceRef="S" targetRef="E"/>
        </bpmn2:process>
      </bpmn2:definitions>)

      assert {:error, errors} = Compiler.compile(xml)

      assert Enum.any?(errors, fn e ->
               String.contains?(e.message, "not reachable from the start")
             end)
    end
  end

  describe "error: node cannot reach end event" do
    test "rejects node that cannot reach any end event" do
      xml = ~s(<bpmn2:definitions xmlns:bpmn2="http://www.omg.org/spec/BPMN/20100524/MODEL"
                   xmlns:ash="https://github.com/lukegalea/ash_bpmn/ns">
        <bpmn2:process id="P" isExecutable="true">
          <bpmn2:startEvent id="S"><bpmn2:outgoing>F1</bpmn2:outgoing></bpmn2:startEvent>
          <bpmn2:exclusiveGateway id="GW" default="F2">
            <bpmn2:incoming>F1</bpmn2:incoming>
            <bpmn2:outgoing>F2</bpmn2:outgoing>
            <bpmn2:outgoing>F3</bpmn2:outgoing>
          </bpmn2:exclusiveGateway>
          <bpmn2:endEvent id="E"><bpmn2:incoming>F2</bpmn2:incoming></bpmn2:endEvent>
          <bpmn2:serviceTask id="DeadEnd" name="Dead end">
            <bpmn2:extensionElements><ash:taskConfig action="dead"/></bpmn2:extensionElements>
            <bpmn2:incoming>F3</bpmn2:incoming>
          </bpmn2:serviceTask>
          <bpmn2:sequenceFlow id="F1" sourceRef="S" targetRef="GW"/>
          <bpmn2:sequenceFlow id="F2" sourceRef="GW" targetRef="E"/>
          <bpmn2:sequenceFlow id="F3" sourceRef="GW" targetRef="DeadEnd"/>
        </bpmn2:process>
      </bpmn2:definitions>)

      assert {:error, errors} = Compiler.compile(xml)

      assert Enum.any?(errors, fn e ->
               String.contains?(e.message, "cannot reach any end event")
             end)
    end
  end

  describe "error: userTask missing candidates" do
    test "rejects userTask with no candidates" do
      xml = ~s(<bpmn2:definitions xmlns:bpmn2="http://www.omg.org/spec/BPMN/20100524/MODEL"
                   xmlns:ash="https://github.com/lukegalea/ash_bpmn/ns">
        <bpmn2:process id="P" isExecutable="true">
          <bpmn2:startEvent id="S"><bpmn2:outgoing>F</bpmn2:outgoing></bpmn2:startEvent>
          <bpmn2:userTask id="UT" name="No candidates">
            <bpmn2:extensionElements>
              <ash:taskConfig>
                <ash:outcomes>
                  <ash:outcome name="approved"/>
                </ash:outcomes>
              </ash:taskConfig>
            </bpmn2:extensionElements>
            <bpmn2:incoming>F</bpmn2:incoming>
            <bpmn2:outgoing>F2</bpmn2:outgoing>
          </bpmn2:userTask>
          <bpmn2:endEvent id="E"><bpmn2:incoming>F2</bpmn2:incoming></bpmn2:endEvent>
          <bpmn2:sequenceFlow id="F" sourceRef="S" targetRef="UT"/>
          <bpmn2:sequenceFlow id="F2" sourceRef="UT" targetRef="E"/>
        </bpmn2:process>
      </bpmn2:definitions>)

      assert {:error, errors} = Compiler.compile(xml)
      assert Enum.any?(errors, fn e -> String.contains?(e.message, "at least one candidate") end)
    end
  end

  describe "error: userTask missing outcomes" do
    test "rejects userTask with no outcomes" do
      xml = ~s(<bpmn2:definitions xmlns:bpmn2="http://www.omg.org/spec/BPMN/20100524/MODEL"
                   xmlns:ash="https://github.com/lukegalea/ash_bpmn/ns">
        <bpmn2:process id="P" isExecutable="true">
          <bpmn2:startEvent id="S"><bpmn2:outgoing>F</bpmn2:outgoing></bpmn2:startEvent>
          <bpmn2:userTask id="UT" name="No outcomes">
            <bpmn2:extensionElements>
              <ash:taskConfig>
                <ash:candidates>
                  <ash:candidate kind="role" of="admin"/>
                </ash:candidates>
              </ash:taskConfig>
            </bpmn2:extensionElements>
            <bpmn2:incoming>F</bpmn2:incoming>
            <bpmn2:outgoing>F2</bpmn2:outgoing>
          </bpmn2:userTask>
          <bpmn2:endEvent id="E"><bpmn2:incoming>F2</bpmn2:incoming></bpmn2:endEvent>
          <bpmn2:sequenceFlow id="F" sourceRef="S" targetRef="UT"/>
          <bpmn2:sequenceFlow id="F2" sourceRef="UT" targetRef="E"/>
        </bpmn2:process>
      </bpmn2:definitions>)

      assert {:error, errors} = Compiler.compile(xml)
      assert Enum.any?(errors, fn e -> String.contains?(e.message, "at least one outcome") end)
    end
  end

  # ── Refusal corpus: constructs nested inside supported nodes ─────────────
  #
  # Each fixture is an otherwise-valid process whose supported node carries a
  # BPMN construct the engine does not implement. Before the honest-compiler
  # change, a timerEventDefinition start executed as a plain none-start and an
  # errorEventDefinition end completed successfully; each of these documents
  # must now be refused, naming the node id and the construct.
  @refusal_corpus [
    {"refusal_timer_start.bpmn", "Start_1", "timerEventDefinition"},
    {"refusal_message_start.bpmn", "Start_1", "messageEventDefinition"},
    {"refusal_signal_start.bpmn", "Start_1", "signalEventDefinition"},
    {"refusal_conditional_start.bpmn", "Start_1", "conditionalEventDefinition"},
    {"refusal_error_end.bpmn", "End_1", "errorEventDefinition"},
    {"refusal_escalation_end.bpmn", "End_1", "escalationEventDefinition"},
    {"refusal_signal_end.bpmn", "End_1", "signalEventDefinition"},
    {"refusal_message_end.bpmn", "End_1", "messageEventDefinition"},
    {"refusal_multi_instance.bpmn", "Approval_1", "multiInstanceLoopCharacteristics"},
    {"refusal_standard_loop.bpmn", "Service_1", "standardLoopCharacteristics"},
    {"refusal_data_association.bpmn", "Service_1", "dataInputAssociation"},
    {"refusal_data_association.bpmn", "Service_1", "dataOutputAssociation"},
    # bpmn:-prefixed unsupported constructs at both levels: at one point only
    # `bpmn2:` was matched, so a `bpmn:`-prefixed document silently ignored
    # exactly these elements.
    {"refusal_bpmn_prefix_subprocess.bpmn", "Sub_1", "subProcess"},
    {"refusal_bpmn_prefix_timer_start.bpmn", "Start_1", "timerEventDefinition"}
  ]

  defp compile_fixture_errors(name) do
    case Compiler.compile(read_fixture(name)) do
      {:ok, _graph} ->
        flunk("expected #{name} to be refused")

      {:error, errors} ->
        errors
    end
  end

  for {fixture, id, construct} <- @refusal_corpus do
    test "refusal corpus: #{fixture} refuses naming '#{id}' and #{construct}" do
      errors = compile_fixture_errors(unquote(fixture))

      assert Enum.any?(errors, fn e ->
               e.path == unquote(id) and
                 String.contains?(e.message, unquote(id)) and
                 String.contains?(e.message, unquote(construct)) and
                 String.contains?(e.message, "not supported")
             end),
             "no error names #{unquote(id)} and #{unquote(construct)}; got: #{inspect(errors)}"
    end
  end

  describe "prefix normalization (FR-1.2)" do
    # The refusal must be a function of the element, not of which prefix the
    # document happened to bind the BPMN namespace to.
    test "bpmn: and bpmn2: unsupported elements refuse identically" do
      for prefix <- ["bpmn2", "bpmn"] do
        xml = """
        <bpmn2:definitions xmlns:bpmn2="http://www.omg.org/spec/BPMN/20100524/MODEL"
                           xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                           xmlns:ash="https://github.com/lukegalea/ash_bpmn/ns">
          <bpmn2:process id="P" isExecutable="true">
            <bpmn2:startEvent id="S"><bpmn2:outgoing>F</bpmn2:outgoing></bpmn2:startEvent>
            <#{prefix}:scriptTask id="Bad">
              <bpmn2:incoming>F</bpmn2:incoming>
              <bpmn2:outgoing>F2</bpmn2:outgoing>
            </#{prefix}:scriptTask>
            <bpmn2:endEvent id="E"><bpmn2:incoming>F2</bpmn2:incoming></bpmn2:endEvent>
            <bpmn2:sequenceFlow id="F" sourceRef="S" targetRef="Bad"/>
            <bpmn2:sequenceFlow id="F2" sourceRef="Bad" targetRef="E"/>
          </bpmn2:process>
        </bpmn2:definitions>
        """

        assert {:error, errors} = Compiler.compile(xml)

        assert Enum.any?(errors, fn e ->
                 e.path == "Bad" and String.contains?(e.message, "'scriptTask'") and
                   String.contains?(e.message, "not supported")
               end),
               "prefix #{prefix}: expected a refusal naming 'scriptTask'; got #{inspect(errors)}"
      end
    end

    test "a supported node type under the bpmn: prefix compiles like its bpmn2: twin" do
      xml = """
      <bpmn2:definitions xmlns:bpmn2="http://www.omg.org/spec/BPMN/20100524/MODEL"
                         xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                         xmlns:ash="https://github.com/lukegalea/ash_bpmn/ns">
        <bpmn2:process id="P" isExecutable="true">
          <bpmn2:startEvent id="S"><bpmn2:outgoing>F</bpmn2:outgoing></bpmn2:startEvent>
          <bpmn:userTask id="UT" name="Review">
            <bpmn:extensionElements>
              <ash:taskConfig>
                <ash:candidates>
                  <ash:candidate kind="role" of="admin"/>
                </ash:candidates>
                <ash:outcomes>
                  <ash:outcome name="approved"/>
                </ash:outcomes>
              </ash:taskConfig>
            </bpmn:extensionElements>
            <bpmn:incoming>F</bpmn:incoming>
            <bpmn:outgoing>F2</bpmn:outgoing>
          </bpmn:userTask>
          <bpmn2:endEvent id="E"><bpmn2:incoming>F2</bpmn2:incoming></bpmn2:endEvent>
          <bpmn2:sequenceFlow id="F" sourceRef="S" targetRef="UT"/>
          <bpmn2:sequenceFlow id="F2" sourceRef="UT" targetRef="E"/>
        </bpmn2:process>
      </bpmn2:definitions>
      """

      assert {:ok, graph} = Compiler.compile(xml)
      assert graph["nodes"]["UT"]["type"] == "userTask"
      assert graph["nodes"]["UT"]["outcomes"] == ["approved"]
    end
  end

  describe "unrecognized children of supported nodes (FR-1.1)" do
    test "refuses an unrecognized BPMN child of a supported node" do
      xml = ~s(<bpmn2:definitions xmlns:bpmn2="http://www.omg.org/spec/BPMN/20100524/MODEL"
                   xmlns:ash="https://github.com/lukegalea/ash_bpmn/ns">
        <bpmn2:process id="P" isExecutable="true">
          <bpmn2:startEvent id="S"><bpmn2:outgoing>F</bpmn2:outgoing></bpmn2:startEvent>
          <bpmn2:serviceTask id="T">
            <bpmn2:extensionElements><ash:taskConfig action="work"/></bpmn2:extensionElements>
            <bpmn2:mysteryElement id="M"/>
            <bpmn2:incoming>F</bpmn2:incoming>
            <bpmn2:outgoing>F2</bpmn2:outgoing>
          </bpmn2:serviceTask>
          <bpmn2:endEvent id="E"><bpmn2:incoming>F2</bpmn2:incoming></bpmn2:endEvent>
          <bpmn2:sequenceFlow id="F" sourceRef="S" targetRef="T"/>
          <bpmn2:sequenceFlow id="F2" sourceRef="T" targetRef="E"/>
        </bpmn2:process>
      </bpmn2:definitions>)

      assert {:error, errors} = Compiler.compile(xml)

      assert Enum.any?(errors, fn e ->
               e.path == "T" and
                 String.contains?(e.message, "unrecognized") and
                 String.contains?(e.message, "mysteryElement")
             end),
             "got: #{inspect(errors)}"
    end

    test "refuses BPMN content inside extensionElements" do
      xml = ~s(<bpmn2:definitions xmlns:bpmn2="http://www.omg.org/spec/BPMN/20100524/MODEL"
                   xmlns:ash="https://github.com/lukegalea/ash_bpmn/ns">
        <bpmn2:process id="P" isExecutable="true">
          <bpmn2:startEvent id="S"><bpmn2:outgoing>F</bpmn2:outgoing></bpmn2:startEvent>
          <bpmn2:serviceTask id="T">
            <bpmn2:extensionElements>
              <ash:taskConfig action="work"/>
              <bpmn2:timerEventDefinition/>
            </bpmn2:extensionElements>
            <bpmn2:incoming>F</bpmn2:incoming>
            <bpmn2:outgoing>F2</bpmn2:outgoing>
          </bpmn2:serviceTask>
          <bpmn2:endEvent id="E"><bpmn2:incoming>F2</bpmn2:incoming></bpmn2:endEvent>
          <bpmn2:sequenceFlow id="F" sourceRef="S" targetRef="T"/>
          <bpmn2:sequenceFlow id="F2" sourceRef="T" targetRef="E"/>
        </bpmn2:process>
      </bpmn2:definitions>)

      assert {:error, errors} = Compiler.compile(xml)

      assert Enum.any?(errors, fn e ->
               e.path == "T" and String.contains?(e.message, "timerEventDefinition") and
                 String.contains?(e.message, "not supported")
             end),
             "got: #{inspect(errors)}"
    end

    # The preserved posture: hosts carry their own extensions under their own
    # namespaces (and directly off nodes, where moddle round-trips them), and
    # the ash: vocabulary inside extensionElements is parsed as before. None
    # of that is a BPMN construct, so none of it refuses.
    test "still accepts host-carried extensions and benign serialization" do
      xml = ~s(<bpmn2:definitions xmlns:bpmn2="http://www.omg.org/spec/BPMN/20100524/MODEL"
                   xmlns:ash="https://github.com/lukegalea/ash_bpmn/ns"
                   xmlns:host="https://example.com/host/ns">
        <bpmn2:process id="P" isExecutable="true">
          <bpmn2:documentation>Process-level documentation is inert.</bpmn2:documentation>
          <bpmn2:startEvent id="S"><bpmn2:outgoing>F</bpmn2:outgoing></bpmn2:startEvent>
          <bpmn2:serviceTask id="T">
            <bpmn2:documentation>Node documentation is inert.</bpmn2:documentation>
            <host:annotation panel="audit"/>
            <bpmn2:extensionElements>
              <ash:taskConfig action="work"/>
              <host:extraMeta ref="x"/>
            </bpmn2:extensionElements>
            <bpmn2:incoming>F</bpmn2:incoming>
            <bpmn2:outgoing>F2</bpmn2:outgoing>
          </bpmn2:serviceTask>
          <bpmn2:endEvent id="E"><bpmn2:incoming>F2</bpmn2:incoming></bpmn2:endEvent>
          <bpmn2:sequenceFlow id="F" sourceRef="S" targetRef="T"/>
          <bpmn2:sequenceFlow id="F2" sourceRef="T" targetRef="E"/>
        </bpmn2:process>
      </bpmn2:definitions>)

      assert {:ok, graph} = Compiler.compile(xml)
      assert graph["nodes"]["T"]["action"] == "work"
    end
  end

  describe "definitions-level warnings (FR-1.3)" do
    test "a message flow touching this process warns, and the publish succeeds" do
      xml = read_fixture("definitions_messageflow.bpmn")

      assert {:ok, graph} = Compiler.compile(xml)

      warnings = graph["warnings"]

      assert Enum.any?(warnings, fn w ->
               w.path == "MessageFlow_submit" and
                 String.contains?(w.message, "MessageFlow_submit") and
                 String.contains?(w.message, "not executed")
             end),
             "got: #{inspect(warnings)}"

      assert Enum.any?(warnings, fn w ->
               w.path == "Participant_requester" and
                 String.contains?(w.message, "Participant_requester")
             end),
             "got: #{inspect(warnings)}"
    end

    test "definitions-level declarations that do not reference this process stay silent" do
      xml = ~s(<bpmn2:definitions xmlns:bpmn2="http://www.omg.org/spec/BPMN/20100524/MODEL"
                   xmlns:ash="https://github.com/lukegalea/ash_bpmn/ns">
        <bpmn2:message id="M_1" name="unrelated"/>
        <bpmn2:signal id="Sig_1" name="unrelated"/>
        <bpmn2:process id="P" isExecutable="true">
          <bpmn2:startEvent id="S"><bpmn2:outgoing>F</bpmn2:outgoing></bpmn2:startEvent>
          <bpmn2:serviceTask id="T">
            <bpmn2:extensionElements><ash:taskConfig action="work"/></bpmn2:extensionElements>
            <bpmn2:incoming>F</bpmn2:incoming>
            <bpmn2:outgoing>F2</bpmn2:outgoing>
          </bpmn2:serviceTask>
          <bpmn2:endEvent id="E"><bpmn2:incoming>F2</bpmn2:incoming></bpmn2:endEvent>
          <bpmn2:sequenceFlow id="F" sourceRef="S" targetRef="T"/>
          <bpmn2:sequenceFlow id="F2" sourceRef="T" targetRef="E"/>
        </bpmn2:process>
      </bpmn2:definitions>)

      assert {:ok, graph} = Compiler.compile(xml)
      assert graph["warnings"] == []
    end
  end

  describe "FEEL engine stamp (FR-1.4)" do
    test "the snapshot records which engine validated the conditions" do
      xml = read_fixture("exclusive.bpmn")
      {:ok, graph} = Compiler.compile(xml)

      assert %{"name" => "boxic_feel", "version" => version} = graph["feel_engine"]
      assert version == to_string(Application.spec(:boxic_feel, :vsn))
      assert version != ""
    end
  end
end
