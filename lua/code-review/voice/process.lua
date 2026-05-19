local redact = require("code-review.redact")

local M = {}

local uv = vim.uv or vim.loop

local function json_decode(text)
  local ok, decoded = pcall(vim.json.decode, text)
  if ok then
    return decoded
  end
  return nil
end

local function consume_json_lines(buffer, chunk, on_line)
  buffer.pending = (buffer.pending or "") .. chunk
  while true do
    local start_pos, end_pos = buffer.pending:find("\r?\n")
    if not start_pos then
      break
    end
    local line = buffer.pending:sub(1, start_pos - 1)
    buffer.pending = buffer.pending:sub(end_pos + 1)
    if line ~= "" then
      on_line(line)
    end
  end
end

function M.record(opts)
  local stdout = uv.new_pipe(false)
  local stderr = uv.new_pipe(false)
  local stdin = uv.new_pipe(false)
  local stdout_buffer = { pending = "" }
  local stderr_text = {}
  local final = nil
  local handle
  handle = uv.spawn(opts.node_cmd, {
    args = {
      opts.helper_path,
      "record",
      "--out",
      opts.out,
      "--max-ms",
      tostring(opts.max_ms),
      "--min-duration-ms",
      tostring(opts.min_duration_ms),
      "--jsonl",
    },
    stdio = { stdin, stdout, stderr },
  }, function(code)
    stdout:read_stop()
    stderr:read_stop()
    stdout:close()
    stderr:close()
    stdin:close()
    handle:close()
    vim.schedule(function()
      if stdout_buffer.pending ~= "" then
        local decoded = json_decode(stdout_buffer.pending)
        if decoded then
          final = decoded
        end
      end
      opts.on_exit(code, final, redact.text(table.concat(stderr_text)))
    end)
  end)
  if not handle then
    return nil, "failed to spawn voice helper"
  end
  stdout:read_start(function(_, chunk)
    if not chunk then
      return
    end
    consume_json_lines(stdout_buffer, chunk, function(line)
      local decoded = json_decode(line)
      if decoded then
        final = decoded
        if opts.on_event then
          vim.schedule(function()
            opts.on_event(decoded)
          end)
        end
      end
    end)
  end)
  stderr:read_start(function(_, chunk)
    if chunk then
      stderr_text[#stderr_text + 1] = chunk
    end
  end)
  return {
    stop = function()
      if stdin and not stdin:is_closing() then
        stdin:write("stop\n")
      end
    end,
    discard = function()
      if stdin and not stdin:is_closing() then
        stdin:write("discard\n")
      end
    end,
    kill = function()
      if handle and not handle:is_closing() then
        handle:kill("sigterm")
      end
    end,
  }
end

function M.transcribe(opts)
  local output = {}
  local stderr = {}
  local args = { opts.node_cmd, opts.helper_path, "transcribe", "--input", opts.input, "--json" }
  if opts.timeout_ms then
    vim.list_extend(args, { "--timeout-ms", tostring(opts.timeout_ms) })
  end
  if opts.max_audio_bytes then
    vim.list_extend(args, { "--max-audio-bytes", tostring(opts.max_audio_bytes) })
  end
  local job = vim.system(args, { text = true }, function(result)
    output[#output + 1] = result.stdout or ""
    stderr[#stderr + 1] = result.stderr or ""
    local decoded = json_decode(table.concat(output))
    vim.schedule(function()
      opts.on_exit(result.code, decoded, redact.text(table.concat(stderr)))
    end)
  end)
  return {
    kill = function()
      if job and job.kill then
        pcall(job.kill, job, "sigterm")
      end
    end,
  }
end

return M
