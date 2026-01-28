defmodule LeaxerCoreWeb.ChatChannel do
  @moduledoc """
  WebSocket channel for chat communication.

  Handles real-time chat with LLM models using the OpenAI-compatible
  `/v1/chat/completions` endpoint from llama-server with streaming.

  ## Events

  ### Incoming
  - `send_message` - Send a chat message (triggers streaming response)
  - `abort_generation` - Cancel the current generation
  - `load_model` - Preload a model for faster first response
  - `get_llm_server_health` - Get detailed LLM server health info
  - `restart_llm_server` - Restart the llama-server process
  - `start_llm_server` - Start llama-server with an optional model

  ### Outgoing
  - `stream_chunk` - Token-by-token streaming from SSE
  - `generation_complete` - Final response with metadata
  - `generation_error` - Error handling
  - `model_status` - Loading/ready status updates
  - `tool_status` - Web search status updates
  - `llm_server_status` - Server lifecycle updates (restarting, loading, ready, error)
  """
  use LeaxerCoreWeb, :channel
  require Logger

  alias LeaxerCore.Workers.LLMServer
  alias LeaxerCore.Workers.ArtifactGenerator
  alias LeaxerCore.Services.WebBrowse

  @impl true
  def join("chat:main", _payload, socket) do
    Logger.info("[ChatChannel] Client joining chat:main")

    # Subscribe to LLM server status and logs for real-time updates
    Phoenix.PubSub.subscribe(LeaxerCore.PubSub, "llm_server:status")
    Phoenix.PubSub.subscribe(LeaxerCore.PubSub, "llm_server:logs")

    # Send current model status on join (delayed to ensure socket is ready)
    Process.send_after(self(), :send_model_status, 100)

    Logger.info("[ChatChannel] Client joined chat:main successfully")
    {:ok, socket}
  end

  @impl true
  def handle_info(:send_model_status, socket) do
    Logger.debug("[ChatChannel] Sending model status...")

    {status, model} =
      try do
        {LLMServer.status(), LLMServer.current_model()}
      catch
        kind, reason ->
          Logger.warning("[ChatChannel] LLMServer not available: #{kind} #{inspect(reason)}")
          {:idle, nil}
      end

    push(socket, "model_status", %{
      status: to_string(status),
      model: model
    })

    Logger.debug("[ChatChannel] Model status sent: #{status}")
    {:noreply, socket}
  end

  # Handle streaming response task completion
  def handle_info({ref, result}, socket) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    case result do
      {:ok, response} ->
        push(socket, "generation_complete", response)

      {:error, reason} ->
        push(socket, "generation_error", %{error: to_string(reason)})
    end

    socket = assign(socket, :current_task, nil)
    {:noreply, socket}
  end

  # Handle task failure
  def handle_info({:DOWN, ref, :process, _pid, reason}, socket) do
    if socket.assigns[:current_task] == ref do
      push(socket, "generation_error", %{error: "Generation task failed: #{inspect(reason)}"})
      socket = assign(socket, :current_task, nil)
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # Handle push messages from the streaming task
  def handle_info({:push, event, payload}, socket) do
    push(socket, event, payload)
    {:noreply, socket}
  end

  # Handle LLM server status broadcasts from PubSub
  def handle_info({:llm_server_status, status}, socket) do
    push(socket, "llm_server_status", %{status: to_string(status)})
    {:noreply, socket}
  end

  def handle_info({:llm_server_status, status, model_or_error}, socket) do
    payload =
      if status == :error do
        %{status: to_string(status), error: model_or_error}
      else
        %{status: to_string(status), model: model_or_error}
      end

    push(socket, "llm_server_status", payload)
    {:noreply, socket}
  end

  # Handle LLM server log broadcasts from PubSub
  def handle_info({:llm_server_log, line}, socket) do
    push(socket, "llm_server_log", %{line: line, timestamp: System.system_time(:millisecond)})
    {:noreply, socket}
  end

  def handle_info(msg, socket) do
    Logger.debug("[ChatChannel] Unhandled message: #{inspect(msg)}")
    {:noreply, socket}
  end

  @impl true
  def handle_in("send_message", payload, socket) do
    %{
      "messages" => messages,
      "model" => model_path
    } = payload

    settings = Map.get(payload, "settings", %{})
    internet_enabled = Map.get(payload, "internet_enabled", false)
    search_provider = Map.get(payload, "search_provider", "searxng")
    search_max_results = Map.get(payload, "search_max_results", 3)
    thinking_enabled = Map.get(payload, "thinking_enabled", false)
    artifact_enabled = Map.get(payload, "artifact_enabled", false)
    existing_artifact = Map.get(payload, "existing_artifact", nil)

    Logger.info("[ChatChannel] Received send_message with #{length(messages)} messages")

    Logger.info(
      "[ChatChannel] Model: #{model_path}, Internet: #{internet_enabled}, Thinking: #{thinking_enabled}, Artifact: #{artifact_enabled}, Provider: #{search_provider}"
    )

    if existing_artifact,
      do:
        Logger.info("[ChatChannel] Existing artifact: #{String.length(existing_artifact)} chars")

    # Debug: Log each message's content length
    Enum.each(messages, fn msg ->
      role = Map.get(msg, "role", "unknown")
      content = Map.get(msg, "content", "")
      Logger.info("[ChatChannel] Message role=#{role}, content_length=#{String.length(content)}")
      # Log first 200 chars of user messages to verify file content
      if role == "user" do
        Logger.info("[ChatChannel] User content preview: #{String.slice(content, 0, 500)}...")
      end
    end)

    # Ensure model is loaded
    case LLMServer.ensure_model_loaded(model_path) do
      :ok ->
        # Get the endpoint
        endpoint = LLMServer.get_endpoint()

        if endpoint do
          # Prepare messages with tool prompt if internet enabled
          prepared_messages =
            if internet_enabled do
              result = prepend_tool_prompt(messages, thinking_enabled)
              Logger.debug("[ChatChannel] Added tool prompt to messages")
              result
            else
              messages
            end

          # Start streaming task
          socket_pid = self()

          search_opts = %{
            provider: search_provider,
            max_results: search_max_results,
            thinking_enabled: thinking_enabled
          }

          task =
            Task.async(fn ->
              result =
                stream_with_tools(
                  endpoint,
                  prepared_messages,
                  settings,
                  socket_pid,
                  internet_enabled,
                  model_path,
                  search_opts
                )

              # Generate artifact document if enabled
              if artifact_enabled do
                case result do
                  {:ok, %{content: assistant_response} = response_data} ->
                    # Pass both original messages and the assistant's response for complete context
                    # If existing_artifact is provided, refine it instead of creating new
                    # Include references for proper citations in the document
                    references = Map.get(response_data, :references, [])

                    case ArtifactGenerator.generate(
                           messages,
                           assistant_response,
                           socket_pid,
                           existing_artifact,
                           references
                         ) do
                      {:ok, artifact} ->
                        send(
                          socket_pid,
                          {:push, "artifact_status",
                           %{
                             status: "complete",
                             title: artifact.title,
                             content: artifact.content
                           }}
                        )

                      {:error, reason} ->
                        send(
                          socket_pid,
                          {:push, "artifact_status", %{status: "error", error: to_string(reason)}}
                        )
                    end

                  _ ->
                    :ok
                end
              end

              result
            end)

          socket = assign(socket, :current_task, task.ref)
          {:reply, {:ok, %{status: "streaming"}}, socket}
        else
          {:reply, {:error, %{reason: "Server not ready"}}, socket}
        end

      {:error, reason} ->
        Logger.error("[ChatChannel] Failed to load model: #{inspect(reason)}")
        {:reply, {:error, %{reason: to_string(reason)}}, socket}
    end
  end

  def handle_in("abort_generation", _payload, socket) do
    Logger.info("[ChatChannel] Abort requested")

    # Cancel the current task if any
    case socket.assigns[:current_task] do
      ref when is_reference(ref) ->
        # The task will be cleaned up when it terminates
        Task.shutdown(ref, :brutal_kill)
        push(socket, "generation_complete", %{aborted: true})

      _ ->
        :ok
    end

    socket = assign(socket, :current_task, nil)
    {:reply, {:ok, %{status: "aborted"}}, socket}
  end

  def handle_in("load_model", %{"model" => model_path}, socket) do
    Logger.info("[ChatChannel] Preloading model: #{model_path}")

    # Notify that we're loading
    push(socket, "model_status", %{status: "loading", model: model_path})

    # Load model in background
    Task.start(fn ->
      case LLMServer.ensure_model_loaded(model_path) do
        :ok ->
          Phoenix.Channel.broadcast(socket, "model_status", %{status: "ready", model: model_path})

        {:error, reason} ->
          Phoenix.Channel.broadcast(socket, "model_status", %{
            status: "error",
            model: model_path,
            error: to_string(reason)
          })
      end
    end)

    {:reply, {:ok, %{status: "loading"}}, socket}
  end

  def handle_in("get_model_status", _payload, socket) do
    status = LLMServer.status()
    model = LLMServer.current_model()

    {:reply, {:ok, %{status: to_string(status), model: model}}, socket}
  end

  def handle_in("get_llm_server_health", _payload, socket) do
    Logger.debug("[ChatChannel] Getting LLM server health")

    health =
      try do
        LLMServer.get_health()
      catch
        kind, reason ->
          Logger.warning(
            "[ChatChannel] LLMServer health check failed: #{kind} #{inspect(reason)}"
          )

          %{
            status: :stopped,
            model: nil,
            server_port: 8080,
            os_pid: nil,
            binary_available: LLMServer.available?()
          }
      end

    {:reply,
     {:ok,
      %{
        status: to_string(health.status),
        model: health.model,
        server_port: health.server_port,
        os_pid: health.os_pid,
        binary_available: health.binary_available
      }}, socket}
  end

  def handle_in("restart_llm_server", _payload, socket) do
    Logger.info("[ChatChannel] Restart LLM server requested")

    # Notify client that server is restarting
    push(socket, "llm_server_status", %{status: "restarting"})

    case LLMServer.restart() do
      :ok ->
        Logger.info("[ChatChannel] LLM server restarted successfully")
        push(socket, "llm_server_status", %{status: "idle"})
        {:reply, {:ok, %{status: "restarted"}}, socket}

      {:error, reason} ->
        Logger.error("[ChatChannel] LLM server restart failed: #{inspect(reason)}")
        push(socket, "llm_server_status", %{status: "error", error: to_string(reason)})
        {:reply, {:error, %{reason: to_string(reason)}}, socket}
    end
  end

  def handle_in("start_llm_server", payload, socket) do
    model_path = Map.get(payload, "model")

    Logger.info(
      "[ChatChannel] Start LLM server requested with model: #{model_path || "none specified"}"
    )

    if model_path do
      # Notify client that server is starting
      push(socket, "llm_server_status", %{status: "loading", model: model_path})

      # Load model in background task
      Task.start(fn ->
        case LLMServer.ensure_model_loaded(model_path) do
          :ok ->
            Logger.info("[ChatChannel] LLM server started with model: #{model_path}")

            Phoenix.Channel.broadcast(socket, "llm_server_status", %{
              status: "ready",
              model: model_path
            })

          {:error, reason} ->
            Logger.error("[ChatChannel] LLM server start failed: #{inspect(reason)}")

            Phoenix.Channel.broadcast(socket, "llm_server_status", %{
              status: "error",
              error: to_string(reason)
            })
        end
      end)

      {:reply, {:ok, %{status: "loading"}}, socket}
    else
      # No model specified - just check if binary is available
      if LLMServer.available?() do
        {:reply, {:ok, %{status: "idle", binary_available: true}}, socket}
      else
        {:reply, {:error, %{reason: "llama-server binary not found"}}, socket}
      end
    end
  end

  # Private Functions

  defp stream_chat_completion(endpoint, messages, settings, socket_pid) do
    url = "#{endpoint}/v1/chat/completions"

    # Build request body
    body = %{
      "messages" => messages,
      "stream" => true,
      "temperature" => Map.get(settings, "temperature", 0.7),
      "max_tokens" => Map.get(settings, "max_tokens", 2048),
      "top_p" => Map.get(settings, "top_p", 0.9),
      "top_k" => Map.get(settings, "top_k", 40)
    }

    Logger.info("[ChatChannel] Sending streaming request to #{url}")
    Logger.debug("[ChatChannel] Request body: #{inspect(body)}")

    # Use Finch for streaming SSE response
    request = Finch.build(:post, url, [{"content-type", "application/json"}], Jason.encode!(body))

    start_time = System.monotonic_time(:millisecond)

    # State: {accumulated_content, buffer, http_status, error_body}
    result =
      Finch.stream(request, LeaxerCore.Finch, {"", "", nil, ""}, fn
        {:status, status}, {acc, buffer, _old_status, err_body} ->
          Logger.info("[ChatChannel] HTTP status: #{status}")
          {acc, buffer, status, err_body}

        {:headers, headers}, {acc, buffer, status, err_body} ->
          Logger.debug("[ChatChannel] Headers: #{inspect(headers)}")
          {acc, buffer, status, err_body}

        {:data, data}, {acc, buffer, status, err_body} ->
          if status != 200 do
            # Accumulate error body for non-200 responses
            {acc, buffer, status, err_body <> data}
          else
            # Combine buffer with new data for handling partial lines
            combined = buffer <> data
            lines = String.split(combined, "\n")

            # Process all complete lines, keep last (possibly incomplete) line as new buffer
            {complete_lines, new_buffer} =
              case List.last(lines) do
                "" -> {Enum.drop(lines, -1), ""}
                partial -> {Enum.drop(lines, -1), partial}
              end

            # Process each SSE line
            new_acc =
              Enum.reduce(complete_lines, acc, fn line, content_acc ->
                process_sse_line(line, content_acc, socket_pid)
              end)

            {new_acc, new_buffer, status, err_body}
          end
      end)

    elapsed = System.monotonic_time(:millisecond) - start_time

    case result do
      {:ok, {final_content, _buffer, 200, _}} ->
        Logger.info(
          "[ChatChannel] Streaming complete, #{String.length(final_content)} chars in #{elapsed}ms"
        )

        {:ok, %{content: final_content, elapsed_ms: elapsed}}

      {:ok, {_, _, status, err_body}} when status != 200 ->
        Logger.error("[ChatChannel] HTTP #{status}: #{err_body}")
        {:error, "HTTP #{status}: #{String.slice(err_body, 0, 200)}"}

      {:ok, {_final_content, _buffer, nil, _}} ->
        # No status received - connection issue
        Logger.error("[ChatChannel] No HTTP status received")
        {:error, "Connection failed - no response from server"}

      {:error, reason} ->
        Logger.error("[ChatChannel] Streaming failed: #{inspect(reason)}")
        {:error, inspect(reason)}
    end
  end

  defp process_sse_line(line, content_acc, socket_pid) do
    line = String.trim(line)

    cond do
      # Empty line - SSE event separator
      line == "" ->
        content_acc

      # Done marker
      line == "data: [DONE]" ->
        content_acc

      # Data line
      String.starts_with?(line, "data: ") ->
        json_str = String.trim_leading(line, "data: ")

        case Jason.decode(json_str) do
          {:ok, %{"choices" => [%{"delta" => delta} | _]}} ->
            # content can be nil in the JSON, not just missing
            content = Map.get(delta, "content") || ""

            if content != "" do
              # Send chunk to client
              send(socket_pid, {:push, "stream_chunk", %{content: content}})
              (content_acc || "") <> content
            else
              content_acc
            end

          {:ok, %{"choices" => [%{"finish_reason" => reason} | _]}} when not is_nil(reason) ->
            # Generation finished
            content_acc

          {:error, _} ->
            Logger.warning("[ChatChannel] Failed to parse SSE JSON: #{json_str}")
            content_acc

          _ ->
            content_acc
        end

      # Comment or other line
      true ->
        content_acc
    end
  end

  # Prepend tool system prompt to enable web search
  defp prepend_tool_prompt(messages, thinking_enabled) do
    tool_prompt = WebBrowse.tool_system_prompt()

    # Add thinking instructions when thinking is enabled
    # This ensures thinking happens even if no tool call is detected
    full_prompt =
      if thinking_enabled do
        """
        #{tool_prompt}

        IMPORTANT: When answering questions, you MUST first write your reasoning inside <think></think> tags, then provide your final answer outside the tags.

        Format:
        <think>
        [Your step-by-step reasoning and analysis here]
        </think>

        [Your final response here]
        """
      else
        tool_prompt
      end

    case messages do
      [%{"role" => "system", "content" => system_content} | rest] ->
        [%{"role" => "system", "content" => system_content <> "\n\n" <> full_prompt} | rest]

      _ ->
        [%{"role" => "system", "content" => full_prompt} | messages]
    end
  end

  # Strip tool prompt from system message (for post-search response)
  defp strip_tool_prompt(messages) do
    tool_prompt = WebBrowse.tool_system_prompt()

    case messages do
      [%{"role" => "system", "content" => system_content} = system_msg | rest] ->
        # Remove the tool prompt that was appended
        clean_content = String.replace(system_content, "\n\n" <> tool_prompt, "")
        [%{system_msg | "content" => clean_content} | rest]

      _ ->
        messages
    end
  end

  # Stream with tool calling support
  defp stream_with_tools(
         endpoint,
         messages,
         settings,
         socket_pid,
         internet_enabled,
         _model_path,
         search_opts
       ) do
    if internet_enabled do
      # Stream the initial response - user sees text as it comes
      case stream_chat_completion(endpoint, messages, settings, socket_pid) do
        {:ok, %{content: content}} ->
          # Check if the streamed content contains a tool call
          Logger.debug(
            "[ChatChannel] Checking for tool call in content (#{String.length(content || "")} chars): #{String.slice(content || "", 0, 200)}"
          )

          case WebBrowse.parse_tool_call(content) do
            {:tool_call, :web_search, %{query: query}} ->
              provider = Map.get(search_opts, :provider, "searxng")
              max_results = Map.get(search_opts, :max_results, 3)

              Logger.info(
                "[ChatChannel] Tool call detected in stream: web_search(#{query}) using #{provider}"
              )

              # Notify client that we're searching
              send(
                socket_pid,
                {:push, "tool_status", %{status: "searching", query: query, provider: provider}}
              )

              # Execute web search
              case WebBrowse.browse(query, provider: provider, max_results: max_results) do
                {:ok, search_results, references} ->
                  Logger.info(
                    "[ChatChannel] Web search complete, results length: #{String.length(search_results)}, refs: #{length(references)}"
                  )

                  # Notify client that search is complete with references for display
                  send(
                    socket_pid,
                    {:push, "tool_status",
                     %{status: "complete", query: query, references: references}}
                  )

                  # Build response instruction based on whether thinking is enabled
                  thinking_enabled = Map.get(search_opts, :thinking_enabled, false)

                  response_instruction =
                    if thinking_enabled do
                      """
                      Here are the search results for "#{query}":

                      #{search_results}

                      INSTRUCTIONS: First, write your analysis inside <think> and </think> tags. Then write your response outside the tags.

                      Your response MUST follow this exact format:
                      <think>
                      [Your step-by-step analysis of the search results here]
                      </think>

                      [Your final response to the user here, citing sources with [1], [2], etc.]
                      """
                    else
                      "Here are the search results for \"#{query}\":\n\n#{search_results}\n\nBased on these search results, please answer the question. Cite sources using [1], [2], etc."
                    end

                  # Build new messages with search results
                  # Strip tool prompt from system message to avoid conflicting instructions
                  clean_messages = strip_tool_prompt(messages)

                  # Include a brief assistant acknowledgment to maintain proper message alternation
                  new_messages =
                    clean_messages ++
                      [
                        %{
                          "role" => "assistant",
                          "content" => "I'll search the web for that information."
                        },
                        %{"role" => "user", "content" => response_instruction}
                      ]

                  # Stream the final response to the user
                  Logger.info(
                    "[ChatChannel] Starting to stream final response with search results, thinking: #{thinking_enabled}"
                  )

                  Logger.debug(
                    "[ChatChannel] Post-search messages: #{length(new_messages)} messages, last user msg length: #{String.length(response_instruction)}"
                  )

                  result =
                    if thinking_enabled do
                      # Two-pass approach: first thinking, then response
                      # Inject <think> tag at the start
                      send(socket_pid, {:push, "stream_chunk", %{content: "<think>\n"}})

                      # First pass: Get analysis of search results
                      analysis_messages =
                        clean_messages ++
                          [
                            %{
                              "role" => "assistant",
                              "content" => "I'll search the web for that information."
                            },
                            %{
                              "role" => "user",
                              "content" =>
                                "Here are the search results for \"#{query}\":\n\n#{search_results}\n\nAnalyze these search results step by step. What are the key points from each source? How do they relate to the question?"
                            }
                          ]

                      case stream_chat_completion(
                             endpoint,
                             analysis_messages,
                             settings,
                             socket_pid
                           ) do
                        {:ok, %{content: thinking_content}} ->
                          # Close thinking tag and add separator
                          send(socket_pid, {:push, "stream_chunk", %{content: "\n</think>\n\n"}})

                          # Second pass: Generate response based on analysis
                          response_messages =
                            clean_messages ++
                              [
                                %{
                                  "role" => "assistant",
                                  "content" => "I'll search the web for that information."
                                },
                                %{
                                  "role" => "user",
                                  "content" =>
                                    "Search results:\n#{search_results}\n\nYour analysis:\n#{thinking_content}\n\nNow write a clear, helpful response to the original question. Cite sources using [1], [2], etc."
                                }
                              ]

                          stream_chat_completion(
                            endpoint,
                            response_messages,
                            settings,
                            socket_pid
                          )

                        {:error, reason} ->
                          # Close thinking tag even on error
                          send(socket_pid, {:push, "stream_chunk", %{content: "\n</think>\n\n"}})
                          {:error, reason}
                      end
                    else
                      # No thinking, just stream response directly
                      stream_chat_completion(endpoint, new_messages, settings, socket_pid)
                    end

                  # Add references to the result for artifact generation
                  case result do
                    {:ok, response} -> {:ok, Map.put(response, :references, references)}
                    error -> error
                  end
              end

            :no_tool_call ->
              # No tool call - content was already streamed (with thinking if enabled via prompt)
              Logger.debug("[ChatChannel] No tool call detected in response")
              {:ok, %{content: content}}
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      # Internet not enabled, just stream normally
      stream_chat_completion(endpoint, messages, settings, socket_pid)
    end
  end
end
