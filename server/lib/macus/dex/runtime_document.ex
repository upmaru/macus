defmodule Macus.Dex.RuntimeDocument do
  @moduledoc """
  The Macus runtime operations as a `tama-operations/1` document, source
  `macus`, loaded into the local `macus` cassette and run by
  `Macus.Dex.RuntimeExecutor` over the private Swift runtime API.

  - Reads (`runtime.read`): status, progress, health, capabilities and
    configuration.
  - Lifecycle (`runtime.write`): create, start, graceful stop, restart and
    configuration replacement.
  - Destructive (`runtime.delete`): forced stop and runtime deletion. Each
    needs its `confirm` token (`"force-stop"`, `"delete-runtime"`), which the
    executor checks and maps to the private API's boolean.

  Stopped-state preconditions are stated in the description and in
  `x-macus-requires-state`; the private API enforces them with a native 409.
  Lifecycle results report `status` (`completed`, or `uncertain` when the
  response was not received within the bounded wait) and the runtime
  `state`. Status results omit the private `incus_socket` path.
  """

  @scopes %{read: "runtime.read", write: "runtime.write", delete: "runtime.delete"}
  @states ["absent", "stopped", "starting", "ready", "stopping", "failed"]
  @mutation_wait_seconds 25

  @doc "Every scope a runtime operation can require."
  @spec scopes() :: [String.t()]
  def scopes, do: Map.values(@scopes) |> Enum.sort()

  @doc "The seconds a lifecycle operation waits for the runtime's reply."
  @spec mutation_wait_seconds() :: pos_integer()
  def mutation_wait_seconds, do: @mutation_wait_seconds

  @doc "The confirmation token an operation requires, or nil."
  @spec confirmation(String.t()) :: String.t() | nil
  def confirmation("macus_runtime_force_stop"), do: "force-stop"
  def confirmation("macus_runtime_delete"), do: "delete-runtime"
  def confirmation(_operation_id), do: nil

  @doc "The operation IDs, in document order."
  @spec operation_ids() :: [String.t()]
  def operation_ids, do: Enum.map(operations(), & &1.id)

  @doc "The document, as decoded JSON."
  @spec document() :: map()
  def document do
    %{
      "openapi" => "3.1.1",
      "info" => %{
        "title" => "Macus runtime operations",
        "version" => "1.0.0",
        "description" =>
          "Lifecycle and inspection of the Macus Linux VM through its private Swift runtime API."
      },
      "x-tama-profile" => "tama-operations/1",
      "x-tama-source" => "macus",
      "paths" => Map.new(operations(), &{"/operations/#{&1.id}", %{"post" => operation(&1)}})
    }
  end

  defp operations do
    [
      %{
        id: "macus_runtime_status",
        summary: "Get runtime status",
        description:
          "Read the Macus VM state (absent, stopped, starting, ready, stopping or failed), uptime and last error. Always readable, also while a lifecycle operation runs.",
        scope: :read,
        input: empty_input(),
        output: status_schema(),
        identity: ["state"]
      },
      %{
        id: "macus_runtime_progress",
        summary: "Get boot progress",
        description:
          "Read the current boot snapshot: state, operation, provisioning phase, elapsed seconds and whether an expected reboot is pending. ready is true only after live guest health. Poll this while a start is running.",
        scope: :read,
        input: empty_input(),
        output: progress_schema(),
        identity: ["state", "operation", "phase"]
      },
      %{
        id: "macus_runtime_health",
        summary: "Get guest health",
        description:
          "Check live guest health: protocol version, Incus version and API extensions, and KVM availability. Fails with a native unavailable error until Incus is ready.",
        scope: :read,
        input: empty_input(),
        output: object_schema("Native guest health record.")
      },
      %{
        id: "macus_runtime_capabilities",
        summary: "Get runtime capabilities",
        description:
          "Read host support (platform, architecture, Apple virtualization, nested virtualization, virtiofs) and live Incus and workload capabilities. Passive: never changes sharing or restarts the VM.",
        scope: :read,
        input: empty_input(),
        output: object_schema("Native capabilities record.")
      },
      %{
        id: "macus_runtime_config_get",
        summary: "Get runtime configuration",
        description:
          "Read the complete runtime configuration: CPUs, memory, data disk, appliance and seed, nested virtualization, shares and timeouts. Fails with a native not_found error before the runtime is created.",
        scope: :read,
        input: empty_input(),
        output: config_schema()
      },
      %{
        id: "macus_runtime_create",
        summary: "Create the runtime",
        description:
          "Create the VM's writable root and persistent data from a complete configuration. Idempotent when the runtime already exists with the same configuration; a different existing configuration is a native 409 conflict.",
        scope: :write,
        input: config_schema(),
        output: mutation_schema(),
        extra: %{"x-macus-idempotent" => true}
      },
      %{
        id: "macus_runtime_start",
        summary: "Start the runtime",
        description:
          "Boot the VM and wait for live Incus readiness. Idempotent when it is already ready. remaining_seconds (1 to 3600) bounds this boot without changing the saved limit. The reply is awaited up to #{@mutation_wait_seconds} seconds; a longer boot reports status uncertain while it continues, so poll macus_runtime_progress. Another lifecycle operation in progress is a native 409 conflict.",
        scope: :write,
        input:
          object(%{
            "remaining_seconds" => %{
              "type" => "integer",
              "minimum" => 1,
              "maximum" => 3600,
              "description" => "Seconds this boot may take, at most the saved readiness limit."
            }
          }),
        output: mutation_schema(),
        extra: %{"x-macus-idempotent" => true}
      },
      %{
        id: "macus_runtime_stop",
        summary: "Stop the runtime",
        description:
          "Shut the VM down gracefully and wait for it to stop. Never forces shutdown on timeout; use macus_runtime_force_stop for that. The reply is awaited up to #{@mutation_wait_seconds} seconds; a longer shutdown reports status uncertain, so check macus_runtime_status.",
        scope: :write,
        input: empty_input(),
        output: mutation_schema(),
        extra: %{"x-macus-idempotent" => true}
      },
      %{
        id: "macus_runtime_force_stop",
        summary: "Force stop the runtime",
        description:
          "Stop the VM immediately without a graceful shutdown, cancelling an active boot. Running workloads lose unsaved state. Requires confirm set to \"force-stop\".",
        scope: :delete,
        destructive: true,
        input: confirmed_input("force-stop", "Send \"force-stop\" to confirm the forced stop."),
        confirmation: "the text \"force-stop\"",
        output: mutation_schema()
      },
      %{
        id: "macus_runtime_restart",
        summary: "Restart the runtime",
        description:
          "Stop the VM gracefully, then boot it and wait for readiness. The reply is awaited up to #{@mutation_wait_seconds} seconds; a longer restart reports status uncertain, so poll macus_runtime_progress.",
        scope: :write,
        input: empty_input(),
        output: mutation_schema()
      },
      %{
        id: "macus_runtime_config_update",
        summary: "Replace runtime configuration",
        description:
          "Replace the complete runtime configuration. Requires a stopped VM: a running VM is a native 409 conflict, and the VM is never restarted implicitly. The appliance and seed cannot change and the data disk cannot shrink; growing it preserves data. New shares take effect at the next start.",
        scope: :write,
        input: config_schema(),
        output: mutation_schema(),
        extra: %{"x-macus-requires-state" => "stopped"}
      },
      %{
        id: "macus_runtime_delete",
        summary: "Delete the runtime",
        description:
          "Destroy the VM's writable root and persistent data, including all Incus state, workloads and images. Keeps the source appliance, seed and logs. Requires a stopped VM (a running VM is a native 409 conflict) and confirm set to \"delete-runtime\".",
        scope: :delete,
        destructive: true,
        input:
          confirmed_input("delete-runtime", "Send \"delete-runtime\" to confirm the deletion."),
        confirmation: "the text \"delete-runtime\"",
        output: mutation_schema(),
        extra: %{"x-macus-requires-state" => "stopped"}
      }
    ]
  end

  defp operation(op) do
    mutation? = op.output == mutation_schema()

    %{
      "operationId" => op.id,
      "summary" => op.summary,
      "description" => op.description,
      "tags" => ["runtime"],
      "x-tama-scopes" => [Map.fetch!(@scopes, op.scope)],
      "x-tama-destructive" => Map.get(op, :destructive, false),
      "x-tama-bounds" =>
        if(mutation?, do: %{"max_wait_seconds" => @mutation_wait_seconds}, else: %{}),
      "x-tama-identity" =>
        Map.get(op, :identity, if(mutation?, do: ["status", "state"], else: [])),
      "requestBody" => json_body(op.input, true),
      "responses" => %{
        "200" => Map.put(json_body(op.output, false), "description", "Result"),
        "default" => Map.put(json_body(error_schema(), false), "description", "Error")
      }
    }
    |> put_confirmation(op)
    |> Map.merge(Map.get(op, :extra, %{}))
  end

  defp put_confirmation(%{} = operation, %{confirmation: description}),
    do:
      Map.put(operation, "x-tama-confirmation", %{
        "field" => "confirm",
        "description" => description
      })

  defp put_confirmation(operation, _op), do: operation

  defp json_body(schema, true),
    do: %{"required" => true, "content" => %{"application/json" => %{"schema" => schema}}}

  defp json_body(schema, false),
    do: %{"content" => %{"application/json" => %{"schema" => schema}}}

  defp object(properties, required \\ []) do
    %{"type" => "object", "properties" => properties, "additionalProperties" => false}
    |> then(&if(required == [], do: &1, else: Map.put(&1, "required", required)))
  end

  defp empty_input, do: object(%{})

  defp confirmed_input(token, description) do
    object(
      %{"confirm" => %{"type" => "string", "const" => token, "description" => description}},
      ["confirm"]
    )
  end

  defp object_schema(description), do: %{"type" => "object", "description" => description}

  defp nullable(type), do: %{"type" => [type, "null"]}

  defp status_schema do
    %{
      "type" => "object",
      "description" => "Runtime status. The private incus_socket path is omitted.",
      "required" => ["state"],
      "properties" => %{
        "api_version" => %{"type" => "integer"},
        "state" => %{"enum" => @states},
        "last_error" => nullable("string"),
        "uptime_seconds" => %{"type" => "integer", "minimum" => 0}
      }
    }
  end

  defp progress_schema do
    %{
      "type" => "object",
      "required" => ["state", "ready"],
      "properties" => %{
        "api_version" => %{"type" => "integer"},
        "schema_version" => %{"type" => "integer"},
        "state" => %{"enum" => @states},
        "ready" => %{"type" => "boolean"},
        "operation" => nullable("string"),
        "phase" => nullable("string"),
        "elapsed_seconds" => %{"type" => "integer", "minimum" => 0},
        "expected_reboot" => %{"type" => "boolean"},
        "detail" => nullable("string"),
        "last_error" => nullable("string")
      }
    }
  end

  defp mutation_schema do
    object(
      %{
        "status" => %{
          "enum" => ["completed", "uncertain"],
          "description" =>
            "completed when the runtime replied; uncertain when the request may have been accepted but no reply arrived within the wait. It was not resent."
        },
        "state" => %{
          "type" => ["string", "null"],
          "description" => "Runtime state after the operation, when known."
        },
        "runtime" => %{
          "oneOf" => [status_schema(), %{"type" => "null"}],
          "description" => "Runtime status after the operation, when known."
        },
        "wait_error" => %{
          "type" => ["string", "null"],
          "description" => "Why no reply was observed, for an uncertain result."
        }
      },
      ["status", "state", "runtime", "wait_error"]
    )
  end

  defp error_schema do
    object(
      %{
        "error" =>
          object(
            %{
              "code" => %{
                "type" => "string",
                "description" =>
                  "Native runtime code (invalid_request, invalid_configuration, not_found, conflict, unavailable, io, timeout) or a Macus code (unauthorized, forbidden, invalid_input, confirmation_required, unknown_operation, invalid_response, unavailable)."
              },
              "message" => %{"type" => "string", "maxLength" => 1024},
              "http_status" => %{"type" => "integer"},
              "outcome" => %{
                "enum" => ["not_dispatched", "read_only", "unknown"],
                "description" =>
                  "For a transport failure: whether the request reached the runtime. unknown means a mutation may have taken effect."
              }
            },
            ["code", "message"]
          )
      },
      ["error"]
    )
  end

  defp config_schema do
    absolute_path = %{"type" => "string", "pattern" => "^/", "maxLength" => 1024}

    share =
      object(
        %{
          "name" => %{"type" => "string", "pattern" => "^[A-Za-z0-9_-]{1,36}$"},
          "path" => Map.put(absolute_path, "description", "An existing host directory."),
          "read_only" => %{"type" => "boolean", "default" => true}
        },
        ["name", "path"]
      )

    object(
      %{
        "schema_version" => %{"const" => 1},
        "cpu_count" => %{"type" => "integer", "minimum" => 1, "maximum" => 64},
        "memory_mib" => %{"type" => "integer", "minimum" => 512, "maximum" => 262_144},
        "data_disk_gib" => %{"type" => "integer", "minimum" => 1, "maximum" => 16_384},
        "appliance_manifest_path" => absolute_path,
        "seed_path" => %{"type" => ["string", "null"], "pattern" => "^/", "maxLength" => 1024},
        "nested_virtualization" => %{"type" => "boolean"},
        "shares" => %{"type" => "array", "items" => share, "maxItems" => 64},
        "readiness_timeout_seconds" => %{"type" => "integer", "minimum" => 1, "maximum" => 1800},
        "shutdown_timeout_seconds" => %{"type" => "integer", "minimum" => 1, "maximum" => 300}
      },
      [
        "schema_version",
        "cpu_count",
        "memory_mib",
        "data_disk_gib",
        "appliance_manifest_path",
        "nested_virtualization",
        "shares",
        "readiness_timeout_seconds",
        "shutdown_timeout_seconds"
      ]
    )
  end
end
