local Providers = require("avante.providers")
local Config = require("avante.config")
local Utils = require("avante.utils")
local Base = require("avante.llm_tools.base")
local HistoryMessage = require("avante.history_message")

---@class AvanteLLMTool
local M = setmetatable({}, Base)

M.name = "dispatch_agent"

M.get_description = function()
  local provider = Providers[Config.provider]
  if Config.provider:match("copilot") and provider.model and provider.model:match("gpt") then
    return [[Launch a new agent that has access to the following tools: `create`, `attempt_completion`, `bash`, `get_diagnostics`, `glob`, `grep`, `insert`, `ls`, `replace_in_file`, `str_replace`, `undo_edit`, `view`, `write_to_file`. When given a task which may be divided into granular steps with clearly defined scope, use the Agent tool to perform each step.]]
  end

  return [[Launch a new agent that has access to the following tools: `create`, `attempt_completion`, `bash`, `get_diagnostics`, `glob`, `grep`, `insert`, `ls`, `replace_in_file`, `str_replace`, `undo_edit`, `view`, `write_to_file`. When given a task which may be divided into granular steps with clearly defined scope, use the Agent tool to perform each step. For example:

- If you need to perform a task with a clearly defined scope that can be executed independently of the project's full context
- If you have a very large task that would be inefficient to execute sequentially with all other steps
- If you need to parallelize work that would otherwise take too long to complete in series

RULES:
- Do not ask for more information than necessary. Use the tools provided to accomplish the user's request efficiently and effectively. When you've completed your task, you must use the attempt_completion tool to present the result to the user. The user may provide feedback, which you can use to make improvements and try again.
- NEVER end attempt_completion result with a question or request to engage in further conversation! Formulate the end of your result in a way that is final and does not require further input from the user.

OBJECTIVE:
1. Analyze the user's task and set clear, achievable goals to accomplish it. Prioritize these goals in a logical order.
2. Work through these goals sequentially, utilizing available tools one at a time as necessary. Each goal should correspond to a distinct step in your problem-solving process. You will be informed on the work completed and what's remaining as you go.
3. Once you've completed the user's task, you must use the attempt_completion tool to present the result of the task to the user. You may also provide a CLI command to showcase the result of your task; this can be particularly useful for web development tasks, where you can run e.g. \`open index.html\` to show the website you've built.

Usage notes:
1. Launch multiple agents concurrently whenever possible, to maximize performance; to do that, use a single message with multiple tool uses
2. When the agent is done, it will return a single message back to you. The result returned by the agent is not visible to the user. To show the user the result, you should send a text message back to the user with a concise summary of the result.
3. Each agent invocation is stateless. You will not be able to send additional messages to the agent, nor will the agent be able to communicate with you outside of its final report. Therefore, your prompt should contain a highly detailed task description for the agent to perform autonomously and you should specify exactly what information the agent should return back to you in its final and only message to you.
4. The agent's outputs should generally be trusted]]
end

---@type AvanteLLMToolParam
M.param = {
  type = "table",
  fields = {
    {
      name = "prompt",
      description = "The task for the agent to perform",
      type = "string",
    },
  },
  required = { "prompt" },
  usage = {
    prompt = "The task for the agent to perform",
  },
}

---@type AvanteLLMToolReturn[]
M.returns = {
  {
    name = "result",
    description = "The result of the agent",
    type = "string",
  },
  {
    name = "error",
    description = "The error message if the agent fails",
    type = "string",
    optional = true,
  },
}

local function get_available_tools()
  return {
    require("avante.llm_tools.create"),
    require("avante.llm_tools.attempt_completion"),
    require("avante.llm_tools.bash"),
    require("avante.llm_tools.get_diagnostics"),
    require("avante.llm_tools.glob"),
    require("avante.llm_tools.grep"),
    require("avante.llm_tools.insert"),
    require("avante.llm_tools.ls"),
    require("avante.llm_tools.replace_in_file"),
    require("avante.llm_tools.str_replace"),
    require("avante.llm_tools.undo_edit"),
    require("avante.llm_tools.view"),
    require("avante.llm_tools.write_to_file"),
  }
end

---@type AvanteLLMToolFunc<{ prompt: string }>
function M.func(opts, on_log, on_complete, session_ctx)
  local Llm = require("avante.llm")
  if not on_complete then return false, "on_complete not provided" end
  local prompt = opts.prompt
  local tools = get_available_tools()
  local start_time = Utils.get_timestamp()

  if on_log then on_log("prompt: " .. prompt) end

  local system_prompt = ([[You are a helpful assistant with access to various tools.
Your task is to help the user with their request: "${prompt}"
Be thorough and use the tools available to you to find the most relevant information.
When you're done, provide a clear and concise summary of what you found.]]):gsub("${prompt}", prompt)

  local messages = {}
  table.insert(messages, { role = "user", content = "go!" })

  local tool_use_messages = {}

  local total_tokens = 0
  local final_response = ""

  local memory_content = nil
  local history_messages = {}

  local stream_options = {
    ask = true,
    disable_compact_history_messages = true,
    memory = memory_content,
    code_lang = "unknown",
    provider = Providers[Config.provider],
    get_history_messages = function() return history_messages end,
    on_tool_log = session_ctx.on_tool_log,
    on_messages_add = function(msgs)
      msgs = vim.islist(msgs) and msgs or { msgs }
      for _, msg in ipairs(msgs) do
        local content = msg.message.content
        if type(content) == "table" and #content > 0 and content[1].type == "tool_use" then
          tool_use_messages[msg.uuid] = true
        end
      end
      for _, msg in ipairs(msgs) do
        local idx = nil
        for i, m in ipairs(history_messages) do
          if m.uuid == msg.uuid then
            idx = i
            break
          end
        end
        if idx ~= nil then
          history_messages[idx] = msg
        else
          table.insert(history_messages, msg)
        end
      end
      if session_ctx.on_messages_add then session_ctx.on_messages_add(msgs) end
    end,
    session_ctx = session_ctx,
    prompt_opts = {
      system_prompt = system_prompt,
      tools = tools,
      messages = messages,
    },
    on_start = session_ctx.on_start,
    on_chunk = function(chunk)
      if not chunk then return end
      final_response = final_response .. chunk
      total_tokens = total_tokens + (#vim.split(chunk, " ") * 1.3)
    end,
    on_stop = function(stop_opts)
      if stop_opts.error ~= nil then
        local err = string.format("dispatch_agent failed: %s", vim.inspect(stop_opts.error))
        on_complete(err, nil)
        return
      end
      local end_time = Utils.get_timestamp()
      local elapsed_time = Utils.datetime_diff(start_time, end_time)
      local tool_use_count = vim.tbl_count(tool_use_messages)
      local summary = "dispatch_agent Done ("
        .. (tool_use_count <= 1 and "1 tool use" or tool_use_count .. " tool uses")
        .. " · "
        .. math.ceil(total_tokens)
        .. " tokens · "
        .. elapsed_time
        .. "s)"
      if session_ctx.on_messages_add then
        local message = HistoryMessage:new({
          role = "assistant",
          content = "\n\n" .. summary,
        }, {
          just_for_display = true,
        })
        session_ctx.on_messages_add({ message })
      end
      local response = string.format("Final response:\n%s\n\nSummary:\n%s", summary, final_response)
      on_complete(response, nil)
    end,
  }

  local function on_memory_summarize(pending_compaction_history_messages)
    Llm.summarize_memory(memory_content, pending_compaction_history_messages or {}, function(memory)
      if memory then stream_options.memory = memory.content end
      local new_history_messages = {}
      for _, msg in ipairs(history_messages) do
        if
          vim
            .iter(pending_compaction_history_messages)
            :find(function(pending_compaction_msg) return pending_compaction_msg.uuid == msg.uuid end)
        then
          goto continue
        end
        table.insert(new_history_messages, msg)
        ::continue::
      end
      history_messages = new_history_messages
      Llm._stream(stream_options)
    end)
  end

  stream_options.on_memory_summarize = on_memory_summarize

  Llm._stream(stream_options)
end

return M
