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

local function safe_close(handle)
  if handle and not handle:is_closing() then
    pcall(handle.close, handle)
  end
end

local function safe_read_stop(pipe)
  if pipe then
    pcall(pipe.read_stop, pipe)
  end
end

local function close_pipes(...)
  for _, pipe in ipairs({ ... }) do
    safe_read_stop(pipe)
    safe_close(pipe)
  end
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

local function schedule_callback(callback, ...)
  local args = { ... }
  vim.schedule(function()
    pcall(callback, unpack(args))
  end)
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
    close_pipes(stdout, stderr, stdin)
    safe_close(handle)
    schedule_callback(function()
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
    close_pipes(stdout, stderr, stdin)
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
          schedule_callback(opts.on_event, decoded)
        end
      end
    end)
  end)
  stderr:read_start(function(_, chunk)
    if chunk then
      stderr_text[#stderr_text + 1] = chunk
    end
  end)
  local function write_stdin(text)
    if not stdin or stdin:is_closing() then
      return false
    end
    local ok = pcall(stdin.write, stdin, text)
    return ok
  end
  return {
    stop = function()
      return write_stdin("stop\n")
    end,
    discard = function()
      return write_stdin("discard\n")
    end,
    kill = function(signal)
      if handle and not handle:is_closing() then
        pcall(handle.kill, handle, signal or "sigterm")
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
  local ok, job = pcall(vim.system, args, { text = true }, function(result)
    output[#output + 1] = result.stdout or ""
    stderr[#stderr + 1] = result.stderr or ""
    local decoded = json_decode(table.concat(output))
    schedule_callback(opts.on_exit, result.code, decoded, redact.text(table.concat(stderr)))
  end)
  if not ok then
    return nil, "failed to start voice transcription"
  end
  return {
    kill = function(signal)
      if job and job.kill then
        pcall(job.kill, job, signal or "sigterm")
      end
    end,
  }
end

return M
