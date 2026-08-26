defmodule Nucleus.NomadJobs.JobTest do
  use ExUnit.Case, async: true

  alias Nucleus.NomadJobs.Job

  describe "child?/1" do
    test "false for a nil or blank ParentID" do
      refute Job.child?(%{"ParentID" => nil})
      refute Job.child?(%{"ParentID" => ""})
      refute Job.child?(%{})
    end

    test "true for any non-blank ParentID — periodic and dispatch alike" do
      assert Job.child?(%{"ParentID" => "acme-nightly-report"})
      assert Job.child?(%{"ParentID" => "acme-batch-import"})
    end
  end

  describe "from_api/3 — version (Decision 1)" do
    test "reads Job.Version from the detail response" do
      stub = %{"Name" => "api", "Status" => "running", "Periodic" => false}
      detail = %{"Version" => 7, "TaskGroups" => []}

      job = Job.from_api(stub, detail, "local")

      assert job.version == 7
    end

    test "never reads Meta.version — the list stub carries no Version field" do
      # This is the prototype's exact bug (nomad.py:139) made permanent: a
      # detail response missing Version (as the list stub always is) yields
      # nil, never a fallback to some other field.
      stub = %{"Name" => "api", "Status" => "running", "Periodic" => false}
      detail = %{"Meta" => %{"version" => "9.9.9"}, "TaskGroups" => []}

      job = Job.from_api(stub, detail, "local")

      assert job.version == nil
    end
  end

  describe "from_api/3 — image (Decision 3)" do
    test "selects the task where Lifecycle == nil, not Tasks[0]" do
      stub = %{"Name" => "api", "Status" => "running", "Periodic" => false}

      detail = %{
        "TaskGroups" => [
          %{
            "Tasks" => [
              %{
                "Name" => "migrate",
                "Lifecycle" => %{"Hook" => "prestart", "Sidecar" => false},
                "Leader" => false,
                "Config" => %{"image" => "registry.example.com/acme/migrate:sha-aaa"}
              },
              %{
                "Name" => "api",
                "Lifecycle" => nil,
                "Leader" => true,
                "Config" => %{"image" => "registry.example.com/acme/api:v1.4.0"}
              },
              %{
                "Name" => "connect-proxy-acme-api",
                "Lifecycle" => %{"Hook" => "prestart", "Sidecar" => true},
                "Leader" => false,
                "Config" => %{"image" => "envoyproxy/envoy:v1.29.0"}
              }
            ]
          }
        ]
      }

      job = Job.from_api(stub, detail, "local")

      assert job.image == "registry.example.com/acme/api:v1.4.0"
    end

    test "prefers Leader == true when several tasks have Lifecycle == nil" do
      stub = %{"Name" => "api", "Status" => "running", "Periodic" => false}

      detail = %{
        "TaskGroups" => [
          %{
            "Tasks" => [
              %{
                "Name" => "sidekick",
                "Lifecycle" => nil,
                "Leader" => false,
                "Config" => %{"image" => "wrong"}
              },
              %{
                "Name" => "primary",
                "Lifecycle" => nil,
                "Leader" => true,
                "Config" => %{"image" => "right"}
              }
            ]
          }
        ]
      }

      job = Job.from_api(stub, detail, "local")

      assert job.image == "right"
    end

    test "yields the unresolved template reference for the ingress gateway shape" do
      stub = %{"Name" => "acme-ingress", "Status" => "running", "Periodic" => false}

      detail = %{
        "TaskGroups" => [
          %{
            "Tasks" => [
              %{
                "Name" => "connect-ingress-acme-ingress",
                "Lifecycle" => nil,
                "Leader" => false,
                "Config" => %{"image" => "${meta.connect.gateway_image}"}
              }
            ]
          }
        ]
      }

      job = Job.from_api(stub, detail, "local")

      assert job.image == "${meta.connect.gateway_image}"
    end

    test "nil, not an error, when no task qualifies" do
      stub = %{"Name" => "api", "Status" => "running", "Periodic" => false}

      detail = %{
        "TaskGroups" => [
          %{
            "Tasks" => [
              %{
                "Name" => "connect-proxy-only",
                "Lifecycle" => %{"Hook" => "prestart", "Sidecar" => true},
                "Leader" => false,
                "Config" => %{"image" => "envoyproxy/envoy:v1.29.0"}
              }
            ]
          }
        ]
      }

      job = Job.from_api(stub, detail, "local")

      assert job.image == nil
      assert job.detail_error == nil
    end
  end

  describe "from_api/3 — cron (Decision 5)" do
    test "reads Periodic.Spec for a job authored with the legacy cron block" do
      stub = %{"Name" => "nightly", "Status" => "running", "Periodic" => true}
      detail = %{"Periodic" => %{"Spec" => "0 3 * * *", "Specs" => []}, "TaskGroups" => []}

      job = Job.from_api(stub, detail, "local")

      assert job.cron == "0 3 * * *"
    end

    test "reads Periodic.Specs for a job authored with the modern crons block" do
      stub = %{"Name" => "hourly", "Status" => "running", "Periodic" => true}
      detail = %{"Periodic" => %{"Spec" => "", "Specs" => ["0 * * * *"]}, "TaskGroups" => []}

      job = Job.from_api(stub, detail, "local")

      assert job.cron == "0 * * * *"
    end

    test "nil, never a blank string, for a non-periodic job" do
      stub = %{"Name" => "api", "Status" => "running", "Periodic" => false}
      detail = %{"Periodic" => nil, "TaskGroups" => []}

      job = Job.from_api(stub, detail, "local")

      assert job.cron == nil
      assert job.periodic? == false
    end
  end

  describe "degraded/3 (Decision 6)" do
    test "sets detail_error and leaves version, image, and cron all nil" do
      stub = %{"Name" => "api", "Status" => "running", "Periodic" => false}

      job = Job.degraded(stub, "local", :unavailable)

      assert job.name == "api"
      assert job.status == "running"
      assert job.namespace == "local"
      assert job.periodic? == false
      assert job.version == nil
      assert job.image == nil
      assert job.cron == nil
      assert job.detail_error == :unavailable
    end
  end
end
