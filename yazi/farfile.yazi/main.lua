-- Target: Yazi 26.9.1 custom VFS provider API.
local M = {}
local binary = os.getenv("FARFILE_CLIENT") or "FarFile.Client"

local function failure(message)
	return Error.fs { kind = "Other", message = message }
end

local function execute(args)
	local output, err = Command(binary):arg(args):output()
	if not output then
		return nil, err or failure("cannot start FarFile.Client")
	end
	if not output.status.success then
		return nil, failure(output.stderr ~= "" and output.stderr or "FarFile.Client failed")
	end
	return output.stdout
end

-- The private --records format is five NUL-terminated UTF-8 fields per entry.
-- Filenames cannot contain NUL, so this avoids a JSON dependency in Lua.
local function records(data)
	local result, pos = {}, 1
	while pos <= #data do
		local row = {}
		for i = 1, 5 do
			local last = data:find("\0", pos, true)
			if not last then
				return nil, failure("invalid FarFile metadata record")
			end
			row[i], pos = data:sub(pos, last - 1), last + 1
		end
		local size, mtime = tonumber(row[3]), tonumber(row[4])
		if not size or not mtime or (row[2] ~= "dir" and row[2] ~= "file") then
			return nil, failure("invalid FarFile metadata value")
		end
		result[#result + 1] = {
			name = row[1],
			kind = row[2],
			size = size,
			mtime = mtime,
			hidden = row[5] == "1",
		}
	end
	return result
end

local function machine(url) return url.spec.domain end
local function path(url) return tostring(url.path) end

local function metadata(entry)
	return Cha {
		kind = entry.hidden and 2 or 0,
		mode = entry.kind == "dir" and 0x4180 or 0x8180,
		len = entry.size,
		mtime = entry.mtime,
	}
end

local function file(url, entry)
	return File { url = url, cha = metadata(entry) }
end

local function stat(url)
	local output, err = execute { "stat", machine(url), path(url), "--records" }
	if not output then return nil, err end
	local parsed, parse_err = records(output)
	if not parsed then return nil, parse_err end
	if #parsed ~= 1 then return nil, failure("expected one stat record") end
	return parsed[1]
end

local function command(args)
	local output, err = execute(args)
	if not output then return false, err end
	return true
end

function M:Capabilities() return { copy_progressive = 1 } end

function M:ReadDir(job)
	local output, err = execute { "ls", machine(job.url), path(job.url), "--records" }
	if not output then return nil, err end
	local entries, parse_err = records(output)
	if not entries then return nil, parse_err end
	local result = {}
	for _, entry in ipairs(entries) do
		local item = file(job.url:join(entry.name), entry)
		result[#result + 1] = { file = item, cha = item.cha }
	end
	return result
end

function M:File(job)
	local entry, err = stat(job.url)
	return entry and file(job.url, entry), err
end

function M:Metadata(job)
	local entry, err = stat(job.url)
	return entry and metadata(entry), err
end

function M:SymlinkMetadata(job) return self:Metadata(job) end

function M:Revalidate(job)
	local latest, err = self:File { url = job.file.url }
	if not latest then return nil, err end
	local old, new = job.file.cha, latest.cha
	if old.len == new.len and old.mtime == new.mtime and old.is_dir == new.is_dir then
		return nil
	end
	return latest
end

function M:Canonicalize(job) return job.url end
function M:Absolute(job) return job.url end
function M:Casefold(job) return job.url end

function M:Open(job)
	local demand = job.demand
	if not (demand.create or demand.create_new or demand.truncate) then
		local entry, err = stat(job.url)
		return entry and (demand.append and entry.size or 0), err
	end
	local args = { "prepare", machine(job.url), path(job.url) }
	if demand.create then args[#args + 1] = "--create" end
	if demand.create_new then args[#args + 1] = "--create-new" end
	if demand.truncate then args[#args + 1] = "--truncate" end
	if demand.append then args[#args + 1] = "--append" end
	local output, err = execute(args)
	if not output then return nil, err end
	local size = tonumber(output)
	if not size then return nil, failure("invalid open result") end
	return demand.append and size or 0
end

function M:Read(job)
	if job.len == 0 then return "" end
	return execute { "read", machine(job.url), path(job.url), "--offset", tostring(job.offset), "--length", tostring(job.len) }
end

function M:Write(job)
	local child, err = Command(binary)
		:arg { "write", machine(job.url), path(job.url), "--offset", tostring(job.offset), "--length", tostring(#job.bytes) }
		:stdin(Command.PIPED)
		:stderr(Command.PIPED)
		:spawn()
	if not child then return false, err or failure("cannot start FarFile.Client") end
	local ok, write_err = child:write_all(job.bytes)
	if not ok then
		child:start_kill()
		return false, write_err
	end
	local flushed, flush_err = child:flush()
	if not flushed then
		child:start_kill()
		return false, flush_err
	end
	-- The explicit --length lets the client finish without waiting for stdin EOF.
	local output, wait_err = child:wait_with_output()
	if not output then return false, wait_err end
	if not output.status.success then
		return false, failure(output.stderr ~= "" and output.stderr or "FarFile.Client write failed")
	end
	return true
end

function M:CreateDir(job) return command { "mkdir", machine(job.url), path(job.url) } end
function M:RemoveFile(job) return command { "rm", machine(job.url), path(job.url) } end
function M:RemoveDir(job) return command { "rmdir", machine(job.url), path(job.url) } end
function M:RemoveDirAll(job) return command { "rmdir-all", machine(job.url), path(job.url) } end

function M:Rename(job)
	-- In Yazi 26.9.1 `to` is a Path, while `from` is a Url.
	return command { "mv", machine(job.from), path(job.from), tostring(job.to) }
end

function M:Copy(job)
	local output, err = execute { "cp", machine(job.from), path(job.from), machine(job.from), tostring(job.to) }
	if not output then return nil, err end
	local bytes = tonumber(output)
	if not bytes then return nil, failure("invalid copy result") end
	return bytes
end

function M:CopyProgressive(job)
	local bytes, err = self:Copy(job)
	if not bytes then return false, err end
	local sent, send_err = job.tx:send(bytes)
	return sent or false, send_err
end

function M:SetLen(job) return command { "setlen", machine(job.url), path(job.url), tostring(job.size) } end

function M:SetAttrs(job)
	if not job.attrs or not job.attrs.mtime then return true end
	return command { "mtime", machine(job.url), path(job.url), tostring(job.attrs.mtime) }
end

function M:provide(job)
	local operation = self[job.op]
	if not operation then return false, failure("unsupported FarFile operation: " .. tostring(job.op)) end
	return operation(self, job)
end

return M
