local curl = require("plenary.curl")
local Utils = require("avante.utils")
local Path = require("plenary.path")
local Config = require("avante.config")
local M = {}

---@param rel_path string
---@return string
local function get_abs_path(rel_path)
  local project_root = Utils.get_project_root()
  return Path:new(project_root):joinpath(rel_path):absolute()
end

function M.confirm(msg)
  local ok = vim.fn.confirm(msg, "&Yes\n&No", 2)
  return ok == 1
end

---@param abs_path string
---@return boolean
local function has_permission_to_access(abs_path)
  if not Path:new(abs_path):is_absolute() then return false end
  local project_root = Utils.get_project_root()
  if abs_path:sub(1, #project_root) ~= project_root then return false end
  local gitignore_path = project_root .. "/.gitignore"
  local gitignore_patterns, gitignore_negate_patterns = Utils.parse_gitignore(gitignore_path)
  return not Utils.is_ignored(abs_path, gitignore_patterns, gitignore_negate_patterns)
end

---@param opts { rel_path: string, depth?: integer }
---@return string files
---@return string|nil error
function M.list_files(opts)
  local abs_path = get_abs_path(opts.rel_path)
  if not has_permission_to_access(abs_path) then return "", "No permission to access path: " .. abs_path end
  local files = Utils.scan_directory_respect_gitignore({
    directory = abs_path,
    add_dirs = true,
    depth = opts.depth,
  })
  local result = ""
  for _, file in ipairs(files) do
    local uniform_path = Utils.uniform_path(file)
    result = result .. uniform_path .. "\n"
  end
  result = result:gsub("\n$", "")
  return result, nil
end

---@param opts { rel_path: string, keyword: string }
---@return string files
---@return string|nil error
function M.search_files(opts)
  local abs_path = get_abs_path(opts.rel_path)
  if not has_permission_to_access(abs_path) then return "", "No permission to access path: " .. abs_path end
  local files = Utils.scan_directory_respect_gitignore({
    directory = abs_path,
  })
  local result = ""
  for _, file in ipairs(files) do
    if file:find(opts.keyword) then result = result .. file .. "\n" end
  end
  if result == "" then
    result = "No files found. Call `create_file` instead if the file needs to be created."
  else
    result = result:gsub("\n$", "")
  end
  return result, nil
end

---@param opts { rel_path: string, keyword: string }
---@return string result
---@return string|nil error
function M.search(opts)
  local abs_path = get_abs_path(opts.rel_path)
  if not has_permission_to_access(abs_path) then return "", "No permission to access path: " .. abs_path end
  if not Path:new(abs_path):exists() then return "", "No such file or directory: " .. abs_path end

  ---check if any search cmd is available
  local search_cmd = vim.fn.exepath("rg")
  if search_cmd == "" then search_cmd = vim.fn.exepath("ag") end
  if search_cmd == "" then search_cmd = vim.fn.exepath("ack") end
  if search_cmd == "" then search_cmd = vim.fn.exepath("grep") end
  if search_cmd == "" then return "", "No search command found" end

  ---execute the search command
  local cmd = ""
  if search_cmd:find("rg") then
    cmd = string.format("%s --files-with-matches --no-ignore-vcs --ignore-case --hidden --glob '!.git'", search_cmd)
    cmd = string.format("%s '%s' %s", cmd, opts.keyword, abs_path)
  elseif search_cmd:find("ag") then
    cmd = string.format("%s '%s' --nocolor --nogroup --hidden --ignore .git %s", search_cmd, opts.keyword, abs_path)
  elseif search_cmd:find("ack") then
    cmd = string.format("%s --nocolor --nogroup --hidden --ignore-dir .git", search_cmd)
    cmd = string.format("%s '%s' %s", cmd, opts.keyword, abs_path)
  elseif search_cmd:find("grep") then
    cmd = string.format("%s -riH --exclude-dir=.git %s %s", search_cmd, opts.keyword, abs_path)
  end

  Utils.debug("cmd", cmd)
  local result = vim.fn.system(cmd)

  return result or "", nil
end

---@param opts { rel_path: string }
---@return string definitions
---@return string|nil error
function M.read_file_toplevel_symbols(opts)
  local RepoMap = require("avante.repo_map")
  local abs_path = get_abs_path(opts.rel_path)
  if not has_permission_to_access(abs_path) then return "", "No permission to access path: " .. abs_path end
  local filetype = RepoMap.get_ts_lang(abs_path)
  local repo_map_lib = RepoMap._init_repo_map_lib()
  if not repo_map_lib then return "", "Failed to load avante_repo_map" end
  local definitions = filetype
      and repo_map_lib.stringify_definitions(filetype, Utils.file.read_content(abs_path) or "")
    or ""
  return definitions, nil
end

---@param opts { rel_path: string }
---@return string content
---@return string|nil error
function M.read_file(opts)
  local abs_path = get_abs_path(opts.rel_path)
  if not has_permission_to_access(abs_path) then return "", "No permission to access path: " .. abs_path end
  local file = io.open(abs_path, "r")
  if not file then return "", "file not found: " .. abs_path end
  local content = file:read("*a")
  file:close()
  return content, nil
end

---@param opts { rel_path: string }
---@return boolean success
---@return string|nil error
function M.create_file(opts)
  local abs_path = get_abs_path(opts.rel_path)
  if not has_permission_to_access(abs_path) then return false, "No permission to access path: " .. abs_path end
  ---create directory if it doesn't exist
  local dir = Path:new(abs_path):parent()
  if not dir:exists() then dir:mkdir({ parents = true }) end
  ---create file if it doesn't exist
  if not dir:joinpath(opts.rel_path):exists() then
    local file = io.open(abs_path, "w")
    if not file then return false, "file not found: " .. abs_path end
    file:close()
  end

  return true, nil
end

---@param opts { rel_path: string, new_rel_path: string }
---@return boolean success
---@return string|nil error
function M.rename_file(opts)
  local abs_path = get_abs_path(opts.rel_path)
  if not has_permission_to_access(abs_path) then return false, "No permission to access path: " .. abs_path end
  if not Path:new(abs_path):exists() then return false, "File not found: " .. abs_path end
  if not Path:new(abs_path):is_file() then return false, "Path is not a file: " .. abs_path end
  local new_abs_path = get_abs_path(opts.new_rel_path)
  if not has_permission_to_access(new_abs_path) then return false, "No permission to access path: " .. new_abs_path end
  if Path:new(new_abs_path):exists() then return false, "File already exists: " .. new_abs_path end
  if not M.confirm("Are you sure you want to rename the file: " .. abs_path .. " to: " .. new_abs_path) then
    return false, "User canceled"
  end
  os.rename(abs_path, new_abs_path)
  return true, nil
end

---@param opts { rel_path: string, new_rel_path: string }
---@return boolean success
---@return string|nil error
function M.copy_file(opts)
  local abs_path = get_abs_path(opts.rel_path)
  if not has_permission_to_access(abs_path) then return false, "No permission to access path: " .. abs_path end
  if not Path:new(abs_path):exists() then return false, "File not found: " .. abs_path end
  if not Path:new(abs_path):is_file() then return false, "Path is not a file: " .. abs_path end
  local new_abs_path = get_abs_path(opts.new_rel_path)
  if not has_permission_to_access(new_abs_path) then return false, "No permission to access path: " .. new_abs_path end
  if Path:new(new_abs_path):exists() then return false, "File already exists: " .. new_abs_path end
  Path:new(new_abs_path):write(Path:new(abs_path):read())
  return true, nil
end

---@param opts { rel_path: string }
---@return boolean success
---@return string|nil error
function M.delete_file(opts)
  local abs_path = get_abs_path(opts.rel_path)
  if not has_permission_to_access(abs_path) then return false, "No permission to access path: " .. abs_path end
  if not Path:new(abs_path):exists() then return false, "File not found: " .. abs_path end
  if not Path:new(abs_path):is_file() then return false, "Path is not a file: " .. abs_path end
  if not M.confirm("Are you sure you want to delete the file: " .. abs_path) then return false, "User canceled" end
  os.remove(abs_path)
  return true, nil
end

---@param opts { rel_path: string }
---@return boolean success
---@return string|nil error
function M.create_dir(opts)
  local abs_path = get_abs_path(opts.rel_path)
  if not has_permission_to_access(abs_path) then return false, "No permission to access path: " .. abs_path end
  if Path:new(abs_path):exists() then return false, "Directory already exists: " .. abs_path end
  Path:new(abs_path):mkdir({ parents = true })
  return true, nil
end

---@param opts { rel_path: string, new_rel_path: string }
---@return boolean success
---@return string|nil error
function M.rename_dir(opts)
  local abs_path = get_abs_path(opts.rel_path)
  if not has_permission_to_access(abs_path) then return false, "No permission to access path: " .. abs_path end
  if not Path:new(abs_path):exists() then return false, "Directory not found: " .. abs_path end
  if not Path:new(abs_path):is_dir() then return false, "Path is not a directory: " .. abs_path end
  local new_abs_path = get_abs_path(opts.new_rel_path)
  if not has_permission_to_access(new_abs_path) then return false, "No permission to access path: " .. new_abs_path end
  if Path:new(new_abs_path):exists() then return false, "Directory already exists: " .. new_abs_path end
  if not M.confirm("Are you sure you want to rename directory " .. abs_path .. " to " .. new_abs_path .. "?") then
    return false, "User canceled"
  end
  os.rename(abs_path, new_abs_path)
  return true, nil
end

---@param opts { rel_path: string }
---@return boolean success
---@return string|nil error
function M.delete_dir(opts)
  local abs_path = get_abs_path(opts.rel_path)
  if not has_permission_to_access(abs_path) then return false, "No permission to access path: " .. abs_path end
  if not Path:new(abs_path):exists() then return false, "Directory not found: " .. abs_path end
  if not Path:new(abs_path):is_dir() then return false, "Path is not a directory: " .. abs_path end
  if not M.confirm("Are you sure you want to delete the directory: " .. abs_path) then
    return false, "User canceled"
  end
  os.remove(abs_path)
  return true, nil
end

---@param opts { rel_path: string, command: string }
---@return string|boolean result
---@return string|nil error
function M.run_command(opts)
  local abs_path = get_abs_path(opts.rel_path)
  if not has_permission_to_access(abs_path) then return false, "No permission to access path: " .. abs_path end
  if not Path:new(abs_path):exists() then return false, "Path not found: " .. abs_path end
  if
    not M.confirm("Are you sure you want to run the command: `" .. opts.command .. "` in the directory: " .. abs_path)
  then
    return false, "User canceled"
  end
  ---change cwd to abs_path
  local old_cwd = vim.fn.getcwd()
  vim.fn.chdir(abs_path)
  local res = Utils.shell_run(opts.command)
  vim.fn.chdir(old_cwd)
  if res.code ~= 0 then
    if res.stdout then return false, "Error: " .. res.stdout .. "; Error code: " .. tostring(res.code) end
    return false, "Error code: " .. tostring(res.code)
  end
  return res.stdout, nil
end

---@param opts { query: string }
---@return string|nil result
---@return string|nil error
function M.web_search(opts)
  local search_engine = Config.web_search_engine
  if search_engine.provider == "tavily" then
    if search_engine.api_key_name == "" then return nil, "No API key provided" end
    local api_key = os.getenv(search_engine.api_key_name)
    if api_key == nil or api_key == "" then
      return nil, "Environment variable " .. search_engine.api_key_name .. " is not set"
    end
    local resp = curl.post("https://api.tavily.com/search", {
      headers = {
        ["Content-Type"] = "application/json",
        ["Authorization"] = "Bearer " .. api_key,
      },
      body = vim.json.encode(vim.tbl_deep_extend("force", {
        query = opts.query,
      }, search_engine.provider_opts)),
    })
    if resp.status ~= 200 then return nil, "Error: " .. resp.body end
    local jsn = vim.json.decode(resp.body)
    return jsn.anwser, nil
  end
end

---@class AvanteLLMTool
---@field name string
---@field description string
---@field param AvanteLLMToolParam
---@field returns AvanteLLMToolReturn[]

---@class AvanteLLMToolParam
---@field type string
---@field fields AvanteLLMToolParamField[]

---@class AvanteLLMToolParamField
---@field name string
---@field description string
---@field type string
---@field optional? boolean

---@class AvanteLLMToolReturn
---@field name string
---@field description string
---@field type string
---@field optional? boolean

---@type AvanteLLMTool[]
M.tools = {
  {
    name = "list_files",
    description = "List files in a directory",
    param = {
      type = "table",
      fields = {
        {
          name = "rel_path",
          description = "Relative path to the directory",
          type = "string",
        },
        {
          name = "depth",
          description = "Depth of the directory",
          type = "integer",
          optional = true,
        },
      },
    },
    returns = {
      {
        name = "files",
        description = "List of files in the directory",
        type = "string[]",
      },
      {
        name = "error",
        description = "Error message if the directory was not listed successfully",
        type = "string",
        optional = true,
      },
    },
  },
  {
    name = "search_files",
    description = "Search for files in a directory",
    param = {
      type = "table",
      fields = {
        {
          name = "rel_path",
          description = "Relative path to the directory",
          type = "string",
        },
        {
          name = "keyword",
          description = "Keyword to search for",
          type = "string",
        },
      },
    },
    returns = {
      {
        name = "files",
        description = "List of files that match the keyword",
        type = "string",
      },
      {
        name = "error",
        description = "Error message if the directory was not searched successfully",
        type = "string",
        optional = true,
      },
    },
  },
  {
    name = "search",
    description = "Search for a keyword in a directory",
    param = {
      type = "table",
      fields = {
        {
          name = "rel_path",
          description = "Relative path to the directory",
          type = "string",
        },
        {
          name = "keyword",
          description = "Keyword to search for",
          type = "string",
        },
      },
    },
    returns = {
      {
        name = "files",
        description = "List of files that match the keyword",
        type = "string",
      },
      {
        name = "error",
        description = "Error message if the directory was not searched successfully",
        type = "string",
        optional = true,
      },
    },
  },
  {
    name = "read_file_toplevel_symbols",
    description = "Read the top-level symbols of a file",
    param = {
      type = "table",
      fields = {
        {
          name = "rel_path",
          description = "Relative path to the file",
          type = "string",
        },
      },
    },
    returns = {
      {
        name = "definitions",
        description = "Top-level symbols of the file",
        type = "string",
      },
      {
        name = "error",
        description = "Error message if the file was not read successfully",
        type = "string",
        optional = true,
      },
    },
  },
  {
    name = "read_file",
    description = "Read the contents of a file",
    param = {
      type = "table",
      fields = {
        {
          name = "rel_path",
          description = "Relative path to the file",
          type = "string",
        },
      },
    },
    returns = {
      {
        name = "content",
        description = "Contents of the file",
        type = "string",
      },
      {
        name = "error",
        description = "Error message if the file was not read successfully",
        type = "string",
        optional = true,
      },
    },
  },
  {
    name = "create_file",
    description = "Create a new file",
    param = {
      type = "table",
      fields = {
        {
          name = "rel_path",
          description = "Relative path to the file",
          type = "string",
        },
      },
    },
    returns = {
      {
        name = "success",
        description = "True if the file was created successfully, false otherwise",
        type = "boolean",
      },
      {
        name = "error",
        description = "Error message if the file was not created successfully",
        type = "string",
        optional = true,
      },
    },
  },
  {
    name = "rename_file",
    description = "Rename a file",
    param = {
      type = "table",
      fields = {
        {
          name = "rel_path",
          description = "Relative path to the file",
          type = "string",
        },
        {
          name = "new_rel_path",
          description = "New relative path for the file",
          type = "string",
        },
      },
    },
    returns = {
      {
        name = "success",
        description = "True if the file was renamed successfully, false otherwise",
        type = "boolean",
      },
      {
        name = "error",
        description = "Error message if the file was not renamed successfully",
        type = "string",
        optional = true,
      },
    },
  },
  {
    name = "delete_file",
    description = "Delete a file",
    param = {
      type = "table",
      fields = {
        {
          name = "rel_path",
          description = "Relative path to the file",
          type = "string",
        },
      },
    },
    returns = {
      {
        name = "success",
        description = "True if the file was deleted successfully, false otherwise",
        type = "boolean",
      },
      {
        name = "error",
        description = "Error message if the file was not deleted successfully",
        type = "string",
        optional = true,
      },
    },
  },
  {
    name = "create_dir",
    description = "Create a new directory",
    param = {
      type = "table",
      fields = {
        {
          name = "rel_path",
          description = "Relative path to the directory",
          type = "string",
        },
      },
    },
    returns = {
      {
        name = "success",
        description = "True if the directory was created successfully, false otherwise",
        type = "boolean",
      },
      {
        name = "error",
        description = "Error message if the directory was not created successfully",
        type = "string",
        optional = true,
      },
    },
  },
  {
    name = "rename_dir",
    description = "Rename a directory",
    param = {
      type = "table",
      fields = {
        {
          name = "rel_path",
          description = "Relative path to the directory",
          type = "string",
        },
        {
          name = "new_rel_path",
          description = "New relative path for the directory",
          type = "string",
        },
      },
    },
    returns = {
      {
        name = "success",
        description = "True if the directory was renamed successfully, false otherwise",
        type = "boolean",
      },
      {
        name = "error",
        description = "Error message if the directory was not renamed successfully",
        type = "string",
        optional = true,
      },
    },
  },
  {
    name = "delete_dir",
    description = "Delete a directory",
    param = {
      type = "table",
      fields = {
        {
          name = "rel_path",
          description = "Relative path to the directory",
          type = "string",
        },
      },
    },
    returns = {
      {
        name = "success",
        description = "True if the directory was deleted successfully, false otherwise",
        type = "boolean",
      },
      {
        name = "error",
        description = "Error message if the directory was not deleted successfully",
        type = "string",
        optional = true,
      },
    },
  },
  {
    name = "run_command",
    description = "Run a command in a directory",
    param = {
      type = "table",
      fields = {
        {
          name = "rel_path",
          description = "Relative path to the directory",
          type = "string",
        },
        {
          name = "command",
          description = "Command to run",
          type = "string",
        },
      },
    },
    returns = {
      {
        name = "stdout",
        description = "Output of the command",
        type = "string",
      },
      {
        name = "error",
        description = "Error message if the command was not run successfully",
        type = "string",
        optional = true,
      },
    },
  },
  {
    name = "web_search",
    description = "Search the web",
    param = {
      type = "table",
      fields = {
        {
          name = "query",
          description = "Query to search",
          type = "string",
        },
      },
    },
    returns = {
      {
        name = "result",
        description = "Result of the search",
        type = "string",
      },
      {
        name = "error",
        description = "Error message if the search was not successful",
        type = "string",
        optional = true,
      },
    },
  },
}

---@param tool_use AvanteLLMToolUse
---@return string | nil result
---@return string | nil error
function M.process_tool_use(tool_use)
  Utils.debug("use tool", tool_use.name, tool_use.input_json)
  local tool = vim.iter(M.tools):find(function(tool) return tool.name == tool_use.name end)
  if tool == nil then return end
  local input_json = vim.json.decode(tool_use.input_json)
  local func = M[tool.name]
  local result, error = func(input_json)
  -- Utils.debug("result", result)
  -- Utils.debug("error", error)
  if result ~= nil and type(result) ~= "string" then result = vim.json.encode(result) end
  return result, error
end

return M
